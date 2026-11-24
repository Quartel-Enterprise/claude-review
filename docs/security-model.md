# Security model

How the review keeps the runner's tokens out of a pull request's reach. To report a vulnerability in
this repository, see [SECURITY.md](../SECURITY.md).

The runner's environment holds the Claude token (OAuth or API key) and the GitHub tokens, and a
prompt injection in a diff could ask the review to quote one in a public comment. So:

- The session reads files only through the Read, Grep and Glob tools (`--tools` names them, since
  Claude Code's native Linux build leaves Grep and Glob out otherwise), and only in the checkout and
  in a copy of the files the pull request changes as of the reviewed commit. The deny rules repeat it
  for `/proc`, `/sys`, `/etc`, `/tmp`, `$RUNNER_TEMP`, the checkout's `.git` and the home's files
  that hold credentials. `~/.claude/projects` stays readable, since a long Bash output is saved
  there.
- The session's Bash commands are `gh pr view`, `gh pr diff`, `gh pr list`, `gh issue view`,
  `gh issue list`, `gh search`, `git status` and `git branch --show-current`. `cat`, `grep`, `jq`,
  `git diff`, `git log`, `git show` and `git blame` are left out, since they read or write a file
  they are given. A PreToolUse hook (`bash-guard.sh`) lets through only one plain line of those
  commands, with no quoting, expansion, pipe or redirection, and none of `gh`'s `--jq`, `-q`,
  `--template` and `-t`.
- `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` keeps the Claude token out of every Bash command's and
  hook's environment, and runs every Bash command in Claude Code's sandbox (the action installs
  bubblewrap and socat for it, and lifts Ubuntu's AppArmor limit on unprivileged user namespaces
  on the runner).
- The hook and its scripts are copied from the action's directory into a read-only one before the
  session starts, and their markers live in a state directory outside the checkout.
- A symlink the pull request adds that leaves the checkout or enters its `.git`, `.github` or
  `.claude` is removed for the review and restored before the fix commit.
- `post-review.sh` masks anything shaped like a token before posting, and so does `commit-fixes.sh`
  for the commit message; it pushes nothing when a fix adds such a string.

The action hides Claude's output, since the logs may be public. A tool the review was denied, or a
Bash command the guard refused, shows as a warning on the run, with only its name and, for Bash, its
program and subcommand. Allow it only when it can neither read nor write a file it is given, nor
print the environment, and then in the four places that list the commands together: `--allowedTools`
in `review/action.yml`, `review/bash-guard.sh`, the prompt and this page.

**What is left.** The tokens are still in the session's own environment, and the mask only knows a
token's plain shapes. Only someone who can push a branch to the repository can try, since forks are
never reviewed. If a token ever shows up in a comment, a commit or a log, revoke it.
