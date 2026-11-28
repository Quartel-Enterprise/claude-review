# The review

The workflow that runs the review is in the [README's setup](../README.md#setup). This page covers
its inputs, outputs, multi-provider modes, and what the review does with a pull request.

## Inputs

The action reads the pull request from the `pull_request` event, so call it from a workflow that
runs on `pull_request`. Drop `fix: 'true'` for a review that only comments.

| Input | Default | Description |
| --- | --- | --- |
| `providers` | **required** | Comma-separated list of providers to run: `claude`, `gemini` (or alias `antigravity`), or `claude,gemini` |
| `claude-oauth-token`, `anthropic-api-key` | | Claude Code OAuth token or Anthropic API key. Set exactly one when `claude` is enabled |
| `gemini-api-key` | | Google AI Studio Gemini API key. Required when `gemini` is enabled |
| `claude-model` | `opus` *(when `claude` enabled)* | Alias (`opus`, `sonnet`, `haiku`) or full model id |
| `gemini-model` | `gemini-4-neon` *(when `gemini` enabled)* | Alias (`carbon`, `neon`, `argon`, `hydrogen`) or full model id |
| `effort` | `'high'` | Shared default effort for all providers: `low`, `medium`, `high`, `xhigh` or `max` |
| `claude-effort` | inherits `effort` | Optional effort override for Claude |
| `gemini-effort` | inherits `effort` | Optional effort override for Gemini (maps to `thinkingLevel` up to each model's ceiling) |
| `allow-custom-effort` | `'false'` | `'true'` to allow non-standard effort levels beyond `low`/`medium`/`high`/`xhigh`/`max` (`ultra` is always rejected) |
| `gemini-cli-version` | `'0.71.1'` | Pinned `@google/gemini-cli` npm version |
| `max-findings` | `'all'` | `'all'` or a positive number: each provider keeps at most that many findings, most severe first |
| `fix` | `'false'` | `'true'` to apply clear, contained findings and push them as one commit to the pull request's branch |
| `cost` | `'true'` | `'true'` to comment what the run cost and how long each provider took. See [What a run costs and takes](cost.md) |
| `show-micro-costs` | `'false'` | `'true'` to include auxiliary models under \$0.01 (such as Haiku background calls) in the cost table and total |
| `instructions` | `''` | Extra instructions appended to the review prompt |
| `allowed-bots` | `''` | Bots whose pull requests are reviewed too, as comma-separated logins without `[bot]` (e.g. `renovate`) |
| `github-token`, `bot-login`, `bot-id` | none | Review as your own GitHub App. When `github-token` is set, `bot-login` and `bot-id` are **required**. Without it, defaults to `claude[bot]` (`209825114`) when `claude` is enabled, or `github-actions[bot]` (`41898282`) for Gemini-only runs |
| `memory-repository`, `memory-ssh-key`, `memory-files` | none | Private review conventions. When `memory-repository` is set, both `memory-ssh-key` and `memory-files` are **required** |

## Outputs

| Output | Description |
| --- | --- |
| `total-duration-seconds` | Sum of execution times across all enabled providers, in seconds |
| `provider-durations` | JSON object mapping each provider name to its execution duration in seconds (e.g. `{"gemini":95,"claude":140}`) |
| `total-cost-usd` | Total reported/estimated cost in USD (after applying `show-micro-costs`), or empty when no provider's cost could be computed |

## Gemini models and thinking levels

| Alias | Resolved model ID | Positioning | Supported `thinkingLevel` |
| --- | --- | --- | --- |
| `neon` *(default)* | `gemini-4-neon` | Balanced frontier engineering & debugging | `LOW`, `MEDIUM`, `HIGH`, `XHIGH` |
| `carbon` | `gemini-4-carbon` | Maximum deep reasoning & architecture | `LOW`, `MEDIUM`, `HIGH` |
| `argon` | `gemini-4-argon` | Efficient frontier reasoning | `LOW`, `MEDIUM`, `HIGH` |
| `hydrogen` | `gemini-4-hydrogen` | Fast, economical daily driver | `LOW`, `MEDIUM`, `HIGH`, `XHIGH` |

Passing `effort: max` maps to `XHIGH` on `gemini-4-neon` and `gemini-4-hydrogen`, and caps cleanly
at `HIGH` on `gemini-4-carbon` and `gemini-4-argon`.

## Running multiple providers

You have two ways to run both Claude and Gemini on the same pull request:

1. **Consolidated in one job (`providers: claude,gemini`):** Gemini runs first, then Claude runs
   second, and all findings are merged into **one pull request review** (with `**Claude**` /
   `**Gemini**` badges on every comment and per-provider counts in the summary) and **one cost &
   timing comment** showing individual and total durations. Compatible with `fix: 'true'`.
2. **Parallel in two jobs (matrix):** run one job with `providers: claude` and another with
   `providers: gemini` (with `fix: 'false'`). Wall-clock time drops to the slower of the two, and
   each job tags its own review and cost comment with its provider name so they never collide.

## Fixes

With `fix: 'true'`, the model may edit existing tracked files of the checkout — never under `.git`,
`.github`, `.claude`, `.gemini` or `.agent-memory` — and can't create files. Before posting,
`commit-fixes.sh` commits the changed tracked files as `bot-login` and pushes them without forcing.
Nothing is pushed when no finding is marked fixed, when a fix touches `.github`, `.claude` or
`.gemini`, when the working tree has an untracked file, when a fix adds a token-shaped string, or
when the branch moved during the review.

For Gemini-only runs with `fix: 'true'`, either grant `permissions: contents: write` on the job
(pushes made with the default `GITHUB_TOKEN` will not trigger downstream pull request workflows),
or provide a GitHub App token via `github-token` (along with `bot-login` and `bot-id`) so pushes
trigger `gate` and check workflows.

A cheaper, fast Gemini review:

```yaml
      - uses: Quartel-Enterprise/ai-review/review@2.0.0
        with:
          providers: gemini
          gemini-api-key: ${{ secrets.GEMINI_API_KEY }}
          gemini-model: hydrogen
          effort: medium
          max-findings: '10'
```

## Reviewing again

The review runs when the pull request opens or a draft is marked ready. A reopened pull request isn't
reviewed, and neither is a later push, the fix commit included. A draft marked ready a second time is
reviewed again. To review again on demand, add a workflow on `pull_request: types: [labeled]` and
pass `instructions` to explain why.

## Pull requests opened with a conflict

GitHub starts no `pull_request` workflow while a pull request conflicts with its base, so one opened
or marked ready with a conflict gets no review on that event. With `synchronize` among the workflow's
types, the push that solves the conflict brings it: on a `synchronize` event, the action reviews only
when the calling workflow has no earlier run since the pull request opened (or was last marked ready),
and never on a push by `bot-login`.

## Your own GitHub App

To post and push as a GitHub App of your own, mint its installation token in an earlier step and
pass `github-token`, `bot-login`, and `bot-id` (both are required whenever `github-token` is set):

```yaml
      - id: app
        uses: actions/create-github-app-token@v3
        with:
          client-id: ${{ vars.REVIEW_APP_CLIENT_ID }}
          private-key: ${{ secrets.REVIEW_APP_PRIVATE_KEY }}
      - uses: Quartel-Enterprise/ai-review/review@2.0.0
        with:
          providers: gemini
          gemini-api-key: ${{ secrets.GEMINI_API_KEY }}
          github-token: ${{ steps.app.outputs.token }}
          bot-login: my-review-app[bot]
          bot-id: '123456789' # gh api 'users/my-review-app[bot]' --jq .id
          fix: 'true'
```

The App needs read and write access to contents and pull requests. Pass the same `bot-login` to
`gate` and `threads`.

## Private conventions

The review follows `AGENTS.md`, `CLAUDE.md`, and `GEMINI.md` in the checkout. When private
conventions live in another repository, set all three of `memory-repository`, `memory-ssh-key`, and
`memory-files` (sparse-checkout pattern such as `conventions/*.md`). The files are checked out into
`.agent-memory` and the review is instructed never to quote them or name their paths in comments.
