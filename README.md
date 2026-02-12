# Adult Hockey Agent

Monitoring agent for adult pick-up hockey registration at Extreme Ice Center (Indian Trail, NC).

## Overview

Polls the DaySmart DASH webapp to track registration counts for Mon/Wed/Fri pick-up hockey sessions. Sends notifications when sessions meet configurable alert criteria.

## Features

- **Smart Alerts**: OPPORTUNITY, FILLING_FAST, SOLD_OUT, NEWLY_AVAILABLE
- **Multi-Channel Notifications**: Slack, Email, SMS, Push
- **Duplicate Suppression**: Stateful tracking prevents alert spam
- **Accelerated Polling**: Automatically speeds up when sessions are filling
- **Manual Registration Tracking**: Mark sessions you've registered for

## Setup

1. Install dependencies:
   ```bash
   npm install
   ```

2. Copy `.env.example` to `.env` and configure:
   ```bash
   cp .env.example .env
   ```

3. Configure at least one notification method (Slack recommended)

4. Build the project:
   ```bash
   npm run build
   ```

5. Run the agent:
   ```bash
   npm start
   ```

## Development

```bash
# Run tests
npm test

# Run tests with UI
npm test:ui

# Format code
npm run format

# Build TypeScript
npm run build
```

## Documentation

- [spec.md](./spec.md) - Complete project specification
- [CLAUDE.md](./CLAUDE.md) - Development guidelines
- [docs/decisions.md](./docs/decisions.md) - Architecture decisions

## License

ISC
