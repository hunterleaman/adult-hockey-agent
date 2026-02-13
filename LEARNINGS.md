# Adult Hockey Agent: Learnings

## Session Log

### Session 1 — API Discovery + Parser (2026-02-13)
- Discovered DASH exposes JSON:API endpoints, no Playwright needed for polling
- Two-step fetch: date-availabilities → events by ID
- Event names live in teams relationship via homeTeam, not event attributes
- JSON:API included[] relationship resolution required for all meaningful data
- Parser: 9 tests passing, handles PLAYERS/GOALIES pairing by time slot
- Cost: ~$X (estimate from Claude Code token usage)

## Reusable Patterns
<!-- Patterns worth extracting to /shared/lib/ -->

## Prompt Templates
<!-- Prompts that worked well, saved for reuse -->

## Content Ideas
<!-- Tagged during development -->

## Metrics
| Session | Duration | Tests | Token Est | Cost Est |
|---------|----------|-------|-----------|----------|
| 1       | ~45min   | 9     | TBD       | TBD      |
