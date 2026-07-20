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

---

## Migrated from CLAUDE.md (2026-07-20, CPT slim-pointer migration)

Sections below were relocated from CLAUDE.md so the root doc can stay in CPT slim pointer form. Body text is verbatim. Where they say "update CLAUDE.md Known Mistakes", read: append to docs/PITFALLS.md instead.

### Conductor Workflow (Feature Branches)

Development uses [Conductor](https://conductor.build) for parallel feature branches with Claude Code (Opus). Each workspace is an isolated git worktree with its own branch, dependencies, and build.

**Cycle:**
1. **⌘N** — Create workspace (auto-creates branch from origin/main, runs setup script)
2. Prompt Claude with the task, referencing spec docs and CLAUDE.md
3. **⌘D** — Review diffs before committing
4. **⌘R** — Run quality checks (`npm run check`)
5. **⌘⇧P** — Create Pull Request
6. Merge PR on GitHub, then archive the workspace

Multiple workspaces run simultaneously for independent features.

**Small changes** (docs, config, formatting): Use Claude Code CLI directly on main. Conductor workspaces are for feature branches that deserve PRs.

## Git Branching Workflow

**CRITICAL**: Always use feature branches for new work. Never commit directly to `main` except for trivial documentation fixes.

### Branch Naming Convention

- `feat/` - New features (e.g., `feat/email-notifications`, `feat/league-standings`)
- `fix/` - Bug fixes (e.g., `fix/alert-oscillation`, `fix/parser-error`)
- `docs/` - Documentation only (e.g., `docs/update-readme`, `docs/api-guide`)
- `deploy/` - Deployment/infrastructure (e.g., `deploy/verify-digitalocean`, `deploy/nginx-ssl`)
- `refactor/` - Code refactoring (e.g., `refactor/parser-types`, `refactor/state-management`)
- `test/` - Test additions/fixes (e.g., `test/evaluator-coverage`)

### Workflow for New Tasks

**BEFORE starting any non-trivial work:**

```bash
# Create and switch to feature branch
git checkout -b feat/descriptive-name

# Push branch to remote immediately (sets upstream tracking)
git push -u origin feat/descriptive-name
```

**DURING work:**

```bash
# Commit frequently with descriptive messages
git add <files>
git commit -m "feat: descriptive message"

# Push to feature branch (not main!)
git push origin feat/descriptive-name
```

**AFTER testing and verification:**

```bash
# Switch back to main
git checkout main

# Pull latest changes (in case main was updated)
git pull origin main

# Merge feature branch (--no-ff preserves branch history)
git merge feat/descriptive-name --no-ff

# Push to main
git push origin main

# Clean up local branch
git branch -d feat/descriptive-name

# Clean up remote branch
git push origin --delete feat/descriptive-name
```

### When to Branch

**ALWAYS use branches for:**
- New features (any new functionality)
- Bug fixes (fixing broken behavior)
- Deployment changes (infrastructure, configs)
- Refactoring (changing code structure)
- Dependency updates (package.json changes)

**MAY commit directly to `main` for:**
- Typo fixes in documentation (1-2 word changes)
- Formatting fixes (prettier, lint auto-fixes)
- Comment clarifications

**NEVER commit directly to `main` for:**
- Code changes (src/)
- Test changes (tests/)
- Configuration changes (.env.example, ecosystem.config.cjs)
- Build changes (package.json, tsconfig.json)

### Pull Requests (Optional but Recommended)

For significant features, consider creating a GitHub Pull Request instead of merging locally:

```bash
# After pushing branch to remote
# Go to: https://github.com/hunterleaman/adult-hockey-agent/pulls
# Click "New Pull Request"
# Select: base: main <- compare: feat/your-branch
# Add description, review changes, merge via GitHub UI
```

**Benefits of PRs:**
- Visual diff review before merging
- GitHub checks (if configured)
- Conversation history for future reference
- Better for portfolio (shows collaboration skills)

### Emergency Hotfixes

For critical production bugs:

```bash
# Create hotfix branch from main
git checkout main
git checkout -b fix/critical-issue

# Fix, test, commit
git commit -m "fix: critical issue description"

# Merge immediately (no waiting for review)
git checkout main
git merge fix/critical-issue --no-ff
git push origin main
```

### Verification Before Merging to Main

Before merging any branch to `main`, ensure:

1. ✅ All tests pass: `npm run check`
2. ✅ Code builds successfully: `npm run build`
3. ✅ No console.log statements in production code
4. ✅ Documentation updated (README.md, CLAUDE.md if needed)
5. ✅ Commit messages follow conventional commits format
6. ✅ CLAUDE.md updated with any new Known Mistakes

**Rule of thumb**: If you're uncertain whether to branch, branch. It's easier to merge a branch than to revert a bad commit to `main`.

## Session-Start Protocol (mandatory at the beginning of every session)

1. ✅ `gh issue list --repo hunterleaman/adult-hockey-agent`
2. ✅ Review what's in progress, what's next
3. ✅ State session goal in first message to Claude

## Session-End Protocol (mandatory before ending any session)

**CRITICAL: Run quality checks first**

```bash
npm run check
```

This runs: typecheck + lint + format:check + test

### Code Quality

1. ✅ `npm run check` — ALL must pass before commit
2. ✅ Fix any failures
3. ✅ Commit with descriptive message (conventional commits format)
4. ✅ `git push` — work is NOT done until push succeeds

### Documentation

5. ✅ Update `docs/SPEC.md` if requirements changed
6. ✅ Update CLAUDE.md "Known Mistakes" if errors occurred
7. ✅ Add ADR to `docs/DECISIONS.md` for architectural choices
8. ✅ Create `docs/sessions/YYYY-MM-DD-topic.md` for complex fixes

### Handoff

9. ✅ Summarize what was accomplished
10. ✅ Note remaining work for next session
11. ✅ Update issue comments with progress if work is incomplete
12. ✅ `gh issue list` to confirm issue state matches reality
