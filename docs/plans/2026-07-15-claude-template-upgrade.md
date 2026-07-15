# Plan: .claude/ Upgrade from claude-project-template

Branch: `feat/claude-template-upgrade`. Source: `~/GitHub/claude-project-template` @ 024b2f3
(== origin/main, clean). Mechanism: `bootstrap.sh` (idempotent, preserve-existing default),
then fill `.claude/.config`, then `lib/substitute.sh render-all`. Ongoing upgrades via
`/audit-kit` (3-way merge anchored on `.claude/.template-version`).

## What the kit installs (net-new here)

- 8 hooks (commit-convention enforcement, context-budget tracker, worktree-clean guard,
  session-start orient, stop checklist, read auto-limit, python inspect allow, post-compact)
  wired via `.claude/settings.json` → symlink to project-local `templates/settings.json`
- 21 commands + 13 supplements (pipeline: /grill-me → /write-a-prd → /prd-to-issues →
  /dispatch-wave; /tdd, /diagnose, /verify, /ship, /land, /orient, /wind-down, /wind-up,
  /learn, /decide, /audit-kit …)
- `docs/hard-rules/` (8 files), `docs/PITFALLS.md`, `lib/` (probe, substitute, workstream,
  kit-detect), `.workstream/` ledger dir, placeholder machinery (`.claude/.config` + schema)
- Preserved (exists here, bootstrap skips): `CLAUDE.md`, `docs/DECISIONS.md`,
  `docs/CHANGELOG.md`, `.claude/settings.local.json`

## Verified blockers (must fix in-plan)

1. **.gitignore swallows the kit**: line 34-35 `.claude/*` + `!.claude/commands/` only.
   `git check-ignore` confirms hooks, settings.json symlink, .config, .template-version,
   .template-meta, commands-supplements would be untracked → absent in clones/worktrees.
   Fix: add unignore rules before bootstrap.
2. **First /audit-kit hard-fails**: needs 6 helper libs in one dir; bootstrap ships only 4,
   and `~/.cache/claude-project-template` is stale (2026-04-30, no lib/ at all).
   Fix: `git -C ~/.cache/claude-project-template fetch && reset --hard origin/main` first.
3. **render-all clobbers our adapted review-pr.md**: `cmd_render_all` overwrites any
   `.claude/commands/*` that has a canonical counterpart — our 262-line bv3-adapted
   /review-pr would be destroyed. No per-file exclude exists. Also: our 5 small commands
   (check, deploy-check, implement-issue, known-mistakes, session-end) are "orphans" →
   render-all exits 1 while they sit in `.claude/commands/`.

## .claude/.config fill (6 null keys)

| Key | Value |
|---|---|
| BUILD_COMMAND / LONG_BUILD_COMMAND | `npm run build` |
| QUALITY_GATE_FAST_STEPS / QUALITY_GATE_ONE_LINER | `npm run check` |
| POST_BUILD_CHECKS | dist/index.js + dist/scraper.js + dist/session-identity.js exist; scrapeEvents exported; grep-ban `company=extremeice` in src |
| PIPELINE_SENTINEL_FILE | `dist/index.js` |

Probe-seeded: PROJECT_NAME=adult-hockey-agent, TEST_COMMAND=npm run test.
Defaults: LONG_BUILD_TIMEOUT_MS=600000, APPEND_ONLY_FILES=docs/CHANGELOG.md+DECISIONS.md,
MAX_DEFERRED_CONSIDERS=5.

## Operator decisions needed

### D1 — Is this the template's "cpt-kit-harvest Wave 4"?
The template repo has an in-flight workstream (PRD #90, issues #91-#104) whose final wave
(#104) is literally "HITL AHA acceptance" — a planned install into THIS repo. Doing a manual
upgrade now either IS that wave (coordinate/record it there) or races it.

### D2 — review-pr policy
- **(a) Migrate to canonical** + express repo-specifics via POST_BUILD_CHECKS config.
  Clean Tier 0 invariant; /audit-kit upgrades flow. LOSES: Session 9/10 rename-fragility
  checklist items and the codex-rescue main-session caveat (no config slot) — would need
  re-homing into CLAUDE.md/supplement.
- **(b) Keep our adapted file**: rename to e.g. `review-pr-aha.md` (orphan) so canonical
  `review-pr.md` renders cleanly beside it, or keep name and never run render-all naively
  (fragile; every .config edit risks a clobber).

### D3 — our 5 small commands
- **(a) Fold into kit equivalents**: /verify≈check+deploy-check, /ship≈session-end,
  /learn≈known-mistakes; implement-issue ≈ pipeline commands. Orphans gone → render-all
  and verify-all green.
- **(b) Keep as orphans**: familiar muscle memory, but render-all exits 1 forever
  (cosmetic-ish, breaks the kit's own quality gate).

## Execution sequence (after decisions)

1. Fix .gitignore unignore rules; commit.
2. Refresh ~/.cache/claude-project-template.
3. Run `bash ~/GitHub/claude-project-template/bootstrap.sh` from repo root (NO --overwrite).
4. Apply D2/D3 file moves/renames.
5. Fill 6 null keys in `.claude/.config`; run `lib/substitute.sh render-all .claude/.config`;
   `verify-all` must pass.
6. Hand-fill `docs/hard-rules/build-command-discipline.md` tokens (render-all doesn't
   cover docs/).
7. Merge kit CLAUDE.md sections (pipeline table, HARD RULE pointers, protocols table) into
   our CLAUDE.md by hand — bootstrap preserves ours.
8. Smoke-test: new session → session-start-orient hook, /orient, /verify; codex companion
   resolution for canonical /review-pr Stages 2-3.
9. `npm run check`; commit; PR.

## Known accepted gaps

- `lib/dispatch.sh` not shipped by bootstrap (dispatch-wave degrades to naked
  `git worktree add`) — accept, or hand-copy later.
- `lib/workstream.sh` needs bash 4+ (flock); stock macOS bash 3.2 degrades gate checks.
- PRIMARY_LANGUAGE probe key absent from schema — preserved-with-warning, cosmetic.
- codex CLI currently 0.144.4 == latest (Session 11 staleness resolved).
