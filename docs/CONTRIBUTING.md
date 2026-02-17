# Contributing to Adult Hockey Agent

## Pre-Commit Quality Checks

**MANDATORY: Run before every commit**

```bash
npm run check
```

This runs (in order):
1. `npm run typecheck` - TypeScript compilation
2. `npm run lint` - ESLint static analysis  
3. `npm run format:check` - Prettier formatting
4. `npm test -- --run` - All tests

### Why All Four?

| Check | Tool | Purpose |
|-------|------|---------|
| **Runtime Logic** | Vitest | Business logic, behavior correctness |
| **Type Safety** | TypeScript | Type mismatches, missing properties |
| **Code Quality** | ESLint | Anti-patterns, unused vars, async issues |
| **Formatting** | Prettier | Consistent style |

**All must pass.** Don't commit if any fail.

## Documentation Guidelines

### When to Update Each File

**`README.md`** (root) - Update for users/public
- Installation and setup instructions
- How to run and configure
- High-level architecture overview
- Update frequency: Major releases

**`CLAUDE.md`** (root) - Update after sessions with issues
- Known mistakes requiring course-correction
- Architectural rules for AI agent
- Session-end protocols
- Update frequency: After each coding session

**`docs/SPEC.md`** - Update when requirements change
- Product requirements specification
- Feature definitions
- Alert rules and thresholds
- Update frequency: When scope changes

**`docs/DECISIONS.md`** - Update for architectural choices
- Architecture Decision Records (ADRs)
- Technology choices with trade-offs
- Non-obvious design decisions
- Update frequency: When making design decisions

**`docs/sessions/`** - Create for complex work
- Detailed problem analysis
- Solution approaches considered
- Validation and testing notes
- Update frequency: After complex fixes/investigations

## Commit Message Format

Use conventional commits format:

```
<type>: <short summary>

<detailed description>

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>
```

**Types**: `fix`, `feat`, `docs`, `refactor`, `test`, `chore`

## Development Workflow

1. **Create feature branch** (optional for solo dev)
2. **Make changes** following architectural rules in CLAUDE.md
3. **Run quality checks**: `npm run check`
4. **Commit** with descriptive message
5. **Push** to remote

## Session-End Protocol

At end of coding session:

1. ✅ Run `npm run check` - fix all failures
2. ✅ Commit with descriptive message
3. ✅ Push to remote
4. ✅ Update CLAUDE.md if mistakes were made
5. ✅ Add ADR to docs/DECISIONS.md for architectural choices
6. ✅ Create docs/sessions/YYYY-MM-DD-topic.md for complex work

## File Organization

```
/
├── README.md              → User-facing documentation
├── CLAUDE.md              → AI agent instructions
│
├── docs/
│   ├── SPEC.md            → Requirements specification
│   ├── DECISIONS.md       → Architecture Decision Records
│   ├── CONTRIBUTING.md    → This file
│   └── sessions/          → Session-specific deep-dives
│
├── src/                   → Source code
├── tests/                 → Test files
└── fixtures/              → Test fixtures and reference data
```

## Getting Help

- Check `README.md` for setup and usage
- Check `docs/SPEC.md` for feature requirements
- Check `CLAUDE.md` for known issues and architectural rules
- Check `docs/DECISIONS.md` for why things are built a certain way
