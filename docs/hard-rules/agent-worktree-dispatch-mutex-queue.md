# Agent Worktree Dispatch: Mutex Queue (HARD RULE)

`Agent` tool calls with `isolation: "worktree"` race on `.git/config.lock` during the worktree-creation step. Git's file locking is process-level: one worktree-creation process writes `.git/config.lock`, others fail with `could not lock config file .git/config: File exists` and silently never launch. The kit ships **`lib/dispatch.sh`** which wraps `git worktree add` in `flock` so only the ~1-second critical section serializes; agent execution after worktree handoff is unrestricted and parallel-safe.

- **Default (mutex available):** Parallel worktree-isolated `Agent` dispatch is supported. The mutex queue serializes the lock-prone `git worktree add` step (~1 second each) and releases the lock immediately; downstream agent execution runs concurrently. Validated by `tests/test-mutex-queue.sh` (5+ concurrent dispatches, zero collisions).
- **Fallback (mutex unavailable, e.g. `flock` not installed):** `lib/dispatch.sh` falls back to naked `git worktree add` and warns. In this environment, dispatch worktree-isolated agents **one at a time, each in its own message**: wait for each `agentId` before firing the next. macOS without Homebrew `util-linux` is the common case; install via `brew install util-linux` to enable the mutex.
- **What IS always parallel-safe (regardless of mutex):**
  - `Agent` **without** `isolation` (Explore subagents, general-purpose research, investigation): parallel is fine.
  - `Bash`/`Read`/`Grep` calls in the main session: parallel is fine.
- **Implementation:** `lib/dispatch.sh` exports `_dispatch_worktree_add` for any consumer-side shell that creates worktrees. Lock path defaults to `${TMPDIR:-/tmp}/cpt-worktree.lock`, override with `DISPATCH_LOCK_FILE`.
