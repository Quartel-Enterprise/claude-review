# When something goes wrong

The run's log shows what the guards and hooks saw, per-provider durations, and any warnings, but
never raw model output.

| What you see | Why, and what to do |
| --- | --- |
| The run fails at "Check the inputs" | An input is missing or invalid: the error names it. Common causes: `providers` missing/unknown, `gemini-api-key` missing when `gemini` is enabled, neither or both of `claude-oauth-token` and `anthropic-api-key` set when `claude` is enabled, or `bot-login`/`bot-id` missing when `github-token` is set |
| The run fails on authentication | The Claude OAuth token expired/revoked, or the Anthropic/Gemini API key is invalid: replace the secret |
| A green run, a "workflow validation" warning, no Claude review | The pull request changes the review's workflow file (Claude Code Action refuses to run on PRs editing its own workflow) |
| A review by `github-actions[bot]` instead of your App | Either no `github-token` was supplied (default on Gemini-only runs) or the session couldn't post with the App token, so the fallback step posted with `github.token` |
| A review saying "The review ended without a findings list" | No enabled provider returned a valid JSON findings array. Check the run link for exit codes or install warnings |
| Warning "Gemini ended without a findings list" inside a multi-provider review | One provider succeeded while the other failed to produce findings; the review still posts the successful provider's findings transparently |
| Warning "bubblewrap can't start a sandbox on this runner" | Claude's Bash commands need `bubblewrap` and `socat` on a GitHub-hosted `ubuntu-latest` runner |
| Warning "The review's guard refused ..." or "The review was denied ..." | A provider tried a tool or shell command outside the security allowlist. Usually harmless; review the [security model](security-model.md) before allowing anything |
| No review and a failed, timed-out job | The job hit `timeout-minutes`. Raise it, lower `effort`, or run `claude` and `gemini` as two parallel matrix jobs |
| Findings fixed but no fix commit | Nothing is pushed in the cases listed under [Fixes](review.md#fixes); the run's log says why |
