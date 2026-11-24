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
      # The label goes either way, so it can be added again.
      - if: always()
        env:
          GH_TOKEN: ${{ github.token }}
          GH_REPO: ${{ github.repository }}
          PR_NUMBER: ${{ github.event.pull_request.number }}
        run: gh api --method DELETE "repos/$GH_REPO/issues/$PR_NUMBER/labels/run-checks" > /dev/null || true
```

Check that a step ran before reading its `count`: a skipped step's output is empty, which an
expression compares equal to `'0'`. `rerun-held` re-runs every failed run of the commit whose
`hold-step` (`Hold for the open threads` by default) failed, so no workflow has to list the gated
ones. With your own GitHub App, pass its `bot-login` to `open-threads` too.

| Input | Default | |
| --- | --- | --- |
| `command` | required | `open-threads` to count the unresolved threads of `pull-request`, or `rerun-held` to re-run the held runs of `sha` |
| `pull-request` | | The pull request number, for `open-threads` |
| `claude-only` | `'false'` | `'true'` to count only the threads the review opened (its `bot-login`'s or `github-actions[bot]`'s), for `open-threads` |
| `bot-login` | `claude[bot]` | The review's `bot-login` |
| `sha` | | The commit whose held runs to re-run, for `rerun-held` |
| `hold-step` | `Hold for the open threads` | The name of the gate workflow's step that fails when the gate holds the checks, for `rerun-held` |
| `token` | `github.token` | A token that reads pull requests and, for `rerun-held`, writes actions |

| Output | |
| --- | --- |
| `count` | How many threads are unresolved (`open-threads`), or how many runs were re-run (`rerun-held`) |
