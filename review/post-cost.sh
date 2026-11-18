#!/usr/bin/env bash
# Posts what a Claude review run cost as a comment on its pull request. Usage:
#
#   EXECUTION_FILE=<the session's execution file> post-cost.sh <pr-number>
#
# The cost is the "total_cost_usd" Claude Code reports in the session's final result, which also holds
# the review's fix, since both run in one session and the result has no figure for each. It is
# computed by Claude Code from the tokens it counted, not read off an invoice, and it is a guess at
# the default model's rate for a model Claude Code has no price for. With a subscription token
# (OAUTH=true) nothing is billed per token, so the comment says the figure is what the same tokens
# would cost through the API. STATE is the directory of the hook's markers: its .pushed says the fix
# commit was pushed, which the comment then mentions.
#
# A comment carries its run and attempt in a hidden tag: a retry of this step updates it, while a
# re-run of the job, which pays for a new session, gets a comment of its own. Only a comment of the
# workflow's token counts as this script's, so another user's comment with the same tag is left alone.
# A result with no cost, or a zero one (a session that crashed or never started reports zeros), posts
# nothing: the posting step already tells the pull request such a run ended without a review.
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
  | select(. != null and (.total_cost_usd | type == "number") and .total_cost_usd > 0)
  | {cost: .total_cost_usd,
     turns: (.num_turns | if type == "number" then . else null end),
     seconds: (.duration_ms | if type == "number" then (. / 1000 | round) else null end),
     models: [(.modelUsage // {}) | to_entries[]
       | select((.key | test("^[A-Za-z0-9._:-]+(\\[[0-9a-z]+\\])?$")) and (.value.costUSD | type == "number"))
       | {model: .key, cost: .value.costUSD}] | sort_by(-.cost)}' "$file" 2> /dev/null)
if [ -z "$result" ]; then
  echo "The session's result holds no cost, or a zero one, so there is none to report."
  exit 0
fi

fixed=false
{ [ "${FIX:-false}" = true ] && [ -n "${STATE:-}" ] && [ -f "$STATE/.pushed" ]; } && fixed=true
run_tag=""
[ -z "${GITHUB_RUN_ID:-}" ] || run_tag="<!-- claude-review-cost run ${GITHUB_RUN_ID} attempt ${GITHUB_RUN_ATTEMPT:-1} -->"
run_url=""
[ -z "${GITHUB_RUN_ID:-}" ] || run_url="${GITHUB_SERVER_URL:-https://github.com}/${repo}/actions/runs/${GITHUB_RUN_ID}"

# shellcheck disable=SC2016 # the $ names are jq's, not the shell's
body=$(jq -r --arg fixed "$fixed" --arg model "${MODEL:-}" --arg effort "${EFFORT:-}" --arg oauth "${OAUTH:-false}" --arg url "$run_url" --arg tag "$run_tag" '
  # Two decimals, or four for a figure under a cent, so a small one still shows.
  def usd: if . > 0 and . < 0.01 then "$" + (. * 10000 | round / 10000 | tostring)
    else (. * 100 | round) as $cents
      | "$\($cents / 100 | floor).\($cents % 100 | tostring | if length < 2 then "0" + . else . end)" end;
  # The model the review runs on is the one the model input names (an alias such as opus matches
  # claude-opus-5-5), else the most expensive one. The others are calls of the same session that the
  # result gives no purpose for, and the effort is the review skill level, set for the review only.
  ($model | ascii_downcase | sub("\\[[0-9a-z]+\\]$"; "")) as $wanted
  | . as $r
  | (([$r.models[] | select($wanted != "" and (.model | ascii_downcase | contains($wanted)))] | first) // $r.models[0] | .model?) as $main
  | "### Review cost\n\n**\(.cost | usd)**"
  + (if (.models | length) > 0 then "\n\n| Model | Effort | Used for | Cost |\n| --- | --- | --- | --- |\n"
      + ([.models[] | . as $m
        | "| `\($m.model)` | " + (if $m.model == $main and $effort != "" then "`\($effort)`" else "–" end)
        + " | " + (if $m.model == $main then (if $fixed == "true" then "the review and its fix commit" else "the review" end) else "other calls of the session" end)
        + " | \($m.cost | usd) |"] | join("\n")) else "" end)
  + "\n\n_Reported by Claude Code from the tokens it counted, not an invoice"
  + (if $oauth == "true" then "; the run uses a subscription, so nothing is billed per token and this is what the same tokens would cost through the API" else "" end)
  + (if .turns != null then ". \(.turns) turns" else "" end)
  + (if .seconds != null then ", \(.seconds)s" else "" end)
  + (if $url != "" then ". [The run](\($url))" else "" end)
  + "._"
  + (if $tag != "" then "\n\n" + $tag else "" end)' <<< "$result")

# The id of this run's comment, when the workflow's token already posted one.
find_comment() {
  [ -n "$run_tag" ] || return 0
  RUN_TAG="$run_tag" gh api --paginate "repos/$repo/issues/$pr/comments" \
    --jq '.[] | select(.user.login == "github-actions[bot]" and (.body | contains(env.RUN_TAG))) | .id' 2> /dev/null | tail -1
}

# Updates this run's comment when there is one, else adds it. Creating a comment isn't idempotent:
# before each retry, a comment of this run means GitHub took the request whose answer was lost.
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
  # A refusal (a token without pull-requests: write, a comment that is gone) won't change by trying
  # again; only a failure with no HTTP answer, or a server error, is retried. gh's message is only
  # matched here, never printed.
  grep -qE 'HTTP (401|403|404|422)' "$err" && break
  [ "$attempt" -lt 3 ] && sleep $((attempt * 5))
done
if [ -n "$url" ]; then
  echo "The cost was posted: $url"
else
  warn "The review's cost couldn't be posted (does the job have pull-requests: write?)."
fi
exit 0
