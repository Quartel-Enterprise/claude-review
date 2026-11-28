# The gate

Optional. Every workflow that builds or tests your project starts with a `review-gate` job, so its
checks run once: after the review when it pushed nothing, or on its fix commit. Save it as
`.github/workflows/review-gate.yml`:

```yaml
name: review-gate
on:
  workflow_call:
    outputs:
      proceed:
        value: ${{ jobs.wait.outputs.proceed }}

jobs:
  wait:
    name: wait for review
    runs-on: ubuntu-latest
    timeout-minutes: 45
    permissions:
      actions: read
      pull-requests: read
    outputs:
      proceed: ${{ steps.gate.outputs.proceed }}
    steps:
      - id: gate
        uses: Quartel-Enterprise/ai-review/gate@2.0.0
        with:
          # Required: set to claude[bot], github-actions[bot], or your GitHub App's bot.
          bot-login: claude[bot]
          # A few minutes under timeout-minutes, so a stuck review lets the checks run.
          wait-minutes: 40
      # The step's name is what the threads action's rerun-held looks for.
      - name: Hold for the open threads
        if: steps.gate.outputs.open-threads != ''
        env:
          OPEN_THREADS: ${{ steps.gate.outputs.open-threads }}
        run: |
          echo "::error::ai-review left $OPEN_THREADS open thread(s), so this workflow's checks didn't run."
          exit 1
```

Each check workflow adds `ready_for_review` to its `pull_request` types and calls the gate on the
events the review runs on, plus the review's own fix commit:

```yaml
name: build
on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]

jobs:
  review-gate:
    if: >-
      github.event.action == 'opened' || github.event.action == 'ready_for_review' ||
      (github.event.action == 'synchronize' && github.event.sender.login == 'claude[bot]')
    uses: ./.github/workflows/review-gate.yml
    permissions:
      actions: read
      pull-requests: read

  build:
    needs: review-gate
    if: ${{ !cancelled() && needs.review-gate.outputs.proceed != 'false' }}
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - run: echo "Your build and tests here"
```

Replace `'claude[bot]'` with your `bot-login` if you use a custom GitHub App (for example,
`my-review-app[bot]`).

| Input | Default | Description |
| --- | --- | --- |
| `bot-login` | **required** | The review's `bot-login` (`claude[bot]`, `github-actions[bot]`, or your GitHub App's bot) |
| `review-workflow` | `.github/workflows/ai-review.yml` | The path of the workflow that runs the opening review |
| `wait-minutes` | `'40'` | How long to wait for the review before letting checks run |
| `token` | `github.token` | A token that reads actions and pull requests |

| Output | Description |
| --- | --- |
| `proceed` | `'false'` when the checks run on a newer head instead, or are held for the review's open threads; `'true'` otherwise |
| `open-threads` | How many of the review's threads hold the checks; empty when none does |

The gate never fails on its own (except via the caller's hold step when threads are unresolved). A
draft, fork, skipped/failed/cancelled review, or a review exceeding `wait-minutes` lets checks run.
