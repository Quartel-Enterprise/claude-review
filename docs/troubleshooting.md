# When something goes wrong

The run's log shows what the Stop hook saw and any warnings, but not Claude's output.

| What you see | Why, and what to do |
| --- | --- |
| The run fails at "Check the inputs" | An input is invalid: the error names it. Both or neither of `oauth-token` and `anthropic-api-key` set is the usual one; on a Dependabot pull request the secret is empty (see the `if` in the [workflow](../README.md#setup)) |
| The run fails on authentication | The OAuth token expired or was revoked, or the API key is wrong: replace the secret |
| A green run, a "workflow validation" warning, no review | The pull request changes the review's workflow file: see [Setup](../README.md#setup), step 4 |
| A review by `github-actions[bot]` instead of `claude[bot]` | The session couldn't post (no App token, a GitHub outage), so the action posted the same findings with the workflow's token. If it happens on every run, check the App's installation and the job's `id-token: write` |
| A review saying "The review ended without a findings list" | The session stopped without its findings (a refusal, a skill that stopped early, a session that never ran). Follow the link to the run |
| Warning "bubblewrap can't start a sandbox on this runner" | The review's Bash commands fail, so it has no diff. Use a GitHub-hosted `ubuntu-latest` runner |
| Warning "The review was denied ..." or "The review's Bash guard refused ..." | The review tried a tool it isn't allowed. Usually harmless; see the [security model](security-model.md) before allowing one |
| No review and a failed, timed-out job | The job hit `timeout-minutes`, and no step runs after that. Raise it, or lower `effort` or `max-findings` |
| Findings fixed but no fix commit | Nothing is pushed in the cases listed under [Fixes](review.md#fixes); the run's log says which |
