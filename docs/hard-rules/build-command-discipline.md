# Build Command Discipline (HARD RULE)

The Claude Code harness auto-backgrounds slow processes. When backgrounded inside a chained `&&` command, the entire chain becomes invisible until polled: this stalls the operator for many minutes per occurrence.

- **NEVER** chain `{{LONG_BUILD_COMMAND}}` (or any other long-running command) into a compound `&&` command. Run it as a **dedicated Bash call** with `timeout: {{LONG_BUILD_TIMEOUT_MS}}`.
- If the harness backgrounds it anyway, **immediately** Read the task output file the harness returned. Do not start any other work until it completes.
- This rule supersedes the "minimize tool calls / parallelize" instinct.
- Same rule applies to any command that historically takes >30s (large test suites, search-index builds, browser-driver installs, asset pipelines).
