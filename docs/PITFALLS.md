# adult-hockey-agent Pitfalls & Lessons Learned

Read by agents when relevant. Not auto-loaded into every session.

## Lessons Learned

<!-- INSTRUCTION: Append entries in this format:
- **{Title}.** {Explanation}. {Why it matters}.
-->

## Known Mistakes (Sessions 1-12)

Migrated verbatim from CLAUDE.md "Known Mistakes" on 2026-07-20 (CPT slim-pointer migration). New mistakes: add a new session block here or a Lessons Learned bullet above; CLAUDE.md keeps only a pointer.

### Session 1 (2026-02-12) - API Discovery

1. **Playwright browsers not installed**: Initial `npm run discover` failed because Playwright browsers weren't installed. Required `npx playwright install chromium` before running browser automation.
2. **Hardcoded dates in discovery scripts**: Initial investigation scripts (`src/fetch-events.ts`, `src/fetch-availabilities.ts`) used hardcoded dates like `2026-02-13`. These are throwaway investigation tools, NOT production patterns. Production scraper must calculate dates dynamically.
3. **Missing event names (empty desc field)**: Initially looked for event names in `event.attributes.desc` which was empty. Event names actually come from the `homeTeam` relationship resolved via JSON:API `included[]` array where `type="teams"`.
4. **Case-sensitive team name filtering**: Parser initially used `teamName.includes('ADULT Pick Up')` which failed to match `"Adult Pick Up Hockey (Mornings)"` (lowercase 'A'). Fixed by using case-insensitive comparison: `teamName.toLowerCase().includes('adult pick up')`.

### Session 2 (2026-02-13) - Core Implementation

1. **Plan mode cannot be exited cleanly from within plan mode**: `/plan mode` cannot be exited cleanly from within plan mode. Use `/plan off` from the CLI prompt to exit, which ends the session. Resume with a fresh claude session to continue work.

### Session 3 (2026-02-16) - ES Modules & Alert Logic Update

1. **Missing .js extensions in ES module imports**: With `"type": "module"` in package.json, Node.js requires explicit `.js` extensions for relative imports. Updated scheduler.ts, index.ts, and scraper.ts to add `.js` extensions to all runtime imports (type-only imports don't need extensions).
2. **OPPORTUNITY alert logic changed**: Updated from `player_spots_remaining <= 10` to `players_registered >= 10`. This better reflects when a session has critical mass (enough committed players) rather than urgency (few spots left). Config variable renamed from `PLAYER_SPOTS_ALERT` to `MIN_PLAYERS_REGISTERED`.

### Session 4 (2026-02-17) - Alert Priority System & Slack Button Fix

1. **Slack 400 Bad Request on SOLD_OUT alerts**: SlackNotifier used `style: 'default'` for buttons, but Slack's Block Kit only accepts `'primary'`, `'danger'`, or omitting the field. Invalid `'default'` value caused 400 errors. Fixed by returning `undefined` for default styling and omitting action button entirely for SOLD_OUT alerts (since registration isn't possible).
2. **Multiple alerts firing for same session**: Evaluator allowed both FILLING_FAST and OPPORTUNITY to fire for the same session. For example, a session with 19/24 players would trigger both alerts with redundant information. Implemented priority hierarchy (SOLD_OUT > NEWLY_AVAILABLE > FILLING_FAST > OPPORTUNITY) with `continue` statements to ensure only one alert per session fires based on highest priority condition met.

### Session 5 (2026-02-17) - Alert Oscillation Fix

1. **Alert oscillation bug**: Despite Session 4 implementing priority hierarchy in evaluation order, the suppression logic had a critical flaw causing alerts to oscillate between FILLING_FAST and OPPORTUNITY. Suppression functions checked `prevState.lastAlertType !== CURRENT_TYPE`, which returned TRUE when previous alert was a different type, causing alerts to alternate indefinitely (e.g., FILLING_FAST → OPPORTUNITY → FILLING_FAST → OPPORTUNITY) despite no session changes. Root cause: suppression logic didn't enforce the priority hierarchy - it only checked if the previous alert was the SAME type, not if it was a HIGHER priority type.

2. **Fix: Hierarchy-aware suppression**: Updated `shouldAlertOpportunity()` and `shouldAlertFillingFast()` to block "downgrades" from higher-priority alerts. OPPORTUNITY now suppressed if previous alert was FILLING_FAST, NEWLY_AVAILABLE, or SOLD_OUT. FILLING_FAST now suppressed if previous alert was NEWLY_AVAILABLE or SOLD_OUT (unless session state changed). This enforces: once a higher-priority alert fires, lower-priority alerts cannot fire unless session meaningfully changes. Added 7 comprehensive tests covering all valid state transitions and blocking invalid downgrades. See `ALERT-HIERARCHY-FIX.md` for complete analysis.

### Session 6 (2026-02-17) - DigitalOcean Production Deployment

1. **Deployment scripts skipped TypeScript**: Both `scripts/setup-server.sh` and `scripts/deploy.sh` used `npm ci --omit=dev` and `npm install --omit=dev` to install dependencies. This skipped devDependencies including TypeScript. Build step (`npm run build`) then failed with `tsc: not found` error. Root cause: TypeScript is a devDependency but required for building. **Fix**: Removed `--omit=dev` flag from both scripts. Dev dependencies are needed for builds and consume minimal disk space (~25MB on 25GB droplet). This also simplifies future rebuilds and dependency management.

2. **SSH key not loaded in agent**: First SSH attempt failed with "Permission denied (publickey)" even though SSH key was added to DigitalOcean. Root cause: SSH key wasn't loaded into local SSH agent. **Fix**: Run `ssh-add ~/.ssh/id_ed25519` before connecting. Verify with `ssh-add -l`. Added to docs/DEPLOY.md troubleshooting section.

3. **Interactive apt prompts during setup**: Running `apt upgrade` presented interactive prompt about `sshd_config` modifications: "What do you want to do about modified configuration file sshd_config?" This blocks automated setup. **Workaround**: Select "install the package maintainer's version" (Option 1) during manual setup. **Future fix**: Add `DEBIAN_FRONTEND=noninteractive` to apt commands in setup script for fully unattended installation.

4. **Repository visibility for cloning**: Attempted `git clone https://github.com/hunterleaman/adult-hockey-agent.git` failed with "Authentication failed" because repo was private. **Options**: (a) Make repo public (easiest for portfolio, all secrets in gitignored .env), or (b) Setup SSH keys on server and use `git clone git@github.com:...`. Made repo public since it's for portfolio and contains no secrets.

### Session 7 (2026-02-19) - Deployment Debugging & Config Edge Cases

1. **`npm ci` skips TypeScript on droplet after stale lockfile**: `npm ci` installs exactly what's in the lockfile. If a previous install used `--omit=dev`, the server-side lockfile state is stale and `npm ci` reproduces the broken state. `npm install` (full) fixes it. Lesson: after any dependency install flag change, run `npm install` once to reset lockfile state, then `npm ci` works correctly going forward.

2. **Config validator rejects MIN_PLAYERS_REGISTERED=0**: Setting `MIN_PLAYERS_REGISTERED=0` for testing crashes the agent because `validateConfig()` requires `> 0`. Use `MIN_PLAYERS_REGISTERED=1` for low-threshold testing. Consider whether the validator should allow 0 for testing or if 1 is the correct minimum.

3. **No structured logger exists yet**: `console.error` is the current pattern for error logging. CLAUDE.md says "no console.log in production code — use a structured logger" but no structured logger has been implemented. `console.error` is acceptable until one exists. Track as tech debt, not a violation.

### Session 8 (2026-02-20) - SSL & Domain Setup

1. **Certbot deploys SSL cert to default nginx config, not app config**: `certbot --nginx` added SSL directives to `/etc/nginx/sites-enabled/default` which serves static files, not the Express proxy. Had to manually add `proxy_pass` and related directives to the correct SSL server block in the adult-hockey-agent site config.

2. **Slack slash commands require HTTPS**: Slack will not send requests to HTTP endpoints. The `dispatch_failed` error gives no useful diagnostic. Required setting up a domain (`adult-hockey-agent.lx-labs.com`) and Let's Encrypt SSL before Slack slash commands and interactivity endpoints would work.

3. **Deploy script does not rebuild TypeScript**: `deploy.sh` pulls code but the build step may use cached output. Always run `npm run build` and `pm2 restart adult-hockey-agent` after deploy to ensure new code is active.

4. **Slack interactivity URL must not include port**: The interactivity request URL was set to `https://domain:3000/slack/interactions` which bypasses the nginx reverse proxy. Slack endpoints should use `https://adult-hockey-agent.lx-labs.com/slack/interactions` without a port since nginx proxies 443 to 3000 internally. Same applies to slash command URLs.

### Session 9 (2026-06-04) - DASH Team Rename Broke Parser (Silent Alert Outage)

1. **DASH renamed pickup teams, parser silently dropped every session**: Slack alerts went quiet for ~a week. The agent kept polling normally (health endpoint healthy, `lastPoll` current), but DASH renamed the home teams from `(PLAYERS) ADULT Pick Up` → `Adult Pickup Skater` and `(GOALIES) ...` → `Adult Pickup Goalie`. `parser.ts` filtered on the literal substring `'adult pick up'` (with a space) and classified player/goalie entries by the `(PLAYERS)`/`(GOALIES)` tags — none of which match the new names. Result: every session was discarded, `evaluate()` saw an empty list, and no alerts fired. **Fix**: match both `'adult pickup'` and `'adult pick up'` in the filter, and detect player/goalie by `Skater`/`Goalie` as well as the old `(PLAYERS)`/`(GOALIES)` tags. Added `fixtures/dash-api/events-pickup-rename.json` (live snapshot) + TDD tests. **Lesson**: parser filters keyed on human-facing strings are fragile to upstream renames; the silent empty-`catch` in `poll()` (`index.ts`) and per-notifier `catch` mean a parsing/data regression produces zero signal. Consider a heartbeat/"0 sessions found N polls in a row" warning.

2. **Diagnosis without SSH**: SSH was independently broken (local `id_ed25519` regenerated 2026-03-23 no longer matched the droplet's `authorized_keys`). Root cause was still confirmed remotely by (a) hitting `/health` (proved the agent was alive and polling), and (b) replaying the scraper's two-step DASH fetch with `curl` to see the live team names. Lesson: the public health endpoint + a manual API replay are enough to localize a data-layer bug without server access.

3. **Pre-existing date-brittle evaluator tests**: 19 tests in `evaluator.test.ts` fail because they hardcode Feb 2026 session dates and `evaluator.ts` skips sessions where `datetime < now`. Fails on `main` regardless of this fix; no production impact (production only evaluates near-future sessions). Tracked separately — make these tests compute relative future dates.

### Session 10 (2026-06-18) - DASH Tenant Migration (Second Silent Outage) + Canary

1. **Rink rebranded and migrated DASH tenants; scraper kept polling the dead one**: Extreme Ice Center became "Charlotte Ice" and moved to a new DASH tenant slug `charlotteice`. The old `extremeice` tenant still responds `200` but is a **stale mirror**: it omits the 6 AM Wed/Fri morning pickup entirely and reports `registered_count = 0` for every event. Production had `company` hardcoded to `extremeice` (`scraper.ts`), so the agent was blind again — `/health` green, polling on schedule, zero useful alerts. Same failure class as Session 9 (a value keyed to upstream identity changed). **Fix**: slug is now `config.company` (env `DASH_COMPANY`, default `charlotteice`), threaded into the scraper and both registration-URL builders (`evaluator.ts`, `commands/sessions.ts`). Confirmed by curl replay + running the compiled scraper: under `charlotteice` the Fri 6:10 AM pickup returns with real counts (19/22).

2. **This corrects the `dash-pickup-state` memory**: its conclusions "registered_count is dead for this format" and "6 AM pickup gone for summer" were **wrong** — both were artifacts of reading the stale `extremeice` tenant. The 6 AM Wed/Fri morning pickup is alive and counts are real on `charlotteice`.

3. **Added a canary (silent-outage watchdog)**: `src/health.ts` + `data/health.json` track consecutive "suspect" polls (0 sessions, or sessions with all-zero registrations). After `CANARY_THRESHOLD_POLLS` (env, default 3) it fires one Slack diagnostic via the new `Notifier.sendDiagnostic()`, suppresses until a healthy poll recovers. `poll()` was restructured so the canary runs even when a scrape throws. This is the durable fix for the "healthy but blind" failure mode that bit us in Sessions 9 and 10.

### Session 11 (2026-07-15) - Morning-Only Alerts + /review-pr Pipeline

1. **Plan snippets can contradict the spec they implement**: the plan's Task 5 specified `facility_ids=${facilityId ?? 1}`, but spec §5 requires falling back to 1 for UNRESOLVED facilities — and the degrade sentinel is `0`, which `??` passes through, producing dead `facility_ids=0` links. Spec governs; fixed with `|| 1`. Lesson: when a plan transcribes spec behavior into code snippets, verify sentinel/falsy semantics against the spec, not the snippet.

2. **`0`-vs-`undefined` sentinel inconsistency class**: `sessionKey` collapsed both to `0` while `sessionMatches` treated `0` as a concrete facility — three different meanings of zero (unknown identity, key sentinel, URL fallback). External adversarial review caught cross-rink mutation/inheritance edges the per-task reviews rated acceptable. Fixed: `0` is "unknown" in matching, and ambiguous unknown-facility matches (multiple same-slot entries) mutate nothing.

3. **Codex CLI silently outdated for server default model**: `/review-pr` Stages 2/3 failed with `The 'gpt-5.6-sol' model requires a newer version of Codex`. The protocol's API-direct fallback (auto-detected `gpt-5.6-luna`) worked and produced high-value findings. Lesson: keep the `codex` CLI upgraded; the fallback path is proven and mandatory, not optional. One transient 401 from the OpenAI API succeeded on immediate retry.

4. **Worktree can't check out a branch already checked out in the main clone**: `git checkout <branch>` in a review worktree fails with "already used by worktree". Detach at `origin/<branch>` instead and push results via `git push origin HEAD:<branch>` (fast-forward).

5. **AskUserQuestion can swallow long preceding content** (carried from Session 10 wind-down): present long content as committed files or PR comments, then ask the short question referencing them. Applied for the /review-pr consolidated findings (PR comment) — worked well.

6. **DASH team names reverted AGAIN upstream** (carried from Session 10 wind-down): Wed 6:10 is back to `(PLAYERS) Adult Pick Up Hockey (Mornings)` while PIH uses `PIH Adult Pickup Skater/Goalie`. The parser's dual-spelling filter already handles both; `facility_id` (never names) drives all location logic.

### Session 12 (2026-07-15) - Task 11 Deploy + Production Verification

1. **`/clear` truncated the wind-down handoff mid-write**: the previous session's `.remember/remember.md` Write was interrupted by `/clear`, leaving a 0-byte file. The SessionStart hook's captured `=== LAST HANDOFF ===` block preserved the content. Lesson: finish the wind-down (see "Saved.") before `/clear`; on wind-up, verify the handoff file is non-empty and rebuild it from the hook block if not.

2. **AskUserQuestion approval doesn't authorize production writes in auto mode**: the permission classifier denied `npm run clear-state` + `pm2 restart` on the droplet even though the user picked a "Controlled test now" option whose description named those actions. The user must explicitly name the destructive action in their own message ("go ahead, clear droplet state and restart") for auto mode to allow it. Design confirmations accordingly.

3. **MORNING_PICKUP in pre-deploy state is not an anomaly**: nearly misdiagnosed old droplet state containing `MORNING_PICKUP`-typed alerts as impossible for pre-PR-#15 code. `git log -S MORNING_PICKUP` showed the type shipped 2026-06-04 (7540b3c); PR #15 added the morning-only *gate* and facility/location, not the alert type. Check a symbol's introduction commit before reasoning about which deploy could have produced data.

4. **Controlled production verification pattern worked well**: `npm run clear-state` + restart forces the initial poll to re-evaluate all sessions as new — alerts fired for morning XIC sessions only (correct labels/URLs), silence for sold-out PIH 11:30s and afternoons, proving the morning gate end-to-end with one command. State was confirmed safe to clear first (`isRegistered` false, `userResponse` null everywhere).
