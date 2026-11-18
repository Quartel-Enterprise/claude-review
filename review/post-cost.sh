#!/usr/bin/env bash
# Posts what a Claude review run cost as a comment on its pull request. Usage:
#
#   EXECUTION_FILE=<the session's execution file> post-cost.sh <pr-number>
#
# The cost is the "total_cost_usd" Claude Code reports in the session's final result, which also holds
# the review's fix, since both run in one session and the result has no figure for each. It is
# computed by Claude Code from the tokens it counted, not read off an invoice. With a subscription
# token (OAUTH=true) nothing is billed per token, so the comment says the figure is what the same
# tokens would cost through the API. A run's comment carries the run in a hidden tag, so a re-run of
# the step updates it instead of adding a second one.
#
# It never fails the review: whatever goes wrong here is a warning, and the exit status is 0. It
# posts with the workflow's token (pull-requests: write), after the session, so it reads no secret.
set -uo pipefail

pr=${1:?usage: post-cost.sh <pr-number>}
repo=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}
file=${EXECUTION_FILE:-}
warn() { echo "::warning::$*" >&2; }

if [ -z "$file" ] || [ ! -f "$file" ]; then
  echo "The session left no execution file, so there is no cost to report."
  exit 0
fi

# The last result of the session, reduced to what the comment shows. A model id is only kept when it
# looks like one, and every number must be a number, so nothing else reaches the public comment.
result=$(jq -c '[.[] | select(.type == "result")] | last
  | select(. != null and (.total_cost_usd | type == "number"))
  | {cost: .total_cost_usd,
     turns: (.num_turns | if type == "number" then . else null end),
     seconds: (.duration_ms | if type == "number" then (. / 1000 | round) else null end),
     models: [(.modelUsage // {}) | to_entries[]
       | select((.key | test("^[A-Za-z0-9._:-]+(\\[[0-9a-z]+\\])?$")) and (.value.costUSD | type == "number"))
       | {model: .key, cost: .value.costUSD}] | sort_by(-.cost)}' "$file" 2> /dev/null)
if [ -z "$result" ]; then
  echo "The session's result holds no cost, so there is none to report."
  exit 0
fi

run_tag=""
[ -z "${GITHUB_RUN_ID:-}" ] || run_tag="<!-- claude-review-cost run ${GITHUB_RUN_ID} -->"
run_url=""
[ -z "${GITHUB_RUN_ID:-}" ] || run_url="${GITHUB_SERVER_URL:-https://github.com}/${repo}/actions/runs/${GITHUB_RUN_ID}"

body=$(jq -r --arg fix "${FIX:-false}" --arg oauth "${OAUTH:-false}" --arg url "$run_url" --arg tag "$run_tag" '
  def usd: if . < 0.01 then "$" + (. * 10000 | round / 10000 | tostring) else "$" + (. * 100 | round / 100 | tostring) end;
  "### Review cost\n\n**\(.cost | usd)**"
  + (if $fix == "true" then ", the review and its fix commit together" else "" end)
  + (if (.models | length) > 1 then "\n\n" + ([.models[] | "- `\(.model)`: \(.cost | usd)"] | join("\n")) else "" end)
  + "\n\n_Reported by Claude Code from the tokens it counted, not an invoice"
  + (if $oauth == "true" then "; the run uses a subscription, so nothing is billed per token and this is what the same tokens would cost through the API" else "" end)
  + (if .turns != null then ". \(.turns) turns" else "" end)
  + (if .seconds != null then ", \(.seconds)s" else "" end)
  + (if $url != "" then ". [The run](\($url))" else "" end)
  + "._"
  + (if $tag != "" then "\n\n" + $tag else "" end)' <<< "$result")

# Updates this run's comment when there is one (a re-run of the step), else adds it.
existing=""
if [ -n "$run_tag" ]; then
  existing=$(RUN_TAG="$run_tag" gh api --paginate "repos/$repo/issues/$pr/comments" \
    --jq '.[] | select(.body | contains(env.RUN_TAG)) | .id' 2> /dev/null | tail -1)
fi
for attempt in 1 2 3; do
  if [ -n "$existing" ]; then
    out=$(jq -n --arg body "$body" '{body: $body}' | gh api --method PATCH "repos/$repo/issues/comments/$existing" --input - --jq .html_url 2>&1) && break
  else
    out=$(jq -n --arg body "$body" '{body: $body}' | gh api --method POST "repos/$repo/issues/$pr/comments" --input - --jq .html_url 2>&1) && break
  fi
  # A refusal (a token without pull-requests: write) won't change by trying again.
  grep -qE 'HTTP (401|403|404|422)' <<< "$out" && break
  [ "$attempt" -lt 3 ] && sleep $((attempt * 5))
done
if [[ "$out" == https://* ]]; then
  echo "The cost was posted: $out"
else
  warn "The review's cost couldn't be posted ($(tr '\n' ' ' <<< "$out" | cut -c1-200))."
fi
exit 0
