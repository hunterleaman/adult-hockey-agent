# Adult Hockey Agent

Monitoring agent for adult pick-up hockey registration at Extreme Ice Center (Indian Trail, NC).

## Overview

Polls the DaySmart DASH webapp to track registration counts for Mon/Wed/Fri pick-up hockey sessions. Sends notifications when sessions meet configurable alert criteria.

## Features

- **Smart Alerts**: Hierarchical alert system (SOLD_OUT → NEWLY_AVAILABLE → FILLING_FAST → OPPORTUNITY)
- **Multi-Channel Notifications**: Console, Slack (Email/SMS/Push coming soon)
- **Duplicate Suppression**: Stateful tracking with priority-aware logic prevents alert spam
- **Accelerated Polling**: Automatically speeds up when sessions are filling (60min → 30min)
- **Active Hours**: Only polls during configured hours (default: 6am-11pm ET)
- **Dynamic Date Calculation**: Automatically finds Mon/Wed/Fri sessions within forward window
- **Production Ready**: Health endpoint, PM2 process management, auto-restart on crashes
- **Deployment Automation**: One-command server setup with automated deployment scripts

## Quick Start

### Prerequisites

- Node.js 20+
- npm

### Local Development

1. **Install dependencies:**

   ```bash
   npm install
   ```

2. **Configure environment:**

   ```bash
   cp .env.example .env
   # Edit .env and add your SLACK_WEBHOOK_URL
   ```

3. **Run tests:**

   ```bash
   npm test
   ```

4. **Start the agent:**
   ```bash
   npm start
   ```

The agent will:

- Run an initial poll immediately
- Schedule polls every 60 minutes (configurable)
- Only poll during active hours (6am-11pm ET)
- Log all activity to console
- Send alerts to Slack when configured

## Configuration

All configuration via environment variables. See `.env.example` for full list:

### Required

- `SLACK_WEBHOOK_URL` - Slack incoming webhook (get from https://api.slack.com/messaging/webhooks)

### Optional (with defaults)

- `PORT=3000` - HTTP server port for health endpoint
- `POLL_INTERVAL_MINUTES=60` - Default polling interval
- `POLL_INTERVAL_ACCELERATED_MINUTES=30` - Accelerated interval when sessions filling
- `POLL_START_HOUR=6` - Start polling at 6am ET
- `POLL_END_HOUR=23` - Stop polling at 11pm ET
- `FORWARD_WINDOW_DAYS=5` - Check sessions up to 5 days ahead
- `MIN_GOALIES=1` - Minimum goalies for OPPORTUNITY alert
- `MIN_PLAYERS_REGISTERED=10` - Minimum players registered for OPPORTUNITY alert
- `PLAYER_SPOTS_URGENT=4` - Player spots remaining threshold for FILLING_FAST

## Production Deployment

For complete deployment instructions including DigitalOcean droplet setup, server configuration, PM2 process management, monitoring, and troubleshooting, see **[docs/DEPLOY.md](docs/DEPLOY.md)**.

**Quick Start**:
1. Create DigitalOcean droplet (Ubuntu 24.04, $6/mo)
2. Clone repo and run `./scripts/setup-server.sh`
3. Configure `.env` with your `SLACK_WEBHOOK_URL`
4. Restart: `pm2 restart adult-hockey-agent`

The agent includes:
- PM2 process management (auto-restart on crashes with exponential backoff)
- Survives server reboots (PM2 startup integration)
- Health check endpoint at `http://localhost:3000/health`
- Automated deployment scripts (`setup-server.sh`, `deploy.sh`)
- Graceful shutdown handling (SIGINT/SIGTERM)

### Health Endpoint

The agent exposes a health check endpoint for monitoring:

```bash
curl http://localhost:3000/health
```

**Response**:
```json
{
  "status": "ok",
  "uptime": 123.456,
  "lastPoll": "2026-02-17T12:00:00.000Z"
}
```

- **status**: Always "ok" if server is running
- **uptime**: Process uptime in seconds
- **lastPoll**: Timestamp of last poll (from state file modification time), or `null` if never polled

## Development

```bash
# Run tests
npm test

# Run tests with UI
npm run test:ui

# Type checking
npm run typecheck

# Format code
npm run format

# Build TypeScript
npm run build
```

## Project Structure

```
adult-hockey-agent/
├── src/
│   ├── index.ts              # Main orchestrator (poll cycle)
│   ├── scheduler.ts          # Polling scheduler + HTTP server startup
│   ├── server.ts             # Express server with health endpoint
│   ├── config.ts             # Environment variable loading
│   ├── scraper.ts            # DASH API scraping
│   ├── parser.ts             # JSON:API response parsing
│   ├── evaluator.ts          # Alert rule evaluation (priority hierarchy)
│   ├── state.ts              # State persistence
│   └── notifiers/
│       ├── interface.ts      # Notifier interface
│       ├── console.ts        # Console notifier
│       └── slack.ts          # Slack notifier (Block Kit formatting)
├── tests/                    # All test files (172 tests)
├── scripts/
│   ├── setup-server.sh       # Automated server provisioning
│   └── deploy.sh             # Deployment/update script
├── data/                     # Runtime state (gitignored)
├── docs/
│   ├── DEPLOY.md             # Complete deployment guide
│   ├── nginx.conf            # Reverse proxy configuration
│   ├── SPEC.md               # Complete specification
│   ├── DECISIONS.md          # Architecture decision records
│   └── CONTRIBUTING.md       # Development protocols
├── ecosystem.config.cjs      # PM2 process management config
├── .env.example              # Environment template
└── CLAUDE.md                 # Development guidelines & session learnings
```

## Alert Rules

Alerts follow a **priority hierarchy** to prevent oscillation and ensure only the most relevant alert fires per session.

### Priority Order (highest → lowest)

**SOLD_OUT** > **NEWLY_AVAILABLE** > **FILLING_FAST** > **OPPORTUNITY**

Once a higher-priority alert fires, lower-priority alerts are suppressed unless session state changes significantly.

### SOLD_OUT 🚫 (Priority 1)

- Session transitioned from available → full
- Always fires (once per transition)
- Includes registered sessions (confirmation)
- Blocks all lower-priority alerts until session reopens

### NEWLY_AVAILABLE ✅ (Priority 2)

- Session transitioned from full → available
- Always fires (once per transition)
- Re-evaluates FILLING_FAST and OPPORTUNITY after firing
- Resets suppression state for the session

### FILLING_FAST ⚡ (Priority 3)

- `player_spots_remaining <= 4` (default, configurable via `PLAYER_SPOTS_URGENT`)
- Purpose: Urgent - act now regardless of goalie count
- Suppression: Re-alert only if spots decreased further
- Blocks OPPORTUNITY alerts (higher urgency takes precedence)

### OPPORTUNITY 🏒 (Priority 4)

- `goalies_registered >= MIN_GOALIES (default: 1) AND players_registered >= MIN_PLAYERS_REGISTERED (default: 10)`
- Purpose: Session has critical mass - worth attending and likely to run
- Suppression: Re-alert only if player count increased by >= 2
- **Note**: Changed from "spots remaining" to "players registered" in Session 3 to better reflect session viability

## Testing

All core logic is fully tested (**172 passing tests**):

```bash
npm test

# Coverage by module:
# - Parser: 9 tests
# - Evaluator: 31 tests (includes priority hierarchy tests)
# - State: 25 tests (includes oscillation prevention tests)
# - Scraper: 27 tests
# - Notifiers: 43 tests (Console: 11, Slack: 32)
# - Config: 24 tests (includes PORT validation)
# - Server: 8 tests (health endpoint)
# - Orchestrator: 5 tests
```

### Running Tests

```bash
# Run all tests
npm test

# Run tests with UI
npm run test:ui

# Run tests in watch mode
npm test -- --watch

# Run full quality check (typecheck + lint + format + tests)
npm run check
```

## Documentation

- **[docs/DEPLOY.md](./docs/DEPLOY.md)** - Complete deployment guide (DigitalOcean setup, troubleshooting, security)
- **[docs/SPEC.md](./docs/SPEC.md)** - Complete project specification
- **[CLAUDE.md](./CLAUDE.md)** - Development guidelines, naming conventions, and known mistakes
- **[docs/DECISIONS.md](./docs/DECISIONS.md)** - Architecture decision records (ADRs)
- **[docs/CONTRIBUTING.md](./docs/CONTRIBUTING.md)** - Development protocols and session-end checklist
- **[docs/nginx.conf](./docs/nginx.conf)** - Nginx reverse proxy configuration (optional)

## Recent Improvements

### Session 6 (2026-02-17): Production Deployment Infrastructure
- ✅ Health check endpoint (`GET /health`)
- ✅ PM2 ecosystem configuration with auto-restart
- ✅ Automated server setup and deployment scripts
- ✅ Comprehensive deployment documentation (docs/DEPLOY.md)
- ✅ Nginx reverse proxy configuration
- ✅ Test suite expanded to 172 tests (up from 141)

### Session 5 (2026-02-17): Alert Oscillation Fix
- ✅ Fixed alert oscillation bug (FILLING_FAST ↔ OPPORTUNITY loop)
- ✅ Implemented hierarchy-aware suppression logic
- ✅ Added 7 comprehensive state transition tests
- ✅ Documented fix in `docs/sessions/2026-02-17-alert-oscillation-fix.md`

### Session 4 (2026-02-17): Alert Priority System
- ✅ Implemented alert priority hierarchy (prevents redundant alerts)
- ✅ Fixed Slack button validation (400 error on `style: 'default'`)
- ✅ Ensured only one alert per session fires (highest priority wins)

### Session 3 (2026-02-16): OPPORTUNITY Alert Logic Update
- ✅ Changed OPPORTUNITY trigger from "spots remaining ≤ 10" to "players registered ≥ 10"
- ✅ Better reflects session viability (critical mass vs urgency)
- ✅ Renamed `PLAYER_SPOTS_ALERT` → `MIN_PLAYERS_REGISTERED`

## Troubleshooting

### Check Agent Health

```bash
# Check if agent is running
pm2 status

# Test health endpoint
curl http://localhost:3000/health

# View logs
pm2 logs adult-hockey-agent --lines 50
```

### Agent not polling

- Check logs: `pm2 logs adult-hockey-agent`
- Verify active hours in .env (POLL_START_HOUR, POLL_END_HOUR)
- Check system time matches ET timezone
- Verify health endpoint shows recent `lastPoll` timestamp

### No Slack notifications

- Verify SLACK_WEBHOOK_URL in .env
- Test webhook manually: `curl -X POST -H 'Content-Type: application/json' -d '{"text":"Test"}' YOUR_WEBHOOK_URL`
- Check Slack app permissions
- Verify no sessions currently meet alert criteria (check state.json)

### Build errors

- Ensure Node.js 20+: `node --version`
- Clean install: `rm -rf node_modules package-lock.json && npm install`
- Check TypeScript: `npm run typecheck`

### Health endpoint returns 404

- Verify agent is running: `pm2 status`
- Check PORT configuration in .env (default: 3000)
- Test locally first: `curl http://localhost:3000/health`
- Check firewall allows port 3000 (if accessing remotely)

## License

ISC

## Contributing

This is a personal project. Feel free to fork for your own use.
