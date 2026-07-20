Universal workstream landing sequence. Run after all PRs for a wave are merged to main.

$ARGUMENTS is optional: workstream identifier (e.g., "WS10 Wave 1"). If empty, infer from recent commits and memory.

## Output Discipline

HARD RULES in force: **Delegate to Subagents** (the Step 0 state gather is one
Explore subagent, never serial raw git/gh dumps in the main thread),
**Run In Background** (any dispatched Agent sets `run_in_background: true`),
and **Build Command Discipline** (never chain long-running verify/test
commands with `&&`; one dedicated Bash call each with an explicit timeout --
`/verify` and each prune step run as separate calls).

Route noise to logs; surface only the essentials:
- Allocate ONE per-invocation log dir up front:
  `LOGDIR="$(mktemp -d -t land.XXXXXX)"` (never a fixed `/tmp/land-<step>.log`:
  a predictable path is symlink-clobber bait and lets parallel sessions
  truncate each other's logs). Route each sync/prune/verify command to
  `"$LOGDIR/<step>.log" 2>&1` (e.g. `"$LOGDIR/sync.log"`,
  `"$LOGDIR/verify.log"`). On a non-zero exit from a step where non-zero means
  failure (a no-match `grep` is not a failure), tail that log, halt, and
  report.
- Only these may surface in the main thread: the Step 0 state-snapshot
  synthesis block, one-line gate prompts + their results, the dash-gate result,
  the commits-about-to-push list, failure-path log tails, and the Section 7
  final report. Everything else stays in the logs.

## 0. State Snapshot (one Explore subagent, under 200 words)

Dispatch ONE Explore subagent to gather ALL landing state in a single pass --
branch/status/log, worktree list, merged-branch prune candidates,
`gh pr list --state merged --limit 20` filtered to the wave (bare `gh pr list`
shows only OPEN PRs and misses every just-merged PR), open issues, memory
inventory -- and return ONE
synthesis block, **under 200 words**, that the main session renders directly.
No serial fan-out of gather calls from the main thread. The synthesis names:
current branch + clean/dirty, the wave's merged PRs, prune candidates
(branches + worktrees), and the doc/memory files Sections 3-4 will touch.

## 1. Sync & Clean

Derive `REPO_ROOT` once so every git op runs `git -C "$REPO_ROOT" ...` per the CWD-Discipline HARD RULE (`/land` runs in the main session and MUST NOT change CWD).

```bash
# `|| true` keeps the derivation from aborting under `set -e` when git fails;
# the ${REPO_ROOT:-$PWD} fallback then anchors MEM_DIR on the launch CWD.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
# Memory home: tracked repo-root memory/ dir (read in step 4 via $MEM_DIR).
MEM_DIR="${REPO_ROOT:-$PWD}/memory"
git -C "$REPO_ROOT" checkout main
git -C "$REPO_ROOT" pull origin main > "$LOGDIR/sync.log" 2>&1
git -C "$REPO_ROOT" branch --merged main | grep -v '\*\|main' | xargs -r git -C "$REPO_ROOT" branch -d
git -C "$REPO_ROOT" worktree list
```
For stale worktrees, scope the removal class to the just-landed wave:
dispatcher worktrees (`.claude/worktrees/agent-*`) and review worktrees
(`.claude/worktrees/review-pr-*`) whose branch/PR merged in THIS wave. A
candidate qualifies only if it passes the same 4-signal verifiably-stale
classification `/orient` uses (merged; no remote branch; no uncommitted
changes and no unpushed commits; no files modified under the path within the
last 30 minutes). Anything uncertain or out-of-scope stays, annotated
`(uncertain: review manually)` -- never delete it.

Present ONE consolidated gate for the whole removal class (skeleton element 3;
never a silent `rm -rf`, never per-item prompts up front):
```
Stale worktrees: {W} ({paths}). Remove and prune now? [y/n]
```
On `y`: enter per-item review. RE-VERIFY each candidate at that moment (the
snapshot may be stale): `git -C <path> status --porcelain` empty AND no
unpushed commits. Then one line per item:
```
Stale: <path> (merged, clean, no unpushed). Remove? [y/n]
```
On per-item `y`: `git -C "$REPO_ROOT" worktree remove <path>` (non-forced; it
refuses dirty or locked worktrees as a safety net), then
`git -C "$REPO_ROOT" worktree prune`; `rm -rf <path>` only for a leftover
non-worktree dir remaining AFTER a successful remove + prune. On per-item `n`,
any refusal, or any re-verify failure: leave it, move on.
On batched `n`: leave them; note it on the final report's Cleanup line.

Verify: `git -C "$REPO_ROOT" status` is clean.

## 2. Full Quality Gate

Run `/verify`. All checks must pass. Fix any failures before proceeding.

## 3. Update Documentation

Read each file before editing:
- **CLAUDE.md "Current State"**: Update workstream entry with status, key metrics, what was delivered.
- **docs/PITFALLS.md**: Add any new lessons learned discovered during the wave.
- **docs/CHANGELOG.md**: Append user-visible changes with date and workstream tag.
- **docs/DECISIONS.md**: Append any architectural decisions made.

## 4. Update Memory

Read `$MEM_DIR/MEMORY.md` (if present) for the active workstream. Mark completed waves with date, update remaining waves' status, note any new blockers.

## 5. Next Actions

Using `gh issue list` and workstream memory:
- List remaining issues in the workstream
- State which are now unblocked
- Note any blockers
- Recommend next wave composition

## 6. Commit & Push

Stage only the doc files that exist. Per the doc-layout standardization sweep
(#37 #12 #49), canonical paths are always `docs/<NAME>.md`. Legacy top-level
copies (pre-sweep retrofits) are preserved verbatim by bootstrap with a
one-time migration warning; the conditional staging below tolerates either
layout while the operator completes migration.

```bash
# memory/MEMORY.md is TRACKED (issue #100): Section 4 edits it, so it MUST be in
# the landing commit -- omitting it drops the memory update and leaves the tree
# dirty (git status non-clean), defeating the machine-loss persistence guarantee.
docs_to_stage=()
for f in CLAUDE.md docs/CHANGELOG.md CHANGELOG.md docs/DECISIONS.md DECISIONS.md docs/PITFALLS.md PITFALLS.md memory/MEMORY.md; do
  [ -e "$REPO_ROOT/$f" ] && docs_to_stage+=("$f")
done
git -C "$REPO_ROOT" add "${docs_to_stage[@]}"
git -C "$REPO_ROOT" status
```
Commit: `docs({workstream}): land {wave}, update status, docs, and memory`

Char-policy gate (issue #92): after committing and before the push confirm,
run the diff-scoped dash gate. It fails when any line added relative to
origin/main introduces an en dash (U+2013) or em dash (U+2014). Legacy dash
bytes already on main are inert (only added lines are scanned), and detection
uses a raw UTF-8 byte pattern that works under BSD and GNU grep alike (no
PCRE grep flags, which BSD/macOS grep rejects).

```bash
DASH_GATE_ROOT="$REPO_ROOT" bash "$REPO_ROOT/lib/dash-gate.sh" check
```

On non-zero exit: the gate prints each offending `file: line` pair. Replace
every flagged character with ASCII (`-`, `->`, or rewrite), amend the landing
commit, and re-run the gate until clean. Do NOT push while the gate is red.

Before pushing, print the commits about to be pushed and halt for operator confirm (push-to-main is a blast-radius op; mirror the `/orient` stale-cleanup y/n shape):
```bash
git -C "$REPO_ROOT" log origin/main..HEAD --oneline
```
Surface a one-line `y/n` prompt naming the commit count, e.g.:
```
About to push N commits to origin/main. Proceed? [y/n]
```
On `y`:
```bash
git -C "$REPO_ROOT" push origin main
```
On `n`: skip the push. Leave the local commits in place for the operator to
inspect, then CONTINUE to Section 7 -- every gate outcome renders the final
report, with the `push declined` variant on the Landed: line.

## 7. Final Report (keep under 10 lines)

Print the fenced `{placeholder}` template below, capped at **10 lines**
(non-blank; blank separators exempt).

```
LAND COMPLETE

Workstream: {slug or wave}
Landed: {N} PRs | pushed: {commit-count} commits to origin/main {or: push declined}
Verify: {pass | FAIL: suite} | Dash gate: {clean | fixed: N}
Cleanup: {B} branches pruned, {W} worktrees {removed | kept}
Docs: {files updated} | Memory: {MEMORY.md updated | unchanged}
Blockers: {none | one line}
Next: {single highest-priority action}
```

Then STOP. No trailing prose.
