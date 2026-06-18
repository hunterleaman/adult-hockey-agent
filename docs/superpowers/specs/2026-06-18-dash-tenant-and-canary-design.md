# DASH Tenant Migration Fix + Canary — Design (2026-06-18)

## Plain-language summary (the "canary")

Coal miners used to carry a canary bird underground. The bird reacted to bad air
long before people did, so a silent bird meant "danger — get out." It was an
early-warning system.

This agent has now gone silently blind **twice**: once when DASH renamed teams
(Session 9) and now because the rink rebranded Extreme Ice → Charlotte Ice and
moved to a new DASH tenant (`charlotteice`) while we kept polling the old, empty
one (`extremeice`). Both times the process looked healthy (`/health` OK, polling
on schedule) but produced **zero useful alerts for weeks**.

The **canary** is a small watchdog that asks every poll: *"Did I find real pickup
sessions with real sign-up numbers?"* If the answer is "no" for N polls in a row
(default 3 ≈ 3 hours), it sends one Slack warning so the next outage is caught in
hours, not weeks.

## Problem

- Production polls `company=extremeice` (hardcoded `src/scraper.ts`). That tenant
  is now a **stale mirror**: it omits the 6 AM Wed/Fri morning pickup entirely and
  reports `registered_count = 0` for everything.
- The live tenant `charlotteice` has the full catalog with real counts (verified
  via curl replay and the compiled scraper: Fri 6/19 06:10 shows players 19/22,
  goalies 3/3).
- The same wrong slug is also in the alert "Register" links (`evaluator.ts`,
  `commands/sessions.ts`).
- This corrects the `dash-pickup-state` memory, which wrongly concluded
  "registered_count is dead" and "6 AM pickup gone for summer" — both were
  artifacts of reading the wrong tenant.

## Design

### 1. Tenant fix + config (P0/P1)
- New config value `company` (env `DASH_COMPANY`, default `charlotteice`),
  validated non-empty in `validateConfig`.
- Threaded into `scrapeEvents(today, forwardDays, company)` and into the two
  registration-URL builders (`evaluator.ts`, `commands/sessions.ts` via the
  command handler deps and server options).

### 2. Canary (P1)
- New isolated module `src/health.ts` + a separate `data/health.json` (keeps the
  `SessionState[]` file shape untouched).
- Pure `evaluateHealth(sessionCount, hasRegistrations, prev, thresholdPolls,
  nowIso)`. A poll is **healthy** when `sessionCount > 0` AND at least one session
  has `playersRegistered > 0`. This catches both failure modes: 0 sessions
  (parser break) and all-zero counts (stale tenant).
- Fires once on crossing `CANARY_THRESHOLD_POLLS` (env, default 3), suppresses
  until a healthy poll recovers it (one recovery message).
- Notifiers gain `sendDiagnostic(text)` (session-less, no buttons) so `Alert`
  stays session-shaped.
- `poll()` refactored so the canary runs even when a scrape throws (hard API
  failures also count as suspect polls).

## What fires on first poll after deploy
MORNING_PICKUP for the returning 6:10 AM sessions (no prior state); the now-visible
full 11:30 session stays silent (SOLD_OUT needs a not-full→full transition). No
alert flood. Canary stays quiet (healthy data present).

## Testing
- TDD: `tests/health.test.ts` (6 cases: healthy reset, all-zero suspect, zero
  sessions, fire-once-at-threshold, recovery-once, custom threshold).
- `config.test.ts`: defaults + env override + validation for `company` /
  `canaryThresholdPolls`.
- Updated slug assertions in `scraper.test.ts` and `slack-integration.test.ts`.
- Full suite: 283 pass; the 19 `evaluator.test.ts` failures are pre-existing
  date-brittle tests (out of scope this session).

## Out of scope (scoped out by user)
Re-tuning threshold alerts, fixing the 19 date-brittle evaluator tests, broader
weekday (Tue/Thu) coverage for the 11:30 sessions.
