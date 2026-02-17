# Organizational Improvements - 2026-02-17

## Issues Identified

### 1. Inconsistent Documentation Updates

**Problem**: Multiple documentation files with unclear purposes and inconsistent updates:
- `decisions.md`: Last updated Feb 12 (initialization only)
- `LEARNINGS.md`: Last updated Feb 13
- `README.md`: Last updated Feb 13
- `CLAUDE.md`: Updated Feb 17 (active)
- `SESSION-2026-02-17.md`: Ad-hoc session notes
- `ALERT-HIERARCHY-FIX.md`: Ad-hoc technical deep-dive

**Root Cause**: No clear protocol for WHEN and WHERE to document different types of information.

### 2. Session-Specific Files in Root Directory

**Problem**: `SESSION-2026-02-17.md` and `ALERT-HIERARCHY-FIX.md` added to root directory, creating clutter.

**Better Organization**: These should live in `docs/sessions/` or be consolidated into existing files.

### 3. Trash in `fixtures/api-discovery/`

**Problem**: Contains Google Maps API calls and unrelated network captures:
- `$rpc_google.internal.maps.mapsjs.v1.MapsJsInternalService_GetViewportInfo_1770929181327.json`
- `maps_api_mapsjs_gen_204_1770929180358.json`
- `6_1770929181864.json` (unclear purpose)
- `dash_2026-02-13.png` (screenshot - useful but wrong location)

**Impact**: Makes it unclear which files are relevant DASH API responses vs noise.

### 4. Scheduler.ts Line 82 Error (RESOLVED)

**Problem**: Line 82 had `main()` without `void` operator, causing ESLint `no-floating-promises` error.

**Fix Applied**: Changed to `void main()` to explicitly mark promise as intentionally not awaited (top-level execution).

---

## Proposed Documentation Structure

### Clear Separation of Concerns

```
/
├── README.md              → Project overview, quick start, high-level architecture
├── CLAUDE.md              → AI agent instructions (current sessions, known mistakes)
├── spec.md                → Product requirements specification
│
├── docs/
│   ├── decisions.md       → Architecture Decision Records (ADRs) - long-term choices
│   ├── sessions/          → NEW: Session-specific notes and deep-dives
│   │   ├── 2026-02-17-alert-hierarchy-fix.md
│   │   ├── 2026-02-17-session-summary.md
│   │   └── YYYY-MM-DD-topic.md
│   └── api/               → NEW: API documentation
│       ├── dash-jsonapi-guide.md
│       └── event-response-examples.json
│
├── fixtures/
│   ├── dash-api/          → RENAMED from api-discovery, cleaned up
│   │   ├── date-availabilities.json
│   │   ├── events_2026-02-13.json
│   │   └── README.md (explains what these are)
│   └── screenshots/       → NEW: Visual references
│       └── dash_2026-02-13.png
│
└── .claude/
    ├── memory/
    │   └── MEMORY.md      → Auto-memory for persistent agent context
    └── project/           → Claude Code project-specific settings (if needed)
```

### Documentation Protocols

#### When to Update Each File

**`README.md`**
- Update when: Public-facing information changes (how to install, run, configure)
- Frequency: Major releases or feature additions
- Audience: External users

**`CLAUDE.md`**
- Update when: Agent makes mistakes requiring course-correction
- Frequency: After each coding session with issues
- Audience: Claude Code agent
- Content: Known mistakes, workarounds, architectural rules

**`docs/decisions.md`**
- Update when: Non-obvious architectural choice made (e.g., dynamic scheduler vs cron)
- Frequency: When making design decisions with trade-offs
- Audience: Future developers (including you)
- Format: ADR (context, decision, consequences)

**`docs/sessions/YYYY-MM-DD-*.md`**
- Update when: Session produces complex fixes or learnings worth deep-dive
- Frequency: End of sessions with significant work
- Audience: Historical reference
- Content: Problem analysis, solutions, validation

**`LEARNINGS.md`** (DEPRECATE?)
- **Proposal**: Consolidate into `CLAUDE.md` Known Mistakes or `docs/sessions/`
- Reason: Redundant with CLAUDE.md's session logs

---

## Recommended Actions

### Immediate Cleanup

1. **Move session files to docs/sessions/**
   ```bash
   mkdir -p docs/sessions
   mv SESSION-2026-02-17.md docs/sessions/2026-02-17-session-summary.md
   mv ALERT-HIERARCHY-FIX.md docs/sessions/2026-02-17-alert-hierarchy-fix.md
   ```

2. **Clean up fixtures/api-discovery/**
   ```bash
   mkdir -p fixtures/screenshots
   mv fixtures/api-discovery/dash_2026-02-13.png fixtures/screenshots/
   rm fixtures/api-discovery/$rpc_google.internal.maps*
   rm fixtures/api-discovery/maps_api*
   rm fixtures/api-discovery/6_*.json
   mv fixtures/api-discovery fixtures/dash-api
   ```

3. **Add ADRs to decisions.md** for recent architectural changes:
   - Dynamic scheduler (setTimeout vs cron)
   - Alert hierarchy enforcement in suppression logic
   - ESLint integration

4. **Update README.md** with:
   - Current feature set (monitoring, alerts, accelerated polling)
   - Project status
   - Recent improvements

### Long-Term Protocol

**Session-End Checklist (add to CLAUDE.md):**

```markdown
## Session-End Protocol

1. **Code Quality**
   - Run tests, lint, type-check
   - Format code with prettier
   - Commit with descriptive message
   - Push to remote

2. **Documentation**
   - Update CLAUDE.md Known Mistakes if errors occurred
   - Add ADR to docs/decisions.md for architectural choices
   - Create docs/sessions/YYYY-MM-DD-topic.md for complex fixes

3. **Cleanup**
   - Remove temporary files
   - Organize fixtures appropriately
   - Run npm audit and address critical vulnerabilities

4. **Handoff**
   - Summarize accomplishments
   - Note remaining work
```

---

## .claude Directory

**Current State**: Contains only `memory/MEMORY.md` (auto-memory for agent)

**Should There Be More?**

**Potentially Useful:**
- `project/settings.json` - Project-specific Claude Code settings (if needed)
- `project/prompts/` - Custom prompt templates (if reusable patterns emerge)

**Not Needed (Yet):**
- Config files (already in .env)
- Logging files (stdout/stderr to systemd journal in production)
- Protocol files (documented in CLAUDE.md, no need for separate files)

**Recommendation**: Keep minimal. Add only if specific Claude Code features require project-level config.

---

## npm audit Vulnerabilities

**Current State**: 7 moderate severity vulnerabilities (from npm uninstall output)

**Action Required**: Run `npm audit` to identify issues, then:
1. Update vulnerable packages if possible
2. Document if vulnerabilities are in dev dependencies only
3. Add to CLAUDE.md if manual workarounds needed

---

## Summary

**Core Problem**: Documentation fragmentation without clear protocols.

**Solution**: Establish clear "what goes where" rules and follow them consistently.

**Key Principle**: Each file should have a single, clear purpose. If you're unsure where something goes, it probably belongs in `docs/sessions/` for historical reference.
