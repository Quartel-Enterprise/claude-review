#!/usr/bin/env bash
# Commits the fixes an AI review applied to the working tree and pushes the commit to the pull
# request's branch, then prints the commit SHA. Usage:
#
#   commit-fixes.sh <<'JSON'
#   [{"file": "a/b.kt", "line": 12, "summary": "...", "outcome": "fixed"}]
#   JSON
#
# Inside Claude's Stop hook, origin already carries the Claude GitHub App token. Outside Claude's
# session (Gemini-only or fallback step), FIX_PUSH_TOKEN is passed via an ephemeral http.extraheader
# so no credential is ever written to .git/config. Changes under .github, .claude, or .gemini are
# always refused, as are untracked files or fixes adding token-shaped strings.
set -euo pipefail

findings=$(cat)
cd "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is not set}"
event=${GITHUB_EVENT_PATH:?GITHUB_EVENT_PATH is not set}
branch=$(jq -r '.pull_request.head.ref // ""' "$event")
head_sha=$(jq -r '.pull_request.head.sha // ""' "$event")
bot_login=${BOT_LOGIN:-github-actions[bot]}
bot_id=${BOT_ID:-41898282}
push_token=${FIX_PUSH_TOKEN:-}

safe_git() { git -c core.hooksPath=/dev/null -c core.fsmonitor=false -c core.quotePath=false "$@"; }
fail() {
  echo "commit-fixes: $*" >&2
  exit 1
}

fixed=$(jq -c '[.[]? | select(type == "object" and .outcome == "fixed")]' <<< "$findings" 2> /dev/null) || fixed='[]'
[ "$(jq 'length' <<< "$fixed")" -gt 0 ] || fail "no finding is marked fixed"
[ -n "$branch" ] && [ -n "$head_sha" ] || fail "the event names no pull request branch"
[ "$(safe_git rev-parse HEAD)" = "$head_sha" ] || fail "the checkout is no longer the reviewed head"

# Restore any tracked symlinks removed before the review.
if [ -n "$(safe_git ls-files -d)" ] &&
  ! restored=$(safe_git ls-files -d -z | safe_git checkout --pathspec-from-file=- --pathspec-file-nul 2>&1); then
  fail "the files removed before the review couldn't be restored: $(tr '\n' ' ' <<< "$restored")"
fi

changed=$(safe_git diff --name-only)
[ -n "$changed" ] || fail "the working tree has no change"
if grep -qE '^\.(github|claude|gemini)/' <<< "$changed"; then
  fail "the fixes change files under .github, .claude or .gemini"
fi
untracked=$(safe_git ls-files --others --exclude-standard)
if [ -n "$untracked" ]; then
  fail "the working tree has untracked files: $(tr '\n' ' ' <<< "$untracked")"
fi

redact() { "$(dirname "$0")/post-review.sh" --redact; }
added=$(safe_git diff -U0 | awk '/^diff --git /{hunk = 0} /^@@/{hunk = 1; next} hunk && /^\+/')
[ "$(redact <<< "$added")" = "$added" ] || fail "the fixes add a token-shaped string"

# Format commit message title from active providers ("AI", "Claude", "Gemini", or "Claude + Gemini").
provider_label="AI"
if [ -n "${PROVIDERS:-}" ]; then
  provider_label=$(jq -rn --arg p "$PROVIDERS" '
    $p | split(",") | map(gsub("^\\s+|\\s+$"; "") | select(. != "") | ascii_downcase
      | {claude: "Claude", gemini: "Gemini"}[.] // (.[0:1] | ascii_upcase) + .[1:])
    | if length == 1 then .[0] else "AI" end')
fi

message="fix: apply the ${provider_label} review findings

$(jq -r '.[] | "- " + (.summary // "Finding" | tostring | gsub("\\s+"; " "))' <<< "$fixed" | redact)"

safe_git \
  -c "user.name=$bot_login" \
  -c "user.email=${bot_id}+${bot_login}@users.noreply.github.com" \
  commit --all --no-verify --quiet --message "$message" > /dev/null 2>&1 || fail "git commit failed"

# A plain push, never forced: a branch that moved during the review keeps its commits.
push_args=()
if [ -n "$push_token" ]; then
  server_url=${GITHUB_SERVER_URL:-https://github.com}
  basic_auth=$(printf 'x-access-token:%s' "$push_token" | base64 | tr -d '\n')
  # Reset any pre-existing multi-valued extraheader before setting our Authorization header.
  push_args=(
    -c "http.${server_url}/.extraheader="
    -c "http.${server_url}/.extraheader=AUTHORIZATION: basic ${basic_auth}"
  )
fi

error=""
for attempt in 1 2; do
  if error=$(safe_git "${push_args[@]}" push --quiet origin "HEAD:refs/heads/$branch" 2>&1 > /dev/null); then
    safe_git rev-parse HEAD
    exit 0
  fi
  [ "$attempt" -lt 2 ] && sleep 5
done
reason=$(sed -E 's#://[^/@[:space:]]+@#://***@#g' <<< "$error" | { grep -E '^(remote:|error:|fatal:| ?!)' || true; } | tail -n 3 | tr '\n' ' ')
fail "git push failed: ${reason:-no error from git}"
