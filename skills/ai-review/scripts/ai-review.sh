#!/usr/bin/env bash
# Self-contained AI code review CLI — works installed via `install.sh`, `npx skills add`,
# or directly from a git clone. Runs local reviews using your local subscriptions
# (Antigravity `agy` for Gemini, Claude Code `claude` for Claude) or API keys, and manages
# self-updates and Agent Skill installations.
#
# Subcommands:
#   ai-review [review options]              Run a local code review (default)
#   ai-review update [--version <tag|ref>]  Update ai-review CLI and bundled skill
#   ai-review skills install|remove|status  Manage /ai-review skill in coding agents
#   ai-review version                       Show installed version
set -euo pipefail

script_path=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")
scripts_dir=$(cd "$(dirname "$script_path")" && pwd)
skill_dir=$(cd "$scripts_dir/.." && pwd)
install_root=$(cd "$skill_dir/../.." 2> /dev/null && pwd || echo "")

usage() {
  cat <<'EOF'
Usage:
  ai-review [options]                                  Run a local AI code review
  ai-review update [--version <tag|branch>]            Update ai-review (CLI + bundled skill)
  ai-review skills install [--agent <name>] [--project <dir>]
  ai-review skills remove  [--agent <name>] [--project <dir>]
  ai-review skills status                              Show installed agent skill links
  ai-review version                                    Print installed version

Review options:
  -p, --provider <list>        Providers: gemini, antigravity (alias for gemini), claude,
                               or comma-separated (e.g. claude,antigravity). Default: gemini
  -m, --model <model>          Model alias/id for the selected single provider (or Gemini when both)
      --gemini-model <model>   Gemini model: neon (default), carbon, argon, hydrogen, or full id
      --claude-model <model>   Claude model: opus (default), sonnet, haiku, or full id
  -e, --effort <level>         Effort: low, medium, high (default), xhigh, max (or future level)
      --gemini-effort <level>  Effort override for Gemini
      --claude-effort <level>  Effort override for Claude
      --gemini-engine <eng>    agy (default, Google subscription) or gemini-cli (GEMINI_API_KEY)
      --claude-engine <eng>    claude (default, Claude subscription) or agy
      --base <ref>             Diff against git ref (default: auto-detect origin/main, main, master)
      --staged                 Review only staged changes (git diff --cached)
      --pr <number>            Review pull request #<number> via gh pr diff
      --post                   Post findings to --pr using post-review.sh
      --fix                    Allow applying clear, contained fixes locally (never commits/pushes)
      --max-findings <n|all>   Cap findings per provider (default: all)
      --instructions <text>    Extra instructions appended to the review prompt
      --show-micro-costs       Include auxiliary models spending < $0.01 (default: hidden)
      --json                   Print merged findings JSON instead of formatted text
  -h, --help                   Show this help
EOF
}

lower() { tr '[:upper:]' '[:lower:]' <<< "$1"; }

cmd_version() {
  if [ -n "$install_root" ] && [ -f "$install_root/.ai-review-version" ]; then
    echo "ai-review $(cat "$install_root/.ai-review-version")"
  elif [ -n "$install_root" ] && [ -d "$install_root/.git" ]; then
    local sha
    sha=$(git -C "$install_root" rev-parse --short HEAD 2> /dev/null || echo "dev")
    echo "ai-review git:${sha}"
  else
    echo "ai-review skill-bundle"
  fi
}

cmd_update() {
  local target_version="" target_repo=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --version) target_version=${2:?missing value for --version}; shift 2 ;;
      --repo) target_repo=${2:?missing value for --repo}; shift 2 ;;
      -h | --help)
        echo "Usage: ai-review update [--version <tag|branch>] [--repo <owner/repo>]"
        return 0
        ;;
      *) echo "Unknown update option: $1" >&2; return 2 ;;
    esac
  done

  if [ -n "$install_root" ] && [ -d "$install_root/.git" ]; then
    echo "Updating git clone at $install_root..."
    git -C "$install_root" pull --ff-only
    return 0
  fi

  local repo="${target_repo:-${AI_REVIEW_REPO:-}}"
  if [ -z "$repo" ] && [ -n "$install_root" ] && [ -f "$install_root/.ai-review-repo" ]; then
    repo=$(cat "$install_root/.ai-review-repo")
  fi
  repo=${repo:-Quartel-Enterprise/ai-review}
  [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { echo "Invalid repo '$repo'." >&2; return 2; }

  local installer=""
  if [ -n "$install_root" ] && [ -x "$install_root/install.sh" ]; then
    installer="$install_root/install.sh"
  else
    local tmp_inst
    tmp_inst=$(mktemp)
    trap 'rm -f "$tmp_inst"' RETURN
    curl -fsSL "https://raw.githubusercontent.com/${repo}/main/install.sh" -o "$tmp_inst"
    chmod +x "$tmp_inst"
    installer="$tmp_inst"
  fi

  local -a args=(--repo "$repo")
  [ -n "$target_version" ] && args+=(--version "$target_version")
  [ -n "$install_root" ] && [ -f "$install_root/.ai-review-version" ] && args+=(--home "$install_root")
  "$installer" "${args[@]}"
}

resolve_skill_targets() {
  local agent=$1 project=$2
  if [ -n "$project" ]; then
    case "$agent" in
      all)
        echo "$project/.agents/skills/ai-review"
        echo "$project/.claude/skills/ai-review"
        ;;
      antigravity | gemini | agents) echo "$project/.agents/skills/ai-review" ;;
      claude) echo "$project/.claude/skills/ai-review" ;;
      codex) echo "$project/.agents/skills/ai-review" ;;
      *) echo "Unknown agent '$agent': use all, antigravity, claude, or codex." >&2; return 2 ;;
    esac
    return 0
  fi

  case "$agent" in
    all)
      local any=false
      if [ -d "$HOME/.gemini" ]; then
        echo "$HOME/.gemini/skills/ai-review"
        any=true
      fi
      if [ -d "$HOME/.claude" ]; then
        echo "$HOME/.claude/skills/ai-review"
        any=true
      fi
      if [ -d "$HOME/.agents" ] || [ "$any" = false ]; then
        echo "$HOME/.agents/skills/ai-review"
      fi
      ;;
    antigravity | gemini) echo "$HOME/.gemini/skills/ai-review" ;;
    claude) echo "$HOME/.claude/skills/ai-review" ;;
    codex | agents) echo "$HOME/.agents/skills/ai-review" ;;
    *) echo "Unknown agent '$agent': use all, antigravity, claude, or codex." >&2; return 2 ;;
  esac
}

cmd_skills() {
  local action=${1:-status}
  [ $# -gt 0 ] && shift
  local agent="all" project=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --agent) agent=$(lower "${2:?missing value for --agent}"); shift 2 ;;
      --project) project=${2:?missing value for --project}; shift 2 ;;
      -h | --help)
        echo "Usage: ai-review skills <install|remove|status> [--agent all|antigravity|claude|codex] [--project <dir>]"
        return 0
        ;;
      *) echo "Unknown skills option: $1" >&2; return 2 ;;
    esac
  done

  case "$action" in
    install | add)
      local targets target target_real
      targets=$(resolve_skill_targets "$agent" "$project") || return $?
      while IFS= read -r target; do
        [ -n "$target" ] || continue
        mkdir -p "$(dirname "$target")"
        if [ -e "$target" ] || [ -L "$target" ]; then
          target_real=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$target")
          if [ "$target_real" = "$skill_dir" ]; then
            echo "✓ Skill already installed -> $target"
            continue
          fi
          # Remove existing non-symlink directory/file so ln -sfn never nests a symlink inside it.
          [ ! -L "$target" ] && rm -rf "$target"
        fi
        ln -sfn "$skill_dir" "$target"
        echo "✓ Linked skill -> $target"
      done <<< "$targets"
      ;;
    remove | uninstall)
      local targets target
      targets=$(resolve_skill_targets "$agent" "$project") || return $?
      while IFS= read -r target; do
        [ -n "$target" ] || continue
        if [ -L "$target" ] || [ -e "$target" ]; then
          rm -rf "$target"
          echo "✓ Removed skill <- $target"
        else
          echo "- Not installed: $target"
        fi
      done <<< "$targets"
      ;;
    status | list)
      echo "Skill source: $skill_dir"
      echo "Version: $(cmd_version)"
      local p
      for p in "$HOME/.gemini/skills/ai-review" "$HOME/.claude/skills/ai-review" "$HOME/.agents/skills/ai-review"; do
        if [ -L "$p" ]; then
          echo "  ✓ $p -> $(readlink "$p")"
        elif [ -d "$p" ]; then
          echo "  ✓ $p (directory)"
        else
          echo "  - $p (not installed)"
        fi
      done
      ;;
    *)
      echo "Unknown skills subcommand '$action': use install, remove, or status." >&2
      return 2
      ;;
  esac
}

case "${1:-}" in
  update) shift; cmd_update "$@"; exit $? ;;
  skills) shift; cmd_skills "$@"; exit $? ;;
  version | --version) cmd_version; exit 0 ;;
esac

providers_raw="gemini"
single_model=""
gemini_model=""
claude_model=""
effort="high"
gemini_effort=""
claude_effort=""
gemini_engine="agy"
claude_engine="claude"
base_ref=""
staged=false
pr_number=""
post_pr=false
fix=false
max_findings="all"
extra_instructions=""
show_micro_costs=false
json_output=false

while [ $# -gt 0 ]; do
  case "$1" in
    -p | --provider | --providers) providers_raw=${2:?missing value for $1}; shift 2 ;;
    -m | --model) single_model=${2:?missing value for $1}; shift 2 ;;
    --gemini-model) gemini_model=${2:?missing value for $1}; shift 2 ;;
    --claude-model) claude_model=${2:?missing value for $1}; shift 2 ;;
    -e | --effort) effort=${2:?missing value for $1}; shift 2 ;;
    --gemini-effort) gemini_effort=${2:?missing value for $1}; shift 2 ;;
    --claude-effort) claude_effort=${2:?missing value for $1}; shift 2 ;;
    --gemini-engine) gemini_engine=${2:?missing value for $1}; shift 2 ;;
    --claude-engine) claude_engine=${2:?missing value for $1}; shift 2 ;;
    --base) base_ref=${2:?missing value for $1}; shift 2 ;;
    --staged) staged=true; shift ;;
    --pr) pr_number=${2:?missing value for $1}; shift 2 ;;
    --post) post_pr=true; shift ;;
    --fix) fix=true; shift ;;
    --max-findings) max_findings=${2:?missing value for $1}; shift 2 ;;
    --instructions) extra_instructions=${2:?missing value for $1}; shift 2 ;;
    --show-micro-costs) show_micro_costs=true; shift ;;
    --json) json_output=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# Normalize providers (antigravity is an alias for gemini).
run_claude=false
run_gemini=false
canonical=()
raw_list=()
IFS=',' read -r -a raw_list <<< "$providers_raw"
for item in ${raw_list[@]+"${raw_list[@]}"}; do
  p=$(lower "$item" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -n "$p" ] || continue
  case "$p" in
    claude)
      if [ "$run_claude" = false ]; then
        run_claude=true
        canonical+=(claude)
      fi
      ;;
    gemini | antigravity)
      if [ "$run_gemini" = false ]; then
        run_gemini=true
        canonical+=(gemini)
      fi
      ;;
    *)
      echo "Unknown provider '$p': use claude, gemini, antigravity, or a comma-separated list." >&2
      exit 2
      ;;
  esac
done
if [ "${#canonical[@]}" -eq 0 ]; then
  echo "At least one provider must be specified." >&2
  exit 2
fi
providers_csv=$(IFS=','; echo "${canonical[*]}")

if [ -n "$single_model" ]; then
  if [ "$run_claude" = true ] && [ "$run_gemini" = false ] && [ -z "$claude_model" ]; then
    claude_model=$single_model
  elif [ -z "$gemini_model" ]; then
    gemini_model=$single_model
  fi
fi

gemini_model=${gemini_model:-neon}
claude_model=${claude_model:-opus}
gemini_effort=${gemini_effort:-$effort}
claude_effort=${claude_effort:-$effort}

for eff in "$effort" "$gemini_effort" "$claude_effort"; do
  if ! [[ "$eff" =~ ^[A-Za-z0-9-]+$ ]]; then
    echo "Invalid effort '$eff': must match [A-Za-z0-9-]+" >&2
    exit 2
  fi
  case "$(lower "$eff")" in
    low | medium | high | xhigh | max) ;;
    *) echo "Warning: '$eff' is not one of the standard effort levels (low, medium, high, xhigh, max); passing through." >&2 ;;
  esac
done

if [ "$post_pr" = true ] && [ -z "$pr_number" ]; then
  echo "--post requires --pr <number>." >&2
  exit 2
fi

command -v jq > /dev/null 2>&1 || { echo "jq is required by ai-review (install via brew install jq / apt-get install jq)." >&2; exit 1; }
git rev-parse --show-toplevel > /dev/null 2>&1 || { echo "Run ai-review inside a git repository." >&2; exit 1; }
workspace=$(git rev-parse --show-toplevel)
cd "$workspace"

resolve_agy_gemini_model() {
  local m e base suffix
  m=$(lower "$1")
  e=$(lower "$2")
  case "$m" in
    neon | gemini-4-neon) base="gemini-4-neon" ;;
    carbon | gemini-4-carbon) base="gemini-4-carbon" ;;
    argon | gemini-4-argon) base="gemini-4-argon" ;;
    hydrogen | gemini-4-hydrogen) base="gemini-4-hydrogen" ;;
    *-low | *-medium | *-high | *-xhigh) echo "$m"; return 0 ;;
    *) echo "$m"; return 0 ;;
  esac
  case "$e" in
    low) suffix="low" ;;
    medium) suffix="medium" ;;
    high) suffix="high" ;;
    xhigh | max)
      case "$base" in
        gemini-4-carbon | gemini-4-argon) suffix="high" ;;
        *) suffix="xhigh" ;;
      esac
      ;;
    *) suffix="$e" ;;
  esac
  echo "${base}-${suffix}"
}

resolve_agy_claude_model() {
  local m e base suffix
  m=$(lower "$1")
  e=$(lower "$2")
  case "$m" in
    opus | claude-opus-5-5) base="claude-opus-5-5" ;;
    sonnet | claude-sonnet-5-5) base="claude-sonnet-5-5" ;;
    *-low | *-medium | *-high) echo "$m"; return 0 ;;
    *) echo "$m"; return 0 ;;
  esac
  case "$e" in
    low) suffix="low" ;;
    medium) suffix="medium" ;;
    high | xhigh | max) suffix="high" ;;
    *) suffix="$e" ;;
  esac
  echo "${base}-${suffix}"
}

resolve_gemini_api_model() {
  case "$(lower "$1")" in
    neon) echo "gemini-4-neon" ;;
    carbon) echo "gemini-4-carbon" ;;
    argon) echo "gemini-4-argon" ;;
    hydrogen) echo "gemini-4-hydrogen" ;;
    *) echo "$1" ;;
  esac
}

state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT
diff_file="$state/review.diff"
target_desc=""

if [ -n "$pr_number" ]; then
  local_head=$(git rev-parse HEAD 2> /dev/null || echo "")
  pr_head=$(gh pr view "$pr_number" --json headRefOid --jq .headRefOid 2> /dev/null || echo "")
  if [ -n "$pr_head" ] && [ -n "$local_head" ] && [ "$local_head" != "$pr_head" ]; then
    if [ "$fix" = true ]; then
      echo "Refusing --fix with --pr #$pr_number: local HEAD ($local_head) does not match PR head ($pr_head). Run 'gh pr checkout $pr_number' first." >&2
      exit 2
    fi
    echo "Warning: local HEAD does not match PR #$pr_number head ($pr_head); file context and line numbers may be stale. Run 'gh pr checkout $pr_number' for an accurate review." >&2
  fi
  gh pr diff "$pr_number" > "$diff_file"
  target_desc="pull request #$pr_number"
elif [ "$staged" = true ]; then
  git diff --cached > "$diff_file"
  target_desc="staged changes"
else
  if [ -z "$base_ref" ]; then
    for candidate in origin/main main origin/master master; do
      if git rev-parse --verify --quiet "$candidate" > /dev/null; then
        base_ref=$candidate
        break
      fi
    done
  fi
  if [ -n "$base_ref" ]; then
    merge_base=$(git merge-base "$base_ref" HEAD 2> /dev/null || echo "$base_ref")
    git diff "$merge_base" > "$diff_file"
    target_desc="changes since $base_ref"
  else
    git diff HEAD > "$diff_file"
    target_desc="working tree changes"
  fi
fi

if [ ! -s "$diff_file" ]; then
  echo "No diff found for $target_desc." >&2
  [ "$json_output" = true ] && echo "[]"
  exit 0
fi

build_prompt() {
  local out_file=$1 eff=$2 max_bytes=${3:-120000}
  python3 - "$out_file" "$diff_file" "$target_desc" "$eff" "$max_findings" "$fix" "$extra_instructions" "$max_bytes" <<'PY'
import pathlib, sys

out_path, diff_path, target_desc, effort, max_findings, fix_str, extra, max_bytes_s = sys.argv[1:9]
max_bytes = int(max_bytes_s)
raw_bytes = pathlib.Path(diff_path).read_bytes()
if len(raw_bytes) > max_bytes:
    diff_text = raw_bytes[:max_bytes].decode("utf-8", errors="ignore") + (
        f"\n... [diff truncated at {max_bytes} bytes; full diff is at `{diff_path}` — "
        "inspect remaining files directly with read tools] ...\n"
    )
else:
    diff_text = raw_bytes.decode("utf-8", errors="replace")

fix = fix_str == "true"
if fix:
    fix_block = (
        "Apply clear, contained fixes directly to existing tracked files in the working tree. "
        "Leave findings requiring product/design decisions untouched. Never edit under `.git`, "
        "`.github`, `.claude`, or `.gemini`, and never commit or push."
    )
    outcome_line = (
        '\n- `"outcome"`: `"fixed"`, `"skipped"`, or `"no_change_needed"`.'
    )
else:
    fix_block = "Read-only review: do not edit, create, or delete any files, and do not commit or push."
    outcome_line = ""

prompt = f"""Review {target_desc} in this repository thoroughly and objectively.

## Instructions
1. Read any convention files present in the repository (`AGENTS.md`, `CLAUDE.md`, `GEMINI.md`).
2. Inspect the full surrounding code of changed files and their callers/callees before reporting any issue.
3. Effort level: `{effort}` (`low`: clear bugs/security; `medium`: edge cases/conventions; `high`: multi-file data flow, concurrency, subtle regressions; `xhigh`/`max`: exhaustive verification).
4. Limit: report at most `{max_findings}` findings (`all` = no cap), ordered most severe first. Only report real, verifiable issues.
5. Fix mode: {fix_block}

## Output format
End your reply with the findings as a JSON array inside a ```json fence, and nothing after it.
Each object must contain: `"file"`, `"line"` (integer line in the new version of the file), optional `"start_line"`, `"summary"`, `"failure_scenario"`, `"category"`, `"severity"` (`"must-fix"`, `"should-fix"`, or `"nitpick"`), `"fix"`, optional `"suggestion"` (exact replacement text for the commented lines when a drop-in replacement fully fixes it){outcome_line}.
Write `[]` inside the ```json fence when there are no findings.

{extra}

## Diff to review
```diff
{diff_text}
```
"""
pathlib.Path(out_path).write_text(prompt, encoding="utf-8")
PY
}

run_gemini_provider() {
  local prompt_file="$state/gemini-prompt.txt"
  local raw_out="$state/gemini-raw.txt"
  local err_out="$state/gemini-err.log"
  local json_out="$state/gemini-out.json"

  local start_ts end_ts dur rc=0 resolved_model="" is_sub=false
  start_ts=$(date +%s)
  if [ "$gemini_engine" = agy ]; then
    command -v agy > /dev/null 2>&1 || { echo "agy CLI not found in PATH (install Antigravity CLI or use --gemini-engine gemini-cli)." >&2; echo 1 > "$state/gemini.rc"; return 1; }
    # Cap inline diff at 64 KiB bytes for argv safety; --add-dir exposes full review.diff.
    build_prompt "$prompt_file" "$gemini_effort" 65536
    local -a mode_args=()
    resolved_model=$(resolve_agy_gemini_model "$gemini_model" "$gemini_effort")
    is_sub=true
    [ "$fix" = true ] && mode_args=(--mode accept-edits)
    echo "[gemini] Running via agy (model=$resolved_model)..." >&2
    agy \
      --model "$resolved_model" \
      --add-dir "$state" \
      ${mode_args[@]+"${mode_args[@]}"} \
      --sandbox \
      --output-format json \
      --print "$(cat "$prompt_file")" \
      > "$json_out" 2> "$err_out" || rc=$?
    if [ -s "$json_out" ]; then
      jq -r '.response // ""' "$json_out" > "$raw_out" 2> /dev/null || cp "$json_out" "$raw_out"
    fi
  elif [ "$gemini_engine" = gemini-cli ]; then
    command -v gemini > /dev/null 2>&1 || { echo "gemini CLI not found in PATH." >&2; echo 1 > "$state/gemini.rc"; return 1; }
    build_prompt "$prompt_file" "$gemini_effort" 200000
    resolved_model=$(resolve_gemini_api_model "$gemini_model")
    local approval_mode="plan"
    [ "$fix" = true ] && approval_mode="auto_edit"
    echo "[gemini] Running via gemini-cli (model=$resolved_model, approval=$approval_mode)..." >&2
    gemini --model "$resolved_model" \
      --include-directories "$state" \
      --approval-mode "$approval_mode" \
      --output-format json \
      --prompt "Follow the code review instructions provided on stdin." \
      < "$prompt_file" \
      > "$json_out" 2> "$err_out" || rc=$?
    if [ -s "$json_out" ]; then
      jq -r '.response // ""' "$json_out" > "$raw_out" 2> /dev/null || cp "$json_out" "$raw_out"
    fi
  else
    echo "Unknown --gemini-engine '$gemini_engine': use agy or gemini-cli." >&2
    echo 2 > "$state/gemini.rc"
    return 2
  fi
  end_ts=$(date +%s)
  dur=$((end_ts - start_ts))
  [ "$dur" -ge 0 ] || dur=0
  echo "$rc" > "$state/gemini.rc"

  if [ "$gemini_engine" = agy ] && [ -s "$json_out" ] && jq -e '.usage' "$json_out" > /dev/null 2>&1; then
    jq -cn \
      --arg model "$resolved_model" \
      --arg engine "$gemini_engine" \
      --argjson sub "$is_sub" \
      --argjson dur "$dur" \
      --slurpfile j "$json_out" \
      '{
        provider: "gemini", model: $model, engine: $engine, subscription: $sub, duration_seconds: $dur,
        input_tokens: ($j[0].usage.input_tokens // 0),
        cached_tokens: ($j[0].usage.cache_read_tokens // 0),
        output_tokens: ($j[0].usage.output_tokens // 0),
        thinking_tokens: ($j[0].usage.thinking_tokens // 0)
      }' > "$state/gemini.stats.json"
  elif [ "$gemini_engine" = gemini-cli ] && [ -s "$json_out" ] && jq -e '.stats.models' "$json_out" > /dev/null 2>&1; then
    jq -cn \
      --arg model "$resolved_model" \
      --arg engine "$gemini_engine" \
      --argjson sub "$is_sub" \
      --argjson dur "$dur" \
      --slurpfile j "$json_out" \
      '($j[0].stats.models | to_entries | map(.value.tokens)) as $t
      | {
          provider: "gemini", model: $model, engine: $engine, subscription: $sub, duration_seconds: $dur,
          input_tokens: ($t | map(.input // ((.prompt // 0) - (.cached // 0))) | add // 0),
          cached_tokens: ($t | map(.cached // 0) | add // 0),
          output_tokens: ($t | map(.candidates // 0) | add // 0),
          thinking_tokens: ($t | map(.thoughts // 0) | add // 0)
        }' > "$state/gemini.stats.json"
  else
    jq -cn --arg model "$resolved_model" --arg engine "$gemini_engine" --argjson sub "$is_sub" --argjson dur "$dur" \
      '{provider: "gemini", model: $model, engine: $engine, subscription: $sub, duration_seconds: $dur}' \
      > "$state/gemini.stats.json"
  fi

  if [ -s "$raw_out" ]; then
    local extracted
    extracted=$(python3 "$scripts_dir/extract-findings.py" < "$raw_out" || true)
    if [ -n "$extracted" ]; then
      jq -c 'map(if type == "object" then . + {provider: "gemini"} else . end)' <<< "$extracted" \
        > "$state/gemini-findings.json"
    fi
  fi
  echo "[gemini] Finished in ${dur}s (exit=$rc)" >&2
  [ "$rc" -eq 0 ] || { tail -n 10 "$err_out" >&2 || true; }
  return "$rc"
}

run_claude_provider() {
  local prompt_file="$state/claude-prompt.txt"
  local raw_out="$state/claude-raw.txt"
  local err_out="$state/claude-err.log"
  local json_out="$state/claude-out.json"

  local start_ts end_ts dur rc=0 resolved_model="" is_sub=true
  start_ts=$(date +%s)
  if [ "$claude_engine" = claude ]; then
    command -v claude > /dev/null 2>&1 || { echo "claude CLI not found in PATH (install Claude Code or use --claude-engine agy)." >&2; echo 1 > "$state/claude.rc"; return 1; }
    build_prompt "$prompt_file" "$claude_effort" 200000
    resolved_model=$claude_model
    [ -n "${ANTHROPIC_API_KEY:-}" ] && is_sub=false
    local tools_arg
    local -a perm_args=()
    if [ "$fix" = true ]; then
      tools_arg="Read,Edit,Grep,Glob"
      perm_args=(--permission-mode acceptEdits)
    else
      tools_arg="Read,Grep,Glob"
    fi
    echo "[claude] Running via claude CLI (model=$resolved_model, effort=$claude_effort)..." >&2
    # Feed prompt on stdin so large diffs never hit Linux's 128 KiB MAX_ARG_STRLEN.
    claude --print \
      --model "$resolved_model" \
      --add-dir "$state" \
      --tools "$tools_arg" \
      ${perm_args[@]+"${perm_args[@]}"} \
      --output-format json \
      < "$prompt_file" \
      > "$json_out" 2> "$err_out" || rc=$?
    if [ -s "$json_out" ]; then
      jq -r '.result // ""' "$json_out" > "$raw_out" 2> /dev/null || cp "$json_out" "$raw_out"
    fi
  elif [ "$claude_engine" = agy ]; then
    command -v agy > /dev/null 2>&1 || { echo "agy CLI not found in PATH." >&2; echo 1 > "$state/claude.rc"; return 1; }
    build_prompt "$prompt_file" "$claude_effort" 65536
    local -a mode_args=()
    resolved_model=$(resolve_agy_claude_model "$claude_model" "$claude_effort")
    [ "$fix" = true ] && mode_args=(--mode accept-edits)
    echo "[claude] Running via agy (model=$resolved_model)..." >&2
    agy \
      --model "$resolved_model" \
      --add-dir "$state" \
      ${mode_args[@]+"${mode_args[@]}"} \
      --sandbox \
      --output-format json \
      --print "$(cat "$prompt_file")" \
      > "$json_out" 2> "$err_out" || rc=$?
    if [ -s "$json_out" ]; then
      jq -r '.response // ""' "$json_out" > "$raw_out" 2> /dev/null || cp "$json_out" "$raw_out"
    fi
  else
    echo "Unknown --claude-engine '$claude_engine': use claude or agy." >&2
    echo 2 > "$state/claude.rc"
    return 2
  fi
  end_ts=$(date +%s)
  dur=$((end_ts - start_ts))
  [ "$dur" -ge 0 ] || dur=0
  echo "$rc" > "$state/claude.rc"

  if [ "$claude_engine" = claude ] && [ -s "$json_out" ] && jq -e '.total_cost_usd // .modelUsage' "$json_out" > /dev/null 2>&1; then
    jq -cn \
      --arg model "$resolved_model" \
      --arg engine "$claude_engine" \
      --argjson sub "$is_sub" \
      --argjson dur "$dur" \
      --slurpfile j "$json_out" \
      '{
        provider: "claude", model: $model, engine: $engine, subscription: $sub, duration_seconds: $dur,
        total_cost_usd: ($j[0].total_cost_usd // null),
        model_usage: ($j[0].modelUsage // null)
      }' > "$state/claude.stats.json"
  elif [ "$claude_engine" = agy ] && [ -s "$json_out" ] && jq -e '.usage' "$json_out" > /dev/null 2>&1; then
    jq -cn \
      --arg model "$resolved_model" \
      --arg engine "$claude_engine" \
      --argjson sub "$is_sub" \
      --argjson dur "$dur" \
      --slurpfile j "$json_out" \
      '{
        provider: "claude", model: $model, engine: $engine, subscription: $sub, duration_seconds: $dur,
        input_tokens: ($j[0].usage.input_tokens // 0),
        cached_tokens: ($j[0].usage.cache_read_tokens // 0),
        output_tokens: ($j[0].usage.output_tokens // 0),
        thinking_tokens: ($j[0].usage.thinking_tokens // 0)
      }' > "$state/claude.stats.json"
  else
    jq -cn --arg model "$resolved_model" --arg engine "$claude_engine" --argjson sub "$is_sub" --argjson dur "$dur" \
      '{provider: "claude", model: $model, engine: $engine, subscription: $sub, duration_seconds: $dur}' \
      > "$state/claude.stats.json"
  fi

  if [ -s "$raw_out" ]; then
    local extracted
    extracted=$(python3 "$scripts_dir/extract-findings.py" < "$raw_out" || true)
    if [ -n "$extracted" ]; then
      jq -c 'map(if type == "object" then . + {provider: "claude"} else . end)' <<< "$extracted" \
        > "$state/claude-findings.json"
    fi
  fi
  echo "[claude] Finished in ${dur}s (exit=$rc)" >&2
  [ "$rc" -eq 0 ] || { tail -n 10 "$err_out" >&2 || true; }
  return "$rc"
}

wall_start=$(date +%s)
if [ "$run_gemini" = true ] && [ "$run_claude" = true ] && [ "$fix" = false ]; then
  run_gemini_provider &
  pid_g=$!
  run_claude_provider &
  pid_c=$!
  wait "$pid_g" || true
  wait "$pid_c" || true
else
  [ "$run_gemini" = true ] && { run_gemini_provider || true; }
  [ "$run_claude" = true ] && { run_claude_provider || true; }
fi
wall_end=$(date +%s)
wall_seconds=$((wall_end - wall_start))
[ "$wall_seconds" -ge 0 ] || wall_seconds=0

any_provider_ok=false
merge_args=()
stats_files=()
if [ "$run_gemini" = true ]; then
  [ "$(cat "$state/gemini.rc" 2> /dev/null || echo 1)" -eq 0 ] && any_provider_ok=true
  [ -f "$state/gemini-findings.json" ] && merge_args+=("gemini:$state/gemini-findings.json")
  [ -f "$state/gemini.stats.json" ] && stats_files+=("$state/gemini.stats.json")
fi
if [ "$run_claude" = true ]; then
  [ "$(cat "$state/claude.rc" 2> /dev/null || echo 1)" -eq 0 ] && any_provider_ok=true
  [ -f "$state/claude-findings.json" ] && merge_args+=("claude:$state/claude-findings.json")
  [ -f "$state/claude.stats.json" ] && stats_files+=("$state/claude.stats.json")
fi

if [ "$any_provider_ok" != true ]; then
  echo "All enabled review providers failed." >&2
  exit 1
fi

stats_json='[]'
if [ "${#stats_files[@]}" -gt 0 ]; then
  stats_json=$(jq -sc '.' "${stats_files[@]}")
fi

merged=""
if [ "${#merge_args[@]}" -gt 0 ]; then
  merged=$(python3 "$scripts_dir/merge-findings.py" "${merge_args[@]}")
fi

if [ "$post_pr" = true ]; then
  repo_nwo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
  if [ "$json_output" = true ]; then
    GITHUB_REPOSITORY="$repo_nwo" \
      GITHUB_WORKSPACE="$workspace" \
      PROVIDERS="$providers_csv" \
      "$scripts_dir/post-review.sh" "$pr_number" <<< "$merged" >&2
  else
    GITHUB_REPOSITORY="$repo_nwo" \
      GITHUB_WORKSPACE="$workspace" \
      PROVIDERS="$providers_csv" \
      "$scripts_dir/post-review.sh" "$pr_number" <<< "$merged"
  fi
fi

if [ "$json_output" = true ]; then
  if [ -n "$merged" ]; then
    echo "$merged"
  else
    echo "[]"
  fi
else
  WALL_SECONDS="$wall_seconds" \
    PROVIDER_STATS="$stats_json" \
    SHOW_MICRO_COSTS="$show_micro_costs" \
    python3 "$scripts_dir/format-findings.py" <<< "$merged"
fi
