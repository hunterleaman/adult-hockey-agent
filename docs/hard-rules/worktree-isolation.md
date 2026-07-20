# Worktree Isolation (HARD RULE)

The main session NEVER changes its working directory. It stays on `main` at the repo root permanently. All code changes go through `Agent` with `isolation: "worktree"`: the agent runs in a subprocess with its own CWD, does its work, and the main session is never affected.

**Why:** `EnterWorktree` changes the main session's shell PWD but the harness maintains a separate internal CWD anchor that does not synchronize. This mismatch causes ghost CWD paths, hooks fighting cleanup, and stale branch state after worktree removal. Agent subprocess isolation avoids this entirely: the main session's CWD is never touched.

**Rules:**
- **NEVER use `EnterWorktree`/`ExitWorktree` in the main session.** All code changes dispatch to an `Agent` with `isolation: "worktree"`.
- **Main session does:** orchestration, `/orient`, `/land`, `/verify`, docs-only commits on main, merges, operator-facing decisions.
- **Agents do:** implementation, reviews, any work that touches code on a feature branch.
- At session start: report worktrees but do NOT delete: other sessions may own them.
- **ALWAYS start `claude` from the main repo root** (`$CLAUDE_PROJECT_DIR`), never from inside a worktree subdirectory.
