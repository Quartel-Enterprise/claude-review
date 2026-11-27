#!/usr/bin/env bash
# Stop hook of a Claude review session (see review/action.yml): when Claude's reply ends, tags
# Claude's findings with provider="claude", merges them with Gemini's findings if Gemini also ran
# in this job, optionally commits fixes through commit-fixes.sh, and posts one consolidated pull
# request review through post-review.sh while the App token is active in the session.
#
#   stop-hook.sh <state dir> <started> <fix: true|false>
set -uo pipefail

dir=$(cd "$(dirname "$0")" && pwd)
state=${1:-}
started=${2:-}
fix=${3:-false}
if [ -z "$state" ] || [ ! -d "$state" ]; then
  echo "stop-hook: no state directory, the action's posting step takes over" >&2
  exit 0
fi
log="$state/.hook-log"
note() { echo "stop-hook: $*" | tee -a "$log" >&2; }

input=$(cat)

if [ -f "$state/.posted" ]; then
  note "the review is already posted ($(cat "$state/.posted")), nothing more to do"
  exit 0
fi

pr=${PR_NUMBER:-$(sed -n 's#^refs/pull/\([0-9]*\)/merge$#\1#p' <<< "${GITHUB_REF:-}")}
if [ -z "$pr" ]; then
  note "no pull request number (PR_NUMBER or GITHUB_REF)"
  exit 0
fi
if [ -z "${PR_HEAD_SHA:-}" ] && [ -n "${GITHUB_EVENT_PATH:-}" ] && [ -f "$GITHUB_EVENT_PATH" ]; then
  PR_HEAD_SHA=$(jq -r '.pull_request.head.sha // ""' "$GITHUB_EVENT_PATH")
  PR_BASE_SHA=$(jq -r '.pull_request.base.sha // ""' "$GITHUB_EVENT_PATH")
  export PR_HEAD_SHA PR_BASE_SHA
fi

if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  note "the Claude OAuth token is in the hook's environment"
else
  note "the Claude OAuth token is not in the hook's environment"
fi

replies=$(jq -r '.last_assistant_message // "" | select(length > 0) | @base64' <<< "$input")
if [ -n "$replies" ]; then
  note "reading the last assistant message from the hook input"
else
  transcript=$(jq -r '.transcript_path // ""' <<< "$input")
  if [ -z "$transcript" ] || [ ! -f "$transcript" ]; then
    note "no last assistant message and no transcript (${transcript:-no path})"
    exit 0
  fi
  replies=$(jq -rs '[.[] | select(.type == "assistant")
    | .message.content
    | if type == "array" then map(select(.type == "text") | .text) | join("\n") else tostring end
    | select(length > 0)] | reverse | .[0:5] | .[] | @base64' "$transcript")
  note "reading the transcript ($(wc -l < "$transcript") lines, $(grep -c . <<< "$replies") assistant messages with text tried)"
fi

claude_findings=""
while read -r encoded; do
  [ -n "$encoded" ] || continue
  reply=$(base64 -d <<< "$encoded")
  claude_findings=$(python3 "$dir/extract-findings.py" <<< "$reply")
  if [ -n "$claude_findings" ]; then
    note "Claude findings list found: $(jq 'length' <<< "$claude_findings") finding(s), in a reply of ${#reply} characters"
    break
  fi
  note "no findings list in a reply of ${#reply} characters"
done <<< "$replies"

if [ -z "$claude_findings" ]; then
  note "no Claude findings list, the action's posting step takes over"
  exit 0
fi

# Tag Claude findings with provider="claude" and merge with Gemini findings if present.
jq -c 'map(if type == "object" then . + {provider: "claude"} else . end)' <<< "$claude_findings" \
  > "$state/claude-findings.json"

merge_args=("claude:$state/claude-findings.json")
provider_warnings=""
if [[ ",${PROVIDERS:-}," == *",gemini,"* ]]; then
  if [ -f "$state/gemini-findings.json" ]; then
    merge_args=("gemini:$state/gemini-findings.json" "${merge_args[@]}")
    note "merging Gemini ($(jq 'length' "$state/gemini-findings.json") finding(s)) and Claude findings"
  else
    provider_warnings="Gemini ended without a findings list; only Claude findings are shown."
    note "Gemini left no findings list; posting Claude findings with warning"
  fi
fi

findings=$(python3 "$dir/merge-findings.py" "${merge_args[@]}")
if [ -z "$findings" ]; then
  note "merged findings empty, the action's posting step takes over"
  exit 0
fi

if [ -n "$started" ] && url=$(STARTED="$started" "$dir/post-review.sh" --already "$pr"); then
  echo "$url" > "$state/.posted"
  note "a review was already posted since the review started: $url"
  exit 0
fi

if [ "$fix" = true ] && [ ! -f "$state/.pushed" ]; then
  if sha=$("$dir/commit-fixes.sh" <<< "$findings" 2> "$state/.commit-log"); then
    echo "$sha" > "$state/.pushed"
    note "pushed the fixes as $sha"
  else
    note "no fixes pushed: $(tr '\n' ' ' < "$state/.commit-log")"
  fi
fi
if [ -f "$state/.pushed" ]; then
  FIXED_IN=$(cat "$state/.pushed")
  export FIXED_IN
fi

if url=$(PROVIDER_WARNINGS="$provider_warnings" "$dir/post-review.sh" "$pr" <<< "$findings"); then
  echo "$url" > "$state/.posted"
  note "posted $url"
else
  note "post-review.sh failed, the action's posting step takes over"
fi
exit 0
