# CWD Discipline (HARD RULE)

The harness anchors its CWD to wherever `claude` was launched. That anchor cannot be changed mid-session: `cd` only affects the current bash call, not the harness' internal CWD tracker. If `claude` was launched from inside `.claude/worktrees/...`, every subsequent operation that relies on `pwd` targets the wrong tree, and Agent-worktree dispatches can nest without warning.

**Rules:**
- **Always launch `claude` from `$CLAUDE_PROJECT_DIR`.** Never from a worktree. `/orient` Step 0 detects violations and aborts.
- **Every local git command in the main session MUST use `git -C $CLAUDE_PROJECT_DIR <subcommand>`.** Never bare `git status`, `git pull`, `git log`. The `-C` flag forces the correct repo root regardless of CWD drift.
- **Every bash command that reads or writes files MUST use absolute paths.** Never relative paths in the main session.
- **`gh` CLI is CWD-independent and safe.** All merges, issue views, PR ops can continue via `gh` even if CWD is drifted.
- **Agents (subprocesses) get a fresh CWD inside their own worktree**: this is correct. The drift problem only affects the main session's harness anchor.
- **If CWD drift is detected mid-session**, do NOT attempt `git pull`/`git merge`/`git checkout`: those will modify whatever worktree `pwd` happens to point at. Operate remotely (`gh`) or switch to absolute `git -C` commands only.
