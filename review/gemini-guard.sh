#!/usr/bin/env bash
# BeforeTool hook for Gemini CLI review sessions (see review/action.yml and review/gemini-run.sh).
# Enforces the same security boundary as Claude's bash-guard.sh and Read/Edit rules:
# - run_shell_command: single plain line of the allowlisted read-only gh/git commands, no quoting,
#   expansion, pipes, redirections, or gh --jq/-q/--template/-t.
# - read_file / grep_search / glob / list_directory: target path must stay inside WORKSPACE or
#   REVIEWED_DIR, never entering .git, /proc, /sys, /etc, /tmp, RUNNER_TEMP, or credential files.
# - replace: allowed only when FIX=true, on an existing file inside WORKSPACE, never under .git,
#   .github, .claude, .gemini, or .agent-memory.
# - Any other tool (write_file, web_fetch, google_web_search, etc.): denied.
#
# Gemini CLI BeforeTool protocol: reads JSON from stdin, writes JSON decision to stdout, exits 0.
# Usage: gemini-guard.sh <state dir> <workspace> <reviewed dir> <fix: true|false>
set -uo pipefail

state=${1:-}
workspace=${2:-}
reviewed=${3:-}
fix=${4:-false}
log=${state:+$state/.guard-log}

input=$(cat)

deny() {
  local label=$1 reason=$2
  if [ -n "$log" ]; then
    echo "$label" >> "$log" 2> /dev/null || true
  fi
  jq -cn --arg reason "Refused by the review's guard: $reason" '{decision: "deny", reason: $reason}'
  exit 0
}

allow() {
  echo '{"decision":"allow"}'
  exit 0
}

tool_name=$(jq -r '.tool_name // ""' <<< "$input" 2> /dev/null) || deny "Tool(?)" "the guard couldn't read the tool call"
[ -n "$tool_name" ] || deny "Tool(?)" "missing tool name"

resolve_path() {
  local raw=$1 base=$2
  python3 - "$raw" "$base" <<'PY'
import os, sys
raw, base = sys.argv[1], sys.argv[2]
if not raw:
    print(os.path.realpath(base))
elif os.path.isabs(raw):
    print(os.path.realpath(raw))
else:
    print(os.path.realpath(os.path.join(base, raw)))
PY
}

is_inside() {
  local target=$1 dir=$2
  [ -n "$dir" ] || return 1
  local real_dir
  real_dir=$(resolve_path "$dir" "/")
  [ "$target" = "$real_dir" ] || [[ "$target" == "$real_dir/"* ]]
}

check_read_path() {
  local raw=$1
  local resolved ws_real
  ws_real=$(resolve_path "$workspace" "/")
  resolved=$(resolve_path "$raw" "$ws_real")
  case "$resolved" in
    "$ws_real/.git" | "$ws_real/.git/"*)
      deny "$tool_name" "reading .git is not allowed"
      ;;
  esac
  if is_inside "$resolved" "$ws_real"; then
    return 0
  fi
  if [ -n "$reviewed" ] && is_inside "$resolved" "$reviewed"; then
    return 0
  fi
  deny "$tool_name" "path '$raw' is outside the checkout"
}

check_edit_path() {
  local raw=$1
  [ -n "$raw" ] || deny "$tool_name" "missing file_path"
  local resolved ws_real
  ws_real=$(resolve_path "$workspace" "/")
  resolved=$(resolve_path "$raw" "$ws_real")
  if ! is_inside "$resolved" "$ws_real"; then
    deny "$tool_name" "path '$raw' is outside the checkout"
  fi
  case "$resolved" in
    "$ws_real/.git" | "$ws_real/.git/"* | \
    "$ws_real/.github" | "$ws_real/.github/"* | \
    "$ws_real/.claude" | "$ws_real/.claude/"* | \
    "$ws_real/.gemini" | "$ws_real/.gemini/"* | \
    "$ws_real/.agent-memory" | "$ws_real/.agent-memory/"*)
      deny "$tool_name" "editing under .git, .github, .claude, .gemini or .agent-memory is not allowed"
      ;;
  esac
  if [ ! -f "$resolved" ]; then
    deny "$tool_name" "only existing tracked files may be edited"
  fi
}

case "$tool_name" in
  run_shell_command)
    command=$(jq -er '.tool_input.command | strings' <<< "$input" 2> /dev/null) ||
      deny "Bash(?)" "the guard couldn't read the command"

    bash_label() {
      local -a w=()
      local shown="" i
      read -r -a w <<< "$command" || true
      for i in 0 1 2; do
        [[ "${w[i]:-}" =~ ^[A-Za-z][A-Za-z0-9._-]*$ ]] || break
        shown+="${shown:+ }${w[i]}"
        [ "$i" -eq 1 ] && [ "${w[0]}" != gh ] && break
      done
      echo "Bash(${shown:-?})"
    }

    case "$command" in
      *$'\n'* | *$'\r'*)
        deny "$(bash_label)" "the command spans several lines"
        ;;
    esac
    if ! [[ "$command" =~ ^[A-Za-z0-9\ _.,:/=@+-]+$ ]]; then
      deny "$(bash_label)" "only letters, digits, spaces and _ . , : / = @ + - are allowed"
    fi

    read -r -a words <<< "$command"
    case "${words[0]:-}/${words[1]:-}/${words[2]:-}" in
      gh/pr/view | gh/pr/diff | gh/pr/list | gh/issue/view | gh/issue/list | gh/search/?*) ;;
      git/status/*) ;;
      git/branch/--show-current)
        [ "${#words[@]}" -eq 3 ] || deny "$(bash_label)" "git branch only runs as git branch --show-current"
        ;;
      *)
        deny "$(bash_label)" "only gh pr view/diff/list, gh issue view/list, gh search, git status and git branch --show-current run here"
        ;;
    esac

    for word in "${words[@]}"; do
      case "$word" in
        --jq | --jq=* | --template | --template=*)
          deny "$(bash_label)" "gh's --jq and --template can read the environment"
          ;;
        --*) ;;
        -*[qt]*)
          deny "$(bash_label)" "gh's -q and -t can read the environment, even with a value attached"
          ;;
      esac
    done

    dir_path=$(jq -r '.tool_input.dir_path // ""' <<< "$input" 2> /dev/null)
    if [ -n "$dir_path" ]; then
      check_read_path "$dir_path"
    fi
    allow
    ;;

  read_file)
    path=$(jq -r '.tool_input.file_path // .tool_input.path // ""' <<< "$input" 2> /dev/null)
    [ -n "$path" ] || deny "$tool_name" "missing file path"
    check_read_path "$path"
    allow
    ;;

  grep_search | glob | list_directory)
    path=$(jq -r '.tool_input.dir_path // .tool_input.path // ""' <<< "$input" 2> /dev/null)
    if [ -n "$path" ]; then
      check_read_path "$path"
    fi
    allow
    ;;

  update_topic)
    # Gemini CLI's internal UI topic label tool (no filesystem, shell, or network access).
    allow
    ;;

  replace)
    if [ "$fix" != true ]; then
      deny "$tool_name" "editing files is disabled unless fix is true"
    fi
    path=$(jq -r '.tool_input.file_path // .tool_input.path // ""' <<< "$input" 2> /dev/null)
    check_edit_path "$path"
    allow
    ;;

  *)
    deny "$tool_name" "tool '$tool_name' is not allowed during code review"
    ;;
esac
