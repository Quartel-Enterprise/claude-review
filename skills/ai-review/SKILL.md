---
name: ai-review
description: Run a local AI code review on the current branch, staged diff, or pull request using Gemini/Antigravity (`agy`), Claude (`claude`), or both in parallel — consuming your local subscriptions with zero pay-as-you-go API cost. Use whenever the user asks to review local changes, run a Gemini/Antigravity review before opening a PR, or cross-review with another model family.
---

# AI Review (Local Skill)

Run a structured local code review using the same findings format (`🔴 Must fix`, `🟡 Should fix`,
`⚪ Nitpick`), conventions (`AGENTS.md`, `CLAUDE.md`, `GEMINI.md`), timing, and API-equivalent cost
reporting as the `ai-review` GitHub Actions.

## How to run

This skill bundles its own self-contained CLI at `scripts/ai-review.sh` (next to this `SKILL.md`).
Run `ai-review` if it is on `PATH`, or invoke `scripts/ai-review.sh` directly from this skill's
directory — no repository clone is required.

- **Gemini / Antigravity (`--provider gemini` or `--provider antigravity`):** uses the local `agy`
  CLI authenticated with your Google subscription by default (`gemini-4-neon-high`). Pass
  `--gemini-engine gemini-cli` to use `GEMINI_API_KEY` instead.
- **Claude (`--provider claude`):** uses the local `claude` CLI authenticated with your Claude
  subscription by default (`opus`). Pass `--claude-engine agy` to run Claude via Antigravity.

## Common Workflows

### 1. Hybrid setup (zero pay-as-you-go cost)
- **Locally (before pushing / opening a PR):** review with Gemini via Antigravity subscription:
  ```bash
  ai-review --provider antigravity --effort high
  ```
- **In CI (GitHub Actions):** run `providers: claude` with `CLAUDE_CODE_OAUTH_TOKEN`.

### 2. Cross-review with a second model family
- Coding in Claude Code → run `ai-review --provider antigravity` (Gemini 4 Neon).
- Coding in Antigravity (Gemini) → run `ai-review --provider claude` (Claude Opus).
- Want both at once (runs in parallel when read-only):
  ```bash
  ai-review --provider claude,antigravity --effort high
  ```

### 3. Apply clear local fixes (no commit or push)
```bash
ai-review --provider antigravity --fix
git diff
```

### 4. Review an existing pull request (and optionally post the review)
```bash
ai-review --provider antigravity --pr 42
ai-review --provider antigravity --pr 42 --post
```

## Updating

- Installed via `npx skills add Quartel-Enterprise/ai-review`: run `npx skills update`.
- Installed via `install.sh`: run `ai-review update` (and `ai-review skills status` to verify).

## Options

- `-p`, `--provider`: `gemini`, `antigravity` (alias for `gemini`), `claude`, or `claude,antigravity`
- `--gemini-model`: `neon` (default, `gemini-4-neon`), `carbon`, `argon`, `hydrogen`, or full id
- `--claude-model`: `opus` (default), `sonnet`, `haiku`, or full id
- `-e`, `--effort`: `low`, `medium`, `high` (default), `xhigh`, `max`
- `--base <ref>`, `--staged`, `--pr <N>`, `--post`, `--fix`, `--max-findings <n|all>`, `--show-micro-costs`, `--json`
