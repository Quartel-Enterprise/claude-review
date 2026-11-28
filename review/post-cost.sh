#!/usr/bin/env bash
# Aggregates cost and timing for an AI review run (Claude, Gemini, or both), writes machine-readable
# summary outputs to STATE/summary.json, and optionally posts one comment on the pull request.
#
# Usage:
#   post-cost.sh <pr-number>
#
# Environment:
#   GITHUB_REPOSITORY, CLAUDE_EXECUTION_FILE, GEMINI_EXECUTION_FILE, STATE,
#   CLAUDE_MODEL, CLAUDE_EFFORT, GEMINI_MODEL, GEMINI_EFFORT,
#   FIX, CLAUDE_OAUTH, SHOW_MICRO_COSTS, PROVIDERS, POST_COST (default: true)
#
# Never fails the review: warnings are emitted on error and exit status is always 0.
set -uo pipefail

dir=$(cd "$(dirname "$0")" && pwd)
pr=${1:?usage: post-cost.sh <pr-number>}
repo=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}
post_cost=${POST_COST:-true}
state=${STATE:-}
warn() { echo "::warning::$*" >&2; }

fixed=false
{ [ "${FIX:-false}" = true ] && [ -n "$state" ] && [ -f "$state/.pushed" ]; } && fixed=true
run_tag=""
if [ -n "${GITHUB_RUN_ID:-}" ]; then
  run_tag="<!-- ai-review-cost run ${GITHUB_RUN_ID} attempt ${GITHUB_RUN_ATTEMPT:-1}${PROVIDERS:+ providers ${PROVIDERS}} -->"
fi
run_url=""
[ -z "${GITHUB_RUN_ID:-}" ] || run_url="${GITHUB_SERVER_URL:-https://github.com}/${repo}/actions/runs/${GITHUB_RUN_ID}"

summary=$(
  FIXED="$fixed" \
  RUN_URL="$run_url" \
  RUN_TAG="$run_tag" \
  python3 "$dir/summarize-cost.py" 2> /dev/null
) || summary=""

if [ -z "$summary" ]; then
  echo "No cost or timing data was available to summarize."
  exit 0
fi

if [ -n "$state" ] && [ -d "$state" ]; then
  printf '%s\n' "$summary" > "$state/summary.json"
fi

if [ "$post_cost" != true ]; then
  exit 0
fi

body=$(jq -r '.body // ""' <<< "$summary" 2> /dev/null)
if [ -z "$body" ]; then
  echo "The session left no cost or timing summary to report."
  exit 0
fi

find_comment() {
  [ -n "$run_tag" ] || return 0
  RUN_TAG="$run_tag" gh api --paginate "repos/$repo/issues/$pr/comments" \
    --jq '.[] | select(.user.login == "github-actions[bot]" and (.body | contains(env.RUN_TAG))) | .id' 2> /dev/null | tail -1
}

existing=$(find_comment)
url=""
err=$(mktemp)
trap 'rm -f "$err"' EXIT
for attempt in 1 2 3; do
  if [ "$attempt" -gt 1 ] && [ -z "$existing" ]; then
    existing=$(find_comment)
  fi
  if [ -n "$existing" ]; then
    method=PATCH
    endpoint="repos/$repo/issues/comments/$existing"
  else
    method=POST
    endpoint="repos/$repo/issues/$pr/comments"
  fi
  if out=$(jq -n --arg body "$body" '{body: $body}' | gh api --method "$method" "$endpoint" --input - --jq .html_url 2> "$err"); then
    url=$out
    break
  fi
  grep -qE 'HTTP (401|403|404|422)' "$err" && break
  [ "$attempt" -lt 3 ] && sleep $((attempt * 5))
done
if [ -n "$url" ]; then
  echo "The cost & timing summary was posted: $url"
else
  warn "The review's cost couldn't be posted (does the job have pull-requests: write?)."
fi
exit 0
