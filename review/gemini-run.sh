#!/usr/bin/env bash
# Runs a Gemini CLI headless review session with the same security model as Claude:
# - Installs a pinned @google/gemini-cli version outside the checkout.
# - Quarantines any .gemini/ directory and .env file in the PR checkout during the run so a
#   malicious PR cannot inject settings, hooks, MCP servers, policies, or env overrides.
# - Configures system-level settings (GEMINI_CLI_SYSTEM_SETTINGS_PATH) with Policy Engine (TOML),
#   a BeforeTool hook (gemini-guard.sh), and environmentVariableRedaction (blocking GEMINI_API_KEY
#   while allowing GH_TOKEN for read-only gh commands).
# - Passes the rendered prompt over stdin (avoiding Linux's 128 KiB argv limit) and passes
#   --include-directories when REVIEWED_DIR differs from GITHUB_WORKSPACE (fix mode).
# - Exits non-zero when installation or Gemini CLI fails so single-provider runs fail cleanly
#   (while multi-provider runs use continue-on-error in review/action.yml).
set -uo pipefail

dir=$(cd "$(dirname "$0")" && pwd)
state=${STATE:?STATE is not set}
workspace=${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is not set}
reviewed=${REVIEWED_DIR:?REVIEWED_DIR is not set}
: "${PR_NUMBER:?PR_NUMBER is not set}"
fix=${FIX:-false}
effort=${GEMINI_EFFORT:-high}
export MAX_FINDINGS="${MAX_FINDINGS:-all}"
raw_model=${GEMINI_MODEL:-neon}
cli_version=${GEMINI_CLI_VERSION:-0.71.1}

resolve_model() {
  case "${1,,}" in
    "" | neon) echo "gemini-4-neon" ;;
    carbon) echo "gemini-4-carbon" ;;
    argon) echo "gemini-4-argon" ;;
    hydrogen) echo "gemini-4-hydrogen" ;;
    *) echo "$1" ;;
  esac
}

# Map review effort to Gemini thinkingLevel. Only models known to cap at HIGH (carbon, argon) are
# clamped from XHIGH/MAX -> HIGH; unknown future models pass XHIGH or custom levels through.
resolve_thinking_level() {
  local model=$1 eff=$2
  case "${eff,,}" in
    low) echo "LOW" ;;
    medium) echo "MEDIUM" ;;
    high) echo "HIGH" ;;
    xhigh | max)
      case "${model,,}" in
        gemini-4-carbon | gemini-4-argon) echo "HIGH" ;;
        *) echo "XHIGH" ;;
      esac
      ;;
    *) tr '[:lower:]' '[:upper:]' <<< "$eff" ;;
  esac
}

model=$(resolve_model "$raw_model")
thinking_level=$(resolve_thinking_level "$model" "$effort")

echo "Running Gemini review with model=$model (thinkingLevel=$thinking_level, effort=$effort)"

cli_prefix="$RUNNER_TEMP/ai-review-gemini-cli"
gemini_bin="$cli_prefix/node_modules/.bin/gemini"
if [ ! -x "$gemini_bin" ]; then
  # Scrub API and GitHub tokens from npm install so lifecycle scripts cannot access them.
  if ! env -u GEMINI_API_KEY -u GH_TOKEN npm install --no-audit --no-fund --silent --prefix "$cli_prefix" "@google/gemini-cli@${cli_version}" > /dev/null 2> "$state/.gemini-install.log"; then
    echo "::warning::Failed to install @google/gemini-cli@${cli_version}."
    jq -cn --arg model "$model" --arg effort "$effort" --arg thinking "$thinking_level" \
      '{provider: "gemini", model: $model, effort: $effort, thinking_level: $thinking, duration_seconds: 0, status: "install_failed"}' \
      > "$state/gemini-meta.json"
    exit 1
  fi
fi

cfg_dir="$RUNNER_TEMP/ai-review-gemini-config"
if [ -d "$cfg_dir" ]; then
  chmod -R u+w "$cfg_dir"
  rm -rf "$cfg_dir"
fi
mkdir -p "$cfg_dir"

policy_file="$cfg_dir/policy.toml"
settings_file="$cfg_dir/settings.json"

{
  cat <<'TOML'
[[rule]]
toolName = ["read_file", "grep_search", "glob", "list_directory", "update_topic"]
decision = "allow"
priority = 100

[[rule]]
toolName = "run_shell_command"
commandPrefix = ["gh pr view", "gh pr diff", "gh pr list", "gh issue view", "gh issue list", "gh search", "git status", "git branch --show-current"]
decision = "allow"
priority = 100

[[rule]]
toolName = "run_shell_command"
decision = "deny"
priority = 50
denyMessage = "Only allowlisted read-only gh and git commands are permitted."

[[rule]]
toolName = ["write_file", "web_fetch", "google_web_search", "save_memory", "activate_skill", "mcp_*"]
decision = "deny"
priority = 900
denyMessage = "This tool is disabled during code review."
TOML
  if [ "$fix" = true ]; then
    cat <<'TOML'

[[rule]]
toolName = "replace"
decision = "allow"
priority = 100
TOML
  else
    cat <<'TOML'

[[rule]]
toolName = "replace"
decision = "deny"
priority = 900
denyMessage = "Editing files is disabled unless fix is true."
TOML
  fi
} > "$policy_file"

# Gemini 2.x models use thinkingBudget rather than thinkingLevel (passing thinkingLevel returns HTTP 400).
use_thinking_level=true
case "${model,,}" in
  gemini-2.* | */gemini-2.*) use_thinking_level=false ;;
esac

# Shell-quote every argument so paths containing spaces or special characters cannot shift $1..$4.
guard_cmd=$(printf '%q %q %q %q %q' "$dir/gemini-guard.sh" "$state" "$workspace" "$reviewed" "$fix")
jq -n \
  --arg model "$model" \
  --arg thinking "$thinking_level" \
  --argjson use_tl "$use_thinking_level" \
  --arg policy "$policy_file" \
  --arg guard "$guard_cmd" \
  '{
    security: {
      environmentVariableRedaction: {
        enabled: true,
        allowed: ["GH_TOKEN", "GH_REPO"],
        blocked: ["GEMINI_API_KEY"]
      }
    },
    adminPolicyPaths: [$policy],
    hooks: {
      BeforeTool: [
        {
          matcher: "*",
          hooks: [
            {
              name: "ai-review-guard",
              type: "command",
              command: $guard
            }
          ]
        }
      ]
    }
  } + (if $use_tl then {
    modelConfigs: {
      customOverrides: [
        {
          match: { model: $model },
          modelConfig: {
            generateContentConfig: {
              thinkingConfig: {
                thinkingLevel: $thinking
              }
            }
          }
        }
      ]
    }
  } else {} end)' > "$settings_file"

chmod -R a-w "$cfg_dir"

prompt_file="$state/gemini-prompt.txt"
python3 - "$dir/gemini-prompt.md" "$prompt_file" <<'PY'
import os, pathlib, sys

template = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
fix = os.environ.get("FIX", "false") == "true"

if fix:
    fix_instructions = (
        "Apply clear, contained fixes directly to the working tree (which is the pull request's "
        "head commit) using `replace` on existing tracked files. Leave any finding that needs the "
        "author's call (a design choice, product behaviour, or a fix that requires a new file) "
        "untouched. Never edit anything under `.git`, `.github`, `.claude`, `.gemini`, or "
        "`.agent-memory`, and never create files, commit, or push."
    )
    outcome_field = (
        '\n- `"outcome"`: `"fixed"` when the working tree now holds its fix, `"skipped"` when '
        'left for the author, or `"no_change_needed"` when closer inspection showed nothing to change.'
    )
else:
    fix_instructions = "Read-only review: do not edit or create any files."
    outcome_field = ""

replacements = {
    "__PR_NUMBER__": os.environ.get("PR_NUMBER", ""),
    "__EFFORT__": os.environ.get("GEMINI_EFFORT", "high"),
    "__MAX_FINDINGS__": os.environ.get("MAX_FINDINGS", "all"),
    "__REVIEWED_DIR__": os.environ.get("REVIEWED_DIR", ""),
    "__FIX_INSTRUCTIONS__": fix_instructions,
    "__OUTCOME_FIELD__": outcome_field,
    "__MEMORY_INSTRUCTIONS__": os.environ.get("MEMORY_INSTRUCTIONS", ""),
    "__EARLIER_COMMENTS__": os.environ.get("EARLIER_COMMENTS", ""),
    "__EXTRA_INSTRUCTIONS__": os.environ.get("EXTRA_INSTRUCTIONS", ""),
}
text = template
for k, v in replacements.items():
    text = text.replace(k, v)
pathlib.Path(sys.argv[2]).write_text(text.strip() + "\n", encoding="utf-8")
PY

exec_file="$state/gemini-execution.json"
stderr_file="$state/gemini-stderr.log"

# Quarantine both .gemini/ and root .env in the PR checkout before running Gemini CLI so a
# malicious PR cannot inject settings, hooks, MCP servers, policies, or env overrides (e.g.
# custom base URLs or proxies), then restore them on exit.
quarantine_dir="$RUNNER_TEMP/ai-review-quarantine"
rm -rf "$quarantine_dir"
mkdir -p "$quarantine_dir"
restore_quarantine() {
  if [ -e "$quarantine_dir/.gemini" ] || [ -L "$quarantine_dir/.gemini" ]; then
    rm -rf "$workspace/.gemini"
    mv "$quarantine_dir/.gemini" "$workspace/.gemini"
  fi
  if [ -e "$quarantine_dir/.env" ] || [ -L "$quarantine_dir/.env" ]; then
    rm -rf "$workspace/.env"
    mv "$quarantine_dir/.env" "$workspace/.env"
  fi
  rm -rf "$quarantine_dir"
}
trap restore_quarantine EXIT
if [ -e "$workspace/.gemini" ] || [ -L "$workspace/.gemini" ]; then
  mv "$workspace/.gemini" "$quarantine_dir/.gemini"
fi
if [ -e "$workspace/.env" ] || [ -L "$workspace/.env" ]; then
  mv "$workspace/.env" "$quarantine_dir/.env"
fi

include_args=()
if [ "$reviewed" != "$workspace" ]; then
  include_args=(--include-directories "$reviewed")
fi

start_ts=$(date +%s)
rc=0
# Pass prompt via stdin (avoiding Linux's 128 KiB MAX_ARG_STRLEN argv limit).
GEMINI_CLI_TRUST_WORKSPACE=true \
  GEMINI_CLI_SYSTEM_SETTINGS_PATH="$settings_file" \
  "$gemini_bin" \
    --model "$model" \
    --policy "$policy_file" \
    --approval-mode yolo \
    --output-format json \
    ${include_args[@]+"${include_args[@]}"} \
    --prompt "Follow the code review instructions provided on stdin." \
    < "$prompt_file" \
    > "$exec_file" 2> "$stderr_file" || rc=$?
end_ts=$(date +%s)
restore_quarantine
trap - EXIT
duration=$((end_ts - start_ts))
[ "$duration" -ge 0 ] || duration=0

status="ok"
findings_count=0
if [ -s "$exec_file" ]; then
  response=$(jq -r '.response // ""' "$exec_file" 2> /dev/null || true)
  if [ -n "$response" ]; then
    findings=$(python3 "$dir/extract-findings.py" <<< "$response" || true)
    if [ -n "$findings" ]; then
      jq -c 'map(if type == "object" then . + {provider: "gemini"} else . end)' <<< "$findings" \
        > "$state/gemini-findings.json"
      findings_count=$(jq 'length' "$state/gemini-findings.json" 2> /dev/null || echo 0)
    else
      status="no_findings_list"
    fi
  else
    status="empty_response"
  fi
else
  status="no_output"
fi

if [ "$rc" -ne 0 ] && [ "$status" = ok ]; then
  status="nonzero_exit"
fi

# In fix mode, revert modified tracked files if Gemini failed or recorded no "fixed" findings,
# so partial or unlisted edits never leak into a subsequent Claude commit-fixes.sh run.
# Only modified files (--diff-filter=M) are reverted so intentionally removed unsafe symlinks stay deleted.
if [ "$fix" = true ]; then
  fixed_marked=0
  if [ "$rc" -eq 0 ] && [ -f "$state/gemini-findings.json" ]; then
    fixed_marked=$(jq '[.[] | select(type == "object" and .outcome == "fixed")] | length' "$state/gemini-findings.json" 2> /dev/null || echo 0)
  fi
  if [ "$rc" -ne 0 ] || [ "$fixed_marked" -eq 0 ]; then
    if [ -n "$(git -C "$workspace" diff --diff-filter=M --name-only 2> /dev/null)" ]; then
      echo "::notice::Reverting unconfirmed Gemini working-tree edits (exit=$rc, fixed=$fixed_marked)."
      git -C "$workspace" -c core.hooksPath=/dev/null -c core.fsmonitor=false \
        diff --diff-filter=M --name-only -z |
        git -C "$workspace" -c core.hooksPath=/dev/null -c core.fsmonitor=false \
          checkout --pathspec-from-file=- --pathspec-file-nul 2> /dev/null || true
    fi
  else
    # Snapshot Gemini's confirmed edits so multi-provider fallback can restore them if Claude fails mid-edit.
    git -C "$workspace" -c core.hooksPath=/dev/null -c core.fsmonitor=false \
      diff --binary > "$state/gemini-fixes.patch" 2> /dev/null || rm -f "$state/gemini-fixes.patch"
  fi
fi

jq -cn \
  --arg model "$model" \
  --arg effort "$effort" \
  --arg thinking "$thinking_level" \
  --arg status "$status" \
  --argjson duration "$duration" \
  --argjson exit_code "$rc" \
  --argjson findings "$findings_count" \
  '{
    provider: "gemini",
    model: $model,
    effort: $effort,
    thinking_level: $thinking,
    duration_seconds: $duration,
    exit_code: $exit_code,
    findings_count: $findings,
    status: $status
  }' > "$state/gemini-meta.json"

echo "Gemini review finished in ${duration}s (status=$status, findings=$findings_count, exit=$rc)"
if [ "$rc" -ne 0 ]; then
  err_hint=""
  if [ -s "$stderr_file" ]; then
    err_hint=$(grep -m1 '"message":' "$stderr_file" 2> /dev/null | "$dir/post-review.sh" --redact | cut -c1-240 || true)
  fi
  echo "::warning::Gemini CLI exited with code $rc (status=$status).${err_hint:+ $err_hint}"
  exit "$rc"
fi
exit 0
