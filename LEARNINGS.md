# Adult Hockey Agent: Learnings

## Session Log

### Session 1 — API Discovery + Parser (2026-02-12)

- Discovered DASH exposes JSON:API endpoints, no Playwright needed for polling
- Two-step fetch: date-availabilities → events by ID
- Event names live in teams relationship via homeTeam, not event attributes
- JSON:API included[] relationship resolution required for all meaningful data
- Parser: 9 tests passing, handles PLAYERS/GOALIES pairing by time slot
- Cost: ~$2-3 (estimated, exact not captured)

### Session 2 — Core Implementation + Production Setup (2026-02-13)

**Implemented:**
- Scraper (27 tests): Two-step fetch pipeline with rate limiting, retries, dynamic date calculation
- Evaluator (23 tests): Alert rules for minimum capacity and alert-worthy events
- State (25 tests): Suppression logic with TTL and session transitions
- Notifiers: Console (11 tests) and Slack (17 tests) with message formatting
- Scheduler (part of index tests): Cron-based polling every 30 minutes
- Main orchestrator (5 tests): End-to-end flow from scrape → evaluate → notify
- Production setup: PM2 ecosystem, deployment guide, comprehensive README

**Key Patterns:**
- TDD throughout: Write failing test first, implement until green
- Dependency injection for testability (Config, State, Notifier instances passed in)
- Exponential backoff with jitter for retries (base=1s, max=30s)
- Atomic file writes for state persistence (write to temp, rename)
- Rate limiting enforced in scraper (30s minimum gap between API requests)

**Challenges:**
- None significant — architecture was well-defined from Session 1 discoveries
- All 142 tests passing on first try after TDD approach

**Cost:** $9.23 (955 input, 64.3k output, 8.2m cache read, 555.1k cache write on Sonnet 4.5, plus $0.08 on Haiku)

## Reusable Patterns

<!-- Patterns worth extracting to /shared/lib/ -->

## Prompt Templates

<!-- Prompts that worked well, saved for reuse -->

## Content Ideas

<!-- Tagged during development -->

## Metrics

| Session | Duration | Tests | Tokens (I/O/Cache)     | Cost     |
| ------- | -------- | ----- | ---------------------- | -------- |
| 1       | ~45min   | 9     | Not captured           | ~$2-3    |
| 2       | ~90min   | 142   | 955/64.3k/8.2m+555.1k  | $9.23    |
