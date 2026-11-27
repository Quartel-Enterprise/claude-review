# Migrating from v1 (`claude-review`) to v2 (`ai-review`)

Version **2.0.0** is a breaking release that rebrands `claude-review` to `ai-review`, adds
**Gemini / Antigravity** and **multi-provider** support, removes Claude-only defaults from `gate`
and `threads`, adds per-provider timing and `show-micro-costs`, and introduces the local CLI and
`/ai-review` skill.

> **Important:** Bump `review`, `gate`, and `threads` to `@2.0.0` together in the same pull request.
> Because `claude-code-action` refuses to review a pull request that edits its own workflow file,
> the migration pull request itself won't be reviewed by Claude; open a small follow-up PR to verify.

---

## Summary of breaking changes

### 1. Action references

Update every `uses:` from `claude-review` to `ai-review` at `@2.0.0`:

| v1 (`1.x`) | v2 (`2.0.0`) |
| --- | --- |
| `Quartel-Enterprise/claude-review/review@1.5.0` | `Quartel-Enterprise/ai-review/review@2.0.0` |
| `Quartel-Enterprise/claude-review/gate@1.5.0` | `Quartel-Enterprise/ai-review/gate@2.0.0` |
| `Quartel-Enterprise/claude-review/threads@1.5.0` | `Quartel-Enterprise/ai-review/threads@2.0.0` |

### 2. `review` action (`review/action.yml`)

| v1 input | v2 input / behaviour | Notes |
| --- | --- | --- |
| *(implicit Claude)* | **`providers`** *(required)* | Must be set explicitly: `claude`, `gemini` (or alias `antigravity`), or `claude,gemini` |
| `oauth-token` | **`claude-oauth-token`** | Renamed to clarify which provider owns the OAuth token |
| `anthropic-api-key` | `anthropic-api-key` | Unchanged; set exactly one of `claude-oauth-token` and `anthropic-api-key` when `claude` is enabled |
| *(none)* | `gemini-api-key` | Required when `gemini` (or `antigravity`) is enabled |
| `model` (default `opus`) | **`claude-model`** / **`gemini-model`** | Split per provider. Empty defaults to `opus` (Claude) and `gemini-4-neon` (Gemini) |
| `effort` (default `high`) | `effort` + `claude-effort` / `gemini-effort` | `effort` stays the shared default (`high`); optional per-provider overrides |
| `github-token` with default `bot-login`/`bot-id` | `bot-login` and `bot-id` **required** when `github-token` is set | Fails early in "Check the inputs" instead of logging a warning |
| `memory-repository` | `memory-ssh-key` and `memory-files` **required** when `memory-repository` is set | Fails early instead of skipping with a warning |
| *(none)* | `show-micro-costs` (default `'false'`) | Auxiliary models under \$0.01 (e.g. Haiku background calls) are now hidden from the cost table and total by default |
| *(no outputs)* | `total-duration-seconds`, `provider-durations`, `total-cost-usd` | New outputs for timing and cost |

### 3. `gate` action (`gate/action.yml`)

| v1 input | v2 input / behaviour | Notes |
| --- | --- | --- |
| `bot-login` (default `claude[bot]`) | **`bot-login` *(required)*** | No default in v2 — pass `claude[bot]`, `github-actions[bot]`, or your custom App's bot login |
| `review-workflow` (default `.github/workflows/claude-review.yml`) | `review-workflow` (default **`.github/workflows/ai-review.yml`**) | Rename your workflow file to `ai-review.yml` or pass `review-workflow` explicitly |

### 4. `threads` action (`threads/action.yml`)

| v1 input | v2 input / behaviour | Notes |
| --- | --- | --- |
| `claude-only` (default `'false'`) | **`review-only`** (default `'false'`) | Renamed to a provider-neutral name |
| `bot-login` (default `claude[bot]`) | **`bot-login` *(required when `review-only: 'true'`)*** | No default in v2 |
| `pull-request` / `sha` | Validated as required per `command` | Fails early if omitted for `open-threads` / `rerun-held` |

---

## Step-by-step YAML migration

### Step 1: Rename and update the review workflow

Rename `.github/workflows/claude-review.yml` → `.github/workflows/ai-review.yml` (and update
`name: claude-review` → `name: ai-review`).

**Before (v1):**

```yaml
      - uses: Quartel-Enterprise/claude-review/review@1.5.0
        with:
          oauth-token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
          model: opus
          effort: high
          fix: 'true'
```

**After (v2 — Claude in CI, keeping your Claude subscription):**

```yaml
      - uses: Quartel-Enterprise/ai-review/review@2.0.0
        with:
          providers: claude
          claude-oauth-token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
          # Optional — defaults to opus and high:
          claude-model: opus
          effort: high
          fix: 'true'
```

**After (v2 — Gemini in CI, or both Claude and Gemini):**

```yaml
      - uses: Quartel-Enterprise/ai-review/review@2.0.0
        with:
          providers: claude,gemini
          claude-oauth-token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
          gemini-api-key: ${{ secrets.GEMINI_API_KEY }}
          effort: high
          fix: 'true'
```

> If you also have an on-demand workflow (such as `.github/workflows/claude-review-on-request.yml`),
> apply the same input changes there (`providers`, `claude-oauth-token`, `claude-model`).

### Step 2: Update `.github/workflows/review-gate.yml` (if you use `gate`)

**Before (v1):**

```yaml
      - id: gate
        uses: Quartel-Enterprise/claude-review/gate@1.5.0
        with:
          wait-minutes: 40
```

**After (v2):**

```yaml
      - id: gate
        uses: Quartel-Enterprise/ai-review/gate@2.0.0
        with:
          bot-login: claude[bot] # or github-actions[bot] / your-app[bot]
          wait-minutes: 40
```

> If you kept the review workflow at `.github/workflows/claude-review.yml` instead of renaming it to
> `.github/workflows/ai-review.yml`, also pass `review-workflow: .github/workflows/claude-review.yml`.

### Step 3: Update `threads` workflows (e.g. `run-checks.yml`, `merge-when-green.yml`)

**Before (v1):**

```yaml
      - id: open
        uses: Quartel-Enterprise/claude-review/threads@1.5.0
        with:
          command: open-threads
          pull-request: ${{ github.event.pull_request.number }}
          claude-only: 'true'
      - if: steps.open.outcome == 'success' && steps.open.outputs.count == '0'
        uses: Quartel-Enterprise/claude-review/threads@1.5.0
        with:
          command: rerun-held
          sha: ${{ github.event.pull_request.head.sha }}
```

**After (v2):**

```yaml
      - id: open
        uses: Quartel-Enterprise/ai-review/threads@2.0.0
        with:
          command: open-threads
          pull-request: ${{ github.event.pull_request.number }}
          review-only: 'true'
          bot-login: claude[bot] # or github-actions[bot] / your-app[bot]
      - if: steps.open.outcome == 'success' && steps.open.outputs.count == '0'
        uses: Quartel-Enterprise/ai-review/threads@2.0.0
        with:
          command: rerun-held
          sha: ${{ github.event.pull_request.head.sha }}
```

### Step 4: Update auxiliary scripts, ref checks, and Dependabot/Renovate

Search the repository for any remaining `claude-review` references:

```bash
grep -rn "claude-review" .github scripts docs
```

Common places to update:
- Ref-consistency check workflows/scripts (e.g. `claude-review-refs.yml`) that assert every action
  uses the same pinned tag.
- `.github/dependabot.yml` or `renovate.json` package-grouping rules referencing `claude-review`.
- Check workflow `if:` conditions on `github.event.sender.login == 'claude[bot]'` if you changed
  `bot-login`.

---

## Optional: Enable the hybrid local + CI setup

If you want **Gemini locally** (using your Google subscription via Antigravity `agy`) alongside
**Claude in CI** (using `CLAUDE_CODE_OAUTH_TOKEN`) with zero pay-as-you-go API cost, see
[Local review & hybrid setup](../docs/local.md).

---

## Migration checklist

- [ ] Updated every `uses:` from `claude-review/*@1.x` to `ai-review/*@2.0.0`
- [ ] Added `providers:` to every `review` step and renamed `oauth-token` → `claude-oauth-token`, `model` → `claude-model` / `gemini-model`
- [ ] Renamed `.github/workflows/claude-review.yml` → `.github/workflows/ai-review.yml` (or set `review-workflow:` on `gate`)
- [ ] Added explicit `bot-login:` to every `gate` step and every `threads` step with `review-only: 'true'`
- [ ] Renamed `claude-only:` → `review-only:` on `threads` steps
- [ ] Updated any `github-token` setups to pass both `bot-login` and `bot-id`
- [ ] Updated any `memory-repository` setups to pass both `memory-ssh-key` and `memory-files`
- [ ] Updated ref-check scripts, Dependabot/Renovate rules, and repo docs
- [ ] Opened a follow-up test PR after merging to verify the review, gate, threads, and cost/timing comment
