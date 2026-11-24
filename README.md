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
aren't reviewed again (see [Reviewing again](docs/review.md#reviewing-again)).

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
  [Your own GitHub App](docs/review.md#your-own-github-app).
- An Ubuntu runner (`ubuntu-latest`): the review's sandbox is installed with `apt-get`, and the
  action fails on any other runner.

## Setup

1. Install the [Claude GitHub App](https://github.com/apps/claude) on the repository.
2. Add the secret (`CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY`) under the repository's
   **Settings > Secrets and variables > Actions**.
3. Add this workflow as `.github/workflows/claude-review.yml`. Keep that path if you will use
   `gate`: it is the gate's default `review-workflow`. Drop `fix: 'true'` for a review that only
   comments.

```yaml
name: claude-review
on:
  pull_request:
    types:
      - opened
      - ready_for_review
      # GitHub starts no pull_request workflow while a pull request conflicts with its base: the push
      # that solves the conflict brings the opening review instead (see "Pull requests opened with a
      # conflict" in docs/review.md). Every other push ends in seconds without reviewing.
      - synchronize

# A push runs in a group of its own, so it neither cancels the opening review nor waits behind it.
concurrency:
  group: >-
    ${{ github.workflow }}-${{ github.event.pull_request.number
    }}${{ github.event.action == 'synchronize' && format('-{0}', github.run_id) || '' }}
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
      # On a push, the review reads this workflow's earlier runs.
      actions: read
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
      - uses: Quartel-Enterprise/claude-review/review@1.5.0
        with:
          oauth-token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
          fix: 'true'
```

4. Merge it to the default branch first. `claude-code-action` refuses to run on a pull request that
   changes the workflow file that started it, so the pull request adding the workflow isn't
   reviewed: its run ends green with a "workflow validation" warning and posts nothing. The same
   goes for any later pull request that edits this file.
5. Open a test pull request and check that a review from `claude[bot]` shows up when the
   `claude-review` run ends.

The action reads the pull request from the `pull_request` event, so call it from a workflow that
runs on `pull_request`. Its inputs (model, effort, `allowed-bots`, your own GitHub App, ...) are in
[The review](docs/review.md).

## Where to go next

| | |
| --- | --- |
| [The review](docs/review.md) | Inputs, fixes, reviewing again, pull requests opened with a conflict, your own GitHub App, private conventions |
| [The gate](docs/gate.md) | Hold your checks until the review ends, so they run once, on the final commit |
| [The threads](docs/threads.md) | Re-run the held checks once the review's threads are resolved |
| [What a run costs](docs/cost.md) | The cost comment and how it is computed |
| [Security model](docs/security-model.md) | What the review can read and run, and what is left |
| [When something goes wrong](docs/troubleshooting.md) | Symptoms and fixes |

## Versions

Pin an exact release in every `uses:` (`@1.5.0`, the latest
[release](https://github.com/Quartel-Enterprise/claude-review/releases)) and bump all of them
together: the gate and the threads action have to agree on which threads hold the checks and which
step name marks a hold. Releases are immutable, so a tag always means the same code. A check in your
repository that fails when the refs differ keeps a partial bump from merging; Dependabot can bump
them together when its `github-actions` updates are grouped.

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md) to propose a change, and [SECURITY.md](SECURITY.md) to report a
vulnerability.
