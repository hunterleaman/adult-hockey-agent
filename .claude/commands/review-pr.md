Comprehensive code review of a PR with conflict resolution, full verification, adversarial and baseline Codex reviews, and automated fixes. If $ARGUMENTS contains a PR number, review that PR. If empty, review the current branch's open PR.

This is the quality gate between agent implementation and human merge. **All stages are non-optional.**

## Output Discipline

HARD RULES in force: **Delegate to Subagents** (the Stage 1 diff-review gather
is ONE Explore subagent returning one capped synthesis block, never raw
`gh pr diff` / changed-file dumps in the main thread), **Run In Background**
(any dispatched Agent sets `run_in_background: true`), and **Build Command
Discipline** (never chain long-running gate/build/test commands with `&&`;
one dedicated Bash call each with an explicit timeout).

Route noise to logs; surface only the essentials:
- Allocate ONE per-invocation log dir up front:
  `LOGDIR="$(mktemp -d -t review-pr.XXXXXX)"; echo "$LOGDIR"` (never a fixed
  `/tmp/review-pr-<step>.log`: a predictable path is symlink-clobber bait and
  lets parallel sessions truncate each other's logs). Shell variables do not
  survive across dedicated Bash calls: capture the echoed absolute path once
  and interpolate that literal path into every later call's redirects. Never
  re-expand `$LOGDIR` in a fresh shell -- unset expansion would redirect to
  `/<step>.log`, and an ambient `LOGDIR` from the environment would route
  logs (and the final cleanup) at an unrelated directory. Route each noisy
  step to `"$LOGDIR/<step>.log" 2>&1` (e.g. `"$LOGDIR/fetch.log"`,
  `"$LOGDIR/gate.log"`, `"$LOGDIR/codex-adv.log"`, `"$LOGDIR/ci-poll.log"`).
  On an unexpected non-zero exit (a no-match `grep` is not a failure; a codex
  non-zero that routes to the documented API fallback is not a halt), tail
  that log, halt, and report.
- Only these may surface in the main thread: the Stage 1 diff-review synthesis
  block, one-line stage results, the consolidated Stage 4 findings list, the
  batched CONSIDER gate + operator token exchange, failure-path log tails, the
  final CI verdict line, and the Stage 10 final report. Everything else stays
  in the logs.

## Hard rules

- Never merge. Human merges.
- Never skip a stage.
- Never `--no-verify`. Never disable a failing check to make it pass.
- Force-push only to feature branches and only with `--force-with-lease`. Never to main.
- Max 3 fix-loop iterations through Stages 5-7. On the third consecutive
  failure, stop and report the full diagnosis (CD-2 teardown first).
- If adversarial review reveals the design is fundamentally wrong, stop and
  report rather than silently pivoting (CD-2 teardown first).

## Teardown on ALL exit paths (CD-2)

Once Stage 0's `EnterWorktree` has run, never stop with the review worktree
still mounted: stranded `review-pr-<number>` worktrees on abort paths are the
CD-2 defect this rule closes. EVERY stop, abort, or blocked report after
Stage 0 runs this teardown before stopping, then still renders the Stage 10
final report:

1. If the review worktree holds uncommitted changes or unpushed commits,
   `ExitWorktree` with action `keep`, and name the preserved path + reason on
   the report's Worktree: line (preserved work is surfaced, never silently
   stranded).
2. Otherwise `ExitWorktree` with action `remove`.

The only STOP exempt from teardown is the Stage 0 `isCrossRepository` stop,
which fires before `EnterWorktree` creates anything. Abort paths below cite
this rule as "(CD-2 teardown first)".

## Stage 0: Setup worktree

Review work MUST happen in an isolated worktree.

```bash
gh pr view $ARGUMENTS --json number,headRefName,headRefOid,isCrossRepository
```

Capture all four fields now, while HEAD still sits on a branch that has an open PR. If `$ARGUMENTS` was empty, use the captured `number` as `$ARGUMENTS` for every later `gh pr` command: after the checkout below, HEAD sits on `review-pr-<number>`, which has no open PR, so selector-free `gh pr` lookups fail.

If `isCrossRepository` is `true`, STOP and report (this stop precedes `EnterWorktree`, so there is no worktree to tear down). This flow fetches and pushes `<branch-name>` on `origin`, which for a fork PR is the base repository: it would review the wrong tree and could push review fixes into a base branch. Cross-repository PRs need operator routing (fetch `refs/pull/<number>/head`; push only to the fork, with operator approval).

Save the captured `headRefOid` as `EXPECTED_OID`. Every force-push below leases on it: a plain `--force-with-lease=<branch-name>` compares against the local remote-tracking ref, which any concurrent fetch (worktrees share refs) can silently advance, letting the push overwrite a collaborator's commits.

Enter a worktree: `EnterWorktree` with name `review-pr-{number}`. Worktree creation goes through the harness only; never run raw `git worktree add` (it bypasses the `lib/dispatch.sh` mutex queue; see `docs/hard-rules/agent-worktree-dispatch-mutex-queue.md`).

Inside the worktree, branch FROM the origin ref. Never `git checkout` the PR branch directly: when `/review-pr` runs from the source branch (the common case) that branch is already checked out in the primary worktree and the checkout aborts.

Run the fetch as its own checked Bash call. On a non-zero exit, tail
`"$LOGDIR/fetch.log"`, halt, and report (CD-2 teardown first). Never proceed
to checkout/rebase on a failed fetch: stale local refs would flow through to
Stage 7, where the lease pinned to `EXPECTED_OID` still matches the true
remote head, so the push would replace newer PR commits with a stale tree.

```bash
git fetch origin <branch-name> main > "$LOGDIR/fetch.log" 2>&1
```

```bash
git checkout -B review-pr-<number> origin/<branch-name>
git rebase origin/main > "$LOGDIR/rebase.log" 2>&1
```

If rebase conflicts arise (the conflict listing is in `"$LOGDIR/rebase.log"`):
1. For **append-only files** (docs/CHANGELOG.md, docs/DECISIONS.md): keep BOTH entries in chronological order
2. For **code conflicts**: read both sides, understand intent, merge correctly
3. After each resolution: `git add <file> && git rebase --continue`
4. After full rebase: `git push --force-with-lease=<branch-name>:"$EXPECTED_OID" origin HEAD:<branch-name>`, then refresh `EXPECTED_OID=$(git rev-parse HEAD)`. The explicit refspec is mandatory: HEAD sits on `review-pr-<number>`, so a bare `git push origin HEAD` would create a remote `review-pr-<number>` branch instead of updating the PR.

If rebase succeeds cleanly, proceed without force-push.

## Stage 1: Claude review (enumerate only, do not fix yet)

### Verification gate

Run the full quality gate BEFORE reviewing code. Failures here are MUST FIX.
Per Build Command Discipline, each block below runs as its own dedicated Bash
call with an explicit timeout (never chained with `&&`), output routed to
`"$LOGDIR/gate.log"`, `"$LOGDIR/build.log"`, and `"$LOGDIR/postbuild.log"`
respectively (append `2>&1`); on a failure, tail that log into the findings.

```bash
npm run check
```
```bash
npm run build
```
```bash
test -f dist/index.js && test -f dist/scraper.js && test -f dist/session-identity.js && node -e "import('./dist/scraper.js').then((m) => { if (typeof m.scrapeEvents !== 'function') { console.error('scrapeEvents export missing'); process.exit(1) } })" && ! grep -rn "company=extremeice" src/scraper.ts src/evaluator.ts src/config.ts src/index.ts src/commands/
```

### CI failure inspection

```bash
gh pr checks $ARGUMENTS > "$LOGDIR/ci-checks.log" 2>&1
gh run view <run-id> --log-failed > "$LOGDIR/ci-failed.log" 2>&1
```

Read the logs; surface only the failing check names. Before classifying a
failing check as MUST FIX, confirm the failure
does not already exist on `origin/main`. Pre-existing failures are out of
scope; record as CONSIDER with a note to file a separate issue.

### Diff review (ONE Explore subagent, under 300 words)

Dispatch ONE Explore subagent as the Step-1 gather (skeleton element 2;
`run_in_background: true`): it runs `gh pr diff $ARGUMENTS` and
`gh pr view $ARGUMENTS --json title,body`, reads the PR description and all
changed files in full (not just the diff), evaluates the checklist below, and
returns ONE synthesis block, **under 300 words**: changed-file inventory, PR
intent, and candidate findings tagged MUST FIX / SHOULD FIX / CONSIDER with
file:line citations. The main session renders the synthesis directly and
records the findings; no serial fan-out of diff/file reads from the main
thread.

### Checklist (evaluated by the gather subagent)

#### A. Active Invariants (from CLAUDE.md)
Read CLAUDE.md "Active Invariants" section and verify each one against the diff.

#### B. Code Quality
- No security vulnerabilities (injection, XSS, OWASP top 10)
- No over-engineering or unnecessary abstractions
- Error handling only at system boundaries
- No dead code, unused imports, commented-out blocks
- Consistent style with surrounding code

#### C. Known Pitfalls
- Read `docs/PITFALLS.md` and review every item against the diff

### Classify Stage 1 findings

- **MUST FIX**: invariant violation, security issue, broken functionality, failing CI
- **SHOULD FIX**: code quality, missed edge cases, style inconsistency
- **CONSIDER**: suggestions, minor improvements

Record findings. Do NOT fix yet.

## Resolving `codex-companion.mjs` (shared by Stages 2 and 3)

Stages 2 and 3 shell out to `codex-companion.mjs`. Resolve the script path once, in order of preference:

1. `${CLAUDE_PLUGIN_ROOT}/scripts/codex-companion.mjs`: set when running inside the Claude Code plugin runtime.
2. `${CODEX_COMPANION_PATH}`: operator override, set in shell profile to run outside the plugin.
3. First match of `ls -1 ${HOME}/.claude-lx/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs | sort -V | tail -n1`: picks the newest installed version from the plugin cache.

If none resolve, stop and report (CD-2 teardown first). Do not skip Stages 2 or 3. Ask the operator to install the openai-codex plugin or export `CODEX_COMPANION_PATH`, then re-run `/review-pr`.

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
node "$CODEX" adversarial-review --wait --base origin/main --scope branch > "$LOGDIR/codex-adv.log" 2>&1
```

The log captures stdout verbatim. Read it and parse findings into the MUST /
SHOULD / CONSIDER schema; surface only the parsed findings, never the raw
log. If the command exits non-zero or times out, fall back to the API direct
path below (a documented fallback, not a halt).

## Stage 3: Codex normal review

Purpose: baseline pass for implementation defects, style, common pitfalls that Claude misses due to familiarity bias.

```bash
node "$CODEX" review --wait --base origin/main --scope branch > "$LOGDIR/codex-norm.log" 2>&1
```

The log captures stdout verbatim. Read it and parse findings. Same failure
policy as Stage 2.

### API direct fallback (mandatory if Codex CLI fails)

If either Stage 2 or 3 fails (quota, timeout, CLI not installed), fall back to the OpenAI API directly using the same `REVIEW_MODEL`.

If the project provides `scripts/openai_adversarial_review.py`:

```bash
python scripts/openai_adversarial_review.py --model "$REVIEW_MODEL" --pr <PR_NUM> --json > "$LOGDIR/api-review.log" 2>&1
```

Then read `"$LOGDIR/api-review.log"` and parse its JSON findings into the
MUST / SHOULD / CONSIDER schema BEFORE Stage 4: fallback findings feed
consolidation exactly like CLI findings. A fallback that ran but was never
read back is observationally identical to "codex found nothing" and falsely
cleans the PR.

<!-- MAIN-SESSION-ONLY-START -->
**Main-session-only fallback.** If `/review-pr` is running in the **main session** (not inside a worktree-isolated `Agent`), the `codex:codex-rescue` subagent is also a valid path. Do NOT use it from a nested Agent -- `CLAUDE_PLUGIN_ROOT` is not propagated, the rescue subagent silently no-ops, and empty output is observationally identical to "codex found nothing." See `docs/PITFALLS.md` -> "Codex review must use CLI in nested Agent subprocesses (silent-failure trap)" and CLAUDE.md HARD RULE "Codex from nested Agents". From a nested Agent, only the `codex` CLI / `node "$CODEX"` / API direct paths are valid.
<!-- MAIN-SESSION-ONLY-END -->

If all valid paths fail (no Codex CLI, no `OPENAI_API_KEY`), do NOT mark the
PR ready (CD-2 teardown first). Report: "Second-opinion review: BLOCKED" on
the Stage 10 report's Second opinion line, with `PR ready for human merge:
NO`.

Note: Codex CLI uses ChatGPT subscription quota. API direct uses `OPENAI_API_KEY` (separate billing). Quota exhaustion on one does not affect the other.

## Stage 4: Consolidate findings

Merge all stages into a single findings list. De-duplicate overlapping
findings. If the merged list exceeds 30 findings, dispatch ONE dedup subagent
(`run_in_background: true`) capped **under 250 words** to consolidate
duplicates and near-duplicates before presenting. Present as one coherent
set, tagged by originating stage.

## Stage 5: Implement fixes

Fix every MUST FIX and SHOULD FIX.

### CONSIDER findings -- default = fix in this PR

CONSIDER findings are **fixed in this PR by default** (per CLAUDE.md "Zero
tolerance for shipped tech debt"). Filing as a follow-up issue is the
**exception**, not the default, and requires an explicit operator-typed
token.

**Procedure (skeleton element 3):**

1. Present ALL CONSIDER findings in ONE batched gate -- a numbered list, one
   line per finding with file:line citation + 1-line rationale -- never one
   prompt per finding:

   ```
   CONSIDER findings ({N}):
     1. {file:line} -- {rationale}
     ...
   Reply per item number: FIX (default) or DEFER:<reason>.
   ```

2. The operator MUST respond per item with one of:
   - `FIX` -- fold into this PR (default; you fix and re-run Stage 6).
   - `DEFER:<reason>` -- file as a follow-up issue with label
     `consider-deferred`. The `<reason>` is required free-text justification
     (e.g. `DEFER:scope-creep -- needs separate ADR for the broader pattern`);
     a bare `DEFER:` without reason is rejected.
3. Any item without an operator-typed `DEFER:<reason>` is treated as `FIX`
   and folded into the in-PR fix list. Never silently file an issue.
4. When `DEFER:<reason>` is approved, file the GitHub issue with:
   - `gh issue create --label consider-deferred --title "<one-line summary>" --body "Deferred from PR #<N> per /review-pr Stage 5. Reason: <reason>. Original finding: <quote>."`
   - Record the new issue number on the Stage 10 report's Deferred line.

HIGH/MED-severity items (MUST FIX, SHOULD FIX) are **never** deferrable --
fix in-PR is the only option.

Commit with conventional format: `fix(review): address <stage>/<category> findings`.

## Stage 6: Re-verify

Rerun the exact Stage 1 verification gate (same dedicated Bash calls, same
`"$LOGDIR/"` routing). Loop back to Stage 5 if anything fails. Hard cap: 3
iterations; the third consecutive failure stops and reports the full
diagnosis (CD-2 teardown first).

```bash
npm run check
```
```bash
npm run build
```
```bash
test -f dist/index.js && test -f dist/scraper.js && test -f dist/session-identity.js && node -e "import('./dist/scraper.js').then((m) => { if (typeof m.scrapeEvents !== 'function') { console.error('scrapeEvents export missing'); process.exit(1) } })" && ! grep -rn "company=extremeice" src/scraper.ts src/evaluator.ts src/config.ts src/index.ts src/commands/
```

## Stage 7: Push and wait for CI

Push with the explicit refspec (HEAD sits on `review-pr-<number>`, not `<branch-name>`; a bare `git push origin HEAD` would create a remote `review-pr-<number>` branch) and the lease pinned to `EXPECTED_OID` (captured in Stage 0, refreshed after every successful push):

```bash
git push --force-with-lease=<branch-name>:"$EXPECTED_OID" origin HEAD:<branch-name>
EXPECTED_OID=$(git rev-parse HEAD)
```

Poll for CI completion filtered by the pushed SHA (max 20 iterations of 30 seconds = 10 minutes wall). Never read the verdict off the latest run: it can be a completed pre-push run reporting a stale green.

```bash
PUSHED_SHA=$(git rev-parse HEAD)
i=0
while [ $i -lt 20 ]; do
  # Empty result means CI has not created the run for this SHA yet: keep waiting.
  STATE=$(gh run list --commit "$PUSHED_SHA" --json status --jq \
    'if length == 0 then "waiting" elif all(.[]; .status == "completed") then "done" else "running" end')
  if [ "$STATE" = "done" ]; then
    break
  fi
  sleep 30
  i=$((i+1))
done
gh run list --commit "$PUSHED_SHA" --json name,status,conclusion,url
```

The closing `gh run list` line is the CI verdict surface (whitelisted); the
poll iterations themselves surface nothing.

If the loop exits without `STATE` reaching `done`, branch on the final `STATE`. `running` means Actions runs exist but are still pending after 10 minutes: fail closed. Do not proceed to Stage 8 and do not report the PR ready; keep polling, or stop and report the pending runs to the operator (CD-2 teardown first when stopping). `waiting` means no Actions run ever appeared: the repository's required checks may come exclusively from external CI or GitHub Apps, which `gh run list` cannot see, so fall through to the SHA-guarded `gh pr checks` verdict below instead of failing closed.

`gh pr checks $ARGUMENTS --watch` is acceptable only after confirming the PR head matches the pushed SHA: `[ "$(gh pr view $ARGUMENTS --json headRefOid --jq .headRefOid)" = "$PUSHED_SHA" ]`. Once the guard passes, take the final verdict from `gh pr checks $ARGUMENTS` for that head: `gh run list` sees only GitHub Actions runs, so required checks from external CI or GitHub Apps never appear in it. The verdict always comes from checks matching `$PUSHED_SHA`, never the most recent run.

If CI fails after push, loop back to Stage 5. Same 3-iteration cap applies across all fix loops.

## Stage 8: Quality gate (if configured)

If the project provides a quality gate script, run it as a dedicated Bash
call routed to `"$LOGDIR/qgate.log" 2>&1`:

```bash
: # n/a -- no quality gate script configured for adult-hockey-agent
```

Interpret the verdict:
- **pass**: proceed.
- **warn**: proceed. Include warnings on the final report's Quality gate line.
- **block**: STOP (CD-2 teardown first). Report the blocking reasons via the
  Stage 10 report; the operator overrides with `/qc-override <reason>`.

If no quality gate script is configured, skip this stage.

## Stage 9: Cleanup (success path)

Run the CD-2 teardown: `ExitWorktree` with action `remove`. The review
branch's commits are already on `origin/<branch-name>` after Stage 7; if the
tool refuses, re-invoke with `discard_changes: true` ONLY after BOTH checks
pass: `git log origin/<branch-name>..HEAD` is empty (every commit pushed) AND
`git status --porcelain --untracked-files=all` is empty (no staged, tracked,
or untracked leftovers -- commit reachability says nothing about files the
gate or tests created). If either check fails, this is not the success path:
use action `keep` and surface the preserved path + reason on the report's
Worktree: line. Finally remove the log dir: confirm the captured literal
path still matches the `review-pr.` mktemp shape under the system temp dir,
then `rm -rf` that literal path (an unset or ambient `$LOGDIR` must never
reach `rm -rf`).

## Stage 10: Final report (keep under 25 lines)

Every outcome renders this report -- success, abort, and blocked paths alike,
each after its teardown per the CD-2 rule. Print the fenced `{placeholder}`
template below, capped at **25 lines** (non-blank; blank separators exempt).

```
REVIEW-PR COMPLETE

PR: #{number} {title} | branch: {branch-name}
Conflicts: {none | resolved: files}
Verification: {pass | FAIL: step} before -> {pass | FAIL: step} after fixes
Stage 1 (Claude): {M} MUST / {S} SHOULD / {C} CONSIDER | {highlight}
Stage 2 (Codex adversarial): {counts | skipped: reason} | {highlight}
Stage 3 (Codex normal): {counts | skipped: reason} | {highlight}
Second opinion: {codex CLI | API direct | BLOCKED}
Quality gate: {pass | warn | block | not configured}
Fixes applied: {N} ({file:line -- rationale, folded})
Deferred: {none | #issue: reason, folded}
Final CI: {green | red | pending | not run} {run-url}
Worktree: {removed | kept: path -- reason | not created}
PR ready for human merge: {YES | NO -- reason}
Next: {single highest-priority action}
```

Then STOP. No trailing prose.
