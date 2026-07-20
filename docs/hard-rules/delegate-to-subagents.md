# Delegate to Subagents (HARD RULE)

Main session context is a scarce resource. Delegate aggressively to subagents (`Agent` tool with Explore or general-purpose subagent types, isolated worktree agents for implementation) so the main session stays lean.

**Default patterns:**
- **Per-PR review** (`/review-pr`): general-purpose subagent runs the full flow (rebase, tests, Codex review, fixes, push) and returns verdict + findings summary + commit SHAs.
- **Investigation / grep / multi-file reads / spec hunting**: Explore subagent, not inline.
- **Implementation work for any issue**: Agent with `isolation: worktree`.
- **Verbose verification runs**: subagent returns a 3-line summary.

**Main session holds ONLY:**
- Slash-command orchestration
- Operator-facing decisions
- Final status reports
- Cross-agent coordination

**Before any Read/Grep/Bash/Glob call in the main session, ask: "can a subagent do this and return a 3-line summary?"** If yes, delegate. Only operate inline when the output must directly inform the very next operator-facing message.
