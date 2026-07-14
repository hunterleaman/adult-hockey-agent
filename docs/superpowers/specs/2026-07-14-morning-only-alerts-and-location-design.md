# Design: Morning-Only Alerts + Location Awareness (XIC/PIH Merger)

**Date:** 2026-07-14
**Status:** Draft — pending user approval
**Workstream:** (1) of 2 — reduce Slack alert volume + clarify location after XIC/PIH merger

## Problem

Extreme Ice Center (XIC, Charlotte Ice) and Pineville Ice House (PIH) merged under the
single DASH tenant `charlotteice`. The agent now emits alerts for both rinks' pickup
sessions with no location context, and message volume has roughly doubled.

User clarification during brainstorming: the mission is not "XIC vs PIH" — it is
**early-morning (~6am) pickup hockey at either rink**. Location must be *visible*
(which rink to drive to), not *filtered*.

## Live API facts (verified by curl replay 2026-07-14)

- Both rinks share tenant `charlotteice`.
- Step-1 `date-availabilities` includes a `locations[]` array parallel to `events[]`.
- Step-2 events: the `resource` relationship (already in our `include=`) resolves to
  `attributes.facility_id` (1 = XIC, 2 = PIH) and `attributes.name`
  (`MAIN RINK` / `TRAINING RINK` = XIC; `Pineville Rink` = PIH).
- Current pickup inventory:
  - XIC 6:10am mornings — `(PLAYERS)/(GOALIES) Adult Pick Up Hockey (Mornings)`, MAIN RINK
  - XIC 12:00pm — `(PLAYERS)/(GOALIES) ADULT Pickup -AFTERNOON/EVENING`, TRAINING RINK
  - PIH 11:30am — `PIH Adult Pickup Skater` / `PIH Adult Pickup Goalie`, Pineville Rink
  - PIH also runs Tuesday pickup — invisible today because the scraper is Mon/Wed/Fri-only.

## Latent bugs found (fixed by this design)

1. **Cross-rink session merge**: parser pairs skater/goalie events by `date:time` key
   (`parser.ts:126`). Two rinks at the same time slot would merge into one corrupt
   session. Same flaw in evaluator state matching (`evaluator.ts:127`).
2. **Wrong registration deep link**: `facility_ids=1` hardcoded (`evaluator.ts:215`) —
   PIH alerts link to XIC's registration page.
3. **No location in output**: `Session` and all notifier messages lack any rink identity.

## Decisions (user-confirmed)

| Decision | Choice |
|---|---|
| Locations | Both rinks, no per-rink toggle |
| Alert rule | Early-morning sessions only, either rink |
| Morning cutoff | Start hour **< 8am** |
| Scraper day coverage | **All 7 days** (was Mon/Wed/Fri) |
| Approach | A — evaluator-gate + location threading, legacy-state fallback |
| Revert path | `ALERT_MORNINGS_ONLY` env flag, default `true` |

Rejected alternatives: (B) filter at parser/scraper — blinds `/sessions` and state
history; (C) per-rink preference engine + digest — YAGNI once the morning gate
collapses volume (mornings are rare → ~0-2 msgs/day).

## Design

### 1. Data model (`parser.ts`)

`Session` gains two fields:

```ts
facilityId: number   // from resource relationship; 0 if unresolvable
location: string     // display label: 'XIC' | 'PIH' | resource-name fallback
```

- Resolve `event.relationships.resource.data.id` → `included[]` where
  `type="resources"` → `attributes.facility_id` + `attributes.name`.
- Label from config map (default `{1: 'XIC', 2: 'PIH'}`); unmapped facility →
  resource name → `Facility ${id}`. IDs drive logic, names are display-only
  (Session 9/10 lesson: never key logic on human-facing strings).
- Session pairing key changes `date:time` → `date:time:facilityId` (fixes bug 1).
- Missing resource relationship → `facilityId: 0`, session kept (degrade, don't
  silently drop — Session 9 lesson).

### 2. Evaluator (`evaluator.ts`)

- New gate immediately after the past-session skip:
  `if (config.alertMorningsOnly && startHour >= config.morningPickupMaxHour) continue`.
  Session still lands in state (history + `/sessions` visibility preserved).
- Gate sits **above** SOLD_OUT/NEWLY_AVAILABLE — non-morning sessions are fully
  silent across all five alert types.
- `findPreviousState`: match `date + time + facilityId`, with legacy fallback —
  a state entry lacking `facilityId` matches on `date + time` alone. One poll after
  deploy, state rewrites with facility and the fallback goes dormant. Prevents a
  one-time MORNING_PICKUP re-fire for already-known sessions.
- `buildRegistrationUrl(date, company, facilityId)` → `facility_ids=${facilityId || 1}`
  (fixes bug 2).
- Plain-text alert messages gain location:
  `🌅 MORNING PICKUP: Wednesday Jul 15, 6:10am @ XIC`.

### 3. Notifiers (`notifiers/slack.ts`, `notifiers/console.ts`, `commands/sessions.ts`)

- Slack header: `🌅 MORNING PICKUP — XIC`.
- Slack body adds `*Where:* XIC (Main Rink)` line.
- Button `sessionValue` gains facility: `date|time|facilityId|eventName`.
  Interactions handler parses tolerantly — legacy 3-part values still work.
- `/sessions` slash command shows **all** sessions (morning or not) with a location
  column — the "what else is on" view lives here, not in alerts.

### 4. Scraper + config (`scraper.ts`, `config.ts`)

- `calculateTargetDates`: every day in the forward window (`isMonWedFri` deleted).
- Config changes:
  - `morningPickupMaxHour` default 9 → **8**
  - new `alertMorningsOnly` (env `ALERT_MORNINGS_ONLY`, default `true`)
  - new `facilityLabels` (env `FACILITY_LABELS=1:XIC,2:PIH`)
- Canary untouched — PIH sessions with real counts keep it green, correctly:
  the agent isn't blind, there's just nothing morning-worthy to say.

### 5. Error handling

- Unparseable `FACILITY_LABELS` → startup validation error (fail fast, matches
  existing `validateConfig` style).
- Resource lookup miss → `facilityId 0`, label fallback, registration URL falls
  back to `facility_ids=1`.

### 6. Testing (TDD, fixture-based per CLAUDE.md)

- New fixture captured from today's live payload — real PIH + XIC events including
  same-day multi-rink pickup.
- Parser: facility extraction, label fallback chain, **cross-rink same-time
  no-merge** regression test.
- Evaluator: morning gate on/off, 7:59 vs 8:00 boundary, legacy-state fallback
  match, PIH alert URL gets `facility_ids=2`.
- Slack: location in header/body, 4-part button value, legacy 3-part parse.

## Expected outcome

With today's schedule: only XIC Wed/Fri 6:10am sessions alert. PIH 11:30 and
XIC noon go silent unless either rink adds a sub-8am session — which then alerts
automatically, any day of the week, correctly labeled and correctly deep-linked.
Volume drops below pre-merger levels.

## Out of scope

- Per-rink enable/disable toggles, slash-command preferences, digest batching
  (all unnecessary once the morning gate lands; revisit if mission changes).
- Workstream (2): `.claude/` tooling upgrade from claude-project-template —
  separate effort, requires separate user approval to begin.
