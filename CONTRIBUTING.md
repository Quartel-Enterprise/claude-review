# Contributing

Thanks for helping. Bug reports, ideas and pull requests are welcome. By taking part you agree to follow
the [Code of Conduct](CODE_OF_CONDUCT.md). To report a vulnerability, don't open an issue: see
[SECURITY.md](SECURITY.md).

## Before you start

- For a bug, [open an issue](https://github.com/Quartel-Enterprise/ai-review/issues/new/choose) with
  the workflow you run and the link to the run. The run's log shows what the guards and hooks saw and
  any warnings, never raw model output, so don't paste anything from a private repository.
- For a larger change, open an issue first so we can agree on the approach before you write it.
- Pull requests from forks aren't reviewed by the action itself, since GitHub withholds secrets from
  them. A maintainer reviews them.

## Development

`scripts/lint.sh` runs what `lint.yml` runs: shellcheck on the scripts and on every action's `run`
blocks, `py_compile` on every Python script, then actionlint. It needs `shellcheck`, `actionlint`,
and Python 3 with `pyyaml`. Run it before you push.

```bash
./scripts/lint.sh
```

If your change touches what the review may read or run, update all five places that list its commands
together: `--allowedTools` in `review/action.yml`, `review/bash-guard.sh`, `review/gemini-guard.sh`
(and the policy in `review/gemini-run.sh`), the prompts (`review/action.yml` and
`review/gemini-prompt.md`), and [the security model](docs/security-model.md).

Keep the docs in step with the code: an input or output goes in the table of
[the review](docs/review.md), [the gate](docs/gate.md) or [the threads](docs/threads.md) page.

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`,
`docs:`, `chore:`).

## Releases

A change ships as a release whose tag is the version (immutable releases), then each repository bumps
every `uses:` to it together. Releasing is a pull request of its own, `chore: release X.Y.Z`, that
bumps the pinned version in every `uses:` of `README.md` and `docs/`:

```bash
grep -rn 'ai-review/.*@[0-9]' README.md docs
```

`review` pins `anthropics/claude-code-action` to a commit and `@google/gemini-cli` to an exact npm
version, so a release of this repository always runs the same tooling: bump them in a release of
their own.
