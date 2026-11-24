# What a run costs

After the session, the action adds one comment to the pull request with the run's cost: the
`total_cost_usd` Claude Code reports in the session's result (`review/post-cost.sh`), and a table of
the models that ran: the model the review runs on (the `model` input) with the `effort` it ran at,
then any other model of the session. What each was used for comes from the calls recorded in the
execution file: how many it made in the session and how many in subagents, and a model with the
cost but no call there was called by Claude Code outside the conversation. The effort is the
`/code-review` skill's level, not a reasoning setting of the model. The review and its fix commit are
one session, so the figure covers both and isn't split between them; the table says so only when the
fix commit was pushed. It is a
comment of its own, so it sends one more notification than the review: set `cost: 'false'` to leave
it out. It needs the caller's `pull-requests: write`, which the review already has.

It is computed by Claude Code from the tokens it counted, not read off an invoice. With `oauth-token`
nothing is billed per token, so the figure is what the same tokens would cost through the API. With
`anthropic-api-key` it is close to what you pay for the models Claude Code knows a price for; for
another model id it is a guess at the default model's rate. A run that times out or is cancelled has
no result, so it has no comment, and neither has a session that crashed before it started (its cost
is zero).

A retry of the step updates the run's comment. A re-run of the job runs a new session, which costs
again, so it gets a comment of its own. Only the workflow's own comments count: another user's
comment holding the same hidden tag is left alone.
