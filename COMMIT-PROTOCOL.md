# Commit Protocol

## MANDATORY Pre-Commit Checklist

**NEVER commit without running:**

```bash
npm run check
```

This runs (in order):
1. `npm run typecheck` - TypeScript compilation check
2. `npm run lint` - ESLint static analysis
3. `npm run format:check` - Prettier formatting check
4. `npm test -- --run` - All unit/integration tests

## Why This Matters

**Today's Failure**: Committed code with ESLint errors because tests alone were run.

**Root Cause**: Tests (Vitest) validate runtime logic, but don't check:
- Code style violations
- Type safety issues
- Unused variables
- Floating promises
- Other static analysis concerns

## What Gets Checked Where

| Check | Tool | Catches |
|-------|------|---------|
| **Runtime Logic** | Vitest | Business logic errors, incorrect behavior |
| **Type Safety** | TypeScript | Type mismatches, missing properties |
| **Code Quality** | ESLint | Anti-patterns, unused vars, floating promises |
| **Formatting** | Prettier | Inconsistent style, spacing |

**All four must pass before commit.**

## Documentation Protocol (from ORGANIZATIONAL-IMPROVEMENTS.md)

### When to Update Each File

**`README.md`** - Update when public-facing info changes
- Installation/setup instructions
- How to run/configure
- High-level architecture overview
- Frequency: Major releases

**`CLAUDE.md`** - Update after each session with issues
- Known mistakes requiring course-correction
- Architectural rules for the agent
- Session-end protocols
- Frequency: After coding sessions

**`docs/decisions.md`** - Update for architectural choices
- Non-obvious design decisions
- Technology choices with trade-offs
- Use ADR format (context, decision, consequences)
- Frequency: When making design decisions

**`docs/sessions/YYYY-MM-DD-*.md`** - Create for complex work
- Detailed problem analysis
- Solution approaches considered
- Validation and testing notes
- Frequency: End of sessions with significant fixes

### File Organization

```
/
├── CLAUDE.md              → AI agent instructions
├── README.md              → Public documentation
├── spec.md                → Requirements
├── COMMIT-PROTOCOL.md     → This file
│
├── docs/
│   ├── decisions.md       → ADRs (long-term choices)
│   └── sessions/          → Session-specific deep-dives
│
└── fixtures/
    ├── dash-api/          → DASH API response samples
    └── screenshots/       → Visual references
```

## Enforcement

**Future Improvement**: Add pre-commit hooks (husky) to run checks automatically.

**For Now**: Manual discipline - run `npm run check` before every commit.
