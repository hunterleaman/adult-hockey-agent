# Adult Hockey Agent

Monitoring agent for adult pick-up hockey registration at Extreme Ice Center (Indian Trail, NC).

## Overview

Polls the DaySmart DASH webapp to track registration counts for Mon/Wed/Fri pick-up hockey sessions. Sends notifications when sessions meet configurable alert criteria.

## Features

- **Smart Alerts**: OPPORTUNITY, FILLING_FAST, SOLD_OUT, NEWLY_AVAILABLE
- **Multi-Channel Notifications**: Console, Slack (Email/SMS/Push coming soon)
- **Duplicate Suppression**: Stateful tracking prevents alert spam
- **Accelerated Polling**: Automatically speeds up when sessions are filling
- **Active Hours**: Only polls during configured hours (default: 6am-11pm ET)
- **Dynamic Date Calculation**: Automatically finds Mon/Wed/Fri sessions within forward window

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

- `POLL_INTERVAL_MINUTES=60` - Default polling interval
- `POLL_INTERVAL_ACCELERATED_MINUTES=30` - Accelerated interval when sessions filling
- `POLL_START_HOUR=6` - Start polling at 6am ET
- `POLL_END_HOUR=23` - Stop polling at 11pm ET
- `FORWARD_WINDOW_DAYS=5` - Check sessions up to 5 days ahead
- `MIN_GOALIES=2` - Minimum goalies for OPPORTUNITY alert
- `PLAYER_SPOTS_ALERT=10` - Player spots threshold for OPPORTUNITY
- `PLAYER_SPOTS_URGENT=4` - Player spots threshold for FILLING_FAST

## Production Deployment (DigitalOcean)

### 1. Create Droplet

```bash
# $6/month Basic Droplet (1GB RAM, 25GB SSD)
# Ubuntu 24.04 LTS
# Select datacenter closest to you
```

### 2. Initial Server Setup

```bash
# SSH into droplet
ssh root@your-droplet-ip

# Update system
apt update && apt upgrade -y

# Install Node.js 20
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs

# Create app user
adduser --disabled-password --gecos "" hockey
usermod -aG sudo hockey

# Switch to app user
su - hockey
```

### 3. Deploy Application

```bash
# Clone repository
cd ~
git clone https://github.com/hunterleaman/adult-hockey-agent.git
cd adult-hockey-agent

# Install dependencies
npm install

# Configure environment
cp .env.example .env
nano .env  # Add your SLACK_WEBHOOK_URL

# Build
npm run build

# Test run
npm start
# Press Ctrl+C after verifying it works
```

### 4. Setup PM2 for Process Management

```bash
# Install PM2 globally
sudo npm install -g pm2

# Start agent with PM2
pm2 start dist/scheduler.js --name hockey-agent

# Save PM2 configuration
pm2 save

# Setup PM2 to start on boot
pm2 startup
# Run the command PM2 outputs (starts with sudo)

# View logs
pm2 logs hockey-agent

# Monitor
pm2 monit
```

### 5. Setup Automatic Updates (Optional)

```bash
# Create update script
cat > ~/update-agent.sh << 'EOF'
#!/bin/bash
cd ~/adult-hockey-agent
git pull
npm install
npm run build
pm2 restart hockey-agent
EOF

chmod +x ~/update-agent.sh

# Test it
./update-agent.sh
```

### 6. Monitoring

```bash
# View logs
pm2 logs hockey-agent

# Tail logs
pm2 logs hockey-agent --lines 100

# Check status
pm2 status

# Restart if needed
pm2 restart hockey-agent
```

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
│   ├── scheduler.ts          # Cron scheduler + CLI entry point
│   ├── config.ts             # Environment variable loading
│   ├── scraper.ts            # DASH API scraping
│   ├── parser.ts             # JSON:API response parsing
│   ├── evaluator.ts          # Alert rule evaluation
│   ├── state.ts              # State persistence
│   └── notifiers/
│       ├── interface.ts      # Notifier interface
│       ├── console.ts        # Console notifier
│       └── slack.ts          # Slack notifier
├── tests/                    # All test files (142 tests)
├── data/                     # Runtime state (gitignored)
├── docs/                     # Architecture decisions
├── .env.example              # Environment template
└── spec.md                   # Complete specification
```

## Alert Rules

### OPPORTUNITY 🏒

- `goalies_registered >= 2 AND player_spots_remaining <= 10`
- Purpose: Session is worth attending and filling up
- Suppression: Re-alert only if spots decreased by >= 2

### FILLING_FAST ⚡

- `player_spots_remaining <= 4`
- Purpose: Act now regardless of goalie count
- Suppression: Re-alert only if spots decreased

### SOLD_OUT 🚫

- Session transitioned from available → full
- Always fires (once per transition)
- Includes registered sessions (confirmation)

### NEWLY_AVAILABLE ✅

- Session transitioned from full → available
- Always fires (once per transition)
- Re-evaluates OPPORTUNITY and FILLING_FAST

## Testing

All core logic is fully tested (142 passing tests):

```bash
npm test

# Coverage by module:
# - Parser: 9 tests
# - Evaluator: 23 tests
# - State: 25 tests
# - Scraper: 27 tests
# - Notifiers: 28 tests
# - Config: 25 tests
# - Orchestrator: 5 tests
```

## Documentation

- [spec.md](./spec.md) - Complete project specification
- [CLAUDE.md](./CLAUDE.md) - Development guidelines and session learnings
- [LEARNINGS.md](./LEARNINGS.md) - Session-by-session progress log
- [docs/decisions.md](./docs/decisions.md) - Architecture decision records

## Troubleshooting

### Agent not polling

- Check logs: `pm2 logs hockey-agent`
- Verify active hours in .env (POLL_START_HOUR, POLL_END_HOUR)
- Check system time matches ET timezone

### No Slack notifications

- Verify SLACK_WEBHOOK_URL in .env
- Test webhook manually: `curl -X POST -H 'Content-Type: application/json' -d '{"text":"Test"}' YOUR_WEBHOOK_URL`
- Check Slack app permissions

### Build errors

- Ensure Node.js 20+: `node --version`
- Clean install: `rm -rf node_modules package-lock.json && npm install`
- Check TypeScript: `npm run typecheck`

## License

ISC

## Contributing

This is a personal project. Feel free to fork for your own use.
