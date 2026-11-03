# claude-review

GitHub Actions that review a pull request with [Claude Code](https://code.claude.com/docs/en/github-actions),
optionally fix what the review found, and hold the pull request's checks until the review ends and
its threads are resolved. They work for any repository and any language: the review reads the diff
and the files of the checkout, and runs none of your code.

| Action | What it does |
| --- | --- |
| `review` | Runs the `/code-review` skill bundled with Claude Code (high effort on Opus by default), optionally with `--fix`, and posts the findings as one pull request review |
| `gate` | Waits for the opening review of the pull request's commit, and tells your check workflows whether to run |
| `threads` | Counts the review's unresolved threads, or re-runs the checks the gate held for them |

Only `review` is needed to get a review on every pull request. Add `gate` and `threads` when the
review pushes fixes (`fix: 'true'`) and you want your checks (build, tests, lint) to run once, on the
final commit, instead of once on the opened commit and again on the fix commit.

## What you get

When a pull request opens, or a draft is marked ready for review, the review posts one review on it
by `claude[bot]`, titled **Code review**:

- Each finding left for the author is an inline comment, labelled 🔴 **Must fix**, 🟡 **Should fix**
  or ⚪ **Nitpick**, most severe first, with a GitHub suggestion when replacing the commented lines
  fully fixes it.
- With `fix: 'true'`, the findings it could fix are pushed as one commit,
  `fix: apply the Claude review findings`, by `claude[bot]`, and listed in the review's body under
  that commit.
- With no finding, the review says "No findings."

The review comments only: it never approves or requests changes. Later pushes to the pull request
aren't reviewed again (see [Reviewing again](#reviewing-again)).

## Requirements

- A GitHub repository where you can add secrets and workflows. Pull requests from forks are never
  reviewed, since GitHub withholds secrets from them.
- One of two secrets for Claude. Other providers (Bedrock, Vertex AI, Foundry) aren't supported.
  - `CLAUDE_CODE_OAUTH_TOKEN`: run `claude setup-token` locally with
    [Claude Code](https://code.claude.com/docs/en/setup) installed and signed in to a Claude
    subscription. The reviews count against that subscription. When the token expires or is
    revoked, the run fails on authentication: create a new one and update the secret.
  - `ANTHROPIC_API_KEY`, from the [Claude Console](https://console.anthropic.com/): the reviews are
    billed per token to that API account.
- The [Claude GitHub App](https://github.com/apps/claude) installed on the repository: the review
  posts as `claude[bot]`, and its fix commit is pushed with the App's token, which starts the pull
  request's workflows on it. The action gets that token by exchanging the workflow's OIDC token, so
  the job needs `id-token: write`. To review as an App of your own instead, see
  [Your own GitHub App](#your-own-github-app).
- An Ubuntu runner (`ubuntu-latest`): the review's sandbox is installed with `apt-get`, and the
  action fails on any other runner.

## Setup

1. Install the [Claude GitHub App](https://github.com/apps/claude) on the repository.
2. Add the secret (`CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY`) under the repository's
   **Settings > Secrets and variables > Actions**.
3. Add the workflow from [The review](#the-review) as `.github/workflows/claude-review.yml`. Keep
   that path if you will use `gate`: it is the gate's default `review-workflow`.
4. Merge it to the default branch first. `claude-code-action` refuses to run on a pull request that
   changes the workflow file that started it, so the pull request adding the workflow isn't
   reviewed: its run ends green with a "workflow validation" warning and posts nothing. The same
   goes for any later pull request that edits this file.
5. Open a test pull request and check that a review from `claude[bot]` shows up when the
   `claude-review` run ends.

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
    # Dependabot's pull requests only get Dependabot's secrets, so they are skipped too.
    if: >-
      !github.event.pull_request.draft &&
      github.event.pull_request.head.repo.full_name == github.repository &&
      github.actor != 'dependabot[bot]'
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
      - uses: actions/checkout@v7
        with:
          ref: ${{ github.event.pull_request.head.sha }}
          fetch-depth: 0
          persist-credentials: false
      - uses: Quartel-Enterprise/claude-review/review@1.2.0
        with:
          oauth-token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
          fix: 'true'
```

The action reads the pull request from the `pull_request` event, so call it from a workflow that
runs on `pull_request` (any of its types). Drop `fix: 'true'` for a review that only comments.

| Input | Default | |
| --- | --- | --- |
| `oauth-token`, `anthropic-api-key` | | A Claude Code OAuth token or an Anthropic API key. Set exactly one, or the run fails |
| `model` | `opus` | An alias (`opus`, `sonnet`, `haiku`) or a full model id |
| `effort` | `high` | The `/code-review` skill's level: `low`, `medium`, `high`, `xhigh` or `max`. Higher levels find more, some of it less certain, and cost more |
| `max-findings` | `all` | `all` or a number: the review keeps the most severe ones |
| `fix` | `'false'` | `'true'` to apply the findings and push them as a commit to the pull request's branch |
| `instructions` | | Extra instructions appended to the prompt, e.g. for a review on request |
| `github-token`, `bot-login`, `bot-id` | none, `claude[bot]`, `209825114` | Review as your own GitHub App: see [below](#your-own-github-app) |
| `memory-repository`, `memory-ssh-key`, `memory-files` | none | Private review conventions: see [below](#private-conventions) |

The action has no outputs. The workflow that calls it stays in your repository; the action itself
comes from the pinned release, never from the pull request.

The review fails only when the run itself does (an expired token, the timeout), never because of
what it found. A finding on a line outside the diff is anchored to the nearest changed line of its
file; one in a file the diff doesn't touch goes in the review's body. The review can't read earlier
reviews, so the action hands it the findings they left, for it not to raise them again.

### Fixes

With `fix`, the model may edit the files of the checkout, never under `.git`, `.github`, `.claude`
or `.agent-memory`, and can't create a file. It fixes only what is clear and contained. Before
posting, the session's Stop hook runs `commit-fixes.sh`, which commits the tracked files the review
changed as the bot user and pushes them with the App's token. Nothing is pushed when no finding is
marked fixed, when a fix touches `.github` or `.claude`, when the working tree has an untracked file,
or when the branch moved during the review: the push is never forced. The fixed findings are then
listed in the review's body, under the fix commit, and open no thread. The fix commit isn't built
before the push, so a fix that breaks the build shows up in its checks.

A cheaper review, for a repository that wants a quick look rather than a thorough one:

```yaml
      - uses: Quartel-Enterprise/claude-review/review@1.2.0
        with:
          anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
          model: sonnet
          effort: medium
          max-findings: '10'
```

### Reviewing again

The review runs on `opened` and `ready_for_review` only. A reopened pull request isn't reviewed, and
neither is a later push, the fix commit included. A draft marked ready a second time is reviewed
again. To review again on demand, add a workflow of your own, for example one on
`pull_request: types: [labeled]` that runs the same steps when a given label is added, passing
`instructions` to say why. Without the review's `fix`, it only comments.

### Your own GitHub App

Without `github-token`, the review exchanges the workflow's OIDC token for one of the Claude GitHub
App. To post and push as an App of your own, mint its installation token in an earlier step and
name its bot user:

```yaml
      - id: app
        uses: actions/create-github-app-token@v3
        with:
          client-id: ${{ vars.REVIEW_APP_CLIENT_ID }}
          private-key: ${{ secrets.REVIEW_APP_PRIVATE_KEY }}
      - uses: Quartel-Enterprise/claude-review/review@1.2.0
        with:
          oauth-token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
          github-token: ${{ steps.app.outputs.token }}
          bot-login: my-review-app[bot]
          bot-id: '123456789' # gh api 'users/my-review-app[bot]' --jq .id
```

The App needs read and write access to contents and pull requests. `bot-id` goes in the fix
commit's author email, which is how GitHub links the commit to the bot. Pass the same `bot-login`
to `gate` and `threads`, and use it in the check workflows' `sender.login` condition below.

### Private conventions

The review follows the repository's `CLAUDE.md`. When the reviewed repository is public and some of
its review conventions live in a private repository instead, the action can read them from there:

- `memory-repository`: the private repository, as `owner/name`.
- `memory-ssh-key`: the private half of a read-only
  [deploy key](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/managing-deploy-keys#deploy-keys)
  of it, stored as a secret of the reviewed repository.
- `memory-files`: the files to read, as a sparse-checkout pattern such as `conventions/*.md`. It
  has no default: without it the review runs without them and warns, so a forgotten input never
  sends the whole repository to the runner.

The files are checked out into `.agent-memory`, read with the same weight as `CLAUDE.md`, and the
review is told never to quote one or name its path in a comment. It may still paraphrase them in
public comments, so pick a pattern that leaves out any file with figures or ids that must stay
private. Without the key, or when the checkout fails, the review runs without them and the run shows
a warning.

### Security

The runner's environment holds the Claude token (OAuth or API key) and the GitHub tokens, and a
prompt injection in a diff could ask the review to quote one in a public comment. So:

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
- `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` keeps the Claude token out of every Bash command's and
  hook's environment, and runs every Bash command in Claude Code's sandbox (the action installs
  bubblewrap and socat for it, and lifts Ubuntu's AppArmor limit on unprivileged user namespaces
  on the runner).
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

### When something goes wrong

The run's log shows what the Stop hook saw and any warnings, but not Claude's output.

| What you see | Why, and what to do |
| --- | --- |
| The run fails at "Check the inputs" | An input is invalid: the error names it. Both or neither of `oauth-token` and `anthropic-api-key` set is the usual one; on a Dependabot pull request the secret is empty (see the `if` above) |
| The run fails on authentication | The OAuth token expired or was revoked, or the API key is wrong: replace the secret |
| A green run, a "workflow validation" warning, no review | The pull request changes the review's workflow file: see [Setup](#setup), step 4 |
| A review by `github-actions[bot]` instead of `claude[bot]` | The session couldn't post (no App token, a GitHub outage), so the action posted the same findings with the workflow's token. If it happens on every run, check the App's installation and the job's `id-token: write` |
| A review saying "The review ended without a findings list" | The session stopped without its findings (a refusal, a skill that stopped early, a session that never ran). Follow the link to the run |
| Warning "bubblewrap can't start a sandbox on this runner" | The review's Bash commands fail, so it has no diff. Use a GitHub-hosted `ubuntu-latest` runner |
| Warning "The review was denied ..." or "The review's Bash guard refused ..." | The review tried a tool it isn't allowed. Usually harmless; see [Security](#security) before allowing one |
| No review and a failed, timed-out job | The job hit `timeout-minutes`, and no step runs after that. Raise it, or lower `effort` or `max-findings` |
| Findings fixed but no fix commit | Nothing is pushed in the cases listed under [Fixes](#fixes); the run's log says which |

## The gate

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
        uses: Quartel-Enterprise/claude-review/gate@1.2.0
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

## The threads

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
        uses: Quartel-Enterprise/claude-review/threads@1.2.0
        with:
          command: open-threads
          pull-request: ${{ github.event.pull_request.number }}
          claude-only: 'true'
      - if: steps.open.outcome == 'success' && steps.open.outputs.count == '0'
        uses: Quartel-Enterprise/claude-review/threads@1.2.0
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

## Versions

Pin an exact release in every `uses:` (`@1.2.0`, the latest
[release](https://github.com/Quartel-Enterprise/claude-review/releases)) and bump all of them
together: the gate and the threads action have to agree on which threads hold the checks and which
step name marks a hold. Releases are immutable, so a tag always means the same code. A check in your
repository that fails when the refs differ keeps a partial bump from merging; Dependabot can bump
them together when its `github-actions` updates are grouped.

## Development

`scripts/lint.sh` runs what `lint.yml` runs: shellcheck on the scripts and on every action's `run`
blocks, then actionlint. A change ships as a release whose tag is the version (immutable releases),
then each repository bumps every `uses:` to it together.

`review` pins `anthropics/claude-code-action` to a commit, so a release of this repository always
runs the same action: bump it here, in a release of its own.
