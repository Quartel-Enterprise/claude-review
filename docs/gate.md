# The gate

Optional. Every workflow that builds or tests your project starts with a `review-gate` job, so its
checks run once: after the review when it pushed nothing, or on its fix commit. The job lives in your
repository as a reusable workflow, since its last step's name is what `threads`' `rerun-held` looks
for. Save it as `.github/workflows/review-gate.yml`:

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
        uses: Quartel-Enterprise/claude-review/gate@1.5.0
        with:
          # bot-login: my-review-app[bot] # with your own GitHub App
          # A few minutes under timeout-minutes, so a stuck review lets the checks run.
          wait-minutes: 40
      # The step's name is what the threads action's rerun-held looks for.
      - name: Hold for the open threads
        if: steps.gate.outputs.open-threads != ''
        env:
          OPEN_THREADS: ${{ steps.gate.outputs.open-threads }}
        run: |
          echo "::error::claude-review left $OPEN_THREADS open thread(s), so this workflow's checks didn't run."
          exit 1
```

Each check workflow adds `ready_for_review` to its `pull_request` types and calls the gate on the
events the review runs on, plus the review's own fix commit. Every other event skips the gate job.
Every job that needs the gate carries the `if` below, so it still runs on a skipped gate and is
skipped only when the gate says `false`:

```yaml
name: build
on:
  pull_request:
    types:
      - opened
      - synchronize
      - reopened
      - ready_for_review

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

On the opening commit, a draft's ready commit and the fix commit, the gate waits for the review run
of the reviewed commit (`review-workflow`, `.github/workflows/claude-review.yml` by default), once a
minute, or every 10 seconds on the fix commit, which is pushed seconds before the review ends. On a
draft marked ready, only a review run the same event created counts, since the commit may already
have a skipped or completed one. When the head moved meanwhile, `proceed` is `false`: the push
started the checks again on the new commit. Once the review ended, `proceed` is `false` and
`open-threads` says how many while a thread the review opened (`bot-login`'s, `claude[bot]` by
default, or `github-actions[bot]`'s when the fallback step posted) is unresolved: the author is about
to push the fixes, and that push runs the checks. The hold step then fails the gate job, so the pull
request shows a failed `review-gate` check saying why, rather than skipped checks that look green.

The gate never fails on its own. A draft or a fork passes right away, and so does a commit with no
review run after a minute (a skipped review, a Dependabot pull request), a failed or cancelled
review, GitHub's API failing three times in a row, or a review still running after `wait-minutes`.
When the review's workflow has another path than `review-workflow`, the gate finds no run on any
commit and lets every check through: it then warns that the repository has no workflow at that path,
so set `review-workflow` to the path of yours.

| Input | Default | |
| --- | --- | --- |
| `review-workflow` | `.github/workflows/claude-review.yml` | The path of the workflow that runs the opening review |
| `wait-minutes` | `40` | How long to wait for the review. Keep it a few minutes under the job's `timeout-minutes`, or a stuck review gets the job cancelled instead |
| `bot-login` | `claude[bot]` | The review's `bot-login` |
| `token` | `github.token` | A token that reads actions and pull requests |

| Output | |
| --- | --- |
| `proceed` | `'false'` when the checks run on a newer head instead, or are held for the review's open threads; `'true'` otherwise |
| `open-threads` | How many of the review's threads hold the checks; empty when none does |

To keep a pull request from merging while the review's threads are open, make the gate's check (or
the checks after it) required in a branch ruleset, and consider the ruleset's "Require conversation
resolution before merging" rule.
