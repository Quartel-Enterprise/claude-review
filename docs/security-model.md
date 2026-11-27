# Security model

How the review keeps the runner's tokens out of a pull request's reach across both Claude and Gemini
sessions. To report a vulnerability in this repository, see [SECURITY.md](../SECURITY.md).

The runner's environment holds AI provider credentials (`CLAUDE_CODE_OAUTH_TOKEN`,
`ANTHROPIC_API_KEY`, `GEMINI_API_KEY`) and GitHub tokens, and a prompt injection in a diff could ask
the review to quote one in a public comment or commit. So:

- **File reading boundaries:**
  - **Claude:** reads only through `Read`, `Grep`, and `Glob` inside the checkout and the reviewed
    commit's copy; explicit deny rules cover `/proc`, `/sys`, `/etc`, `/tmp`, `$RUNNER_TEMP`,
    `.git`, and credential files in `$HOME`.
  - **Gemini:** uses a read-only TOML Policy Engine file (`adminPolicyPaths` + `--policy`) **and** a
    `BeforeTool` hook (`review/gemini-guard.sh`) that resolves every path for `read_file`,
    `grep_search`, `glob`, and `list_directory` and denies anything outside the checkout or reviewed
    commit copy, as well as `.git`. Tools like `write_file`, `web_fetch`, `google_web_search`,
    `save_memory`, `activate_skill`, and `mcp_*` are explicitly denied.
- **Untrusted PR settings ignored:** for Gemini, any `.gemini/` directory in the PR checkout is
  quarantined outside the workspace for the duration of the run (and restored on exit), while
  `GEMINI_CLI_SYSTEM_SETTINGS_PATH` points to a read-only settings file outside the checkout, so a
  malicious PR's `.gemini/settings.json`, hooks, MCP servers, or policies cannot load.
- **Shell allowlist & guard:** both Claude (`review/bash-guard.sh`) and Gemini
  (`review/gemini-guard.sh`) permit only `gh pr view`, `gh pr diff`, `gh pr list`, `gh issue view`,
  `gh issue list`, `gh search`, `git status`, and `git branch --show-current` — each as one plain
  line with no quoting, expansion, pipe, or redirection, and none of `gh`'s `--jq`, `-q`,
  `--template`, or `-t`.
- **Environment scrubbing & sandboxing:**
  - Claude uses `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` with `bubblewrap` and `socat`.
  - Gemini enables `security.environmentVariableRedaction.enabled: true` so API keys are redacted
    from subprocess environments.
- **Read-only scripts & symlink removal:** hooks and scripts are copied into a read-only directory
  outside the checkout before any session starts. Any symlink in the PR leaving the checkout or
  entering `.git`, `.github`, `.claude`, or `.gemini` is removed before the review and restored
  before committing fixes.
- **Edit boundaries & redaction:** with `fix: 'true'`, neither provider may edit `.git`, `.github`,
  `.claude`, `.gemini`, or `.agent-memory`, nor create new files; `commit-fixes.sh` re-verifies all
  paths before committing. `post-review.sh --redact` masks Claude (`sk-ant-...`), Gemini
  (`AIza...` / `AQ....`), generic (`sk-...`), GitHub (`gh*`, `github_pat_*`), JWT, and Basic/Bearer
  token shapes before anything reaches GitHub, and `commit-fixes.sh` refuses to push any diff that
  adds a token-shaped string.
- **Hidden logs:** neither Claude's nor Gemini's raw output is printed to public Actions logs. Only
  refused tool/command names appear as warnings.

If you change what shell commands the review may run, keep all five places aligned:
`--allowedTools` in `review/action.yml`, `review/bash-guard.sh`, `review/gemini-guard.sh` (plus
`review/gemini-run.sh` policy), the prompts (`review/action.yml` and `review/gemini-prompt.md`), and
this page.

**What is left.** Tokens remain in the provider CLI's own process environment, and redaction matches
known token shapes only. Forks are never reviewed. If a token ever appears in a comment, commit, or
log, revoke it immediately.
