# Architecture Decision Records

## Format

Each entry follows:

- **Date**: YYYY-MM-DD
- **Decision**: What was decided
- **Context**: Why it mattered
- **Consequences**: Trade-offs accepted

---

## 2026-02-12: Project Initialization

**Decision**: Use ES modules (type: "module") with NodeNext module resolution

**Context**: Modern Node.js supports ES modules natively. TypeScript's NodeNext resolution provides the best compatibility between CommonJS and ESM.

**Consequences**:

- Must use `.js` extensions in import statements (TypeScript limitation)
- Better tree-shaking and modern tooling support
- Cleaner async/await syntax

---

## 2026-02-12: State Persistence Strategy

**Decision**: JSON file on disk, no database

**Context**: Simple state (session tracking, alert suppression). No complex queries needed. Must survive process restarts.

**Consequences**:

- Atomic write pattern required (write to temp, rename)
- Limited to single-process deployment
- Easy to inspect and debug
- Zero infrastructure dependencies

---

## 2026-02-12: Notification Architecture

**Decision**: Plugin-based notifiers implementing common interface

**Context**: Multiple notification channels needed (Slack, Email, SMS, Push). Users configure only what they want.

**Consequences**:

- Each notifier independently testable
- Easy to add new channels
- Graceful degradation if one channel fails
- Must handle partial failures (some notifiers succeed, others fail)

---

## ADR-001: 2026-02-12 - Use Direct HTTP API Calls Instead of Playwright for Polling

**Decision**: Use direct HTTP requests to DASH JSON:API endpoints for polling. Retain Playwright only for Phase 2 auto-registration.

**Context**: Initial assumption was that DASH is a SPA requiring browser rendering to access data. API discovery revealed DASH exposes a full JSON:API at `/dash/jsonapi/api/v1/` that returns all registration data as structured JSON. The web UI internally uses this API via XHR/fetch calls.

**Consequences**:

- ✅ **Faster**: HTTP requests complete in ~200ms vs 3-5s for browser rendering
- ✅ **Cheaper**: No need for Chromium process (saves ~150MB RAM per poll)
- ✅ **More reliable**: No browser crashes, render timeouts, or DOM parsing fragility
- ✅ **Simpler deployment**: No headless browser dependencies on production server
- ⚠️ **Two-step fetch required**: Must call date-availabilities first to get event IDs, then fetch events by ID (this is how the SPA works internally)
- ⚠️ **JSON:API complexity**: Relationship resolution requires parsing `included[]` array and matching by `{type, id}` pairs
- ⚠️ **Playwright still needed**: Phase 2 auto-registration requires authenticated checkout flow via browser automation

**Implementation**:

- Polling: `src/scraper.ts` uses `fetch()` to call DASH API
- Phase 2: `src/registrar.ts` (future) uses Playwright for checkout

---

## ADR-002: 2026-02-12 - Two-Step Fetch Pipeline for Events

**Decision**: Fetch events using a two-step pipeline: (1) date-availabilities to get event IDs, (2) events endpoint with filter[id__in] to get event details.

**Context**: DASH API does not support direct date range queries on the events endpoint. The SPA frontend calls `/date-availabilities` first to discover which events exist on which dates, then fetches those specific event IDs. Attempting to fetch events by date range alone (`filter[start_date__gte]`) without event IDs returns incomplete results.

**Consequences**:

- ✅ **Matches SPA behavior**: Replicates the exact flow the web UI uses
- ✅ **Complete data**: Ensures we get all events DASH considers "available" for a date
- ✅ **Efficient**: date-availabilities returns minimal metadata (just IDs), then we fetch full details only for dates we care about (Mon/Wed/Fri)
- ⚠️ **Two round-trips**: Requires sequential API calls (date-availabilities THEN events)
- ⚠️ **Cache coordination**: date-availabilities response should be cached for the poll cycle to avoid redundant requests

**Implementation**:

1. Calculate target dates (today + forward window, filter Mon/Wed/Fri)
2. `GET /date-availabilities?filter[date__gte]={earliest-date}`
3. Extract `attributes.events[]` arrays for target dates
4. `GET /events?filter[id__in]={comma-separated-ids}&include=summary,homeTeam`
5. Pass to parser

---

## ADR-003: 2026-02-12 - JSON:API Relationship Resolution for Event Names

**Decision**: Resolve event names by following `homeTeam` relationships from events to teams entities in the `included[]` array.

**Context**: Initial investigation assumed event names would be in `event.attributes.name` or `event.attributes.desc`. Both fields are empty or contain generic values. The actual event names (e.g., "(PLAYERS) ADULT Pick Up MORNINGS") are stored in a separate `teams` entity and linked via the `homeTeam` relationship. This follows JSON:API spec for normalized relational data.

**Consequences**:

- ✅ **Correct data**: Gets the actual team names displayed in the DASH UI
- ✅ **Structured**: Separation of events from teams allows reuse (teams can have multiple events)
- ⚠️ **Complex parsing**: Parser must build lookup maps from `included[]` and resolve relationships by `{type, id}` pairs
- ⚠️ **Missing relationships**: Must handle cases where `homeTeam` is null or referenced team not in `included[]`
- ⚠️ **Include parameter required**: API requests must include `include=homeTeam` or teams won't be in response

**Implementation**:

- Parser builds `Map<string, JsonApiIncluded>` from `included[]` keyed by `"${type}:${id}"`
- For each event: `event.relationships.homeTeam.data.id` → lookup `"teams:{id}"` → get `attributes.name`
- Same pattern for summary data: `event.relationships.summary.data.id` → lookup `"event-summaries:{id}"` → get registration counts

---

## ADR-004: 2026-02-17 - Dynamic Polling with setTimeout Instead of Cron

**Decision**: Use `setTimeout` with recursive scheduling instead of `node-cron` for poll scheduling.

**Context**: Spec requires accelerated polling (30 min) when any session has <= 4 spots remaining, otherwise normal polling (60 min). Cron schedules are static and cannot change interval based on application state.

**Consequences**:

- ✅ **Dynamic intervals**: Can check session state after each poll and adjust next interval
- ✅ **Simpler code**: No cron expression parsing, just plain milliseconds
- ✅ **Precise timing**: Schedules exactly N minutes from completion of previous poll (not wall-clock aligned)
- ✅ **Fewer dependencies**: Removed `node-cron` package
- ⚠️ **Process must stay alive**: Unlike cron, scheduler stops if process crashes (acceptable for systemd-managed service)
- ⚠️ **Drift from wall-clock**: Polls at completion+interval, not on-the-hour (acceptable, more predictable)

**Implementation**:

- `scheduleNextPoll()`: Checks `shouldAccelerate()`, uses `pollIntervalAcceleratedMinutes` or `pollIntervalMinutes`
- Recursive: Each poll completion calls `scheduleNextPoll()` to queue the next one
- Graceful shutdown: Clears timeout on SIGINT/SIGTERM

---

## ADR-005: 2026-02-17 - Alert Hierarchy Enforcement in Suppression Logic

**Decision**: Suppress lower-priority alerts when a higher-priority alert was previously sent for the same session, unless session state has meaningfully changed.

**Context**: Initial priority system (Session 4) only enforced hierarchy in evaluation ORDER (check FILLING_FAST before OPPORTUNITY). Suppression logic checked `prevState.lastAlertType !== CURRENT_TYPE`, allowing alerts to oscillate (FILLING_FAST → OPPORTUNITY → FILLING_FAST) despite no session changes. This spammed users with redundant notifications.

**Consequences**:

- ✅ **Prevents alert oscillation**: Lower-priority alerts cannot fire after higher-priority alerts
- ✅ **Clearer UX**: User receives one definitive alert about current session state
- ✅ **Enforces priority hierarchy**:
  - SOLD_OUT > NEWLY_AVAILABLE > FILLING_FAST > OPPORTUNITY
  - Once higher-priority alert fires, lower-priority suppressed
- ⚠️ **Requires state tracking**: Suppression depends on knowing previous alert type
- ⚠️ **No downgrade notifications**: If spots open up (FILLING_FAST → fewer spots), user not notified (acceptable - can add PRESSURE_EASED alert type later if needed)

**Implementation**:

- `shouldAlertOpportunity()`: Returns false if previous alert was FILLING_FAST, NEWLY_AVAILABLE, or SOLD_OUT
- `shouldAlertFillingFast()`: Returns false if previous alert was NEWLY_AVAILABLE or SOLD_OUT (unless player count increased)
- Comprehensive test coverage: 7 tests for valid transitions, blocking downgrades, and same-priority suppression

**See Also**: `docs/sessions/2026-02-17-alert-hierarchy-fix.md` for detailed analysis

---

## ADR-006: 2026-02-17 - ESLint Integration for Code Quality

**Decision**: Add ESLint with TypeScript support to enforce architectural rules and catch common issues.

**Context**: CLAUDE.md specifies rules like "no console.log in production code" and "no any types", but these were only enforced via manual review. Project lacked a lint script, making it unclear if code met standards.

**Consequences**:

- ✅ **Automated enforcement**: ESLint catches violations in CI/CD
- ✅ **Prevents regressions**: Rules like no-floating-promises catch async bugs
- ✅ **Self-documenting**: Rules encode architectural decisions in config
- ✅ **IDE integration**: Developers get real-time feedback
- ⚠️ **Build overhead**: Adds ~300ms to build time
- ⚠️ **Config complexity**: ESLint v10 uses flat config format (learning curve)
- ⚠️ **Rule exceptions needed**: Parser deals with untyped external API, needs `any` usage

**Implementation**:

- `eslint.config.js`: Flat config for ESLint v10
- Enforces: no-console (except specific files), no-explicit-any, explicit-function-return-type, no-floating-promises
- Exceptions: Parser (warns on `any`), tests (relaxed), discovery scripts (ignored)
- Scripts: `npm run lint`, `npm run lint:fix`

---
