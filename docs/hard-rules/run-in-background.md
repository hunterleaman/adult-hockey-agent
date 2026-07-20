# Agent Dispatches MUST Use `run_in_background: true` (HARD RULE)

Every `Agent` tool call MUST set `run_in_background: true`. Foreground dispatches block the operator's view of the agent (no entry in the agent dashboard) and waste main-session context on synchronous waiting.

- **Rule:** All `Agent` calls: worktree-isolated implementation agents, Explore subagents, general-purpose research agents, code-reviewer agents: set `run_in_background: true`.
- **Why:** Operator visibility (background agents appear in the agent panel UI) + main session can keep responding while agent runs + the harness notifies on completion automatically (no polling needed).
- **What this DOESN'T change:** Worktree-isolated dispatches still serial (one message per agent). Background is not parallel. Background = visible + non-blocking-on-other-agents. The dependency chain logic is unchanged: dispatch agent N+1 only after agent N's notification arrives.
- **Exception:** None. If the dispatch is so trivial that synchronous-foreground feels right, it's almost certainly something that shouldn't be an Agent dispatch in the first place: use Read/Grep/Bash inline instead.
