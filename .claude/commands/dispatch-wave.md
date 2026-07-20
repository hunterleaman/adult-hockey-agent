Parallel agent dispatch with pre-flight checks, self-correcting agents, and status tracking.

$ARGUMENTS: space-separated GitHub issue numbers (e.g., "3 4 5"). If empty, check memory for the next unblocked wave.

## 1. Pre-Flight (mandatory, do not skip)

Run `/preflight`. All checks must pass before dispatching any agents.

## 2. Read & Analyze Issues

For each issue number:
```bash
gh issue view {number}
```

- Parse title, body, labels, and dependencies
- Identify which issues are independent (can run in parallel)
- Flag any with ordering dependencies (must be sequential)
- Group into parallel-safe batches

## 3. Dispatch Agents

For each independent issue, dispatch an Agent with `isolation: "worktree"`. Each agent gets:

- **Branch name**: `{issue-number}-{short-kebab-description}`
- **TDD enforced**: tests first, then implementation
- **Self-correction**: If tests fail, retry up to 3 cycles. After 3 failures, report and stop.

**Concurrency:** Parallel worktree-isolated dispatches are supported when the mutex queue is available (see `lib/dispatch.sh`, issue #50). The kernel `flock`-wraps `git worktree add` to serialize the 1-second `.git/config` critical section while leaving downstream agent execution parallel. If `flock` is unavailable on the host (e.g. macOS without Homebrew `util-linux`), the helper falls back to naked `git worktree add` and the operator-facing CLAUDE.md HARD RULE "Agent Worktree Dispatch — Mutex Queue" says to dispatch serially. Any consumer-side shell that creates worktrees concurrently SHOULD source `lib/dispatch.sh` and call `_dispatch_worktree_add` instead of bare `git worktree add`.

Each agent's prompt MUST include:
- Reuse existing modules, search codebase before writing new code
- Do NOT update docs/CHANGELOG.md or docs/DECISIONS.md. `/land` handles this
- Push to correct remote: `git push -u origin {branch-name}`
- PR body must include `Closes #{issue-number}`
- Run the full quality gate before marking complete

## 4. Monitor & Report

After all agents complete, report a status matrix:

```
| Issue | Branch              | Tests    | PR  | Status           |
|-------|---------------------|----------|-----|------------------|
| #3    | 3-x-history-scraper | 18 pass  | #10 | Ready for review |
| #4    | 4-voice-profiler    | 12 pass  | #11 | Ready for review |
```

## 5. Review PRs

Run `/review-pr` on each PR sequentially.

## 6. Handoff

Report to operator:
- Which PRs are merge-ready (link each)
- Any PRs needing operator attention (and why)
- Recommended merge order (if dependencies exist)
- Remind: after merging all, run `/land` to complete the wave
