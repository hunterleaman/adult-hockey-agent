# adult-hockey-agent Review Checklist

Project-specific supplement to the canonical /review-pr command. Recovered on 2026-07-20 from the superseded local /review-pr fork (git 68ab574, .claude/commands/review-pr.md) during the CPT slim-pointer migration. Body text is verbatim from the fork. The fork's "Known Mistakes in CLAUDE.md" convention is superseded: pitfalls now live in docs/PITFALLS.md.

## Verification gate

Run the full quality gate BEFORE reviewing code. Failures here are MUST FIX.

Fast suite (single dedicated Bash call — `npm run check` = typecheck + lint + format:check + all tests):

```bash
npm run check
```

Long build (dedicated Bash call, timeout 120000, never chained):

```bash
npm run build
```

Post-build verification + regression greps (single Bash call). Scope note: `src/api-discovery.ts`, `src/fetch-events.ts`, `src/fetch-availabilities.ts` are documented throwaway discovery tools and `src/notifiers/console.ts` legitimately writes to console — greps target production files only.

```bash
test -f dist/index.js && test -f dist/scraper.js && test -f dist/session-identity.js \
  && node -e "import('./dist/scraper.js').then((m) => { if (typeof m.scrapeEvents !== 'function') { console.error('scrapeEvents export missing'); process.exit(1) } })" \
  && ! grep -rn "company=extremeice" src/scraper.ts src/evaluator.ts src/config.ts src/index.ts src/commands/
```

## Checklist

### A. Project rules (docs/CONVENTIONS.md, docs/ARCHITECTURE.md, CLAUDE.md invariants)
Read and verify each against the diff:
- **Naming Convention** (always `adult-hockey-agent`; `adulthockey` for system users)
- **Architecture Rules** (strict TS, no `any`, error handling with retry, no console.log in production code — `console.error` tolerated as tracked tech debt, state persisted to JSON atomically, injected dependencies)
- **Constraints** (DASH rate limits: 30s gap, sequential requests; alert messages include registration URL; no auto-purchase; dynamic dates — no hardcoded event IDs/dates in production code)
- **Code Style** (no semicolons, single quotes, 2-space indent, explicit return types on exports, `.js` extensions on relative runtime imports)

### B. Code Quality
- No security vulnerabilities (injection, XSS, OWASP top 10)
- No over-engineering or unnecessary abstractions
- Error handling only at system boundaries
- No dead code, unused imports, commented-out blocks
- Consistent style with surrounding code

### C. Known Pitfalls
- Read docs/PITFALLS.md (Lessons Learned + Known Mistakes, all sessions) and review every item against the diff. Pay special attention to the Session 9/10 class: logic keyed on human-facing strings that upstream renames silently break.
