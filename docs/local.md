# Local review & hybrid setup

Run the same structured code review locally from **any** git repository using
**Gemini / Antigravity (`agy`)**, **Claude (`claude`)**, or **both in parallel** — consuming your
local subscriptions with zero pay-as-you-go API billing, and **no git clone required**.

## Recommended hybrid setup (\$0 pay-as-you-go)

| Stage | Provider | Authentication |
| --- | --- | --- |
| **Local (before opening / updating a PR)** | **Gemini 4 Neon** (`--provider antigravity` / `gemini`) via `agy` CLI | Google subscription (Antigravity) |
| **CI (GitHub Actions on PR open)** | **Claude Opus** (`providers: claude`) via `review` action | `CLAUDE_CODE_OAUTH_TOKEN` (Claude subscription) |

You get two independent frontier model families reviewing the same pull request without paying
per-token API fees — and you are free to flip or combine providers locally or in CI at any time.

## Install without cloning

Pick either installation method (both require zero manual cloning and update in one command):

### Option A: `ai-review` CLI + Agent Skill (recommended, `android` CLI style)

Installs `ai-review` into `~/.local/bin` from the latest GitHub Release and automatically links the
`/ai-review` skill into detected agents (Antigravity, Claude Code, Codex):

```bash
curl -fsSL https://raw.githubusercontent.com/Quartel-Enterprise/ai-review/main/install.sh | bash
```

Keep CLI + skill up to date anytime:

```bash
ai-review update
ai-review skills status
ai-review skills install --agent claude # or antigravity, codex, all
```

### Option B: `npx skills` (Agent Skill only, same ecosystem as `android/skills`)

Installs the self-contained `skills/ai-review/` bundle directly into Antigravity, Claude Code,
Codex, Cursor, and other compatible agents:

```bash
npx skills add Quartel-Enterprise/ai-review
```

Update anytime:

```bash
npx skills update
```

## Usage

Run `ai-review` inside any git repository:

```bash
# Default: Gemini 4 Neon (high) via Antigravity CLI on branch diff vs main
ai-review

# Equivalent explicit alias (`antigravity` == `gemini`)
ai-review --provider antigravity --effort xhigh

# Review with Claude locally (uses local `claude` CLI subscription)
ai-review --provider claude --model opus

# Run Claude and Gemini/Antigravity in parallel locally (consolidated report + timing + cost)
ai-review --provider claude,antigravity --effort high

# Apply clear, contained fixes locally (never commits or pushes)
ai-review --provider antigravity --fix

# Review only staged changes, or against a custom base branch
ai-review --staged
ai-review --base origin/develop

# Review a pull request (and optionally post as one GitHub PR review)
ai-review --provider antigravity --pr 42
ai-review --provider antigravity --pr 42 --post
```

## Subcommands & Options

| Command / Flag | Default | Description |
| --- | --- | --- |
| `ai-review update [--version <tag>]` | latest release | Updates the installed CLI and bundled skill from GitHub Releases (or `git pull` in a clone) |
| `ai-review skills install\|remove\|status` | detected agents | Links, removes, or inspects `/ai-review` skill links (`--agent all\|antigravity\|claude\|codex`, `--project <dir>`) |
| `ai-review version` | | Prints the installed version |
| `-p`, `--provider` | `gemini` | `gemini`, `antigravity` (alias for `gemini`), `claude`, or comma-separated (`claude,antigravity`) |
| `--fallback` | none | Fallback provider (`claude`, `gemini`, or `antigravity`) if the primary provider fails (e.g. quota limit) or returns no findings list |
| `-m`, `--model` | provider default | Shorthand model alias/id for the single selected provider, or for Gemini when both run (use `--gemini-model` / `--claude-model` for multi-provider runs) |
| `--gemini-model` | `neon` (`gemini-4-neon`) | `neon`, `carbon`, `argon`, `hydrogen`, or full model id |
| `--claude-model` | `opus` | `opus`, `sonnet`, `haiku`, or full model id |
| `-e`, `--effort` | `high` | `low`, `medium`, `high`, `xhigh`, or `max` |
| `--gemini-effort`, `--claude-effort` | inherits `--effort` | Per-provider effort override |
| `--gemini-engine` | `agy` | `agy` (Google subscription) or `gemini-cli` (`GEMINI_API_KEY`) |
| `--claude-engine` | `claude` | `claude` (Claude subscription) or `agy` |
| `--base <ref>` | auto (`origin/main`, `main`, `master`) | Diff against a git ref (includes committed + uncommitted tracked edits) |
| `--staged` | off | Review staged changes only (`git diff --cached`) |
| `--pr <number>` | none | Review PR `#<number>` via `gh pr diff` |
| `--post` | off | Post merged findings to `--pr` via `post-review.sh` |
| `--fix` | off | Allow applying clear local fixes (runs providers sequentially when multiple are enabled) |
| `--max-findings` | `all` | Cap findings per provider (`all` or positive integer) |
| `--instructions` | empty | Extra review instructions |
| `--show-micro-costs` | off | Include auxiliary models spending under \$0.01 in the cost summary |
| `--json` | off | Output merged findings JSON instead of formatted terminal text |
