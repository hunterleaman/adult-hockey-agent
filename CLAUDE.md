# CLAUDE.md — Adult Hockey Agent

## Project Overview

Monitoring agent that tracks adult pick-up hockey registration at Extreme Ice Center via the DaySmart DASH webapp. Sends notifications when sessions meet configurable criteria. Future scope includes league standings, stats, and scheduling.

## Naming Convention

**CRITICAL**: Always use the full three-word name "adult-hockey-agent" in all contexts. Never use shortened versions.

### Internal References (code, configs, infrastructure)
- **Repository name**: `adult-hockey-agent`
- **Package name**: `adult-hockey-agent` (package.json)
- **PM2 app name**: `adult-hockey-agent`
- **File paths**: `/path/to/adult-hockey-agent/`
- **Git references**: `adult-hockey-agent`
- **Droplet hostname**: `adult-hockey-agent`
- **Firewall name**: `adult-hockey-agent-firewall`
- **Nginx upstream**: `adult_hockey_agent` (underscores for variable names)
- **Backup scripts**: `backup-adult-hockey-agent.sh`

### System Usernames (no hyphens allowed)
- **SSH/system user**: `adulthockey` (one word, no hyphens)
- **File ownership**: `adulthockey:adulthockey`
- **Home directory**: `/home/adulthockey`

### External/Marketing References
- **Public name**: "Adult Hockey Agent" (title case, spaces)
- **Documentation titles**: "Adult Hockey Agent"
- **README headers**: "# Adult Hockey Agent"

### ❌ NEVER Use These
- ~~`hockey-agent`~~ (missing "adult-")
- ~~`hockey`~~ (too generic, ambiguous)
- ~~`aha`~~ or ~~`AHA`~~ (unclear acronym)
- ~~`user: hockey`~~ (should be `adulthockey`)

### Why This Matters
1. **Clarity**: "hockey-agent" is ambiguous (youth? league? standings?)
2. **Searchability**: Full name ensures unique, unambiguous search results
3. **Professionalism**: Consistent naming across codebase, docs, and infrastructure
4. **Portability**: If project scope expands (youth hockey, league stats), naming remains clear

**Rule of thumb**: When in doubt, use the full three-word name `adult-hockey-agent` with hyphens (or `adulthockey` for usernames where hyphens aren't allowed).

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

### Session 1 (2026-02-12) - API Discovery

1. **Playwright browsers not installed**: Initial `npm run discover` failed because Playwright browsers weren't installed. Required `npx playwright install chromium` before running browser automation.
2. **Hardcoded dates in discovery scripts**: Initial investigation scripts (`src/fetch-events.ts`, `src/fetch-availabilities.ts`) used hardcoded dates like `2026-02-13`. These are throwaway investigation tools, NOT production patterns. Production scraper must calculate dates dynamically.
3. **Missing event names (empty desc field)**: Initially looked for event names in `event.attributes.desc` which was empty. Event names actually come from the `homeTeam` relationship resolved via JSON:API `included[]` array where `type="teams"`.
4. **Case-sensitive team name filtering**: Parser initially used `teamName.includes('ADULT Pick Up')` which failed to match `"Adult Pick Up Hockey (Mornings)"` (lowercase 'A'). Fixed by using case-insensitive comparison: `teamName.toLowerCase().includes('adult pick up')`.

### Session 2 (2026-02-13) - Core Implementation

1. **Plan mode cannot be exited cleanly from within plan mode**: `/plan mode` cannot be exited cleanly from within plan mode. Use `/plan off` from the CLI prompt to exit, which ends the session. Resume with a fresh claude session to continue work.

### Session 3 (2026-02-16) - ES Modules & Alert Logic Update

1. **Missing .js extensions in ES module imports**: With `"type": "module"` in package.json, Node.js requires explicit `.js` extensions for relative imports. Updated scheduler.ts, index.ts, and scraper.ts to add `.js` extensions to all runtime imports (type-only imports don't need extensions).
2. **OPPORTUNITY alert logic changed**: Updated from `player_spots_remaining <= 10` to `players_registered >= 10`. This better reflects when a session has critical mass (enough committed players) rather than urgency (few spots left). Config variable renamed from `PLAYER_SPOTS_ALERT` to `MIN_PLAYERS_REGISTERED`.

### Session 4 (2026-02-17) - Alert Priority System & Slack Button Fix

1. **Slack 400 Bad Request on SOLD_OUT alerts**: SlackNotifier used `style: 'default'` for buttons, but Slack's Block Kit only accepts `'primary'`, `'danger'`, or omitting the field. Invalid `'default'` value caused 400 errors. Fixed by returning `undefined` for default styling and omitting action button entirely for SOLD_OUT alerts (since registration isn't possible).
2. **Multiple alerts firing for same session**: Evaluator allowed both FILLING_FAST and OPPORTUNITY to fire for the same session. For example, a session with 19/24 players would trigger both alerts with redundant information. Implemented priority hierarchy (SOLD_OUT > NEWLY_AVAILABLE > FILLING_FAST > OPPORTUNITY) with `continue` statements to ensure only one alert per session fires based on highest priority condition met.

### Session 5 (2026-02-17) - Alert Oscillation Fix

1. **Alert oscillation bug**: Despite Session 4 implementing priority hierarchy in evaluation order, the suppression logic had a critical flaw causing alerts to oscillate between FILLING_FAST and OPPORTUNITY. Suppression functions checked `prevState.lastAlertType !== CURRENT_TYPE`, which returned TRUE when previous alert was a different type, causing alerts to alternate indefinitely (e.g., FILLING_FAST → OPPORTUNITY → FILLING_FAST → OPPORTUNITY) despite no session changes. Root cause: suppression logic didn't enforce the priority hierarchy - it only checked if the previous alert was the SAME type, not if it was a HIGHER priority type.

2. **Fix: Hierarchy-aware suppression**: Updated `shouldAlertOpportunity()` and `shouldAlertFillingFast()` to block "downgrades" from higher-priority alerts. OPPORTUNITY now suppressed if previous alert was FILLING_FAST, NEWLY_AVAILABLE, or SOLD_OUT. FILLING_FAST now suppressed if previous alert was NEWLY_AVAILABLE or SOLD_OUT (unless session state changed). This enforces: once a higher-priority alert fires, lower-priority alerts cannot fire unless session meaningfully changes. Added 7 comprehensive tests covering all valid state transitions and blocking invalid downgrades. See `ALERT-HIERARCHY-FIX.md` for complete analysis.

## API Architecture

DASH exposes a JSON:API at `/dash/jsonapi/api/v1/`. Polling requires a **two-step fetch flow**:

### Step 1: Get Event IDs for Date Range

```
GET /dash/jsonapi/api/v1/date-availabilities?cache[save]=false&page[size]=365&sort=id&filter[date__gte]={YYYY-MM-DD}&company=extremeice
```

Returns:

```json
{
  "data": [
    {
      "id": "2026-02-13",
      "attributes": {
        "date": "2026-02-13T00:00:00",
        "count": 8,
        "events": [213376, 214134, 213364, ...],  // <-- Event IDs
        "sports": [20, 20, ...],
        "programs": [7, 7, ...]
      }
    }
  ]
}
```

### Step 2: Fetch Events by IDs

```
GET /dash/jsonapi/api/v1/events?cache[save]=false&filter[id__in]={comma-separated-ids}&filter[unconstrained]=1&company=extremeice&include=summary,homeTeam,resource
```

Returns events with **JSON:API relationships** in `included[]` array.

### JSON:API Relationship Resolution

**Getting event names:**

1. Event → `relationships.homeTeam.data.id` (e.g., `"5421"`)
2. Lookup in `included[]` where `type="teams"` and `id="5421"`
3. Get `attributes.name` → `"(PLAYERS) ADULT Pick Up MORNINGS"`

**Getting registration data:**

1. Event → `relationships.summary.data.id` (e.g., `"213364"`)
2. Lookup in `included[]` where `type="event-summaries"` and `id="213364"`
3. Extract:
   - `attributes.registered_count` → current registrations
   - `attributes.composite_capacity` → max capacity
   - `attributes.remaining_registration_slots` → spots left (can be negative)
   - `attributes.registration_status` → `"full"` | `"open"`

### CRITICAL: Event Names Location

- ❌ **NOT** in `event.attributes.name` (doesn't exist)
- ❌ **NOT** in `event.attributes.desc` (empty string)
- ✅ **YES** in `included[]` where `type="teams"` via `homeTeam` relationship

### API Response Format

Uses JSON:API spec (https://jsonapi.org/):

- Main resources in `data[]`
- Related resources in `included[]`
- Relationships link by `{type, id}` pairs
- Content-Type: `application/vnd.api+json`

## Production Scraper Requirements

When implementing `src/scraper.ts`, follow these requirements:

### Dynamic Date Calculation

- **NO hardcoded event IDs or dates** anywhere in production code
- Calculate forward window dynamically: `today + FORWARD_WINDOW_DAYS` (default 5 days)
- Filter for Mon/Wed/Fri dates only within the window
- Fetch events for discovered dates via the two-step pipeline

### Two-Step Fetch Pipeline

1. **Call date-availabilities** with calculated date range
2. **Parse response** to extract event IDs for Mon/Wed/Fri dates
3. **Call events endpoint** with `filter[id__in]=<discovered-ids>`
4. **Pass response to parser** (already implemented in `src/parser.ts`)

### Discovery Scripts Are NOT Production Patterns

The following scripts are **throwaway investigation tools** only:

- `src/api-discovery.ts` - Playwright-based network capture tool
- `src/fetch-events.ts` - Manual event ID fetcher with hardcoded IDs
- `src/fetch-availabilities.ts` - Single-date availability checker

**Do not copy patterns from these scripts into production code.** They use hardcoded dates and manual IDs for investigation purposes.

### Error Handling

Must handle gracefully:

- No events found for a date (empty events array)
- API returns 4xx/5xx errors (retry with exponential backoff)
- Network timeouts (configurable timeout, default 30s)
- Malformed JSON responses (log and skip, don't crash)
- Missing relationships in included[] (skip that event, continue)

### Rate Limiting

- Minimum 30-second gap between API requests (per DASH constraints)
- No concurrent requests (run date-availabilities, THEN events sequentially)
- Cache date-availabilities response for the current poll cycle (no need to re-fetch)

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

**CRITICAL: Run quality checks first**

```bash
npm run check
```

This runs: typecheck + lint + format:check + test

### Code Quality

1. ✅ `npm run check` — ALL must pass before commit
2. ✅ Fix any failures
3. ✅ Commit with descriptive message (conventional commits format)
4. ✅ `git push` — work is NOT done until push succeeds

### Documentation

5. ✅ Update `docs/SPEC.md` if requirements changed
6. ✅ Update CLAUDE.md "Known Mistakes" if errors occurred
7. ✅ Add ADR to `docs/DECISIONS.md` for architectural choices
8. ✅ Create `docs/sessions/YYYY-MM-DD-topic.md` for complex fixes

### Handoff

9. ✅ Summarize what was accomplished
10. ✅ Note remaining work for next session

**See docs/CONTRIBUTING.md for detailed protocols.**

## File Organization

- src/ — all source code
- tests/ — all test files, mirror src/ structure
- fixtures/ — saved HTML snapshots from DASH for testing
- data/ — runtime state (gitignored except .gitkeep)
