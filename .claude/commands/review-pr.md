Comprehensive code review of a PR with conflict resolution, full verification, adversarial and baseline Codex reviews, and automated fixes. If $ARGUMENTS contains a PR number, review that PR. If empty, review the current branch's open PR.

Adapted for adult-hockey-agent from the CPT/bv3 canonical `/review-pr` (buy.vodka-v3 @ 2026-05-18). This is the quality gate between agent implementation and human merge. **All stages are non-optional.**

## Hard rules

- Never merge. Human merges.
- Never skip a stage.
- Never `--no-verify`. Never disable a failing check to make it pass.
- Force-push only to feature branches and only with `--force-with-lease`. Never to main.
- Max 3 fix-loop iterations through Stages 5-7. On the third consecutive failure, stop and report the full diagnosis.
- If adversarial review reveals the design is fundamentally wrong, stop and report rather than silently pivoting.

## Stage 0: Setup worktree

Review work MUST happen in an isolated worktree.

```bash
gh pr view $ARGUMENTS --json headRefName --jq .headRefName
```

Enter a worktree: `EnterWorktree` with name `review-pr-{number}`.

Inside the worktree:

```bash
git fetch origin <branch-name>
git checkout <branch-name>
git fetch origin main
git rebase origin/main
```

If rebase conflicts arise:
1. For **append-only files** (docs/DECISIONS.md, CLAUDE.md "Known Mistakes" section): keep BOTH entries in chronological order
2. For **code conflicts**: read both sides, understand intent, merge correctly
3. After each resolution: `git add <file> && git rebase --continue`
4. After full rebase: `git push --force-with-lease origin HEAD`

If rebase succeeds cleanly, proceed without force-push.

## Stage 1: Claude review (enumerate only, do not fix yet)

### Verification gate

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

### CI failure inspection

```bash
gh pr checks $ARGUMENTS
gh run view <run-id> --log-failed
```

Before classifying a failing check as MUST FIX, confirm the failure does not already exist on `origin/main`. Pre-existing failures are out of scope; record as CONSIDER with a note to file a separate issue. (If this repo has no CI checks configured, record "no CI configured" and move on.)

### Diff review

```bash
gh pr diff $ARGUMENTS
gh pr view --json number,title,body
```

Read the PR description and all changed files in full (not just the diff).

### Checklist

#### A. Project rules (from CLAUDE.md)
Read and verify each against the diff:
- **Naming Convention** (always `adult-hockey-agent`; `adulthockey` for system users)
- **Architecture Rules** (strict TS, no `any`, error handling with retry, no console.log in production code — `console.error` tolerated as tracked tech debt, state persisted to JSON atomically, injected dependencies)
- **Constraints** (DASH rate limits: 30s gap, sequential requests; alert messages include registration URL; no auto-purchase; dynamic dates — no hardcoded event IDs/dates in production code)
- **Code Style** (no semicolons, single quotes, 2-space indent, explicit return types on exports, `.js` extensions on relative runtime imports)

#### B. Code Quality
- No security vulnerabilities (injection, XSS, OWASP top 10)
- No over-engineering or unnecessary abstractions
- Error handling only at system boundaries
- No dead code, unused imports, commented-out blocks
- Consistent style with surrounding code

#### C. Known Pitfalls
- Read CLAUDE.md "Known Mistakes" (all sessions) and review every item against the diff — this repo's equivalent of docs/PITFALLS.md. Pay special attention to the Session 9/10 class: logic keyed on human-facing strings that upstream renames silently break.

### Classify Stage 1 findings

- **MUST FIX**: project-rule violation, security issue, broken functionality, failing CI
- **SHOULD FIX**: code quality, missed edge cases, style inconsistency
- **CONSIDER**: suggestions, minor improvements

Record findings. Do NOT fix yet.

## Resolving `codex-companion.mjs` (shared by Stages 2 and 3)

Stages 2 and 3 shell out to `codex-companion.mjs`. Resolve the script path once, in order of preference:

1. `${CLAUDE_PLUGIN_ROOT}/scripts/codex-companion.mjs`: set when running inside the Claude Code plugin runtime.
2. `${CODEX_COMPANION_PATH}`: operator override, set in shell profile to run outside the plugin.
3. First match of `ls -1 ${HOME}/.claude-lx/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs | sort -V | tail -n1`: picks the newest installed version from the plugin cache.

If none resolve, stop and report. Do not skip Stages 2 or 3. Ask the operator to install the openai-codex plugin or export `CODEX_COMPANION_PATH`.

Capture the resolved path as `$CODEX` for the stages below.

### Model resolution (used by API direct fallback)

Auto-detects the latest OpenAI flagship model. No manual updates when new models ship.

```bash
# Override: OPENAI_REVIEW_MODEL forces a specific model, skipping auto-detect.
# Auto-detect: queries OpenAI API, picks latest flagship, caches 24h in /tmp.
# Fallback: gpt-5.5 if API is unreachable and no cache exists.
REVIEW_MODEL="${OPENAI_REVIEW_MODEL:-}"
if [ -z "$REVIEW_MODEL" ]; then
  _CACHE="/tmp/openai-review-model-cache"
  if [ -f "$_CACHE" ] && [ -n "$(find "$_CACHE" -mmin -1440 2>/dev/null)" ]; then
    REVIEW_MODEL=$(cat "$_CACHE")
  elif [ -n "${OPENAI_API_KEY:-}" ]; then
    REVIEW_MODEL=$(curl -sf https://api.openai.com/v1/models \
      -H "Authorization: Bearer $OPENAI_API_KEY" \
      | python3 -c "
import sys, json
data = json.load(sys.stdin).get('data', [])
skip = {'mini','preview','audio','realtime','embed','tts','whisper','dall','search'}
flagships = [m for m in data if m['id'].startswith('gpt-')
             and not any(s in m['id'] for s in skip)]
print(max(flagships, key=lambda m: m.get('created',0))['id'] if flagships else '')
" 2>/dev/null) || true
    [ -n "$REVIEW_MODEL" ] && echo "$REVIEW_MODEL" > "$_CACHE"
  fi
  REVIEW_MODEL="${REVIEW_MODEL:-gpt-5.5}"
fi
echo "Review model: $REVIEW_MODEL"
```

Codex CLI stages omit `--model` and let the server pick its default. The API direct fallback uses `$REVIEW_MODEL`.

## Stage 2: Codex adversarial review

Purpose: challenge the implementation approach, design choices, tradeoffs, assumptions. Not a stricter defects pass. Ask: is this the right approach? What assumptions does it depend on? Where does the design fail under real-world conditions?

```bash
node "$CODEX" adversarial-review --wait --base origin/main --scope branch
```

Capture stdout verbatim. Parse findings into the MUST / SHOULD / CONSIDER schema. If the command exits non-zero or times out, fall back to the API direct path below.

## Stage 3: Codex normal review

Purpose: baseline pass for implementation defects, style, common pitfalls that Claude misses due to familiarity bias.

```bash
node "$CODEX" review --wait --base origin/main --scope branch
```

Capture stdout verbatim. Parse findings. Same failure policy as Stage 2.

### API direct fallback (mandatory if Codex CLI fails)

If either Stage 2 or 3 fails (quota, timeout, CLI not installed), fall back to the OpenAI API directly using the same `REVIEW_MODEL` (this repo has no `scripts/openai_adversarial_review.py`; compose the request inline with the branch diff and the same MUST/SHOULD/CONSIDER schema).

**Main-session-only fallback.** If `/review-pr` is running in the **main session** (not inside a worktree-isolated `Agent`), the `codex:codex-rescue` subagent is also a valid path. Do NOT use it from a nested Agent — `CLAUDE_PLUGIN_ROOT` is not propagated, the rescue subagent silently no-ops, and empty output is observationally identical to "codex found nothing." From a nested Agent, only the `codex` CLI / `node "$CODEX"` / API direct paths are valid.

If all valid paths fail (no Codex CLI, no `OPENAI_API_KEY`), do NOT mark the PR ready. Report: "Second-opinion review: BLOCKED."

Note: Codex CLI uses ChatGPT subscription quota. API direct uses `OPENAI_API_KEY` (separate billing). Quota exhaustion on one does not affect the other.

## Stage 4: Consolidate findings

Merge all stages into a single findings list. De-duplicate overlapping findings. Present as one coherent set, tagged by originating stage.

## Stage 5: Implement fixes

Fix every MUST FIX and SHOULD FIX.

### CONSIDER findings — default = fix in this PR

CONSIDER findings are **fixed in this PR by default**. Filing as a follow-up issue is the **exception**, not the default, and requires an explicit operator-typed token.

**Procedure for each CONSIDER:**

1. Present the finding to the operator with file:line citation + 1-line rationale.
2. The operator MUST respond with one of:
   - `FIX` — fold into this PR (default; you fix and re-run Stage 6).
   - `DEFER:<reason>` — file as a follow-up issue with label `consider-deferred`. The `<reason>` is required free-text justification; a bare `DEFER:` without reason is rejected.
3. If the operator does not type `DEFER:<reason>`, treat the finding as `FIX` and fold it into the in-PR fix list. Never silently file an issue.
4. When `DEFER:<reason>` is approved, file the GitHub issue with:
   - `gh issue create --label consider-deferred --title "<one-line summary>" --body "Deferred from PR #<N> per /review-pr Stage 5. Reason: <reason>. Original finding: <quote>."`
   - Record the new issue number in the Stage 9 report's "Remaining CONSIDER items" section.

HIGH/MED-severity items (MUST FIX, SHOULD FIX) are **never** deferrable — fix in-PR is the only option.

Commit with conventional format: `fix(review): address <stage>/<category> findings`.

## Stage 6: Re-verify

Rerun the exact Stage 1 verification gate. Loop back to Stage 5 if anything fails. Hard cap: 3 iterations.

```bash
npm run check
```

```bash
npm run build
```

```bash
test -f dist/index.js && test -f dist/scraper.js && test -f dist/session-identity.js \
  && node -e "import('./dist/scraper.js').then((m) => { if (typeof m.scrapeEvents !== 'function') { console.error('scrapeEvents export missing'); process.exit(1) } })" \
  && ! grep -rn "company=extremeice" src/scraper.ts src/evaluator.ts src/config.ts src/index.ts src/commands/
```

## Stage 7: Push and wait for CI

```bash
git push --force-with-lease origin HEAD
gh pr checks $ARGUMENTS --watch
```

If CI fails after push, loop back to Stage 5. Same 3-iteration cap applies across all fix loops. If no CI checks are configured on this repo, record that and proceed.

## Stage 8: Quality gate (if configured)

No project-specific quality gate script is configured for adult-hockey-agent. Skip this stage (record "not configured" in the report). If one is added later, run it here and interpret pass/warn/block per the canonical protocol.

## Stage 9: Report

Required fields:

- **Conflicts**: found and resolved, or "none"
- **Verification**: gate pass/fail before and after fixes
- **Stage 1 (Claude) findings**: count by severity + highlights
- **Stage 2 (Codex adversarial) findings**: count by severity + highlights
- **Stage 3 (Codex normal) findings**: count by severity + highlights
- **Quality gate**: not configured
- **Fixes applied**: file + line + rationale for each
- **Final CI status**: green/red + run URL (or "no CI configured")
- **PR ready for human merge**: YES / NO
- **Remaining CONSIDER items**: surfaced to operator

## Stage 10: Cleanup

Exit the worktree: `ExitWorktree` with action `remove`.
