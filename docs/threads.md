# The threads

Resolving a thread starts no workflow, so the held checks need something else to run them: a label,
or a merge-when-green workflow once every conversation is resolved. This workflow re-runs them when
the `run-checks` label is added and every thread the review opened is resolved:

```yaml
name: run-checks
on:
  pull_request:
    types:
      - labeled

jobs:
  rerun:
    if: github.event.label.name == 'run-checks'
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      actions: write
      contents: read
      pull-requests: write
    steps:
      - id: open
        uses: Quartel-Enterprise/ai-review/threads@2.0.0
        with:
          command: open-threads
          pull-request: ${{ github.event.pull_request.number }}
          review-only: 'true'
          bot-login: claude[bot]
      - if: steps.open.outcome == 'success' && steps.open.outputs.count == '0'
        uses: Quartel-Enterprise/ai-review/threads@2.0.0
        with:
          command: rerun-held
          sha: ${{ github.event.pull_request.head.sha }}
      # The label goes either way, so it can be added again.
      - if: always()
        env:
          GH_TOKEN: ${{ github.token }}
          GH_REPO: ${{ github.repository }}
          PR_NUMBER: ${{ github.event.pull_request.number }}
        run: gh api --method DELETE "repos/$GH_REPO/issues/$PR_NUMBER/labels/run-checks" > /dev/null || true
```

Check that a step ran before reading its `count`: a skipped step's output is empty, which an
expression compares equal to `'0'`.

| Input | Default | Description |
| --- | --- | --- |
| `command` | **required** | `open-threads` to count unresolved threads of `pull-request`, or `rerun-held` to re-run held runs of `sha` |
| `pull-request` | required for `open-threads` | The pull request number |
| `review-only` | `'false'` | `'true'` to count only threads opened by the AI review (`bot-login` or `github-actions[bot]`) |
| `bot-login` | required when `review-only: 'true'` | The review's `bot-login` (`claude[bot]`, `github-actions[bot]`, or your GitHub App's bot) |
| `sha` | required for `rerun-held` | The commit whose held runs to re-run |
| `hold-step` | `'Hold for the open threads'` | Name of the gate workflow step that fails when checks are held |
| `token` | `github.token` | A token that reads pull requests and, for `rerun-held`, writes actions |

| Output | Description |
| --- | --- |
| `count` | How many threads are unresolved (`open-threads`), or how many runs were re-run (`rerun-held`) |
