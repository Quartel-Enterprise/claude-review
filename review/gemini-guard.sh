#!/usr/bin/env bash
# BeforeTool hook for Gemini CLI review sessions (see review/action.yml and review/gemini-run.sh).
# Enforces the same security boundary as Claude's bash-guard.sh and Read/Edit rules:
# - run_shell_command: single plain line of the allowlisted read-only gh/git commands, no quoting,
#   expansion, pipes, redirections, or gh --jq/-q/--template/-t.
# - read_file / grep_search / glob / list_directory: every path parameter must stay inside
#   WORKSPACE or REVIEWED_DIR, never entering .git, /proc, /sys, /etc, /tmp, RUNNER_TEMP, or
#   credential files; glob/grep patterns and includes cannot traverse upward ('..'), start with
#   '/' or '~', or target '.git'.
# - replace: allowed only when FIX=true, on an existing file inside WORKSPACE, never under .git,
#   .github, .claude, .gemini, or .agent-memory.
# - Any other tool (write_file, web_fetch, google_web_search, etc.): denied.
# - Fails closed on any jq parse error.
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

tool_name=$(jq -er '.tool_name | strings' <<< "$input" 2> /dev/null) || deny "Tool(?)" "the guard couldn't read the tool call"
[ -n "$tool_name" ] || deny "Tool(?)" "missing tool name"

resolve_path() {
  local raw=$1 base=$2
  python3 - "$raw" "$base" <<'PY'
import os, sys
raw, base = sys.argv[1], sys.argv[2]
if not raw:
    print(os.path.realpath(base))
else:
    expanded = os.path.expanduser(raw)
    if expanded.startswith("~"):
        sys.exit(1)
    if os.path.isabs(expanded):
        print(os.path.realpath(expanded))
    else:
        print(os.path.realpath(os.path.join(base, expanded)))
PY
}

ws_real=""
rev_real=""
if [ -n "$workspace" ]; then
  ws_real=$(resolve_path "$workspace" "/") || ws_real=""
fi
if [ -n "$reviewed" ]; then
  rev_real=$(resolve_path "$reviewed" "/") || rev_real=""
fi

is_inside() {
  local target=$1 real_dir=$2
  [ -n "$real_dir" ] || return 1
  [ "$target" = "$real_dir" ] || [[ "$target" == "$real_dir/"* ]]
}

check_read_path() {
  local raw=$1
  local resolved
  [ -n "$ws_real" ] || deny "$tool_name" "couldn't resolve workspace"
  resolved=$(resolve_path "$raw" "$ws_real") || deny "$tool_name" "couldn't resolve path"
  case "$resolved" in
    "$ws_real/.git" | "$ws_real/.git/"*)
      deny "$tool_name" "reading .git is not allowed"
      ;;
  esac
  if is_inside "$resolved" "$ws_real"; then
    return 0
  fi
  if [ -n "$rev_real" ] && is_inside "$resolved" "$rev_real"; then
    return 0
  fi
  deny "$tool_name" "path '$raw' is outside the checkout"
}

check_pattern_safe() {
  local raw=$1 field=$2
  [ -n "$raw" ] || return 0
  local reason
  if ! reason=$(python3 - "$raw" <<'PY'
import fnmatch, sys

raw = sys.argv[1]
if "\\" in raw:
    print("cannot contain backslashes")
    sys.exit(1)


def expand_braces(s, max_items=64):
    """Iteratively expand comma-separated brace groups with a strict cap."""
    results = [s]
    while True:
        next_results = []
        expanded_any = False
        for item in results:
            # Find the innermost '{...}' group.
            start = -1
            end = -1
            for i, ch in enumerate(item):
                if ch == "{":
                    start = i
                elif ch == "}":
                    if start == -1:
                        print("contains unbalanced braces")
                        sys.exit(1)
                    end = i
                    break
            if start == -1:
                next_results.append(item)
                continue
            if end == -1:
                print("contains unbalanced braces")
                sys.exit(1)
            body = item[start + 1 : end]
            # Reject range expansions like {a..z} or {1..5}; allow comma lists only.
            if ".." in body or "," not in body:
                print("contains unsupported brace expression")
                sys.exit(1)
            prefix, suffix = item[:start], item[end + 1 :]
            alts = body.split(",")
            for alt in alts:
                next_results.append(prefix + alt + suffix)
                if len(next_results) > max_items:
                    print("exceeds brace expansion limit")
                    sys.exit(1)
            expanded_any = True
        results = next_results
        if not expanded_any:
            break
    return results


for candidate in expand_braces(raw):
    if candidate.startswith("/") or candidate.startswith("~"):
        print("cannot start with '/' or '~'")
        sys.exit(1)
    for part in candidate.split("/"):
        if not part:
            continue
        if part == ".." or part == ".git":
            print("cannot traverse parent directories or target .git")
            sys.exit(1)
        if part in ("*", "**"):
            continue
        if (part.startswith(".") and any(c in part for c in "*?[]")) or fnmatch.fnmatchcase(".git", part) or fnmatch.fnmatchcase("..", part):
            print("cannot match .git or parent directories via wildcards")
            sys.exit(1)
PY
  ); then
    deny "$tool_name" "$field ${reason:-contains an unsafe path pattern}"
  fi
}

# Extract every non-empty string value for the listed tool_input keys (fails closed on jq errors).
extract_fields() {
  local jq_filter=$1
  jq -r "(.tool_input // {} | objects) | $jq_filter" <<< "$input" 2> /dev/null
}

check_edit_path() {
  local raw=$1
  [ -n "$raw" ] || deny "$tool_name" "missing file_path"
  local resolved
  [ -n "$ws_real" ] || deny "$tool_name" "couldn't resolve workspace"
  resolved=$(resolve_path "$raw" "$ws_real") || deny "$tool_name" "couldn't resolve path"
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

    dir_paths=$(extract_fields '[(.dir_path, .directory, .cwd) | strings | select(length > 0)] | .[]') ||
      deny "$(bash_label)" "couldn't inspect shell directory parameters"
    while IFS= read -r dp; do
      [ -n "$dp" ] || continue
      check_read_path "$dp"
    done <<< "$dir_paths"
    allow
    ;;

  read_file)
    paths=$(extract_fields '[(.file_path, .path) | strings | select(length > 0)] | .[]') ||
      deny "$tool_name" "couldn't inspect file path"
    [ -n "$paths" ] || deny "$tool_name" "missing file path"
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      check_read_path "$p"
    done <<< "$paths"
    allow
    ;;

  grep_search | glob | list_directory)
    paths=$(extract_fields '[(.dir_path, .path, .directory) | strings | select(length > 0)] | .[]') ||
      deny "$tool_name" "couldn't inspect directory parameters"
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      check_read_path "$p"
    done <<< "$paths"

    if [ "$tool_name" = glob ]; then
      pats=$(extract_fields '[(.pattern, .include) | strings | select(length > 0)] | .[]') ||
        deny "$tool_name" "couldn't inspect pattern/include parameters"
      while IFS= read -r pat; do
        [ -n "$pat" ] || continue
        check_pattern_safe "$pat" "pattern/include"
      done <<< "$pats"
    elif [ "$tool_name" = grep_search ]; then
      # For grep_search, .pattern is a content regex; only file-filter fields (.include, .glob) are paths.
      pats=$(extract_fields '[(.include, .glob) | strings | select(length > 0)] | .[]') ||
        deny "$tool_name" "couldn't inspect include/glob parameters"
      while IFS= read -r pat; do
        [ -n "$pat" ] || continue
        check_pattern_safe "$pat" "include/glob"
      done <<< "$pats"
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
    paths=$(extract_fields '[(.file_path, .path) | strings | select(length > 0)] | .[]') ||
      deny "$tool_name" "couldn't inspect file path"
    [ -n "$paths" ] || deny "$tool_name" "missing file path"
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      check_edit_path "$p"
    done <<< "$paths"
    allow
    ;;

  *)
    deny "$tool_name" "tool '$tool_name' is not allowed during code review"
    ;;
esac
