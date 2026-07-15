# Morning-Only Alerts + Location Awareness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Alert only on early-morning (<8am) pickup sessions at either rink (XIC or PIH), with rink location visible in every message, correct per-facility registration links, and the cross-rink session-merge bug fixed.

**Architecture:** Both rinks share DASH tenant `charlotteice`; the `resource` relationship (already in our `include=`) carries `facility_id` (1=XIC, 2=PIH) and rink name. A new `session-identity` module becomes the single definition of session equality (date+time+facility, with legacy fallback). The evaluator gains one morning gate; everything else is threading location through parser → evaluator → notifiers → interactions.

**Tech Stack:** TypeScript (strict, ES modules), Vitest, fixture-based tests, Express, Slack Block Kit.

**Spec:** `docs/superpowers/specs/2026-07-14-morning-only-alerts-and-location-design.md`

## Global Constraints

- Branch: `feat/morning-only-alerts-and-location` (already created; commit every task here)
- TypeScript strict mode, **no `any` types**
- No semicolons, single quotes, 2-space indent (Prettier enforces; run `npm run format` if unsure)
- Explicit return types on all exported functions
- Relative **runtime** imports need `.js` extensions (`"type": "module"`); type-only imports do not
- Tests are fixture-based (no live DASH calls, no Playwright mocks)
- `npm test -- --run <file>` runs a single test file; `npm run check` = typecheck + lint + format:check + all tests
- Conventional commit messages
- NOTE: `tsc --noEmit` does not cover `tests/` (tsconfig includes only `src/`) — vitest transpiles without typechecking. Test literals missing new Config fields won't fail typecheck, but add fields anyway where the plan says so, for runtime correctness.
- Fixtures already committed: `fixtures/dash-api/events-multi-facility.json` (live capture 2026-07-14, events for Wed 2026-07-15 — contains XIC 6:10am pickup on MAIN RINK fac=1, PIH 11:30am pickup on Pineville Rink fac=2, XIC 12:00pm pickup on TRAINING RINK fac=1)

---

### Task 1: Session identity module

**Files:**
- Create: `src/session-identity.ts`
- Test: `tests/session-identity.test.ts`

**Interfaces:**
- Produces: `SessionRef { date: string; time: string; facilityId?: number }`, `sessionKey(ref: SessionRef): string`, `sessionMatches(a: SessionRef, b: SessionRef): boolean`. Every later task imports these.

- [ ] **Step 1: Write the failing test**

Create `tests/session-identity.test.ts`:

```ts
import { describe, it, expect } from 'vitest'
import { sessionKey, sessionMatches } from '../src/session-identity'

describe('sessionKey', () => {
  it('includes date, time, and facilityId', () => {
    expect(sessionKey({ date: '2026-07-15', time: '06:10', facilityId: 1 })).toBe(
      '2026-07-15:06:10:1'
    )
  })

  it('uses 0 when facilityId is missing (legacy entries)', () => {
    expect(sessionKey({ date: '2026-07-15', time: '06:10' })).toBe('2026-07-15:06:10:0')
  })
})

describe('sessionMatches', () => {
  it('matches when date, time, and facilityId are equal', () => {
    expect(
      sessionMatches(
        { date: '2026-07-15', time: '11:30', facilityId: 2 },
        { date: '2026-07-15', time: '11:30', facilityId: 2 }
      )
    ).toBe(true)
  })

  it('does NOT match same date+time at a different facility', () => {
    expect(
      sessionMatches(
        { date: '2026-07-15', time: '11:30', facilityId: 1 },
        { date: '2026-07-15', time: '11:30', facilityId: 2 }
      )
    ).toBe(false)
  })

  it('falls back to date+time when either side lacks facilityId (legacy)', () => {
    expect(
      sessionMatches(
        { date: '2026-07-15', time: '06:10' },
        { date: '2026-07-15', time: '06:10', facilityId: 1 }
      )
    ).toBe(true)
    expect(
      sessionMatches(
        { date: '2026-07-15', time: '06:10', facilityId: 1 },
        { date: '2026-07-15', time: '06:10' }
      )
    ).toBe(true)
  })

  it('never matches differing date or time', () => {
    expect(
      sessionMatches({ date: '2026-07-15', time: '06:10' }, { date: '2026-07-15', time: '06:00' })
    ).toBe(false)
    expect(
      sessionMatches({ date: '2026-07-16', time: '06:10' }, { date: '2026-07-15', time: '06:10' })
    ).toBe(false)
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- --run tests/session-identity.test.ts`
Expected: FAIL — cannot find module '../src/session-identity'

- [ ] **Step 3: Write minimal implementation**

Create `src/session-identity.ts`:

```ts
/**
 * Single definition of session identity. Post-merger, XIC (facility 1) and
 * PIH (facility 2) share one DASH tenant, so date+time alone is ambiguous —
 * two rinks can run pickup at the same time slot.
 */
export interface SessionRef {
  date: string // YYYY-MM-DD
  time: string // HH:MM (24h)
  facilityId?: number // DASH facility; undefined on legacy state/button values
}

export function sessionKey(ref: SessionRef): string {
  return `${ref.date}:${ref.time}:${ref.facilityId ?? 0}`
}

export function sessionMatches(a: SessionRef, b: SessionRef): boolean {
  if (a.date !== b.date || a.time !== b.time) return false
  // Legacy fallback: state entries and Slack button values written before
  // facility awareness lack facilityId — match on date+time alone for those.
  if (a.facilityId === undefined || b.facilityId === undefined) return true
  return a.facilityId === b.facilityId
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm test -- --run tests/session-identity.test.ts`
Expected: PASS (6 tests)

- [ ] **Step 5: Commit**

```bash
git add src/session-identity.ts tests/session-identity.test.ts
git commit -m "feat: add session-identity module (date+time+facility equality)"
```

---

### Task 2: Parser — facility extraction + cross-rink collision fix

**Files:**
- Modify: `src/parser.ts`
- Create: `fixtures/dash-api/events-cross-rink-collision.json`
- Test: `tests/parser.test.ts` (append new describe block)

**Interfaces:**
- Consumes: `sessionKey` from Task 1.
- Produces: `Session` gains optional `facilityId?: number`, `location?: string`, `rinkName?: string`. New export `DEFAULT_FACILITY_LABELS: Record<number, string>`. `parseEvents(apiResponse, facilityLabels?)` gains optional second param defaulting to `DEFAULT_FACILITY_LABELS`.

- [ ] **Step 1: Create the hand-crafted collision fixture**

The real fixture has no same-time cross-rink pair yet — that's the latent bug. Create `fixtures/dash-api/events-cross-rink-collision.json` (synthetic, shaped exactly like the real JSON:API payload):

```json
{
  "data": [
    {
      "id": "900001",
      "type": "events",
      "attributes": { "start": "2026-08-05T06:00:00", "end": "2026-08-05T07:10:00" },
      "relationships": {
        "homeTeam": { "data": { "type": "teams", "id": "7001" } },
        "summary": { "data": { "type": "event-summaries", "id": "900001" } },
        "resource": { "data": { "type": "resources", "id": "1" } }
      }
    },
    {
      "id": "900002",
      "type": "events",
      "attributes": { "start": "2026-08-05T06:00:00", "end": "2026-08-05T07:10:00" },
      "relationships": {
        "homeTeam": { "data": { "type": "teams", "id": "7002" } },
        "summary": { "data": { "type": "event-summaries", "id": "900002" } },
        "resource": { "data": { "type": "resources", "id": "1" } }
      }
    },
    {
      "id": "900003",
      "type": "events",
      "attributes": { "start": "2026-08-05T06:00:00", "end": "2026-08-05T07:10:00" },
      "relationships": {
        "homeTeam": { "data": { "type": "teams", "id": "7003" } },
        "summary": { "data": { "type": "event-summaries", "id": "900003" } },
        "resource": { "data": { "type": "resources", "id": "4" } }
      }
    },
    {
      "id": "900004",
      "type": "events",
      "attributes": { "start": "2026-08-05T06:00:00", "end": "2026-08-05T07:10:00" },
      "relationships": {
        "homeTeam": { "data": { "type": "teams", "id": "7004" } },
        "summary": { "data": { "type": "event-summaries", "id": "900004" } },
        "resource": { "data": { "type": "resources", "id": "4" } }
      }
    }
  ],
  "included": [
    { "type": "teams", "id": "7001", "attributes": { "name": "(PLAYERS) Adult Pick Up Hockey (Mornings)" } },
    { "type": "teams", "id": "7002", "attributes": { "name": "(GOALIES) Adult Pick Up Hockey (Mornings)" } },
    { "type": "teams", "id": "7003", "attributes": { "name": "PIH Adult Pickup Skater" } },
    { "type": "teams", "id": "7004", "attributes": { "name": "PIH Adult Pickup Goalie" } },
    { "type": "event-summaries", "id": "900001", "attributes": { "registered_count": 9, "composite_capacity": 22 } },
    { "type": "event-summaries", "id": "900002", "attributes": { "registered_count": 1, "composite_capacity": 3 } },
    { "type": "event-summaries", "id": "900003", "attributes": { "registered_count": 15, "composite_capacity": 22 } },
    { "type": "event-summaries", "id": "900004", "attributes": { "registered_count": 2, "composite_capacity": 3 } },
    { "type": "resources", "id": "1", "attributes": { "name": "MAIN RINK", "facility_id": 1 } },
    { "type": "resources", "id": "4", "attributes": { "name": "Pineville Rink", "facility_id": 2 } }
  ]
}
```

- [ ] **Step 2: Write the failing tests**

Append to `tests/parser.test.ts` (follow the file's existing fixture-loading pattern — it reads JSON from `fixtures/dash-api/` with `fs.readFileSync` + `JSON.parse`):

```ts
describe('facility awareness (XIC/PIH merger)', () => {
  const multiFacility = JSON.parse(
    fs.readFileSync('fixtures/dash-api/events-multi-facility.json', 'utf-8')
  )
  const collision = JSON.parse(
    fs.readFileSync('fixtures/dash-api/events-cross-rink-collision.json', 'utf-8')
  )

  it('extracts facilityId, location label, and rinkName from the resource relationship', () => {
    const sessions = parseEvents(multiFacility)

    expect(sessions).toHaveLength(3)

    const morning = sessions.find((s) => s.time === '06:10')!
    expect(morning.facilityId).toBe(1)
    expect(morning.location).toBe('XIC')
    expect(morning.rinkName).toBe('MAIN RINK')
    expect(morning.playersRegistered).toBe(12)
    expect(morning.playersMax).toBe(22)
    expect(morning.goaliesRegistered).toBe(1)
    expect(morning.goaliesMax).toBe(3)

    const pih = sessions.find((s) => s.time === '11:30')!
    expect(pih.facilityId).toBe(2)
    expect(pih.location).toBe('PIH')
    expect(pih.rinkName).toBe('Pineville Rink')
    expect(pih.playersRegistered).toBe(22)
    expect(pih.isFull).toBe(true)

    const noon = sessions.find((s) => s.time === '12:00')!
    expect(noon.facilityId).toBe(1)
    expect(noon.location).toBe('XIC')
    expect(noon.rinkName).toBe('TRAINING RINK')
  })

  it('does NOT merge same-time sessions at different rinks (collision regression)', () => {
    const sessions = parseEvents(collision)

    expect(sessions).toHaveLength(2)

    const xic = sessions.find((s) => s.facilityId === 1)!
    expect(xic.playersRegistered).toBe(9)
    expect(xic.goaliesRegistered).toBe(1)
    expect(xic.location).toBe('XIC')

    const pih = sessions.find((s) => s.facilityId === 2)!
    expect(pih.playersRegistered).toBe(15)
    expect(pih.goaliesRegistered).toBe(2)
    expect(pih.location).toBe('PIH')
  })

  it('falls back to rink name for unmapped facilities', () => {
    const sessions = parseEvents(collision, { 1: 'XIC' }) // no label for facility 2
    const pih = sessions.find((s) => s.facilityId === 2)!
    expect(pih.location).toBe('Pineville Rink')
  })

  it('keeps sessions with a missing resource relationship (facilityId 0)', () => {
    const noResource = JSON.parse(JSON.stringify(collision)) as typeof collision
    // strip resource relationships from the XIC pair only
    delete noResource.data[0].relationships.resource
    delete noResource.data[1].relationships.resource

    const sessions = parseEvents(noResource)
    expect(sessions).toHaveLength(2)
    const unknown = sessions.find((s) => s.facilityId === 0)!
    expect(unknown.location).toBe('Facility 0')
  })
})
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `npm test -- --run tests/parser.test.ts`
Expected: new describe block FAILS (facilityId undefined, collision produces 1 merged session); pre-existing tests still PASS.

- [ ] **Step 4: Implement in `src/parser.ts`**

4a. Add import at top:

```ts
import { sessionKey } from './session-identity.js'
```

4b. Extend the `Session` interface (after `price: number`):

```ts
  facilityId?: number // DASH facility: 1 = XIC, 2 = PIH; 0 if unresolvable
  location?: string // Display label ('XIC' | 'PIH'), from facilityLabels config
  rinkName?: string // Rink surface from resource: 'MAIN RINK', 'Pineville Rink', ...
```

4c. Add the default label map export (above `parseEvents`):

```ts
// Facility labels are display-only; facility IDs drive all logic. IDs are
// stable across DASH renames (Session 9/10 lesson: never key logic on
// human-facing strings).
export const DEFAULT_FACILITY_LABELS: Record<number, string> = { 1: 'XIC', 2: 'PIH' }
```

4d. Extend `JsonApiEvent.relationships` with:

```ts
    resource?: {
      data: { type: string; id: string } | null
    }
```

4e. Extend `ParsedEvent` with `facilityId: number` and `rinkName: string`.

4f. Change the `parseEvents` signature:

```ts
export function parseEvents(
  apiResponse: JsonApiResponse,
  facilityLabels: Record<number, string> = DEFAULT_FACILITY_LABELS
): Session[] {
```

4g. Inside the event loop, after the summary lookup succeeds, resolve the resource (degrade, don't drop — Session 9 lesson):

```ts
    // Resolve resource -> facility. Post-merger, facility_id distinguishes
    // XIC (1) from PIH (2). Missing resource degrades to facilityId 0.
    const resourceData = event.relationships.resource?.data
    const resource = resourceData
      ? includedMap.get(`${resourceData.type}:${resourceData.id}`)
      : undefined
    const facilityId: number = resource?.attributes?.facility_id ?? 0
    const rinkName: string = resource?.attributes?.name ?? ''
```

and add `facilityId, rinkName` to the `parsedEvents.push({ ... })` object.

4h. In the grouping loop, replace the key and seed location fields. Replace:

```ts
    const sessionKey = `${date}:${time}`

    if (!sessionMap.has(sessionKey)) {
```

with:

```ts
    const key = sessionKey({ date, time, facilityId: event.facilityId })

    if (!sessionMap.has(key)) {
```

(rename ALL uses of the old local `sessionKey` string variable in this loop to `key` — the local previously shadowed nothing, now it must not shadow the import), and extend the seeded object:

```ts
        facilityId: event.facilityId,
        location:
          facilityLabels[event.facilityId] ??
          (event.rinkName || `Facility ${event.facilityId}`),
        rinkName: event.rinkName,
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `npm test -- --run tests/parser.test.ts`
Expected: PASS (all pre-existing + 4 new)

- [ ] **Step 6: Commit**

```bash
git add src/parser.ts tests/parser.test.ts fixtures/dash-api/events-cross-rink-collision.json
git commit -m "feat: extract facility/location in parser, fix cross-rink session merge"
```

---

### Task 3: Config — morning gate flag, facility labels, cutoff 8am

**Files:**
- Modify: `src/config.ts`
- Test: `tests/config.test.ts` (append; follow the file's existing env save/restore pattern)

**Interfaces:**
- Consumes: `DEFAULT_FACILITY_LABELS` from Task 2.
- Produces: `Config` gains `alertMorningsOnly: boolean` and `facilityLabels: Record<number, string>`; `morningPickupMaxHour` default changes 9 → 8. Env vars: `ALERT_MORNINGS_ONLY`, `FACILITY_LABELS`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/config.test.ts` (reuse its existing beforeEach/afterEach env isolation; if it saves/restores `process.env`, add the new vars to that mechanism):

```ts
describe('morning gate + facility labels', () => {
  it('defaults morningPickupMaxHour to 8', () => {
    delete process.env.MORNING_PICKUP_MAX_HOUR
    expect(loadConfig().morningPickupMaxHour).toBe(8)
  })

  it('defaults alertMorningsOnly to true', () => {
    delete process.env.ALERT_MORNINGS_ONLY
    expect(loadConfig().alertMorningsOnly).toBe(true)
  })

  it('parses ALERT_MORNINGS_ONLY=false', () => {
    process.env.ALERT_MORNINGS_ONLY = 'false'
    expect(loadConfig().alertMorningsOnly).toBe(false)
  })

  it('defaults facilityLabels to 1:XIC,2:PIH', () => {
    delete process.env.FACILITY_LABELS
    expect(loadConfig().facilityLabels).toEqual({ 1: 'XIC', 2: 'PIH' })
  })

  it('parses FACILITY_LABELS override', () => {
    process.env.FACILITY_LABELS = '1:Charlotte,2:Pineville,3:NewRink'
    expect(loadConfig().facilityLabels).toEqual({
      1: 'Charlotte',
      2: 'Pineville',
      3: 'NewRink',
    })
  })

  it('throws a clear error on malformed FACILITY_LABELS', () => {
    process.env.FACILITY_LABELS = 'garbage'
    expect(() => loadConfig()).toThrow(/FACILITY_LABELS/)
  })
})
```

Also update any existing test asserting `morningPickupMaxHour` defaults to 9 — change the expectation to 8.

- [ ] **Step 2: Run tests to verify they fail**

Run: `npm test -- --run tests/config.test.ts`
Expected: FAIL — alertMorningsOnly undefined, maxHour 9, facilityLabels undefined.

- [ ] **Step 3: Implement in `src/config.ts`**

3a. Import at top (type-only import stays extension-less):

```ts
import { DEFAULT_FACILITY_LABELS } from './parser.js'
```

3b. Add to the `Config` interface after `morningPickupMaxHour: number`:

```ts
  alertMorningsOnly: boolean
  facilityLabels: Record<number, string>
```

3c. In `loadConfig()`, change the `morningPickupMaxHour` default to 8 and add:

```ts
    morningPickupMaxHour: parseIntOrDefault(process.env.MORNING_PICKUP_MAX_HOUR, 8),
    // Post-merger (XIC + PIH), the mission is early-morning pickup at either
    // rink. When true, sessions starting at/after morningPickupMaxHour never
    // alert (any type) but are still tracked in state and /sessions.
    alertMorningsOnly: parseBoolOrDefault(process.env.ALERT_MORNINGS_ONLY, true),
    facilityLabels: parseFacilityLabels(process.env.FACILITY_LABELS),
```

3d. Add helpers at the bottom (next to `parseIntOrDefault`):

```ts
function parseBoolOrDefault(value: string | undefined, defaultValue: boolean): boolean {
  if (!value || value.trim() === '') {
    return defaultValue
  }
  const normalized = value.trim().toLowerCase()
  if (normalized === 'true' || normalized === '1' || normalized === 'yes') return true
  if (normalized === 'false' || normalized === '0' || normalized === 'no') return false
  return defaultValue
}

function parseFacilityLabels(value: string | undefined): Record<number, string> {
  if (!value || value.trim() === '') {
    return { ...DEFAULT_FACILITY_LABELS }
  }
  const labels: Record<number, string> = {}
  for (const pair of value.split(',')) {
    const [idStr, ...labelParts] = pair.split(':')
    const id = parseInt(idStr, 10)
    const label = labelParts.join(':').trim()
    if (isNaN(id) || id <= 0 || !label) {
      throw new Error(
        `FACILITY_LABELS must be comma-separated "id:label" pairs (e.g. "1:XIC,2:PIH"), got: "${value}"`
      )
    }
    labels[id] = label
  }
  return labels
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm test -- --run tests/config.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/config.ts tests/config.test.ts
git commit -m "feat: add alertMorningsOnly + facilityLabels config, morning cutoff 9->8"
```

---

### Task 4: State — facility-aware matching

**Files:**
- Modify: `src/state.ts`
- Test: `tests/state.test.ts` (append)

**Interfaces:**
- Consumes: `sessionMatches` from Task 1.
- Produces: `updateRegistrationStatus(state, date, time, isRegistered, facilityId?)` and `updateUserResponse(state, date, time, userResponse, remindIntervalHours, facilityId?)` gain an optional trailing `facilityId?: number`. `updateSessionState` and `mergeUserResponses` match facility-aware internally (signatures unchanged).

- [ ] **Step 1: Write the failing tests**

Append to `tests/state.test.ts` (reuse its existing SessionState factory if one exists; otherwise build entries inline like its other tests):

```ts
describe('facility-aware matching (XIC/PIH merger)', () => {
  const baseSession = {
    date: '2026-08-05',
    dayOfWeek: 'Wednesday',
    time: '06:00',
    timeLabel: '6am - 7:10am',
    eventName: '(PLAYERS) Adult Pick Up Hockey (Mornings)',
    playersRegistered: 9,
    playersMax: 22,
    goaliesRegistered: 1,
    goaliesMax: 3,
    isFull: false,
    price: 0,
  }
  const xicSession = { ...baseSession, facilityId: 1, location: 'XIC' }
  const pihSession = {
    ...baseSession,
    eventName: 'PIH Adult Pickup Skater',
    facilityId: 2,
    location: 'PIH',
  }
  const makeEntry = (session: typeof xicSession) => ({
    session,
    lastAlertType: null,
    lastAlertAt: null,
    lastPlayerCount: null,
    isRegistered: false,
    userResponse: null,
    userRespondedAt: null,
    remindAfter: null,
  })

  it('updateUserResponse with facilityId only touches the matching rink', () => {
    const state = [makeEntry(xicSession), makeEntry(pihSession)]
    const updated = updateUserResponse(state, '2026-08-05', '06:00', 'not_interested', 2, 2)

    expect(updated.find((s) => s.session.facilityId === 2)!.userResponse).toBe('not_interested')
    expect(updated.find((s) => s.session.facilityId === 1)!.userResponse).toBeNull()
  })

  it('updateUserResponse without facilityId matches legacy-style (date+time)', () => {
    const state = [makeEntry(xicSession)]
    const updated = updateUserResponse(state, '2026-08-05', '06:00', 'registered', 2)

    expect(updated[0].userResponse).toBe('registered')
    expect(updated[0].isRegistered).toBe(true)
  })

  it('updateSessionState keeps same-time sessions at different rinks as separate entries', () => {
    let state = updateSessionState([], xicSession, null, null)
    state = updateSessionState(state, pihSession, null, null)

    expect(state).toHaveLength(2)

    // updating XIC counts must not clobber PIH
    state = updateSessionState(state, { ...xicSession, playersRegistered: 12 }, null, null)
    expect(state).toHaveLength(2)
    expect(state.find((s) => s.session.facilityId === 1)!.session.playersRegistered).toBe(12)
    expect(state.find((s) => s.session.facilityId === 2)!.session.playersRegistered).toBe(9)
  })

  it('updateSessionState matches a legacy entry lacking facilityId (no duplicate, no re-alert)', () => {
    const legacyEntry = makeEntry({ ...baseSession } as typeof xicSession)
    const state = updateSessionState([legacyEntry], xicSession, null, null)

    expect(state).toHaveLength(1)
    expect(state[0].session.facilityId).toBe(1)
  })

  it('mergeUserResponses matches facility-aware', () => {
    const pollState = [makeEntry(xicSession), makeEntry(pihSession)]
    const freshState = [
      {
        ...makeEntry(pihSession),
        userResponse: 'not_interested' as const,
        userRespondedAt: new Date().toISOString(),
      },
    ]

    const merged = mergeUserResponses(pollState, freshState)
    expect(merged.find((s) => s.session.facilityId === 2)!.userResponse).toBe('not_interested')
    expect(merged.find((s) => s.session.facilityId === 1)!.userResponse).toBeNull()
  })
})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npm test -- --run tests/state.test.ts`
Expected: new tests FAIL (same-rink updates clobber the other rink, updateUserResponse has no 6th param).

- [ ] **Step 3: Implement in `src/state.ts`**

3a. Import:

```ts
import { sessionMatches } from './session-identity.js'
```

3b. `updateRegistrationStatus` — add trailing `facilityId?: number` param, replace the predicate:

```ts
export function updateRegistrationStatus(
  state: SessionState[],
  date: string,
  time: string,
  isRegistered: boolean,
  facilityId?: number
): SessionState[] {
  return state.map((s) => {
    if (sessionMatches({ date, time, facilityId }, s.session)) {
```

3c. `updateSessionState` — replace the findIndex predicate:

```ts
  const existingIndex = state.findIndex((s) => sessionMatches(session, s.session))
```

3d. `updateUserResponse` — add trailing `facilityId?: number` param, replace the predicate:

```ts
export function updateUserResponse(
  state: SessionState[],
  date: string,
  time: string,
  userResponse: UserResponse,
  remindIntervalHours: number,
  facilityId?: number
): SessionState[] {
  const now = new Date()
  return state.map((s) => {
    if (sessionMatches({ date, time, facilityId }, s.session)) {
```

3e. `mergeUserResponses` — replace the find predicate:

```ts
    const fresh = freshState.find((s) => sessionMatches(entry.session, s.session))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm test -- --run tests/state.test.ts`
Expected: PASS (all pre-existing + 5 new)

- [ ] **Step 5: Commit**

```bash
git add src/state.ts tests/state.test.ts
git commit -m "feat: facility-aware session matching in state layer"
```

---

### Task 5: Evaluator — morning gate, facility URLs, location in messages

**Files:**
- Modify: `src/evaluator.ts`
- Test: `tests/evaluator.test.ts`

**Interfaces:**
- Consumes: `Config.alertMorningsOnly` (Task 3), `Session.facilityId/location` (Task 2), `sessionMatches` (Task 1).
- Produces: `buildRegistrationUrl(date, company, facilityId?)` (module-private; behavior visible via `Alert.registrationUrl`). Alert messages contain ` @ ${location}` when location present.

- [ ] **Step 1: Update the test config fixture**

In `tests/evaluator.test.ts`, add to `defaultConfig` (after `morningPickupMaxHour: 9`):

```ts
    alertMorningsOnly: false,
    facilityLabels: { 1: 'XIC', 2: 'PIH' },
```

`alertMorningsOnly: false` preserves the semantics of every pre-existing test (they use non-morning default time `18:30`). Gate-specific tests below opt in with `true`.

- [ ] **Step 2: Write the failing tests**

Append inside the top-level `describe('evaluator', ...)`:

```ts
  describe('morning-only gate (alertMorningsOnly)', () => {
    const gatedConfig: Config = {
      ...defaultConfig,
      alertMorningsOnly: true,
      morningPickupMaxHour: 8,
    }

    it('suppresses ALL alert types for sessions starting at/after the cutoff', () => {
      // 11:30 PIH session transitioning to full would normally fire SOLD_OUT
      const session = createSession({ time: '11:30', isFull: true, facilityId: 2 })
      const prev = createState(createSession({ time: '11:30', isFull: false, facilityId: 2 }))

      const alerts = evaluate([session], [prev], gatedConfig)
      expect(alerts).toHaveLength(0)
    })

    it('fires for sessions starting before the cutoff (7:59 boundary)', () => {
      const session = createSession({ time: '07:59', playersRegistered: 10, goaliesRegistered: 1 })
      const alerts = evaluate([session], [createState(session)], gatedConfig)
      expect(alerts).toHaveLength(1)
    })

    it('suppresses at exactly the cutoff hour (08:00)', () => {
      const session = createSession({ time: '08:00', playersRegistered: 10, goaliesRegistered: 1 })
      const alerts = evaluate([session], [createState(session)], gatedConfig)
      expect(alerts).toHaveLength(0)
    })

    it('gate off (alertMorningsOnly false) restores legacy behavior', () => {
      const session = createSession({ time: '11:30', playersRegistered: 10, goaliesRegistered: 1 })
      const alerts = evaluate([session], [createState(session)], defaultConfig)
      expect(alerts).toHaveLength(1)
    })
  })

  describe('facility-aware alerts', () => {
    it('uses the session facilityId in the registration URL', () => {
      const session = createSession({
        playersRegistered: 10,
        goaliesRegistered: 1,
        facilityId: 2,
        location: 'PIH',
      })
      const alerts = evaluate([session], [createState(session)], defaultConfig)

      expect(alerts).toHaveLength(1)
      expect(alerts[0].registrationUrl).toContain('facility_ids=2')
    })

    it('falls back to facility_ids=1 when facilityId is missing', () => {
      const session = createSession({ playersRegistered: 10, goaliesRegistered: 1 })
      const alerts = evaluate([session], [createState(session)], defaultConfig)
      expect(alerts[0].registrationUrl).toContain('facility_ids=1')
    })

    it('includes the location label in the alert message', () => {
      const session = createSession({
        playersRegistered: 10,
        goaliesRegistered: 1,
        facilityId: 2,
        location: 'PIH',
      })
      const alerts = evaluate([session], [createState(session)], defaultConfig)
      expect(alerts[0].message).toContain('@ PIH')
    })

    it('matches previous state facility-aware (same time, different rink = different session)', () => {
      const xic = createSession({ time: '06:00', facilityId: 1, location: 'XIC' })
      const pihPrev = createState(
        createSession({ time: '06:00', facilityId: 2, location: 'PIH', isFull: true })
      )

      // XIC session is unseen (only PIH tracked at this slot) and it's a
      // morning session -> MORNING_PICKUP, NOT a NEWLY_AVAILABLE downgrade
      // from PIH's full->open transition.
      const alerts = evaluate([xic], [pihPrev], defaultConfig)
      expect(alerts).toHaveLength(1)
      expect(alerts[0].type).toBe('MORNING_PICKUP')
    })
  })
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `npm test -- --run tests/evaluator.test.ts`
Expected: new tests FAIL; pre-existing tests PASS.

- [ ] **Step 4: Implement in `src/evaluator.ts`**

4a. Import:

```ts
import { sessionMatches } from './session-identity.js'
```

4b. In `evaluate()`, insert the gate directly after the past-session skip block:

```ts
    // Morning gate: post-merger the mission is early-morning pickup at either
    // rink. Non-morning sessions stay tracked in state (visibility via
    // /sessions) but never alert — any type, including SOLD_OUT.
    if (config.alertMorningsOnly && !isMorningPickup(session, config)) {
      continue
    }
```

4c. Replace `findPreviousState`'s predicate:

```ts
function findPreviousState(
  session: Session,
  previousState: SessionState[]
): SessionState | undefined {
  return previousState.find((state) => sessionMatches(session, state.session))
}
```

4d. In `createAlert`, add the location suffix and thread facility into the URL. Add as the first lines of the function:

```ts
  const spotsRemaining = session.playersMax - session.playersRegistered
  const where = session.location ? ` @ ${session.location}` : ''
```

then append `${where}` to the first line of EVERY message template, immediately after `${formatTime(session.time)}`, e.g.:

```ts
    OPPORTUNITY: `🏒 OPPORTUNITY: ${session.dayOfWeek} ${formatDate(session.date)}, ${formatTime(session.time)}${where}\nPlayers: ...`,
```

(same insertion point for FILLING_FAST, SOLD_OUT, NEWLY_AVAILABLE, MORNING_PICKUP), and change the return:

```ts
    registrationUrl: buildRegistrationUrl(session.date, company, session.facilityId),
```

4e. Update `buildRegistrationUrl`:

```ts
function buildRegistrationUrl(
  date: string,
  company: string = 'charlotteice',
  facilityId?: number
): string {
  return `https://apps.daysmartrecreation.com/dash/x/#/online/${company}/event-registration?date=${date}&facility_ids=${facilityId ?? 1}`
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `npm test -- --run tests/evaluator.test.ts`
Expected: PASS (all pre-existing + 8 new)

- [ ] **Step 6: Commit**

```bash
git add src/evaluator.ts tests/evaluator.test.ts
git commit -m "feat: morning-only alert gate + facility-aware URLs and messages"
```

---

### Task 6: Interactions — facility in button values

**Files:**
- Modify: `src/interactions/actions.ts`
- Test: `tests/interactions/actions.test.ts` (append)

**Interfaces:**
- Consumes: `sessionMatches` (Task 1), `updateUserResponse` 6-arg form (Task 4).
- Produces: `SessionIdentity` gains `facilityId?: number`. `parseActionValue` accepts BOTH `{date}|{time}|{facilityId}|{eventName}` (new) and `{date}|{time}|{eventName}` (legacy buttons already in Slack history).

- [ ] **Step 1: Write the failing tests**

Append to `tests/interactions/actions.test.ts`:

```ts
describe('facility-aware action values', () => {
  it('parses the new 4-part value {date}|{time}|{facilityId}|{eventName}', () => {
    const result = parseActionValue('2026-08-05|06:00|2|PIH Adult Pickup Skater')
    expect(result).toEqual({
      date: '2026-08-05',
      time: '06:00',
      facilityId: 2,
      eventName: 'PIH Adult Pickup Skater',
    })
  })

  it('still parses legacy 3-part values (no facilityId)', () => {
    const result = parseActionValue('2026-08-05|06:00|(PLAYERS) Adult Pick Up')
    expect(result).toEqual({
      date: '2026-08-05',
      time: '06:00',
      eventName: '(PLAYERS) Adult Pick Up',
    })
  })

  it('treats a non-numeric 3rd part of a 4-part value as legacy eventName containing a pipe', () => {
    const result = parseActionValue('2026-08-05|06:00|Team|Name')
    expect(result).toEqual({
      date: '2026-08-05',
      time: '06:00',
      eventName: 'Team|Name',
    })
  })
})
```

Also add a `processInteraction` test following the file's existing temp-statePath pattern: seed state with two entries — same date+time, `facilityId: 1` and `facilityId: 2` (reuse the session shape from the file's existing fixtures, adding `facilityId`) — dispatch a `session_not_interested` action whose value is `{date}|{time}|2|PIH Adult Pickup Skater`, then assert only the `facilityId: 2` entry has `userResponse === 'not_interested'` and the result has `found: true`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `npm test -- --run tests/interactions/actions.test.ts`
Expected: FAIL — 4-part value parses `facilityId` into eventName; both entries or wrong entry updated.

- [ ] **Step 3: Implement in `src/interactions/actions.ts`**

3a. Import `sessionMatches`:

```ts
import { sessionMatches } from '../session-identity.js'
```

3b. Extend the interface:

```ts
export interface SessionIdentity {
  date: string
  time: string
  facilityId?: number
  eventName: string
}
```

3c. Replace `parseActionValue`:

```ts
/**
 * Parse the pipe-delimited session identity from a button value.
 * New format: {date}|{time}|{facilityId}|{eventName}
 * Legacy format (buttons sent before facility awareness): {date}|{time}|{eventName}
 * Detect new format by a purely numeric 3rd part with >= 4 segments.
 */
export function parseActionValue(value: string): SessionIdentity | null {
  const parts = value.split('|')
  if (parts.length < 3) return null

  if (parts.length >= 4 && /^\d+$/.test(parts[2])) {
    const [date, time, facilityStr, ...rest] = parts
    const eventName = rest.join('|')
    if (!date || !time || !eventName) return null
    return { date, time, facilityId: parseInt(facilityStr, 10), eventName }
  }

  const [date, time, ...rest] = parts
  const eventName = rest.join('|')
  if (!date || !time || !eventName) return null
  return { date, time, eventName }
}
```

3d. In `processInteraction`, replace the `found` predicate and thread facility:

```ts
  const found = state.some((s) => sessionMatches(sessionId, s.session))

  if (found) {
    const updatedState = updateUserResponse(
      state,
      sessionId.date,
      sessionId.time,
      userResponse,
      remindIntervalHours,
      sessionId.facilityId
    )
    saveState(statePath, updatedState)
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm test -- --run tests/interactions/actions.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/interactions/actions.ts tests/interactions/actions.test.ts
git commit -m "feat: facility-aware Slack button values with legacy fallback"
```

---

### Task 7: Slack notifier + /sessions command — location display

**Files:**
- Modify: `src/notifiers/slack.ts`, `src/commands/sessions.ts`
- Test: `tests/notifiers/slack.test.ts`, `tests/commands/sessions.test.ts` (append)

**Interfaces:**
- Consumes: `Session.facilityId/location/rinkName` (Task 2), 4-part value format (Task 6 — value built here must match what Task 6 parses).
- Produces: Slack header `${emoji} ${TYPE} — ${location}`; body `*Where:* ${location} (${rinkName})` line; button value `{date}|{time}|{facilityId ?? 0}|{eventName}`. `/sessions` blocks show ` @ *${location}*` and per-facility registration links.

Note: `src/notifiers/console.ts` needs NO change — it prints `alert.message`, which already carries `@ ${location}` from Task 5.

- [ ] **Step 1: Write the failing tests**

Append to `tests/notifiers/slack.test.ts` (follow its existing pattern — it mocks `fetch` and inspects the JSON payload; reuse its alert/session factory, adding `facilityId: 2, location: 'PIH', rinkName: 'Pineville Rink'` overrides):

```ts
describe('location display (XIC/PIH merger)', () => {
  it('includes location in the header', async () => {
    // build an OPPORTUNITY alert whose session has location 'PIH'
    // send it, capture payload
    const header = payload.blocks[0]
    expect(header.text.text).toBe('🏒 OPPORTUNITY — PIH')
  })

  it('includes a Where line with rink name', async () => {
    const section = payload.blocks[1]
    expect(section.text.text).toContain('*Where:* PIH (Pineville Rink)')
  })

  it('omits location suffix when session has none (legacy)', async () => {
    // alert whose session lacks location
    expect(header.text.text).toBe('🏒 OPPORTUNITY')
    expect(section.text.text).not.toContain('*Where:*')
  })

  it('embeds facilityId in button values', async () => {
    const actions = payload.blocks.find((b) => b.type === 'actions')
    expect(actions.elements[1].value).toBe(
      '2026-08-05|06:00|2|PIH Adult Pickup Skater'
    )
  })
})
```

(Adapt the skeleton above to the file's real capture mechanism — assertions and expected strings are exact, harness code follows the file's existing style.)

Append to `tests/commands/sessions.test.ts`:

```ts
describe('location display', () => {
  it('shows the location label and per-facility register link', () => {
    // build a state entry whose session has facilityId 2, location 'PIH'
    const response = buildSessionsResponse(state, null, 'charlotteice')
    const text = JSON.stringify(response.blocks)
    expect(text).toContain('@ *PIH*')
    expect(text).toContain('facility_ids=2')
  })

  it('falls back to facility_ids=1 for legacy entries without facilityId', () => {
    const response = buildSessionsResponse(legacyState, null, 'charlotteice')
    expect(JSON.stringify(response.blocks)).toContain('facility_ids=1')
  })
})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npm test -- --run tests/notifiers/slack.test.ts tests/commands/sessions.test.ts`
Expected: new tests FAIL.

- [ ] **Step 3: Implement in `src/notifiers/slack.ts`**

3a. Header (in `buildPayload`):

```ts
          text: `${emoji} ${alert.type.replace('_', ' ')}${alert.session.location ? ` — ${alert.session.location}` : ''}`,
```

3b. Button value (in `buildPayload`):

```ts
      const sessionValue = `${alert.session.date}|${alert.session.time}|${alert.session.facilityId ?? 0}|${alert.session.eventName}`
```

3c. Where line (in `formatMessage`) — replace the opening line construction:

```ts
    let message = `*${session.dayOfWeek}, ${this.formatDate(session.date)}* at *${this.formatTime(session.time)}*\n`
    if (session.location) {
      message += `*Where:* ${session.location}${session.rinkName ? ` (${session.rinkName})` : ''}\n`
    }
    message += '\n'
```

- [ ] **Step 4: Implement in `src/commands/sessions.ts`**

In `formatSessionBlock`:

```ts
  const regUrl = `https://apps.daysmartrecreation.com/dash/x/#/online/${company}/event-registration?date=${session.date}&facility_ids=${session.facilityId ?? 1}`

  let text = `*${session.dayOfWeek}, ${formatDate(session.date)}* at *${formatTime(session.time)}*${session.location ? ` @ *${session.location}*` : ''}\n`
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `npm test -- --run tests/notifiers/slack.test.ts tests/commands/sessions.test.ts`
Expected: PASS. Also run `npm test -- --run tests/notifiers/slack-integration.test.ts tests/interactions/handler.test.ts` — if either asserts on 3-part button values or header text, update those assertions to the new format.

- [ ] **Step 6: Commit**

```bash
git add src/notifiers/slack.ts src/commands/sessions.ts tests/notifiers/ tests/commands/
git commit -m "feat: show rink location in Slack alerts and /sessions"
```

---

### Task 8: Scraper — all days + label threading

**Files:**
- Modify: `src/scraper.ts`
- Test: `tests/scraper.test.ts`

**Interfaces:**
- Consumes: `parseEvents(response, facilityLabels)` (Task 2).
- Produces: `calculateTargetDates(today?, forwardDays?)` returns EVERY date in the window. `isMonWedFri` is DELETED. `scrapeEvents(today?, forwardDays?, company?, facilityLabels?)` gains optional 4th param passed to `parseEvents`.

- [ ] **Step 1: Update tests**

In `tests/scraper.test.ts`:
- Delete the entire `describe('isMonWedFri', ...)` block and remove `isMonWedFri` from the import.
- Replace `calculateTargetDates` expectations: for a window of N forward days the function now returns N+1 consecutive dates (today inclusive). Example new test:

```ts
  describe('calculateTargetDates', () => {
    it('returns every date in the forward window, all days of week', () => {
      const monday = new Date('2026-07-13T12:00:00Z')
      const dates = calculateTargetDates(monday, 5)
      expect(dates).toEqual([
        '2026-07-13',
        '2026-07-14',
        '2026-07-15',
        '2026-07-16',
        '2026-07-17',
        '2026-07-18',
      ])
    })
  })
```

(Keep any existing calculateTargetDates edge-case tests, updated to expect all days rather than Mon/Wed/Fri subsets.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `npm test -- --run tests/scraper.test.ts`
Expected: FAIL — Mon/Wed/Fri filtering still active.

- [ ] **Step 3: Implement in `src/scraper.ts`**

3a. Delete the `isMonWedFri` function entirely.

3b. Replace `calculateTargetDates`:

```ts
/**
 * Calculate target dates (every day) within forward window from today.
 * Post-merger, PIH runs pickup on days XIC never did (e.g. Tuesdays), so the
 * scraper covers all days; the evaluator's morning gate controls alert volume.
 */
export function calculateTargetDates(today: Date = new Date(), forwardDays: number = 5): string[] {
  const dates: string[] = []
  const endDate = new Date(today)
  endDate.setDate(endDate.getDate() + forwardDays)

  const current = new Date(today)
  while (current <= endDate) {
    dates.push(current.toISOString().split('T')[0])
    current.setDate(current.getDate() + 1)
  }

  return dates
}
```

3c. Update `scrapeEvents` signature and the final parse call (update its doc comment too — it says "Mon/Wed/Fri"):

```ts
export async function scrapeEvents(
  today: Date = new Date(),
  forwardDays: number = 5,
  company: string = DEFAULT_COMPANY,
  facilityLabels?: Record<number, string>
): Promise<Session[]> {
```

```ts
  // Step 5: Parse events into sessions
  return parseEvents(eventsData, facilityLabels)
```

(`parseEvents` defaults its second param when `facilityLabels` is undefined — passing `undefined` through is fine. If TypeScript complains about `exactOptionalPropertyTypes`, call it as `facilityLabels === undefined ? parseEvents(eventsData) : parseEvents(eventsData, facilityLabels)` — but plain pass-through should compile.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm test -- --run tests/scraper.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/scraper.ts tests/scraper.test.ts
git commit -m "feat: scrape all days of week (PIH runs pickup beyond Mon/Wed/Fri)"
```

---

### Task 9: Poll pipeline threading (`index.ts`)

**Files:**
- Modify: `src/index.ts`
- Test: `tests/index.test.ts` (verify/adjust)

**Interfaces:**
- Consumes: `sessionKey` (Task 1), `scrapeEvents` 4-arg form (Task 8), `config.facilityLabels` (Task 3).

- [ ] **Step 1: Implement in `src/index.ts`**

1a. Import:

```ts
import { sessionKey } from './session-identity.js'
```

1b. Thread labels into the scrape (Step 1 of `poll`):

```ts
    sessions = await scrapeEvents(
      new Date(),
      config.forwardWindowDays,
      config.company,
      config.facilityLabels
    )
```

1c. Replace both alerted-session key sites (Step 5 of `poll`):

```ts
    const alertedSessions = new Map(
      alerts.map((a) => [sessionKey(a.session), { type: a.type, at: new Date().toISOString() }])
    )

    for (const session of sessions) {
      const alertInfo = alertedSessions.get(sessionKey(session))

      state = updateSessionState(state, session, alertInfo?.type || null, alertInfo?.at || null)
    }
```

- [ ] **Step 2: Run the index tests**

Run: `npm test -- --run tests/index.test.ts`
Expected: PASS. If any test stubs `scrapeEvents` and asserts its call args, add the 4th argument (`config.facilityLabels` / `expect.any(Object)`). If any test's config fixture lacks the new fields and a failure results, add `alertMorningsOnly: false, facilityLabels: { 1: 'XIC', 2: 'PIH' }` to that fixture.

- [ ] **Step 3: Commit**

```bash
git add src/index.ts tests/index.test.ts
git commit -m "feat: thread facility labels + facility-aware keys through poll cycle"
```

---

### Task 10: Env docs + full verification

**Files:**
- Modify: `.env.example` (if the file doesn't exist, skip 1a — do NOT create it)
- Modify: `docs/SPEC.md` (only if it documents alert rules/env vars — keep the edit surgical)

- [ ] **Step 1: Document new env vars**

1a. Append to `.env.example`:

```bash
# Only alert on early-morning sessions (start hour < MORNING_PICKUP_MAX_HOUR).
# Non-morning sessions stay visible in /sessions but never alert.
ALERT_MORNINGS_ONLY=true

# Morning cutoff hour (24h). Default 8 = sessions starting before 8:00am alert.
MORNING_PICKUP_MAX_HOUR=8

# Display labels for DASH facility IDs (XIC = Extreme Ice/Charlotte Ice, PIH = Pineville Ice House)
FACILITY_LABELS=1:XIC,2:PIH
```

1b. If `docs/SPEC.md` has an env-var or alert-rules section, add the three vars above and one line describing the morning gate. Otherwise skip.

- [ ] **Step 2: Full quality gate**

Run: `npm run check`
Expected: typecheck PASS, lint PASS, format:check PASS, ALL tests PASS. Fix anything red before committing (run `npm run format` for formatting failures).

- [ ] **Step 3: Manual smoke test against live DASH (read-only)**

```bash
npm run build
node -e "
import('./dist/scraper.js').then(async (m) => {
  const sessions = await m.scrapeEvents(new Date(), 5, 'charlotteice')
  console.log(JSON.stringify(sessions, null, 2))
})
"
```

Expected: sessions from BOTH facilities across all days in the window, each with `facilityId`, `location` ('XIC'/'PIH'), `rinkName`. PIH Tuesday sessions present if within window. No duplicates, no merged cross-rink sessions.

- [ ] **Step 4: Commit**

```bash
git add .env.example docs/SPEC.md
git commit -m "docs: document ALERT_MORNINGS_ONLY, MORNING_PICKUP_MAX_HOUR, FACILITY_LABELS"
```

- [ ] **Step 5: Push the branch**

```bash
git push -u origin feat/morning-only-alerts-and-location
```

---

### Task 11: Deploy (GATED — requires explicit user approval first)

Do NOT execute this task until the user has approved workstream (1) completion. Deployment steps for reference (from Session 10 handoff):

```bash
# as the app user (root has no pm2):
ssh -o User=adulthockey adult-hockey-agent
cd ~/adult-hockey-agent
git pull origin main        # after PR merge to main
npm install
npm run build
pm2 restart adult-hockey-agent
pm2 logs adult-hockey-agent --lines 50   # watch first poll: expect location-tagged alerts, no canary
```

No env changes required on the droplet — all three new vars have correct defaults. Optional: set `ALERT_MORNINGS_ONLY=false` later to widen alerts without a deploy.

---

## Self-Review Notes

- Spec coverage: parser/facility (Task 2), morning gate + URLs + messages (Task 5), Slack + /sessions display (Task 7), all-days scraper (Task 8), config (Task 3), state matching + legacy fallback (Tasks 1/4/6), fixtures + collision regression (Task 2), env docs (Task 10). Canary: no change required (spec §4) — verified `src/health.ts` is untouched by design.
- Type consistency: `SessionRef` uses optional `facilityId?: number` everywhere; `sessionKey`/`sessionMatches` names consistent across Tasks 1, 2, 4, 5, 6, 9. `parseEvents(response, facilityLabels?)` matches Tasks 2, 3 (import), 8 (call).
- Known accepted risk: a legacy 3-part button value at a slot where BOTH rinks have a session matches the first entry (ambiguous). Transient — only affects buttons sent pre-deploy.
