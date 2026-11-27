#!/usr/bin/env bash
# Runs a Gemini CLI headless review session with the same security model as Claude:
# - Installs a pinned @google/gemini-cli version outside the checkout.
# - Configures system-level settings (GEMINI_CLI_SYSTEM_SETTINGS_PATH) with folderTrust enabled
#   so any .gemini/settings.json inside an untrusted PR checkout is ignored.
# - Enforces tool restrictions with BOTH the Policy Engine (TOML) and a BeforeTool hook
#   (gemini-guard.sh), plus environmentVariableRedaction for subprocesses.
# - Captures JSON output and stderr outside the checkout so raw model output never reaches public logs.
# - Records duration, model, effort, and extracted findings (tagged with provider="gemini") in STATE.
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

# Resolve Gemini model aliases to full API model IDs.
resolve_model() {
  case "${1,,}" in
    "" | neon) echo "gemini-4-neon" ;;
    carbon) echo "gemini-4-carbon" ;;
    argon) echo "gemini-4-argon" ;;
    hydrogen) echo "gemini-4-hydrogen" ;;
    *) echo "$1" ;;
  esac
}

# Map review effort to Gemini thinkingLevel, respecting per-model ceilings.
resolve_thinking_level() {
  local model=$1 eff=$2
  case "${eff,,}" in
    low) echo "LOW" ;;
    medium) echo "MEDIUM" ;;
    high) echo "HIGH" ;;
    xhigh | max)
      case "${model,,}" in
        gemini-4-neon | gemini-4-hydrogen) echo "XHIGH" ;;
        *) echo "HIGH" ;;
      esac
      ;;
    *) echo "HIGH" ;;
  esac
}

model=$(resolve_model "$raw_model")
thinking_level=$(resolve_thinking_level "$model" "$effort")

echo "Running Gemini review with model=$model (thinkingLevel=$thinking_level, effort=$effort)"

# Install pinned @google/gemini-cli outside the checkout so PR contents cannot affect it.
cli_prefix="$RUNNER_TEMP/ai-review-gemini-cli"
gemini_bin="$cli_prefix/node_modules/.bin/gemini"
if [ ! -x "$gemini_bin" ]; then
  if ! npm install --no-audit --no-fund --silent --prefix "$cli_prefix" "@google/gemini-cli@${cli_version}" > /dev/null 2> "$state/.gemini-install.log"; then
    echo "::warning::Failed to install @google/gemini-cli@${cli_version}."
    jq -cn --arg model "$model" --arg effort "$effort" --arg thinking "$thinking_level" \
      '{provider: "gemini", model: $model, effort: $effort, thinking_level: $thinking, duration_seconds: 0, status: "install_failed"}' \
      > "$state/gemini-meta.json"
    exit 1
  fi
fi

# Generate read-only TOML policy and system settings outside the checkout.
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

guard_cmd="$dir/gemini-guard.sh $state $workspace $reviewed $fix"
jq -n \
  --arg model "$model" \
  --arg thinking "$thinking_level" \
  --arg policy "$policy_file" \
  --arg guard "$guard_cmd" \
  '{
    security: {
      environmentVariableRedaction: { enabled: true }
    },
    adminPolicyPaths: [$policy],
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
    },
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
  }' > "$settings_file"

chmod -R a-w "$cfg_dir"

# Render the review prompt from gemini-prompt.md without shell-expanding untrusted text.
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

# Quarantine any .gemini directory in the PR checkout before running Gemini CLI so a malicious PR
# cannot inject .gemini/settings.json, hooks, MCP servers, or policies, then restore it on exit.
quarantine_gemini="$RUNNER_TEMP/ai-review-quarantined-gemini"
rm -rf "$quarantine_gemini"
restore_quarantine() {
  if [ -e "$quarantine_gemini" ]; then
    rm -rf "$workspace/.gemini"
    mv "$quarantine_gemini" "$workspace/.gemini"
  fi
}
trap restore_quarantine EXIT
if [ -e "$workspace/.gemini" ]; then
  mv "$workspace/.gemini" "$quarantine_gemini"
fi

start_ts=$(date +%s)
rc=0
GEMINI_CLI_TRUST_WORKSPACE=true \
  GEMINI_CLI_SYSTEM_SETTINGS_PATH="$settings_file" \
  "$gemini_bin" \
    --model "$model" \
    --policy "$policy_file" \
    --approval-mode yolo \
    --output-format json \
    --prompt "$(cat "$prompt_file")" \
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
fi
exit 0
