#!/bin/bash

# The two questions the workflows around the review gate ask GitHub, answered in one place so they
# agree on which threads hold the checks and which runs were held:
#   review_gate.sh open-threads <pr> [--review-only]
#   review_gate.sh rerun-held <sha>
# open-threads prints how many review threads of the pull request are unresolved; with --review-only,
# only the ones the AI review opened (BOT_LOGIN or github-actions[bot]). rerun-held re-runs every
# run on the commit whose gate held its checks for those threads, and prints how many it re-ran.
# Both read GH_REPO and GH_TOKEN, and exit non-zero when GitHub's API fails. open-threads also reads
# BOT_LOGIN (required with --review-only), and rerun-held reads HOLD_STEP.
set -euo pipefail

export HOLD_STEP="${HOLD_STEP:-Hold for the open threads}"
export BOT_LOGIN="${BOT_LOGIN:-}"

open_threads() {
  local pr=$1 filter='.' threads
  if [ "${2:-}" = --review-only ]; then
    : "${BOT_LOGIN:?BOT_LOGIN is required with --review-only}"
    # The review's bot user's threads, or github-actions[bot]'s when the fallback posting step posted.
    # GraphQL names bots without the [bot] suffix, so __typename tells a bot from a user of the same name.
    filter='select(.comments.nodes[0].author // {} | .__typename == "Bot"
      and (.login + "[bot]" == env.BOT_LOGIN or .login == "github-actions"))'
  fi
  # The $ names in the query are GraphQL variables.
  # shellcheck disable=SC2016
  threads=$(gh api graphql --paginate \
    -F owner="${GH_REPO%/*}" \
    -F name="${GH_REPO#*/}" \
    -F number="$pr" \
    -f query='query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          reviewThreads(first: 100, after: $endCursor) {
            nodes { id isResolved comments(first: 1) { nodes { author { __typename login } } } }
            pageInfo { hasNextPage endCursor }
          }
        }
      }
    }' \
    --jq ".data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved | not) | $filter | .id")
  grep -c . <<< "$threads" || true
}

rerun_held() {
  local sha=$1 runs run held rerun=0
  runs=$(gh api "repos/$GH_REPO/actions/runs?head_sha=$sha&event=pull_request&per_page=100" \
    --jq '.workflow_runs[] | select(.status == "completed" and .conclusion == "failure") | .id')
  for run in $runs; do
    held=$(gh api "repos/$GH_REPO/actions/runs/$run/jobs" \
      --jq '[.jobs[] | .steps[]? | select(.name == env.HOLD_STEP and .conclusion == "failure")] | length')
    if [ "$held" -gt 0 ]; then
      gh api --method POST "repos/$GH_REPO/actions/runs/$run/rerun" > /dev/null
      rerun=$((rerun + 1))
    fi
  done
  echo "$rerun"
}

: "${GH_REPO:?GH_REPO is not set}"
case "${1:-}" in
  open-threads) open_threads "${2:?usage: review_gate.sh open-threads <pr> [--review-only]}" "${3:-}" ;;
  rerun-held) rerun_held "${2:?usage: review_gate.sh rerun-held <sha>}" ;;
  *)
    echo "usage: review_gate.sh open-threads <pr> [--review-only] | rerun-held <sha>" >&2
    exit 2
    ;;
esac
