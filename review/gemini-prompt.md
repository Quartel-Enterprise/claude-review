Review pull request #__PR_NUMBER__ of this repository thoroughly and objectively.

## How to review
1. Read the pull request diff with `gh pr diff __PR_NUMBER__` (and PR metadata with `gh pr view __PR_NUMBER__` if helpful).
2. Read any repository convention files present in the checkout (`AGENTS.md`, `CLAUDE.md`, `GEMINI.md`) using `read_file`.
3. Inspect the full surrounding code of every changed file and its callers/callees using `read_file`, `grep_search`, `glob`, and `list_directory`. Never rely on the diff hunks alone when verifying types, nullability, locking, error paths, or side effects.
4. Effort level: `__EFFORT__`
   - `low`: focus on clear, high-confidence bugs, crashes, security holes, and broken flows.
   - `medium`: also check edge cases, error handling, resource leaks, and convention violations.
   - `high`: trace multi-file data flow, concurrency/races, subtle regressions, API contracts, and security boundaries carefully.
   - `xhigh` or `max`: perform exhaustive verification across callers, boundary conditions, failure modes, security invariants, and subtle state transitions.
5. Limit: report at most `__MAX_FINDINGS__` findings (`all` means no cap), ordered most severe first. Only report real, verifiable issues — avoid speculative noise or style preferences already enforced by linters.

## Fix mode
__FIX_INSTRUCTIONS__

## Output format
End your reply with the findings as a JSON array inside a ```json fence, and nothing after it:
one object per finding, most severe first, each with:
- `"file"`: relative path from repository root
- `"line"`: integer line number in the new version of the file
- `"start_line"` (optional): integer start line when the finding spans multiple lines
- `"summary"`: concise one-sentence title of the issue
- `"failure_scenario"`: clear explanation of what goes wrong, when it happens, and why
- `"category"`: short category such as `"correctness"`, `"security"`, `"concurrency"`, `"error-handling"`, `"performance"`, `"conventions"`, `"maintainability"`
- `"severity"`: one of:
  - `"must-fix"`: the change shouldn't merge with it — a bug users would hit (crash, wrong data, data loss, broken flow), a security hole, or a race that corrupts state.
  - `"should-fix"`: a real problem worth fixing in this PR with limited impact — an edge case, degraded error handling, a broken repository convention, or a clear cleanup that pays off.
  - `"nitpick"`: optional — naming, wording, small simplification, or style tooling doesn't enforce.
- `"fix"`: one or two sentences on how to fix it, written for the author. Markdown is fine, with a short code sketch in a fenced block when the fix spans several places.
- `"suggestion"` (optional): only when replacing lines `"start_line"` to `"line"` (or `"line"` alone) of the file, and nothing else, fully fixes the finding — the exact text replacing those lines, every line whole and indented as in the file. Read those lines from the reviewed commit's copy, `__REVIEWED_DIR__/<file>`, instead of recalling them, and keep `"line"` and `"start_line"` on exactly the lines it replaces. An empty string deletes them. Leave `"suggestion"` out whenever it would only be a sketch, the fix touches other lines, or the working tree already holds the fix.__OUTCOME_FIELD__

Write `[]` inside the ```json fence when there are no findings.
A later step posts that array as one pull request review. Don't post anything to GitHub yourself, don't run the app, and don't commit or push.

## Tool constraints
Take the pull request diff from `gh pr diff __PR_NUMBER__`, and read files with `read_file`, `grep_search`, `glob`, and `list_directory`.
Shell commands (`run_shell_command`) only run `gh pr view/diff/list`, `gh issue view/list`, `gh search`, `git status`, and `git branch --show-current`, each as one plain line: no quotes, pipes, redirections, or shell variables, and no `--jq`, `--template`, `-q`, or `-t`.
A search runs without quotes. A symlink that leaves the checkout or enters `.git`, `.github`, `.claude`, or `.gemini` was removed before the review, so `git status` shows it as deleted: that isn't part of the change.

__MEMORY_INSTRUCTIONS__
__EARLIER_COMMENTS__
__EXTRA_INSTRUCTIONS__
