# The review

The workflow that runs the review is in the [README's setup](../README.md#setup). This page covers
its inputs and what the review does with a pull request.

## Inputs

The action reads the pull request from the `pull_request` event, so call it from a workflow that
runs on `pull_request` (any of its types). Drop `fix: 'true'` for a review that only comments.

| Input | Default | |
| --- | --- | --- |
| `oauth-token`, `anthropic-api-key` | | A Claude Code OAuth token or an Anthropic API key. Set exactly one, or the run fails |
| `model` | `opus` | An alias (`opus`, `sonnet`, `haiku`) or a full model id |
| `effort` | `high` | The `/code-review` skill's level: `low`, `medium`, `high`, `xhigh` or `max`. Higher levels find more, some of it less certain, and cost more |
| `max-findings` | `all` | `all` or a number: the review keeps the most severe ones |
| `fix` | `'false'` | `'true'` to apply the findings and push them as a commit to the pull request's branch |
| `cost` | `'true'` | `'true'` to comment what the run cost on the pull request, `'false'` to leave it out. See [What a run costs](cost.md) |
| `instructions` | | Extra instructions appended to the prompt, e.g. for a review on request |
| `allowed-bots` | | Bots whose pull requests are reviewed too, as comma-separated logins without `[bot]` (e.g. `renovate`). A run a bot started fails otherwise, since claude-code-action refuses it |
| `github-token`, `bot-login`, `bot-id` | none, `claude[bot]`, `209825114` | Review as your own GitHub App: see [below](#your-own-github-app) |
| `memory-repository`, `memory-ssh-key`, `memory-files` | none | Private review conventions: see [below](#private-conventions) |

The action has no outputs. The workflow that calls it stays in your repository; the action itself
comes from the pinned release, never from the pull request.

The review fails only when the run itself does (an expired token, the timeout), never because of
what it found. A finding on a line outside the diff is anchored to the nearest changed line of its
file; one in a file the diff doesn't touch goes in the review's body. The review can't read earlier
reviews, so the action hands it the findings they left, for it not to raise them again.

## Fixes

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
      - uses: Quartel-Enterprise/claude-review/review@1.5.0
        with:
          anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
          model: sonnet
          effort: medium
          max-findings: '10'
```

## Reviewing again

The review runs when the pull request opens or a draft is marked ready. A reopened pull request isn't
reviewed, and neither is a later push, the fix commit included. A draft marked ready a second time is reviewed
again. To review again on demand, add a workflow of your own, for example one on
`pull_request: types: [labeled]` that runs the same steps when a given label is added, passing
`instructions` to say why. Without the review's `fix`, it only comments.

## Pull requests opened with a conflict

GitHub starts no `pull_request` workflow while a pull request conflicts with its base, so one opened,
or marked ready, with a conflict gets no review on that event. With `synchronize` among the
workflow's types, as above, the push that solves the conflict brings it: on a `synchronize` event,
the action reviews only when the calling workflow has no run between the pull request's opening (or,
for a draft, its last marking as ready) and this one, and never on a push by `bot-login`, its own fix
commit. Runs a draft left before it was marked ready don't count. Every other push ends in a few seconds, green, without reviewing. The job needs
`actions: read` for that; without it, or when GitHub's API fails, the push isn't reviewed.

The gate doesn't wait for that review, since the push is the author's: the checks run on it right
away, and again on the review's fix commit, if any.

## Your own GitHub App

Without `github-token`, the review exchanges the workflow's OIDC token for one of the Claude GitHub
App. To post and push as an App of your own, mint its installation token in an earlier step and
name its bot user:

```yaml
      - id: app
        uses: actions/create-github-app-token@v3
        with:
          client-id: ${{ vars.REVIEW_APP_CLIENT_ID }}
          private-key: ${{ secrets.REVIEW_APP_PRIVATE_KEY }}
      - uses: Quartel-Enterprise/claude-review/review@1.5.0
        with:
          oauth-token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
          github-token: ${{ steps.app.outputs.token }}
          bot-login: my-review-app[bot]
          bot-id: '123456789' # gh api 'users/my-review-app[bot]' --jq .id
```

The App needs read and write access to contents and pull requests. `bot-id` goes in the fix
commit's author email, which is how GitHub links the commit to the bot. Pass the same `bot-login`
to `gate` and `threads`, and use it in the check workflows' `sender.login` condition (see [The gate](gate.md)).

## Private conventions

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
