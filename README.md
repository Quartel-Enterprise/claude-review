# ai-review

AI code review with **Claude**, **Gemini**, or **both at once** — **locally before you even open a
pull request** (via the `ai-review` CLI or `/ai-review` agent skill) and **automatically in GitHub
Actions**. It works for any repository and any language: the reviewer reads the diff and files of
the checkout, and runs none of your code.

| Surface | What it does |
| --- | --- |
| **Local CLI & `/ai-review` skill** | Reviews your local branch, staged changes, or any pull request before opening or merging a PR — using your existing **Claude Code** (`claude`) and **Google Antigravity** (`agy`) subscriptions (or API keys), with zero git clone required |
| **`review` (GitHub Action)** | Runs Claude Code (`opus` at `high` effort by default), Gemini CLI (`gemini-4-neon` at `high` thinking level by default), or both in CI, optionally applies fixes, and posts all findings as one pull request review with clear provider attribution |
| **`gate` (GitHub Action)** | Waits for the opening review of the pull request's commit, and tells your check workflows whether to run |
| **`threads` (GitHub Action)** | Counts the review's unresolved threads, or re-runs the checks the gate held for them |

You can use the **local CLI / skill on its own** (no CI setup needed), use **`review` in CI on its
own**, or combine both (for example, Gemini locally via your subscription + Claude in CI). Add
`gate` and `threads` when CI pushes fixes (`fix: 'true'`) and you want your checks (build, tests,
lint) to run once, on the final commit, instead of once on the opened commit and again on the fix
commit.

## Local review (before opening a PR)

Review your branch or staged changes right from your terminal — or from Antigravity, Claude Code,
or Codex via `/ai-review` — before pushing or opening a pull request:

```bash
# Install the CLI + /ai-review skill (no git clone required)
curl -fsSL https://raw.githubusercontent.com/Quartel-Enterprise/ai-review/main/install.sh | bash

# Or install only the Agent Skill
npx skills add Quartel-Enterprise/ai-review
```

```bash
# Review your current branch with Gemini, falling back to Claude on quota/errors
ai-review --provider antigravity --fallback claude

# Review only staged changes before committing
ai-review --staged

# Run Claude and Gemini in parallel on your local changes
ai-review --provider claude,antigravity --effort high

# Review an existing PR locally (add --post to publish as one GitHub PR review)
ai-review --provider claude --pr 42
```

Update anytime with `ai-review update`. See [Local review & hybrid setup](docs/local.md) for all
flags, `--fix`, `--json`, and subscription/API key configuration.

## What you get

When a pull request opens, or a draft is marked ready for review, the review posts one pull request
review titled **Code review · Claude**, **Code review · Gemini**, or **Code review · Claude + Gemini**:

- Each finding left for the author is an inline comment, labelled 🔴 **Must fix**, 🟡 **Should fix**
  or ⚪ **Nitpick**, most severe first, with the provider name (**Claude** or **Gemini**) and a
  GitHub suggestion when replacing the commented lines fully fixes it.
- With `fix: 'true'`, the findings it could fix are pushed as one commit
  (`fix: apply the AI review findings` — or named after the single provider) and listed in the
  review's body under that commit.
- With `cost: 'true'` (default), a summary comment reports per-provider and total **execution time**
  and **cost** (hiding auxiliary micro-costs under \$0.01 by default).
- With no finding, the review says "No findings."

The review comments only: it never approves or requests changes. Later pushes to the pull request
aren't reviewed again (see [Reviewing again](docs/review.md#reviewing-again)).

## Requirements

- A GitHub repository where you can add secrets and workflows. Pull requests from forks are never
  reviewed, since GitHub withholds secrets from them.
- Credentials for the provider(s) you list in `providers`:
  - **Gemini (`providers: gemini`):** `GEMINI_API_KEY` from [Google AI Studio](https://aistudio.google.com/).
  - **Claude (`providers: claude`):** either `CLAUDE_CODE_OAUTH_TOKEN` (`claude setup-token`) or
    `ANTHROPIC_API_KEY` from the [Claude Console](https://console.anthropic.com/), plus the
    [Claude GitHub App](https://github.com/apps/claude) installed on the repository (or
    [your own GitHub App](docs/review.md#your-own-github-app) via `github-token`). When using the
    Claude GitHub App without `github-token`, the job also needs `permissions: id-token: write` to
    exchange the workflow's OIDC token.
  - **Both (`providers: claude,gemini`):** credentials for both providers.
- An Ubuntu runner (`ubuntu-latest`).

## Setup

Add `.github/workflows/ai-review.yml`. Keep that path if you will use `gate`: it is the gate's
default `review-workflow`.

### Gemini only

```yaml
name: ai-review
on:
  pull_request:
    types: [opened, ready_for_review, synchronize]

concurrency:
  group: >-
    ${{ github.workflow }}-${{ github.event.pull_request.number
    }}${{ github.event.action == 'synchronize' && format('-{0}', github.run_id) || '' }}
  cancel-in-progress: true

jobs:
  review:
    if: >-
      !github.event.pull_request.draft &&
      github.event.pull_request.head.repo.full_name == github.repository &&
      github.actor != 'dependabot[bot]'
    runs-on: ubuntu-latest
    timeout-minutes: 30
    permissions:
      actions: read
      contents: read
      pull-requests: write
      issues: read
    steps:
      - uses: actions/checkout@v7
        with:
          ref: ${{ github.event.pull_request.head.sha }}
          fetch-depth: 0
          persist-credentials: false
      - uses: Quartel-Enterprise/ai-review/review@2.0.0
        with:
          providers: gemini
          gemini-api-key: ${{ secrets.GEMINI_API_KEY }}
```

### Both Claude and Gemini on the same pull request

When `claude` is enabled without `github-token`, add `id-token: write` to the job's `permissions`:

```yaml
    permissions:
      actions: read
      contents: read
      pull-requests: write
      issues: read
      id-token: write
    steps:
      - uses: actions/checkout@v7
        with:
          ref: ${{ github.event.pull_request.head.sha }}
          fetch-depth: 0
          persist-credentials: false
      - uses: Quartel-Enterprise/ai-review/review@2.0.0
        with:
          providers: claude,gemini
          claude-oauth-token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
          gemini-api-key: ${{ secrets.GEMINI_API_KEY }}
          effort: high
          fix: 'true'
```

Need lower wall-clock latency when running both providers without `fix: 'true'`? You can also run
two parallel matrix jobs (one with `providers: claude` and one with `providers: gemini`): each job
tags its own review and cost comment independently so they never collide.

All inputs and outputs (`claude-model`, `gemini-model`, `effort`, `show-micro-costs`,
`allowed-bots`, your own GitHub App, private conventions, ...) are in [The review](docs/review.md).

## Where to go next

| | |
| --- | --- |
| [The review](docs/review.md) | Inputs, outputs, multi-provider setups, fixes, reviewing again, your own GitHub App, private conventions |
| [Local review & hybrid setup](docs/local.md) | Install `ai-review` CLI (`install.sh` + `ai-review update`) or `/ai-review` skill (`npx skills add`) with zero cloning |
| [The gate](docs/gate.md) | Hold your checks until the review ends, so they run once, on the final commit |
| [The threads](docs/threads.md) | Re-run the held checks once the review's threads are resolved |
| [What a run costs and takes](docs/cost.md) | The cost & timing comment, micro-cost filtering, and how figures are computed |
| [Security model](docs/security-model.md) | What Claude and Gemini can read and run, and what is left |
| [When something goes wrong](docs/troubleshooting.md) | Symptoms and fixes |
| [Migrating from v1 to v2](migrations/v1-to-v2.md) | Breaking changes, before/after YAML snippets, and migration checklist |

## Versions

Pin an exact release in every `uses:` (`@2.0.0`, the latest
[release](https://github.com/Quartel-Enterprise/ai-review/releases)) and bump all of them together:
the gate and the threads action have to agree on which threads hold the checks and which step name
marks a hold. Releases are immutable, so a tag always means the same code.

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md) to propose a change, and [SECURITY.md](SECURITY.md) to report a
vulnerability.
