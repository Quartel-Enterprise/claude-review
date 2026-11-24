# Contributing

Thanks for helping. Bug reports, ideas and pull requests are welcome. By taking part you agree to follow
the [Code of Conduct](CODE_OF_CONDUCT.md). To report a vulnerability, don't open an issue: see
[SECURITY.md](SECURITY.md).

## Before you start

- For a bug, [open an issue](https://github.com/Quartel-Enterprise/claude-review/issues/new/choose) with
  the workflow you run and the link to the run. The run's log shows what the Stop hook saw and any
  warnings, but not Claude's output, so don't paste anything from a private repository.
- For a larger change, open an issue first so we can agree on the approach before you write it.
- Pull requests from forks aren't reviewed by the action itself, since GitHub withholds secrets from
  them. A maintainer reviews them.

## Development

`scripts/lint.sh` runs what `lint.yml` runs: shellcheck on the scripts and on every action's `run`
blocks, then actionlint. It needs `shellcheck`, `actionlint`, and Python 3 with `pyyaml`. Run it before
you push.

```bash
./scripts/lint.sh
```

If your change touches what the review may read or run, update the four places that list its commands
together: `--allowedTools` in `review/action.yml`, `review/bash-guard.sh`, the prompt, and
[the security model](docs/security-model.md).

Keep the docs in step with the code: an input goes in the table of [the review](docs/review.md),
[the gate](docs/gate.md) or [the threads](docs/threads.md) page.

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`,
`docs:`, `chore:`).

## Releases

A change ships as a release whose tag is the version (immutable releases), then each repository bumps
every `uses:` to it together. Releasing is a pull request of its own, `chore: release X.Y.Z`, that bumps
the pinned version in every `uses:` of `README.md` and `docs/`:

```bash
grep -rn 'claude-review/.*@[0-9]' README.md docs
```

`review` pins `anthropics/claude-code-action` to a commit, so a release of this repository always runs
the same action: bump it here, in a release of its own.
