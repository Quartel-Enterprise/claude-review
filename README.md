# claude-review

GitHub Actions that review a pull request with Claude Code, optionally fix what the review found,
and hold the pull request's checks until the review ends and its threads are resolved. Shared by
the Quare apps, so a fix reaches all of them through a release.

| Action | What it does |
| --- | --- |
| `review` | Runs the `/code-review` skill bundled with Claude Code at high effort, on Opus, optionally with `--fix`, and posts the findings as one pull request review |
| `gate` | Waits for the opening review of the pull request's commit, and tells the check workflows whether to run |
| `threads` | Counts the review's unresolved threads, or re-runs the checks the gate held for them |

Pin an exact release in every `uses:` (`@1.0.0`) and bump all of them together. Releases are
immutable, so a tag always means the same code.

## Setup

- The `CLAUDE_CODE_OAUTH_TOKEN` secret, created with `claude setup-token`: the reviews count against
  that Claude subscription instead of being billed per token. When it expires or is revoked, the run
  fails on authentication: create a new one and update the secret.
- The Claude GitHub App installed on the repository: the review posts as `claude[bot]`, and its fix
  commit is pushed with the App's token, which starts the pull request's workflows on it.

## The review

```yaml
name: claude-review
on:
  pull_request:
    types:
      - opened
      - ready_for_review

concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number }}
  cancel-in-progress: true

jobs:
  review:
    # GitHub withholds secrets from pull requests opened from forks, so the review can't run there.
    if: >-
      !github.event.pull_request.draft &&
      github.event.pull_request.head.repo.full_name == github.repository
    runs-on: ubuntu-latest
    timeout-minutes: 30
    permissions:
      contents: read
      pull-requests: write
      issues: read
      id-token: write
    steps:
      # The head commit, not GitHub's merge of it with main: the review's line numbers have to match
      # the commit the comments are anchored to. No persisted credentials: checkout keeps
      # GITHUB_TOKEN's header in a file of its own, which claude-code-action doesn't find when it
      # swaps in the App's token, so the fix push would be refused.
      - uses: actions/checkout@v6
        with:
          ref: ${{ github.event.pull_request.head.sha }}
          fetch-depth: 0
          persist-credentials: false
      - uses: Quartel-Enterprise/claude-review/review@1.0.0
        with:
          oauth-token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
          fix: 'true'
```

| Input | |
| --- | --- |
| `oauth-token` | The `CLAUDE_CODE_OAUTH_TOKEN` secret. Required |
| `fix` | `'true'` to apply the findings and push them as a commit to the pull request's branch |
| `instructions` | Extra instructions appended to the prompt, e.g. for a review on request |
| `memory-repository`, `memory-ssh-key`, `memory-files` | A private repository of agent memories, a read-only deploy key of it, and the sparse-checkout pattern of the files to read (`*.md` by default) |

The workflow that calls the action stays in each repository: `claude-code-action` refuses to run
when the pull request changes the workflow file that started it, so a change to it can only be tried
out after it merges. The run then ends green with a "workflow validation" warning and posts nothing.
The action itself comes from the pinned release, never from the pull request.

The review fails only when the run itself does (an expired token, the timeout), never because of
what it found. Every finding left for the author is an inline comment, labelled 🔴 **Must fix**,
🟡 **Should fix** or ⚪ **Nitpick**, most severe first, with a GitHub suggestion when replacing the
commented lines fully fixes it. A finding on a line outside the diff is anchored to the nearest
changed line of its file; one in a file the diff doesn't touch goes in the review's body. The review
can't read earlier reviews, so the action hands it the findings they left, for it not to raise them
again.

### Fixes

With `fix`, the model may edit the files of the checkout, never under `.git`, `.github`, `.claude`
or `.agent-memory`, and can't create a file. It fixes only what is clear and contained. Before
posting, the Stop hook runs `commit-fixes.sh`, which commits the tracked files the review changed as
`claude[bot]` and pushes them with the App's token. Nothing is pushed when no finding is marked
fixed, when a fix touches `.github` or `.claude`, when the working tree has an untracked file, or
when the branch moved during the review: the push is never forced. The fixed findings are then
listed in the review's body, under the fix commit, and open no thread. The fix commit isn't built
before the push, so a fix that breaks the build shows up in its checks.

### Agent memories

When the reviewed repository is public and its conventions live in a private repository of agent
memories, the review checks out `memory-files` of it into `.agent-memory`, reads them with the same
weight as `CLAUDE.md`, and is told never to quote one or name its path in a comment. Pick a pattern
that leaves out any memory with figures or ids a public comment must never repeat. Without the key,
or when the checkout fails, the review runs without them and the run shows a warning.

### Security

The runner's environment holds the Claude OAuth token and the GitHub tokens, and a prompt injection
in a diff could ask the review to quote one in a public comment. So:

- The session reads files only through the Read, Grep and Glob tools (`--tools` names them, since
  Claude Code's native Linux build leaves Grep and Glob out otherwise), and only in the checkout and
  in a copy of the files the pull request changes as of the reviewed commit. The deny rules repeat it
  for `/proc`, `/sys`, `/etc`, `/tmp`, `$RUNNER_TEMP`, the checkout's `.git` and the home's files
  that hold credentials. `~/.claude/projects` stays readable, since a long Bash output is saved
  there.
- The session's Bash commands are `gh pr view`, `gh pr diff`, `gh pr list`, `gh issue view`,
  `gh issue list`, `gh search`, `git status` and `git branch --show-current`. `cat`, `grep`, `jq`,
  `git diff`, `git log`, `git show` and `git blame` are left out, since they read or write a file
  they are given. A PreToolUse hook (`bash-guard.sh`) lets through only one plain line of those
  commands, with no quoting, expansion, pipe or redirection, and none of `gh`'s `--jq`, `-q`,
  `--template` and `-t`.
- `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` keeps the Claude OAuth token out of every Bash command's and
  hook's environment, and runs every Bash command in Claude Code's sandbox (the action installs
  bubblewrap and socat for it).
- The hook and its scripts are copied from the action's directory into a read-only one before the
  session starts, and their markers live in a state directory outside the checkout.
- A symlink the pull request adds that leaves the checkout or enters its `.git`, `.github` or
  `.claude` is removed for the review and restored before the fix commit.
- `post-review.sh` masks anything shaped like a token before posting, and so does `commit-fixes.sh`
  for the commit message; it pushes nothing when a fix adds such a string.

The action hides Claude's output, since the logs may be public. A tool the review was denied, or a
Bash command the guard refused, shows as a warning on the run, with only its name and, for Bash, its
program and subcommand. Allow it only when it can neither read nor write a file it is given, nor
print the environment, and then in the four places that list the commands together: `--allowedTools`
in `review/action.yml`, `review/bash-guard.sh`, the prompt and this page.

**What is left.** The tokens are still in the session's own environment, and the mask only knows a
token's plain shapes. Only someone who can push a branch to the repository can try, since forks are
never reviewed. If a token ever shows up in a comment, a commit or a log, revoke it.

## The gate

Every workflow that builds or tests the app starts with a `review-gate` job, so the checks run once:
after the review when it pushed nothing, or on its fix commit. The job lives in each repository as a
reusable workflow, since its last step's name is what `threads`' `rerun-held` looks for:

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
        uses: Quartel-Enterprise/claude-review/gate@1.0.0
      # The step's name is what the threads action's rerun-held looks for.
      - name: Hold for the open threads
        if: steps.gate.outputs.open-threads != ''
        env:
          OPEN_THREADS: ${{ steps.gate.outputs.open-threads }}
        run: |
          echo "::error::claude-review left $OPEN_THREADS open thread(s), so this workflow's checks didn't run."
          exit 1
```

Each check workflow adds `ready_for_review` to its `pull_request` types and calls it on the events
the review runs on, plus the review's own fix commit; every other event skips the gate job, and the
other jobs run on a skipped gate:

```yaml
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
```

On the opening commit, a draft's ready commit and the fix commit, the gate waits for the review run
of the reviewed commit (`review-workflow`, `.github/workflows/claude-review.yml` by default), once a
minute, or every 10 seconds on the fix commit, which is pushed seconds before the review ends. On a
draft marked ready, only a review run the same event created counts, since the commit may already
have a skipped or completed one. When the head moved meanwhile, `proceed` is `false`: the push
started the checks again on the new commit. Once the review ended, `proceed` is `false` and
`open-threads` says how many while a thread the review opened (`claude[bot]`'s, or
`github-actions[bot]`'s when the fallback step posted) is unresolved: the author is about to push the
fixes, and that push runs the checks. A draft or a fork passes right away, and so does a failed or
cancelled review, GitHub's API failing three times in a row, or a review still running after 40
minutes.

## The threads

Resolving a thread starts no workflow, so the held checks need something else to run them: a label,
or a merge-when-green workflow once every conversation is resolved.

```yaml
- id: open
  uses: Quartel-Enterprise/claude-review/threads@1.0.0
  with:
    command: open-threads
    pull-request: ${{ github.event.pull_request.number }}
    claude-only: 'true'
- if: steps.open.outputs.count == '0'
  uses: Quartel-Enterprise/claude-review/threads@1.0.0
  with:
    command: rerun-held
    sha: ${{ github.event.pull_request.head.sha }}
```

`rerun-held` needs `actions: write`. It re-runs every failed run of the commit whose `hold-step`
(`Hold for the open threads` by default) failed, so no workflow has to list the gated ones.

## Development

`lint.yml` runs actionlint and shellcheck. A change ships as a release whose tag is the version,
then a bump of every `uses:` in the apps.
