# adult-hockey-agent Architecture

Relocated verbatim from CLAUDE.md on 2026-07-20 (CPT slim-pointer migration). Read together with docs/SPEC.md before touching the scraper, parser, or evaluator.

## Architecture Rules

- TypeScript strict mode, no `any` types
- Functional style preferred over classes (except where interfaces demand it, e.g., Notifier)
- All async operations must have error handling with retry logic
- No console.log in production code — use a structured logger
- Environment variables loaded once at startup via config.ts, validated with clear error messages
- State persisted to JSON file, never held only in memory
- Every module exports pure functions or classes with injected dependencies (testable)

## API Architecture

DASH exposes a JSON:API at `/dash/jsonapi/api/v1/`. Polling requires a **two-step fetch flow**:

### Step 1: Get Event IDs for Date Range

```
GET /dash/jsonapi/api/v1/date-availabilities?cache[save]=false&page[size]=365&sort=id&filter[date__gte]={YYYY-MM-DD}&company=charlotteice
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
GET /dash/jsonapi/api/v1/events?cache[save]=false&filter[id__in]={comma-separated-ids}&filter[unconstrained]=1&company=charlotteice&include=summary,homeTeam,resource
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
- Scrape every date in the window — post-merger PIH runs pickup on additional days beyond the old Mon/Wed/Fri XIC schedule; the evaluator's morning gate (`ALERT_MORNINGS_ONLY`) controls alert volume, not the scraper
- Fetch events for discovered dates via the two-step pipeline

### Two-Step Fetch Pipeline

1. **Call date-availabilities** with calculated date range
2. **Parse response** to extract event IDs for every date in the window
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
