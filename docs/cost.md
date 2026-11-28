# What a run costs and takes

After the session, the action computes a cost and timing summary (`review/post-cost.sh` and
`review/summarize-cost.py`), exports it through the action outputs (`total-duration-seconds`,
`provider-durations`, `total-cost-usd`), and — when `cost: 'true'` (default) — posts one comment on
the pull request titled **Review cost & timing**.

## Timing

The comment and action outputs report:

- **Per-provider duration:** how long each enabled provider (`Gemini`, `Claude`) took to run.
- **Total duration:** the sum across enabled providers, shown in the headline (e.g.
  `Total time: 3m 42s (Gemini: 1m 32s + Claude: 2m 10s)`).

## Cost calculation

- **Claude:** read from `total_cost_usd` and `modelUsage` reported by Claude Code. With
  `claude-oauth-token`, nothing is billed per token, so the figure is the API equivalent.
- **Gemini:** estimated from `stats.models.<model>.tokens` (`prompt`, `cached`, `candidates`, and
  `thoughts`) returned by Gemini CLI (`--output-format json`) using standard Google AI Studio API
  rates. Unknown model IDs show duration and `–` for cost rather than guessing.

## Micro-cost filtering (`show-micro-costs`)

Claude Code often makes small auxiliary calls outside the main review model (for example, Haiku
spending a fraction of a cent under \$0.01). By default (`show-micro-costs: 'false'`), auxiliary
models spending less than \$0.01 are hidden from the table and excluded from the displayed total so
the summary stays focused on the primary review model(s).

Set `show-micro-costs: 'true'` to include every model and micro-cost in the table and total.

## Comment lifecycle

Each cost comment carries a hidden tag containing the run ID, attempt, and active provider list
(`<!-- ai-review-cost run ... providers ... -->`). A retry updates the existing comment; a re-run
posts a new one; and parallel provider jobs in the same workflow run never overwrite each other.
Set `cost: 'false'` to omit the comment while still keeping the action's timing/cost outputs.
