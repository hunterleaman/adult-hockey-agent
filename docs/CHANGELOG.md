# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.0.0-production] - 2026-02-17

### 🎉 First Production Release

Adult Hockey Agent deployed to DigitalOcean VPS and running 24/7 with PM2 process management.

### Added

#### Production Infrastructure
- **Health Check Endpoint** (`GET /health`)
  - Returns agent status, uptime, and last poll timestamp
  - Accessible at `http://localhost:3000/health`
  - Used for monitoring and verification
- **Express Server** integration with polling scheduler
  - Runs on configurable PORT (default: 3000)
  - Graceful shutdown handling (SIGINT/SIGTERM)
  - Server starts before first poll
- **PM2 Process Management**
  - `ecosystem.config.cjs` configuration
  - Auto-restart on crashes with exponential backoff
  - Memory limit: 500MB
  - Log rotation and persistence
  - Survives server reboots via PM2 startup integration
- **Deployment Automation**
  - `scripts/setup-server.sh` - Automated server provisioning
  - `scripts/deploy.sh` - Code update and restart automation
  - Both scripts idempotent (safe to re-run)
- **Comprehensive Documentation**
  - `docs/DEPLOY.md` - Complete deployment guide (800+ lines)
  - `docs/nginx.conf` - Nginx reverse proxy configuration
  - Deployment session document with troubleshooting
  - Security hardening recommendations

#### Alert System Improvements
- **Priority Hierarchy** (Session 4)
  - SOLD_OUT > NEWLY_AVAILABLE > FILLING_FAST > OPPORTUNITY
  - Prevents multiple alerts for same session
  - Only highest-priority alert fires per session
- **Oscillation Prevention** (Session 5)
  - Fixed alert oscillation bug between FILLING_FAST and OPPORTUNITY
  - Hierarchy-aware suppression logic
  - 7 comprehensive state transition tests
  - See `docs/sessions/2026-02-17-alert-oscillation-fix.md`

#### Configuration
- **PORT** environment variable for HTTP server (default: 3000)
- **MIN_PLAYERS_REGISTERED** replaces `PLAYER_SPOTS_ALERT` (Session 3)
  - Changed from "spots remaining ≤ 10" to "players registered ≥ 10"
  - Better reflects session viability (critical mass vs urgency)
- **MIN_GOALIES** default changed from 2 to 1

#### Testing
- **172 passing tests** (up from 142)
  - 8 new tests for health endpoint
  - 7 new tests for alert oscillation prevention
  - 31 tests for evaluator (includes priority hierarchy)
  - 43 tests for notifiers (Slack Block Kit formatting)
  - 24 tests for config (includes PORT validation)

#### Documentation
- **Git Branching Workflow** added to CLAUDE.md
  - Branch naming conventions (feat/, fix/, docs/, deploy/, refactor/)
  - Complete workflow (create → work → merge → cleanup)
  - Pull request guidelines (optional but recommended)
  - Pre-merge verification checklist
- **Naming Convention** section in CLAUDE.md
  - Use "adult-hockey-agent" (three words, hyphenated) everywhere
  - Use "adulthockey" for system usernames (no hyphens)
  - Never use shortened versions like "hockey-agent" or "hockey"
- **Session Documents**
  - `docs/sessions/2026-02-17-digitalocean-deployment.md`
  - `docs/sessions/2026-02-17-alert-oscillation-fix.md`

### Fixed

- **Deployment Scripts** (Session 6)
  - Removed `--omit=dev` flag from `setup-server.sh` and `deploy.sh`
  - TypeScript (devDependency) now installed correctly
  - Builds no longer fail with "tsc: not found" error
- **Slack Button Validation** (Session 4)
  - Fixed 400 Bad Request on SOLD_OUT alerts
  - Removed invalid `style: 'default'` from Slack buttons
  - Omit action button entirely for SOLD_OUT (registration not possible)
- **Alert Oscillation** (Session 5)
  - Fixed infinite loop between FILLING_FAST and OPPORTUNITY alerts
  - Suppression logic now enforces priority hierarchy
  - Lower-priority alerts blocked after higher-priority alert fires
- **ES Module Imports** (Session 3)
  - Added `.js` extensions to all relative imports
  - Required for `"type": "module"` in package.json

### Changed

- **OPPORTUNITY Alert Logic** (Session 3)
  - **Old**: `player_spots_remaining <= 10`
  - **New**: `players_registered >= 10`
  - **Rationale**: Better reflects session viability (critical mass) vs urgency
  - Config variable renamed: `PLAYER_SPOTS_ALERT` → `MIN_PLAYERS_REGISTERED`
- **Alert Evaluation Order** (Session 4)
  - Evaluates in priority order to ensure correct alert selection
  - Uses `continue` to skip lower-priority alerts after firing
- **README.md** (Session 6)
  - Updated to reflect all 6 development sessions
  - Accurate test counts (172 tests)
  - Current alert rules with priority hierarchy
  - Production deployment details
  - Recent improvements section (Sessions 3-6)

### Deployment

- **Platform**: DigitalOcean VPS
- **OS**: Ubuntu 24.04 LTS
- **Size**: Basic $6/mo (1 vCPU, 1GB RAM, 25GB SSD)
- **Region**: NYC1
- **Server IP**: 198.211.102.15
- **User**: adulthockey
- **Process Manager**: PM2
- **Uptime**: 24/7 with auto-restart
- **Health Endpoint**: http://198.211.102.15:3000/health
- **Deployed**: 2026-02-17 21:00 UTC
- **Status**: ✅ Production ready, monitoring adult pick-up hockey sessions

### Performance

- **Memory Usage**: ~78MB (well within 1GB limit)
- **CPU Usage**: 0% idle, spikes during polls
- **Polling Interval**: 60 minutes (30 minutes when FILLING_FAST detected)
- **Active Hours**: 6am-11pm ET
- **Forward Window**: 5 days

### Known Issues

1. **Port 3000 Open to All IPs**
   - Should restrict to Slack IP ranges for production
   - Not blocking - works correctly
   - Action: Implement firewall restriction after verification

2. **npm Version Warning**
   - npm 10.8.2 installed, 11.10.0 available
   - Non-critical
   - Action: Optional upgrade in future

### Security

- **Environment Variables**: All secrets in `.env` (gitignored)
- **No Hardcoded Credentials**: Webhook URL, API keys in env vars only
- **SSH Key Authentication**: Password authentication disabled
- **Non-Root User**: Agent runs as `adulthockey` user
- **PM2 Process Isolation**: Sandboxed process with resource limits

---

## [Unreleased]

### Planned Features

- Email notifications (Resend integration)
- SMS notifications (Twilio integration)
- Push notifications (Pushover integration)
- League standings tracking
- Player statistics
- Schedule management
- Auto-registration (Phase 2 - requires explicit approval)

### Future Improvements

- Nginx reverse proxy with SSL/HTTPS
- Let's Encrypt SSL certificate
- Domain name configuration
- Automated backups (cron job for state.json)
- PM2 Plus monitoring alerts
- Uptime monitoring (UptimeRobot)
- Log rotation configuration
- Slack IP range restriction

---

## Version History

- **1.0.0-production** (2026-02-17) - First production release, deployed to DigitalOcean
- **0.x.x** (2026-02-12 to 2026-02-17) - Development sessions 1-6

---

## Development Sessions

1. **Session 1** (2026-02-12): API Discovery - DASH JSON:API exploration
2. **Session 2** (2026-02-13): Core Implementation - Parser, evaluator, state management
3. **Session 3** (2026-02-16): ES Modules & Alert Logic Update
4. **Session 4** (2026-02-17): Alert Priority System & Slack Button Fix
5. **Session 5** (2026-02-17): Alert Oscillation Fix
6. **Session 6** (2026-02-17): DigitalOcean Production Deployment

See `CLAUDE.md` Known Mistakes section for detailed session learnings.
See `docs/sessions/` for comprehensive session documentation.
