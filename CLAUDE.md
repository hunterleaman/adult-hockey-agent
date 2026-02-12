# CLAUDE.md — Adult Hockey Agent

## Project Overview
Monitoring agent that tracks adult pick-up hockey registration at Extreme Ice Center via the DaySmart DASH webapp. Sends notifications when sessions meet configurable criteria. Future scope includes league standings, stats, and scheduling.

## Architecture Rules
- TypeScript strict mode, no `any` types
- Functional style preferred over classes (except where interfaces demand it, e.g., Notifier)
- All async operations must have error handling with retry logic
- No console.log in production code — use a structured logger
- Environment variables loaded once at startup via config.ts, validated with clear error messages
- State persisted to JSON file, never held only in memory
- Every module exports pure functions or classes with injected dependencies (testable)

## Code Style
- No semicolons (Prettier handles it)
- Single quotes
- 2-space indentation
- Explicit return types on all exported functions
- Comments only for: non-obvious business logic, DASH-specific quirks, or workarounds

## Testing
- Vitest for all tests
- Test against saved HTML fixtures, not live DASH site
- Parser tests: verify extraction against real page snapshots
- Evaluator tests: cover all alert rules including edge cases
- State tests: verify suppression logic and transitions
- No mocking Playwright in unit tests — use fixture files instead

## Known Mistakes
<!-- Update this section when Claude Code makes errors -->

## Constraints
- Polling must respect DASH rate limits — minimum 30-second gap between requests
- No concurrent Playwright instances (memory constraint on $6 droplet)
- State file must be atomic-write safe (write to temp, rename)
- Alert messages must include direct registration URL
- Never auto-purchase without explicit user approval
- Phase 2 auto-registration is OUT OF SCOPE for initial build

## Development Workflow
1. Read spec.md before starting any task
2. Write failing test first
3. Implement until test passes
4. Verify against spec requirements
5. Commit with descriptive message
6. Push to remote

## Session-End Protocol (mandatory before ending any session)
1. Update spec.md if requirements changed or were clarified
2. Update "Known Mistakes" section above if Claude Code produced errors that needed correction
3. Add entries to docs/decisions.md for non-obvious architectural choices
4. Commit doc updates separately: `docs: update spec and learnings from session N`
5. Run all tests, lint, type-check
6. `git push` — work is NOT done until push succeeds
7. Summarize what was accomplished and what remains

## File Organization
- src/ — all source code
- tests/ — all test files, mirror src/ structure  
- fixtures/ — saved HTML snapshots from DASH for testing
- data/ — runtime state (gitignored except .gitkeep)
