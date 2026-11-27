#!/usr/bin/env bash
# Local AI code review CLI — run from any git repository using your local subscriptions
# (Antigravity `agy` for Gemini, Claude Code `claude` for Claude) or API keys.
#
# Supports choosing one provider (`gemini` / alias `antigravity`, or `claude`) or both
# (`claude,gemini` / `claude,antigravity`, executed in parallel when read-only).
#
# Usage:
#   ai-review [options]
#
# Examples:
#   ai-review                                        # Gemini 4 Neon (high) via agy on branch diff
#   ai-review --provider antigravity --effort xhigh  # Same as --provider gemini
#   ai-review --provider claude                      # Claude Opus via claude CLI
#   ai-review --provider claude,antigravity          # Both in parallel, merged report + timing
#   ai-review --fix                                  # Apply clear local fixes (no commit/push)
#   ai-review --pr 42 --post                         # Review PR #42 and post via post-review.sh
set -euo pipefail

# Resolve symlinks so this script finds review/ helpers even when symlinked into ~/.local/bin.
script_path=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")
repo_root=$(cd "$(dirname "$script_path")/.." && pwd)
review_dir="$repo_root/review"
local_dir="$repo_root/local"

usage() {
  cat <<'EOF'
Usage: ai-review [options]

Options:
  -p, --provider <list>        Providers: gemini, antigravity (alias for gemini), claude,
                               or comma-separated (e.g. claude,gemini). Default: gemini
  -m, --model <model>          Model alias/id for the selected single provider (or Gemini when both)
      --gemini-model <model>   Gemini model: neon (default), carbon, argon, hydrogen, or full id
      --claude-model <model>   Claude model: opus (default), sonnet, haiku, or full id
  -e, --effort <level>         Effort: low, medium, high (default), xhigh, max
      --gemini-effort <level>  Effort override for Gemini
      --claude-effort <level>  Effort override for Claude
      --gemini-engine <eng>    agy (default, uses Google subscription) or gemini-cli (uses GEMINI_API_KEY)
      --claude-engine <eng>    claude (default, uses Claude subscription) or agy
      --base <ref>             Diff against git ref (default: auto-detect origin/main, main, master)
      --staged                 Review only staged changes (git diff --cached)
      --pr <number>            Review pull request #<number> via gh pr diff
      --post                   Post findings to --pr using review/post-review.sh
      --fix                    Allow applying clear, contained fixes locally (never commits/pushes)
      --max-findings <n|all>   Cap findings per provider (default: all)
      --instructions <text>    Extra instructions appended to the review prompt
      --show-micro-costs       Include auxiliary models spending < $0.01 (default: hidden)
      --json                   Print merged findings JSON instead of formatted text
  -h, --help                   Show this help
EOF
}

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
IFS=',' read -r -a raw_list <<< "$providers_raw"
for item in "${raw_list[@]}"; do
  p=$(tr '[:upper:]' '[:lower:]' <<< "$item" | xargs)
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
  case "$eff" in
    low | medium | high | xhigh | max) ;;
    *) echo "Invalid effort '$eff': use low, medium, high, xhigh, or max." >&2; exit 2 ;;
  esac
done

if [ "$post_pr" = true ] && [ -z "$pr_number" ]; then
  echo "--post requires --pr <number>." >&2
  exit 2
fi

git rev-parse --show-toplevel > /dev/null 2>&1 || { echo "Run ai-review inside a git repository." >&2; exit 1; }
workspace=$(git rev-parse --show-toplevel)
cd "$workspace"

# Map model + effort to agy model IDs (e.g. gemini-4-neon-high, claude-opus-5-5-high).
lower() { tr '[:upper:]' '[:lower:]' <<< "$1"; }

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
        gemini-4-neon | gemini-4-hydrogen) suffix="xhigh" ;;
        *) suffix="high" ;;
      esac
      ;;
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

# Build the diff to review.
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT
diff_file="$state/review.diff"
target_desc=""

if [ -n "$pr_number" ]; then
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
    # Include both committed branch changes and uncommitted tracked edits.
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
  local out_file=$1 eff=$2
  python3 - "$out_file" "$diff_file" "$target_desc" "$eff" "$max_findings" "$fix" "$extra_instructions" <<'PY'
import pathlib, sys

out_path, diff_path, target_desc, effort, max_findings, fix_str, extra = sys.argv[1:8]
diff_text = pathlib.Path(diff_path).read_text(encoding="utf-8", errors="replace")
# Cap inline diff size to keep prompts snappy; the agent can read files directly for full context.
if len(diff_text) > 120000:
    diff_text = diff_text[:120000] + "\n... [diff truncated; inspect remaining files directly with read tools] ...\n"

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
  build_prompt "$prompt_file" "$gemini_effort"

  local start_ts end_ts dur rc=0 resolved_model="" is_sub=false
  start_ts=$(date +%s)
  if [ "$gemini_engine" = agy ]; then
    command -v agy > /dev/null 2>&1 || { echo "agy CLI not found in PATH (install Antigravity CLI or use --gemini-engine gemini-cli)." >&2; return 1; }
    local -a mode_args=()
    resolved_model=$(resolve_agy_gemini_model "$gemini_model" "$gemini_effort")
    is_sub=true
    [ "$fix" = true ] && mode_args=(--mode accept-edits)
    echo "[gemini] Running via agy (model=$resolved_model)..." >&2
    agy \
      --model "$resolved_model" \
      ${mode_args[@]+"${mode_args[@]}"} \
      --sandbox \
      --output-format json \
      --print "$(cat "$prompt_file")" \
      > "$json_out" 2> "$err_out" || rc=$?
    if [ -s "$json_out" ]; then
      jq -r '.response // ""' "$json_out" > "$raw_out" 2> /dev/null || cp "$json_out" "$raw_out"
    fi
  elif [ "$gemini_engine" = gemini-cli ]; then
    command -v gemini > /dev/null 2>&1 || { echo "gemini CLI not found in PATH." >&2; return 1; }
    resolved_model=$(resolve_gemini_api_model "$gemini_model")
    echo "[gemini] Running via gemini-cli (model=$resolved_model)..." >&2
    gemini --model "$resolved_model" \
      --output-format json \
      --prompt "$(cat "$prompt_file")" \
      > "$json_out" 2> "$err_out" || rc=$?
    if [ -s "$json_out" ]; then
      jq -r '.response // ""' "$json_out" > "$raw_out" 2> /dev/null || cp "$json_out" "$raw_out"
    fi
  else
    echo "Unknown --gemini-engine '$gemini_engine': use agy or gemini-cli." >&2
    return 1
  fi
  end_ts=$(date +%s)
  dur=$((end_ts - start_ts))
  [ "$dur" -ge 0 ] || dur=0

  # Save normalized stats (duration + tokens) for cost/timing display.
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
    extracted=$(python3 "$review_dir/extract-findings.py" < "$raw_out" || true)
    if [ -n "$extracted" ]; then
      jq -c 'map(if type == "object" then . + {provider: "gemini"} else . end)' <<< "$extracted" \
        > "$state/gemini-findings.json"
    fi
  fi
  echo "[gemini] Finished in ${dur}s (exit=$rc)" >&2
  [ "$rc" -eq 0 ] || { tail -n 10 "$err_out" >&2 || true; }
}

run_claude_provider() {
  local prompt_file="$state/claude-prompt.txt"
  local raw_out="$state/claude-raw.txt"
  local err_out="$state/claude-err.log"
  local json_out="$state/claude-out.json"
  build_prompt "$prompt_file" "$claude_effort"

  local start_ts end_ts dur rc=0 resolved_model="" is_sub=true
  start_ts=$(date +%s)
  if [ "$claude_engine" = claude ]; then
    command -v claude > /dev/null 2>&1 || { echo "claude CLI not found in PATH (install Claude Code or use --claude-engine agy)." >&2; return 1; }
    resolved_model=$claude_model
    [ -n "${ANTHROPIC_API_KEY:-}" ] && is_sub=false
    local tools_arg
    if [ "$fix" = true ]; then
      tools_arg="Read,Edit,Grep,Glob"
    else
      tools_arg="Read,Grep,Glob"
    fi
    echo "[claude] Running via claude CLI (model=$resolved_model, effort=$claude_effort)..." >&2
    claude --print \
      --model "$resolved_model" \
      --tools "$tools_arg" \
      --output-format json \
      "$(cat "$prompt_file")" \
      > "$json_out" 2> "$err_out" || rc=$?
    if [ -s "$json_out" ]; then
      jq -r '.result // ""' "$json_out" > "$raw_out" 2> /dev/null || cp "$json_out" "$raw_out"
    fi
  elif [ "$claude_engine" = agy ]; then
    command -v agy > /dev/null 2>&1 || { echo "agy CLI not found in PATH." >&2; return 1; }
    local -a mode_args=()
    resolved_model=$(resolve_agy_claude_model "$claude_model" "$claude_effort")
    [ "$fix" = true ] && mode_args=(--mode accept-edits)
    echo "[claude] Running via agy (model=$resolved_model)..." >&2
    agy \
      --model "$resolved_model" \
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
    return 1
  fi
  end_ts=$(date +%s)
  dur=$((end_ts - start_ts))
  [ "$dur" -ge 0 ] || dur=0

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
    extracted=$(python3 "$review_dir/extract-findings.py" < "$raw_out" || true)
    if [ -n "$extracted" ]; then
      jq -c 'map(if type == "object" then . + {provider: "claude"} else . end)' <<< "$extracted" \
        > "$state/claude-findings.json"
    fi
  fi
  echo "[claude] Finished in ${dur}s (exit=$rc)" >&2
  [ "$rc" -eq 0 ] || { tail -n 10 "$err_out" >&2 || true; }
}

wall_start=$(date +%s)
# Run providers in parallel when read-only; sequentially when --fix edits files.
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

merge_args=()
stats_files=()
if [ "$run_gemini" = true ]; then
  [ -f "$state/gemini-findings.json" ] && merge_args+=("gemini:$state/gemini-findings.json")
  [ -f "$state/gemini.stats.json" ] && stats_files+=("$state/gemini.stats.json")
fi
if [ "$run_claude" = true ]; then
  [ -f "$state/claude-findings.json" ] && merge_args+=("claude:$state/claude-findings.json")
  [ -f "$state/claude.stats.json" ] && stats_files+=("$state/claude.stats.json")
fi

stats_json='[]'
if [ "${#stats_files[@]}" -gt 0 ]; then
  stats_json=$(jq -sc '.' "${stats_files[@]}")
fi

merged=""
if [ "${#merge_args[@]}" -gt 0 ]; then
  merged=$(python3 "$review_dir/merge-findings.py" "${merge_args[@]}")
fi

if [ "$post_pr" = true ]; then
  repo_nwo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
  GITHUB_REPOSITORY="$repo_nwo" \
    PROVIDERS="$providers_csv" \
    "$review_dir/post-review.sh" "$pr_number" <<< "$merged"
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
    python3 "$local_dir/format-findings.py" <<< "$merged"
fi
