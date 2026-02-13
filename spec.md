# Adult Hockey Agent: Spec

## Overview

Monitoring agent that polls the DaySmart DASH webapp to track adult pick-up hockey registration at Extreme Ice Center (Indian Trail, NC). Sends notifications when sessions meet criteria. Designed for future extension to league standings, stats, and scheduling. Phase 2 adds auto-registration with human approval.

## Target URL

```
https://apps.daysmartrecreation.com/dash/x/#/online/extremeice/event-registration?date={YYYY-MM-DD}&facility_ids=1
```

## Phase 1: Monitor + Alert

### What It Does

1. Polls DASH event page for Mon/Wed/Fri sessions within a configurable forward window (default: 5 days)
2. Parses registration counts for both PLAYERS and GOALIES entries per session
3. Evaluates alert rules against parsed data
4. Sends notifications via pluggable notification modules
5. Tracks state to suppress duplicate alerts
6. Tracks user registrations via manual flag (Slack command or API)

### Sessions of Interest

- Event type: Any event whose name contains "ADULT Pick Up" (hockey only, not Broomball)
- Days: Monday, Wednesday, Friday
- All time slots discovered on those days (do NOT hardcode specific times)
- Player entries identified by: name contains "(PLAYERS)" AND "ADULT Pick Up"
- Goalie entries identified by: name contains "(GOALIES)" AND "Adult Pick Up"
- Sessions are paired: each time slot has a PLAYERS entry and a corresponding GOALIES entry
- Handle edge cases: holidays, special events, or schedule changes may alter available sessions

### Alert Rules

**OPPORTUNITY (primary)**

- `goalies_registered >= 2 AND player_spots_remaining <= 10`
- Purpose: Session is worth attending (enough goalies) and filling up

**FILLING_FAST (urgency)**

- `player_spots_remaining <= 4`
- Purpose: Act now regardless of goalie count
- Triggers accelerated polling (30-min interval)

**SOLD_OUT (informational)**

- Session transitioned from available to full since last poll
- Always fires even if previously alerted for other conditions

**NEWLY_AVAILABLE (recovery)**

- Session was previously full, now has spots (cancellation)
- Re-evaluate OPPORTUNITY and FILLING_FAST rules

### Alert Suppression

- OPPORTUNITY: Don't re-alert for same session unless spots decreased by >= 2 since last alert
- FILLING_FAST: Alert once per session, then only if spots decrease further
- SOLD_OUT: Always alert (once per transition)
- NEWLY_AVAILABLE: Always alert (once per transition)

### Polling Schedule

- Default interval: 60 minutes
- Accelerated interval: 30 minutes (when any tracked session has <= 4 player spots)
- Active hours: 0600-2300 ET
- Configurable via environment variables

### Registration Tracking (v1: Manual)

- User marks sessions as "registered" via Slack command or HTTP API
- Format: `POST /register { "date": "2026-02-18", "time": "06:00" }`
- Or Slack: `/hockey registered 2026-02-18 06:00`
- Agent excludes registered sessions from OPPORTUNITY and FILLING_FAST alerts
- SOLD_OUT alerts still fire for registered sessions (confirmation that you got in)

### Notification Modules (implement in order)

1. **Console** - stdout logging, always active
2. **Slack webhook** - primary notification channel
3. **Email** - via Resend or SendGrid (free tier)
4. **SMS** - via Twilio (~$0.01/msg)
5. **Push** - via Pushover ($5 one-time)

Each module implements a common interface:

```typescript
interface Notifier {
  name: string
  send(alert: Alert): Promise<void>
  isConfigured(): boolean
}
```

### Notification Content

```
🏒 OPPORTUNITY: Friday Feb 20, 6:00am
Players: 14/24 (10 spots left)
Goalies: 2/3
Status: Worth signing up!
[Register Now](https://apps.daysmartrecreation.com/dash/x/#/online/extremeice/event-registration?date=2026-02-20&facility_ids=1)
```

### Data Model

```typescript
interface Session {
  date: string // YYYY-MM-DD
  dayOfWeek: string // Monday | Wednesday | Friday
  time: string // HH:MM (24h)
  timeLabel: string // "6:00am - 7:10am"
  eventName: string // Full event name from DASH
  playersRegistered: number
  playersMax: number
  goaliesRegistered: number
  goaliesMax: number
  isFull: boolean // Derived: playersRegistered >= playersMax
  price: number
}

interface SessionState {
  session: Session
  lastAlertType: AlertType | null
  lastAlertAt: string | null // ISO timestamp
  lastPlayerCount: number | null
  isRegistered: boolean // Manual flag
}

interface Alert {
  type: 'OPPORTUNITY' | 'FILLING_FAST' | 'SOLD_OUT' | 'NEWLY_AVAILABLE'
  session: Session
  message: string
  registrationUrl: string
}
```

### State Persistence

- JSON file on disk (simple, no database needed)
- Path: `./data/state.json`
- Contains: array of SessionState for all tracked sessions
- Prune sessions older than today on each poll cycle

## Phase 2: Auto-Registration (Future)

### What It Does

1. When OPPORTUNITY or FILLING_FAST alert fires, agent asks user for approval
2. User approves via Slack reaction, Slack command, or API call
3. Agent launches authenticated browser session
4. Navigates checkout flow: Add to Cart -> Login -> Select Registrant -> Confirm -> Checkout
5. Reports success/failure back to user

### Authentication

- Credentials stored in environment variables
- `DASH_EMAIL` and `DASH_PASSWORD`
- Session cookies cached to avoid re-login on every action

### Checkout Flow (from screenshots)

1. Navigate to event date page
2. Click "Add to cart" on target PLAYERS session
3. Login with stored credentials
4. Verify cart contents (correct session, correct date)
5. Click "Select Registrants"
6. Confirm registrant name matches expected user
7. Click "Confirm Registration"
8. On checkout page: verify total, use stored payment method
9. Click "Checkout"
10. Capture confirmation and report back

### Safety Gates

- Never auto-checkout without explicit user approval
- Verify session details match what was alerted before purchasing
- Timeout if any step takes > 30 seconds
- Screenshot each step for audit trail
- Maximum spend limit per day (configurable, default: $30)

## Technical Architecture

### Stack

- Runtime: Node.js 20+ with TypeScript
- Browser automation: Playwright (Chromium)
- Scheduling: node-cron
- State: JSON file (upgrade to SQLite if needed)
- Notifications: Slack webhook, Resend, Twilio, Pushover
- Deployment: DigitalOcean droplet ($6/mo)

### Project Structure

```
adult-hockey-agent/
├── src/
│   ├── index.ts              # Entry point, scheduler setup
│   ├── scraper.ts            # DASH page scraping logic
│   ├── parser.ts             # HTML/API response parsing
│   ├── evaluator.ts          # Alert rule evaluation
│   ├── state.ts              # State persistence
│   ├── notifiers/
│   │   ├── interface.ts      # Notifier interface
│   │   ├── console.ts
│   │   ├── slack.ts
│   │   ├── email.ts
│   │   ├── sms.ts
│   │   └── push.ts
│   ├── api.ts                # HTTP API for manual registration flags
│   └── config.ts             # Environment variable loading
├── tests/
│   ├── parser.test.ts        # Parse real HTML/API snapshots
│   ├── evaluator.test.ts     # Alert rule logic
│   ├── state.test.ts         # State management
│   ├── notifiers/
│   │   ├── console.test.ts   # Output format verification
│   │   ├── slack.test.ts     # Payload structure (mocked HTTP)
│   │   ├── email.test.ts     # Payload structure (mocked HTTP)
│   │   ├── sms.test.ts       # Payload structure (mocked HTTP)
│   │   └── push.test.ts      # Payload structure (mocked HTTP)
│   └── config.test.ts        # Env var validation
├── data/
│   └── .gitkeep
├── fixtures/                 # Saved HTML/API snapshots for testing
│   ├── friday-full.html
│   ├── friday-available.html
│   └── wednesday-partial.html
├── docs/
│   └── decisions.md          # Architecture Decision Records (ADR log)
├── CLAUDE.md
├── spec.md                   # This file
├── package.json
├── tsconfig.json
├── .env.example
├── .gitignore
└── README.md
```

### Environment Variables

```bash
# Required
ANTHROPIC_API_KEY=           # Only needed if adding AI-powered features later

# Notifications (configure at least one)
SLACK_WEBHOOK_URL=           # Slack incoming webhook
RESEND_API_KEY=              # Email via Resend
RESEND_FROM_EMAIL=           # Sender address
RESEND_TO_EMAIL=             # Your email
TWILIO_ACCOUNT_SID=          # SMS
TWILIO_AUTH_TOKEN=
TWILIO_FROM_NUMBER=
TWILIO_TO_NUMBER=
PUSHOVER_USER_KEY=           # Push notifications
PUSHOVER_APP_TOKEN=

# DASH Auth (Phase 2)
DASH_EMAIL=
DASH_PASSWORD=

# Polling Config
POLL_INTERVAL_MINUTES=60
POLL_INTERVAL_ACCELERATED_MINUTES=30
POLL_START_HOUR=6
POLL_END_HOUR=23
FORWARD_WINDOW_DAYS=5

# Alert Thresholds
MIN_GOALIES=2
PLAYER_SPOTS_ALERT=10
PLAYER_SPOTS_URGENT=4
```

### API Discovery: ✅ COMPLETED (2026-02-12)

**Finding**: DASH exposes a full JSON:API at `/dash/jsonapi/api/v1/`. Playwright NOT needed for polling. Use direct HTTP requests (faster, cheaper, more reliable). Playwright retained only for Phase 2 auto-registration.

**Key Endpoints**:

1. **GET** `/dash/jsonapi/api/v1/date-availabilities?filter[date__gte]={date}&company=extremeice`
   - Returns event IDs grouped by date
   - Response: `{ data: [{ id: "2026-02-13", attributes: { events: [213376, 214134, ...] } }] }`

2. **GET** `/dash/jsonapi/api/v1/events?filter[id__in]={ids}&include=summary,homeTeam&company=extremeice`
   - Returns full event details with relationships
   - Content-Type: `application/vnd.api+json`
   - Relationships in `included[]` array (JSON:API spec)

**Data Structure**:

- Event names: `event → homeTeam → included[] where type="teams" → attributes.name`
- Registration counts: `event → summary → included[] where type="event-summaries" → attributes.{registered_count, composite_capacity, registration_status}`
- Must resolve JSON:API relationships via `{type, id}` pairs

**Authentication**: None required for read-only event queries. Auth needed only for Phase 2 checkout.

## Success Criteria

- Accurately parses registration counts matching what the DASH UI shows
- Alerts arrive within polling interval of criteria being met
- No duplicate alerts for the same condition on the same session
- Runs unattended on DigitalOcean for 7+ days without intervention
- Handles DASH being down or slow gracefully (retry + log, don't crash)
- All alert rules covered by automated tests

## Out of Scope (v1)

- Mobile app
- Web dashboard
- Multi-rink support
- Goalie-specific registration
- Calendar integration
- Payment method management
