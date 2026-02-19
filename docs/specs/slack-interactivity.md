# Spec: Slack Interactive Messages

**Issue:** #7
**Status:** Draft
**Author:** Hunter Leaman
**Date:** 2026-02-19

## Summary

Add interactive buttons to Slack alert notifications so the user can respond directly from Slack. Responses persist in state and inform future polling/notification behavior. This is the foundation for smart polling (#8) and auto-registration (#4).

## Problem

The agent sends notifications but has no feedback loop. The user cannot tell the agent "I registered for this" or "I don't care about this session" without SSH'ing into the server and editing state.json manually. This means:

- Duplicate notifications for sessions the user already registered for
- Noise from sessions the user will never attend (e.g., afternoon sessions on workdays)
- No data to drive smart polling decisions
- No path to auto-registration approval flow

## Solution

Add three interactive buttons to each non-SOLD_OUT Slack notification:

- **✅ Registered** — User has signed up. Stop alerting for this session.
- **❌ Not Interested** — User won't attend. Stop alerting for this session.
- **⏰ Remind Later** — Snooze. Re-alert after a configurable interval (default: 2 hours).

SOLD_OUT notifications get no buttons (no action to take).

When the user clicks a button, Slack sends a POST to the agent's public endpoint. The agent updates state.json and sends an ephemeral confirmation back to Slack.

## Architecture

### Current Flow

```
Scheduler → Scraper → Parser → Evaluator → Notifier (webhook POST to Slack)
                                                ↓
                                          Slack displays message
                                          (no feedback path)
```

### New Flow

```
Scheduler → Scraper → Parser → Evaluator → Notifier (webhook POST to Slack)
                                                ↓
                                          Slack displays message + buttons
                                                ↓
                                          User clicks button
                                                ↓
                                          Slack POSTs to agent endpoint
                                                ↓
                                          Agent updates state.json
                                                ↓
                                          Agent responds to Slack (confirmation)
```

### Components

1. **Slack App Configuration** — Convert from incoming webhook to a Slack App with Interactivity enabled
2. **Interaction Endpoint** — New Express route: `POST /slack/interactions`
3. **Button Payloads** — Add interactive buttons to existing Block Kit messages
4. **State Updates** — Extend state.json schema with user response tracking
5. **Confirmation Messages** — Ephemeral responses back to Slack after button click

## Slack App Migration

### Current Setup
- Incoming Webhook (simple POST URL, no interactivity support)

### Required Setup
- Slack App with:
  - **Incoming Webhooks** enabled (keeps current notification flow working)
  - **Interactivity** enabled, pointing to: `https://<droplet-ip-or-domain>/slack/interactions`
  - **Bot Token** for sending ephemeral responses (confirmation messages)

### Migration Steps
1. Go to https://api.slack.com/apps
2. Create New App → From Scratch
3. Name: "Adult Hockey Agent", Workspace: your workspace
4. Features → Incoming Webhooks → Enable → Add New Webhook to Workspace → Select channel
5. Features → Interactivity & Shortcuts → Enable → Set Request URL to `http://198.211.102.15:3000/slack/interactions`
6. OAuth & Permissions → Bot Token Scopes: `chat:write` (for ephemeral responses)
7. Install App to Workspace
8. Copy: Bot Token (`xoxb-...`), new Webhook URL, Signing Secret

### Environment Variables (add to .env)
```
SLACK_WEBHOOK_URL=https://hooks.slack.com/services/T.../B.../...  # updated from new app
SLACK_BOT_TOKEN=xoxb-...
SLACK_SIGNING_SECRET=...
```

### HTTPS Consideration
Slack requires HTTPS for the Interactivity Request URL in production apps. For development/personal use, Slack allows HTTP for Request URLs when the app is installed only to your own workspace. If Slack rejects the HTTP URL, you have two options:
- **Option A (simplest):** Use Cloudflare Tunnel (`cloudflared`) to expose the endpoint over HTTPS without buying a domain or cert. Free tier is sufficient.
- **Option B:** Add nginx + Let's Encrypt to the droplet with a domain.

Validate which is required during implementation before committing to either approach.

## Interaction Endpoint

### Route: `POST /slack/interactions`

Slack sends all button clicks as a single POST with `Content-Type: application/x-www-form-urlencoded` containing a `payload` field with JSON.

### Request Validation

**CRITICAL:** Verify the Slack signing secret on every request. This prevents spoofed requests.

```typescript
// Signature verification (must happen before JSON parsing)
import crypto from 'crypto'

function verifySlackSignature(
  signingSecret: string,
  signature: string,
  timestamp: string,
  body: string
): boolean {
  // Reject requests older than 5 minutes (replay attack prevention)
  const fiveMinutesAgo = Math.floor(Date.now() / 1000) - 60 * 5
  if (parseInt(timestamp) < fiveMinutesAgo) return false

  const sigBasestring = `v0:${timestamp}:${body}`
  const mySignature = 'v0=' + crypto
    .createHmac('sha256', signingSecret)
    .update(sigBasestring)
    .digest('hex')

  return crypto.timingSafeEqual(
    Buffer.from(mySignature),
    Buffer.from(signature)
  )
}
```

### Payload Structure (from Slack)

```json
{
  "type": "block_actions",
  "user": { "id": "U...", "name": "hunter" },
  "trigger_id": "...",
  "actions": [
    {
      "action_id": "session_registered",
      "block_id": "actions_block",
      "value": "2026-02-20|05:50|(PLAYERS) ADULT Pick Up MORNINGS",
      "type": "button"
    }
  ],
  "response_url": "https://hooks.slack.com/actions/..."
}
```

### Action IDs

- `session_registered` — User clicked "Registered"
- `session_not_interested` — User clicked "Not Interested"
- `session_remind_later` — User clicked "Remind Later"

### Action Value Encoding

The button `value` field encodes the session identity. Use pipe-delimited format:

```
{date}|{time}|{eventName}
```

Example: `2026-02-20|05:50|(PLAYERS) ADULT Pick Up MORNINGS`

This uniquely identifies a session in state.json. The value field has a 2000 character limit (plenty).

### Response Handling

```typescript
// POST /slack/interactions
async function handleInteraction(req, res) {
  // 1. Verify signature (reject if invalid)
  // 2. Parse payload JSON from form-encoded body
  // 3. Extract action_id and value
  // 4. Parse session identity from value
  // 5. Find matching session in state
  // 6. Update state based on action
  // 7. Respond 200 immediately (Slack requires <3s response)
  // 8. Send confirmation via response_url (async, after 200)
}
```

**IMPORTANT:** Respond with HTTP 200 within 3 seconds. Slack shows an error to the user if the endpoint is slow. Do the state update synchronously (it's a file write, fast enough), then send the confirmation message asynchronously via `response_url`.

## Button Payloads

### Current Block Kit Structure

```json
{
  "blocks": [
    { "type": "header", "text": { "type": "plain_text", "text": "🏒 OPPORTUNITY" } },
    { "type": "section", "text": { "type": "mrkdwn", "text": "..." } },
    {
      "type": "actions",
      "elements": [
        { "type": "button", "text": { "type": "plain_text", "text": "Register Now" }, "url": "...", "style": "primary" }
      ]
    }
  ]
}
```

### New Block Kit Structure

```json
{
  "blocks": [
    { "type": "header", "text": { "type": "plain_text", "text": "🏒 OPPORTUNITY" } },
    { "type": "section", "text": { "type": "mrkdwn", "text": "..." } },
    {
      "type": "actions",
      "block_id": "actions_block",
      "elements": [
        {
          "type": "button",
          "text": { "type": "plain_text", "text": "Register Now" },
          "url": "https://example.com/register?date=2026-02-20",
          "style": "primary"
        },
        {
          "type": "button",
          "text": { "type": "plain_text", "text": "✅ Registered" },
          "action_id": "session_registered",
          "value": "2026-02-20|05:50|(PLAYERS) ADULT Pick Up MORNINGS"
        },
        {
          "type": "button",
          "text": { "type": "plain_text", "text": "❌ Not Interested" },
          "action_id": "session_not_interested",
          "value": "2026-02-20|05:50|(PLAYERS) ADULT Pick Up MORNINGS"
        },
        {
          "type": "button",
          "text": { "type": "plain_text", "text": "⏰ Remind Later" },
          "action_id": "session_remind_later",
          "value": "2026-02-20|05:50|(PLAYERS) ADULT Pick Up MORNINGS"
        }
      ]
    }
  ]
}
```

Note: "Register Now" is a link button (has `url`, no `action_id`). The other three are interactive buttons (have `action_id`, no `url`). Link buttons don't trigger interaction payloads.

### SOLD_OUT Notifications

No changes. SOLD_OUT already has no action buttons. Keep it that way.

## State Schema Changes

### Current State Entry

```typescript
interface SessionState {
  session: Session
  lastAlertType: AlertType | null
  lastAlertAt: string | null    // ISO timestamp
  lastPlayerCount: number | null
  isRegistered: boolean
}
```

### New State Entry

```typescript
interface SessionState {
  session: Session
  lastAlertType: AlertType | null
  lastAlertAt: string | null
  lastPlayerCount: number | null
  isRegistered: boolean
  // NEW fields
  userResponse: 'registered' | 'not_interested' | 'remind_later' | null
  userRespondedAt: string | null   // ISO timestamp
  remindAfter: string | null       // ISO timestamp (only set for remind_later)
}
```

### State Update Logic by Action

**session_registered:**
```typescript
entry.isRegistered = true
entry.userResponse = 'registered'
entry.userRespondedAt = new Date().toISOString()
```

**session_not_interested:**
```typescript
entry.userResponse = 'not_interested'
entry.userRespondedAt = new Date().toISOString()
```

**session_remind_later:**
```typescript
entry.userResponse = 'remind_later'
entry.userRespondedAt = new Date().toISOString()
entry.remindAfter = new Date(Date.now() + REMIND_INTERVAL_MS).toISOString()
```

Where `REMIND_INTERVAL_MS` defaults to 2 hours (7200000ms), configurable via `REMIND_INTERVAL_HOURS` env var.

### Impact on Evaluator

The evaluator must check `userResponse` before firing alerts:

- `userResponse === 'registered'` → suppress all future alerts for this session
- `userResponse === 'not_interested'` → suppress all future alerts for this session
- `userResponse === 'remind_later'` → suppress alerts until `remindAfter` timestamp passes, then reset `userResponse` to null and resume normal evaluation

This is a small change in the evaluator's suppression logic, not a restructure.

## Confirmation Messages

After updating state, POST to the `response_url` from the interaction payload:

### Registered
```json
{
  "response_type": "ephemeral",
  "replace_original": false,
  "text": "✅ Marked as registered for Friday 2/20 at 5:50am. You won't receive further alerts for this session."
}
```

### Not Interested
```json
{
  "response_type": "ephemeral",
  "replace_original": false,
  "text": "❌ Dismissed Friday 2/20 at 5:50am. You won't receive further alerts for this session."
}
```

### Remind Later
```json
{
  "response_type": "ephemeral",
  "replace_original": false,
  "text": "⏰ Snoozed Friday 2/20 at 5:50am. I'll remind you again in 2 hours."
}
```

Using `replace_original: false` keeps the original notification visible (user may want to reference the session details). The confirmation appears as an ephemeral message only visible to the user who clicked.

## File Structure

### New Files
```
src/interactions/
  handler.ts          # Express route handler for /slack/interactions
  verify.ts           # Slack signature verification
  actions.ts          # Action processing (state updates per action type)

tests/interactions/
  handler.test.ts     # Route handler tests (fixture-based, mocked state)
  verify.test.ts      # Signature verification tests
  actions.test.ts     # Action processing tests

tests/fixtures/
  slack-interaction-registered.json    # Sample Slack interaction payload
  slack-interaction-dismissed.json
  slack-interaction-remind.json
```

### Modified Files
```
src/notifiers/slack.ts    # Add interactive buttons to buildPayload()
src/evaluator.ts          # Add userResponse-based suppression
src/state.ts              # Extend SessionState type, handle new fields
src/index.ts              # Register /slack/interactions route on Express app
src/config.ts             # Add SLACK_BOT_TOKEN, SLACK_SIGNING_SECRET, REMIND_INTERVAL_HOURS
.env.example              # Add new env vars
```

## Implementation Order

Build and test in this sequence. Each step should be independently committable and testable.

### Step 1: Slack App Setup + Endpoint Skeleton
- Create Slack App, configure Interactivity URL
- Add `POST /slack/interactions` route that returns 200 and logs the payload
- Add env vars (SLACK_SIGNING_SECRET, SLACK_BOT_TOKEN)
- Deploy to droplet, verify Slack delivers payloads
- **Test:** Send a test button click, confirm payload arrives in PM2 logs

### Step 2: Signature Verification
- Implement `verify.ts` with signing secret validation
- Wire into route handler (reject unsigned requests)
- **Test:** Unit tests with known signature fixtures

### Step 3: State Schema Extension
- Add new fields to SessionState type
- Ensure backward compatibility (existing state.json without new fields works)
- Default `userResponse` to null, `userRespondedAt` to null, `remindAfter` to null
- **Test:** State read/write with old and new schema formats

### Step 4: Action Processing
- Implement `actions.ts` — parse action_id + value, update state
- Wire into route handler
- **Test:** Unit tests for each action type against state fixtures

### Step 5: Interactive Buttons in Notifications
- Modify `slack.ts` buildPayload() to include interactive buttons
- Encode session identity in button value fields
- **Test:** Update existing slack.test.ts, verify new block structure

### Step 6: Evaluator Suppression
- Add userResponse checks to evaluator suppression logic
- Handle remind_later expiry (reset when remindAfter passes)
- **Test:** Evaluator tests with userResponse states

### Step 7: Confirmation Messages
- POST ephemeral confirmations to response_url after state update
- **Test:** Verify correct message text per action type

### Step 8: Deploy + Integration Test
- Deploy full feature to droplet
- Trigger a real notification, click each button type, verify:
  - State file updates correctly
  - Confirmation message appears in Slack
  - Subsequent polls respect the user response
  - Remind later re-alerts after interval

## Testing Strategy

All tests use fixture payloads, not live Slack. Follow existing project patterns.

### Fixtures Needed
- Slack interaction payload for each action type (registered, not_interested, remind_later)
- Slack interaction payload with invalid signature (for rejection testing)
- State.json with old schema (backward compatibility)
- State.json with new schema fields populated

### What NOT to Mock
- State file read/write (use temp files in tests)
- JSON parsing of Slack payloads (use real fixture structure)

### What to Mock
- `fetch` calls to response_url (confirmation messages)
- Clock/timers for remind_later expiry testing

## Configuration

### New Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| SLACK_SIGNING_SECRET | Yes | — | From Slack App → Basic Information → Signing Secret |
| SLACK_BOT_TOKEN | Yes | — | From Slack App → OAuth → Bot User OAuth Token |
| REMIND_INTERVAL_HOURS | No | 2 | Hours before remind_later snooze expires |

### Existing Variables (unchanged)
| Variable | Description |
|----------|-------------|
| SLACK_WEBHOOK_URL | Updated to new Slack App's webhook URL |

## Security

- All interaction requests validated via Slack signing secret (HMAC-SHA256)
- Requests older than 5 minutes rejected (replay attack prevention)
- No user authentication needed (single-user agent, Slack identity implicit)
- Bot token stored in .env, never committed to git
- Express endpoint only processes `block_actions` type payloads, ignores everything else

## Cost Impact

- Zero additional API costs (Slack interactions are free)
- Minimal compute: one state file write per button click
- No additional Slack API calls except ephemeral response POSTs (free tier)

## Out of Scope

- Slash commands (Phase 2, after buttons are proven)
- Auto-registration flow (Issue #4, depends on this feature)
- Smart polling integration (Issue #8, depends on this feature's state schema)
- Message update after button click (replacing original message with updated status)
- Multi-user support (single user agent)

## Open Questions

1. **HTTPS requirement:** Does Slack enforce HTTPS for Interactivity URLs on workspace-only apps? Validate during Step 1 before committing to cloudflared or nginx+certbot.
2. **Button click after session passes:** If a user clicks "Registered" on a past session, the state update is harmless but unnecessary. Ignore gracefully (update state, send confirmation, no special handling needed).
