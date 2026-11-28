# Security policy

## Supported versions

Only the latest [release](https://github.com/Quartel-Enterprise/ai-review/releases) gets security
fixes. Releases are immutable and every `uses:` pins one, so after a fix, bump yours to the new
release.

## Reporting a vulnerability

Please don't open a public issue, pull request or discussion for a vulnerability.

Report it privately with GitHub's
[private vulnerability reporting](https://github.com/Quartel-Enterprise/ai-review/security/advisories/new):
the **Report a vulnerability** button on the repository's **Security** tab.

Include what you found, the workflow and inputs that trigger it, and what an attacker gains. A
proof of concept helps; please don't run it against a repository you don't own.

You can expect an answer within a few days. We will confirm the problem, work on a fix in a private
advisory, release it, and credit you in the advisory unless you prefer not to be named.

## What counts

The action runs AI models over a pull request's diff with the runner's secrets in their environment,
so the interesting reports are the ones where a pull request makes the review leak or misuse them: a
token in a comment, a commit or a log, a file read or written outside what
[the security model](docs/security-model.md) allows, a push to a branch the review shouldn't touch,
or a way around `bash-guard.sh` or `gemini-guard.sh`.

The tokens being in the session's own environment, and the mask knowing only a token's plain shapes,
are known limits listed under "What is left" on that page.

Vulnerabilities in upstream provider CLIs belong to their maintainers
([Anthropic](https://www.anthropic.com/responsible-disclosure-policy) for Claude Code,
[Google](https://bughunters.google.com/) for Gemini CLI).
