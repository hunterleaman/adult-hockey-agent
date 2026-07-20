# adult-hockey-agent

Monitoring agent for adult pick-up hockey registration at Charlotte Ice (formerly Extreme Ice Center) via the DaySmart DASH webapp. Alerts Slack when sessions meet configurable criteria. Production: DigitalOcean droplet, PM2 + nginx + SSL at adult-hockey-agent.lx-labs.com. Future scope: league standings, stats, scheduling.

## Stack
- TypeScript (strict, ES modules) on Node.js; functional style, injected dependencies
- Vitest + fixture files, ESLint, Prettier; Playwright (discovery scripts only)
- Slack notifications + slash commands (Express endpoints behind nginx)

## Directory Layout
```
src/       # source (scraper, parser, evaluator, notifiers, commands/)
tests/     # Vitest tests, mirror src/ structure
fixtures/  # saved DASH API/HTML snapshots for tests
data/      # runtime state (gitignored except .gitkeep)
scripts/   # server setup + deploy
docs/      # SPEC, ARCHITECTURE, CONVENTIONS, REVIEW-CHECKLIST, DECISIONS, DEPLOY, CONTRIBUTING, PITFALLS, hard-rules/
```

## Commands
```
npm run check        # quality gate: typecheck + lint + format:check + tests
npm run build        # tsc
npm run dev          # build + run scheduler locally
npm run test         # vitest
npm run clear-state  # wipe data/state.json (next poll re-evaluates all sessions)
```

## Canonical Docs
| Doc | Purpose |
|---|---|
| docs/SPEC.md | Requirements spec; read before any task |
| docs/ARCHITECTURE.md | Architecture rules, DASH JSON:API two-step fetch flow, scraper requirements |
| docs/CONVENTIONS.md | Full naming convention, code style, testing rules |
| docs/REVIEW-CHECKLIST.md | AHA-specific /review-pr checklist + verification gate |
| docs/DECISIONS.md | ADR log |
| docs/DEPLOY.md | Droplet deployment + troubleshooting |
| docs/CONTRIBUTING.md | Detailed git workflow + session protocols |

## Active Invariants (checked in /review-pr)
- DASH rate limits: minimum 30s gap between API requests; sequential, never concurrent.
- No hardcoded event IDs/dates in production code; forward window computed dynamically.
- DASH tenant slug comes from config (env DASH_COMPANY); never hardcode extremeice.
- No concurrent Playwright instances (memory constraint on $6 droplet).
- State file writes are atomic (temp + rename); state never held only in memory.
- Alerts include a direct registration URL. Never auto-purchase without explicit user approval; Phase 2 auto-registration is out of scope.
- TypeScript strict, no any; no console.log in production (console.error = tracked tech debt).

## Conventions (full matrix: docs/CONVENTIONS.md)
- Naming: always the full name `adult-hockey-agent` (system user: `adulthockey`). Never hockey-agent, hockey, or aha.
- Style: no semicolons, single quotes, 2-space indent, explicit return types on exports, `.js` extensions on relative runtime imports.
- Testing: Vitest against saved fixtures, never the live DASH site; no mocking Playwright in unit tests.

## Pitfalls & Lessons Learned
See docs/PITFALLS.md (includes Known Mistakes, Sessions 1-12); new entries go there, not here. Read before implementing related areas.

## Current State
Production on droplet: morning-only alerts + facility location deployed and verified (Session 12, 2026-07-15); canary watchdog guards the silent-outage class (Sessions 9/10). CPT kit retrofit in progress on branch cpt-retrofit-w4.

## Development Pipeline

| Phase | Action | Tool | Who |
|-------|--------|------|-----|
| 1. Design | Interrogate the feature design | `/grill-me` (or `/grill-with-docs`) | Interactive, operator answers |
| 2. PRD | Formalize as PRD GitHub issue | `/write-a-prd` | Interactive, operator reviews |
| 3. Issues | Decompose into vertical-slice issues | `/prd-to-issues` | Semi-automated, operator approves |
| 4. Implement | TDD, one branch per issue, one PR per branch | Agent dispatch (worktrees) | Automated, agents execute |
| 5. AI Review | Rebase, verify, review, fix, push clean PR | `/review-pr` | Automated, per PR |
| 5b. Codex Review | Adversarial + standard from second model | Inline in /review-pr | Automated, skips if unavailable |
| 6. Human Review | Operator reviews merge-ready PRs | GitHub PR UI | Manual, merge or reject |
| 7. Close | Close PRD issue when child issues merge | GitHub | Manual |

**Enforcement:** see `docs/hard-rules/pipeline-phase-gating.md`.

Do NOT use superpowers brainstorming or plan-writing. Use /grill-me and /write-a-prd instead.

## Operating Constraints (HARD RULES)

Read every file under docs/hard-rules/ before any non-trivial action. These bodies are mandatory context.

- **Worktree Isolation.** Main session never changes CWD; all code changes dispatch to `Agent` with `isolation: "worktree"`. -> docs/hard-rules/worktree-isolation.md
- **Build Command Discipline.** Never chain long-running commands into `&&`; run dedicated Bash calls with explicit timeout. -> docs/hard-rules/build-command-discipline.md
- **Delegate to Subagents.** Main session orchestrates; subagents do reads, greps, reviews, implementations. -> docs/hard-rules/delegate-to-subagents.md
- **CWD Discipline.** Always launch `claude` from repo root; all git in main session uses `git -C <root>`. -> docs/hard-rules/cwd-discipline.md
- **Agent Worktree Dispatch Mutex Queue.** `lib/dispatch.sh` serializes `git worktree add`; fall back to one-at-a-time when `flock` is unavailable. -> docs/hard-rules/agent-worktree-dispatch-mutex-queue.md
- **Codex CLI Only in Nested Agents.** Inside any worktree-isolated Agent, call codex via the CLI directly; never the rescue Skill or subagent. -> docs/hard-rules/codex-cli-only.md
- **Run In Background.** Every `Agent` tool call sets `run_in_background: true` for visibility and non-blocking dispatch. -> docs/hard-rules/run-in-background.md
- **Pipeline Phase Gating.** `/grill-me` is the mandatory entry point; Phases 1-3 are gated by `lib/workstream.sh` on disk. -> docs/hard-rules/pipeline-phase-gating.md

## Branching Workflow
- Feature branches for all non-trivial work; PR required for src/, tests/, config, or build changes. Direct to main only for typo/formatting/comment fixes. When uncertain, branch.
- Branch prefixes: feat/ fix/ docs/ deploy/ refactor/ test/ (e.g. feat/email-notifications).
- PR body must include `Closes #{issue-number}`. Commits reference issues.
- Features start with /grill-me -> /write-a-prd -> /prd-to-issues
- Detailed walkthroughs (merge steps, hotfixes, Conductor): docs/CONTRIBUTING.md.

## Protocols

| Command | Purpose |
|---|---|
| `/orient` | Quick session orientation; runs automatically at session start. |
| `/preflight` | Pre-flight verification before multi-agent dispatch or deployment. |
| `/verify` | Run the full verification suite end-to-end. |
| `/land` | Universal workstream landing sequence after all PRs for a wave merge. |
| `/ship` | Full quality gate, regression checks, docs update, commit, push for the current feature branch. |
| `/decide` | Apply the decision framework (accuracy > maintainability > scalability > future-proofing > client-readiness > minimal intervention). |
| `/learn` | Record a lesson learned and append to memory or `docs/PITFALLS.md`. |
| `/diagnose` | Investigate a failure or unexpected behavior via the diagnose subagent. |
| `/triage` | Sort open issues / PRs / failures into actionable buckets via the triage subagent. |
| `/improve-architecture` | Identify deep-module / refactoring opportunities via the architecture subagent. |
| `/zoom-out` | Step back from inner-loop work to re-evaluate scope and strategy. |
| `/audit-kit` | Surgical 3-way merge between project-installed kit and the canonical template. |
| `/wind-down` | Context-safe session wind-down; writes resume prompt with phase-aware DO-FIRST. |
| `/wind-up` | Resume from the last `/wind-down`; runs the workstream slug-resolution cascade. |
| `/dispatch-wave` | Parallel agent dispatch with pre-flight checks and status tracking. |
| `/tdd` | Spec-first, test-first implementation flow via the TDD subagent. |

Consumer-local commands (pre-kit, allowlisted): /check /deploy-check /implement-issue /known-mistakes /session-end.

## Context Discipline
- Cap research-agent responses (under 200 words for lookups, 500 for investigations).
- Run /wind-down proactively before the harness auto-compacts.

## Integration Verification
**Built is not Wired is not Deployed.** New module/hook/route: verify it is registered in entry points, callable from consuming code, and runs end-to-end before claiming done.

## Communication Style
Extremely concise. Lead with the action or answer; one-line status updates; never narrate tool calls. Commits and PR descriptions dense and factual.

## Session Protocols
- Start: /orient; `gh issue list`; state the session goal.
- End, branch in flight: /ship. `npm run check` must pass; commit; push (work is NOT done until push succeeds).
- End, wave fully merged: /land.
- Docs on the way out: docs/SPEC.md if requirements changed, docs/PITFALLS.md for mistakes, ADR in docs/DECISIONS.md, docs/sessions/YYYY-MM-DD-topic.md for complex fixes. Detail: docs/CONTRIBUTING.md.

## Development Methodology: Spec-Driven, Test-First
Read docs/SPEC.md before starting any task. Spec -> failing test -> implement until green -> verify against spec -> refactor under green. Tests are the acceptance criteria.

## Error-to-Learning Protocol
Workaround discovered or same error twice in a session: append to docs/PITFALLS.md as `- **{Title}.** {Explanation}. {Why it matters}.` Use /learn for quick capture. Skip transient errors.

## Commit Convention
`{type}({scope}): {description}` -- types: feat, fix, docs, refactor, deploy, test, chore.
