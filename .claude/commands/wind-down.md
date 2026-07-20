Context-safe session wind-down. Use this when the context window is getting full
and you need to end THIS session cleanly WITHOUT clobbering work owned by other
parallel sessions in other workstreams.

**This is NOT `/ship`.** `/ship` is the happy-path session-end for a completed
workstream: it verifies, commits, pushes. `/wind-down` is the context-exhaustion
path: it preserves cross-session integrity, writes a workstream-scoped resume
prompt, and refuses to auto-commit or auto-stash work (you must choose).

## Output Discipline

HARD RULES in force: **Delegate to Subagents** (the Step 1 state gather is one
Explore subagent, never raw bash in the main thread), **Run In Background**
(any dispatched Agent sets `run_in_background: true`), and **Build Command
Discipline** (never chain long-running git/gh calls with `&&`; one dedicated
call each, so the operator sees each result).

Route noise to logs; surface only the essentials:
- Allocate ONE per-invocation log dir up front:
  `LOGDIR="$(mktemp -d -t wind-down.XXXXXX)"` (never a fixed
  `/tmp/wind-down-<step>.log`: a predictable path is symlink-clobber bait and
  lets parallel sessions truncate each other's logs -- the same reason Step 5a
  requires `mktemp`). Route each gather/verify command to `"$LOGDIR/<step>.log"
  2>&1` (e.g. `"$LOGDIR/snapshot.log"`, `"$LOGDIR/verify.log"`). On an
  unexpected non-zero exit (a no-match `grep` is not a failure), tail that log,
  halt, and report.
- Only these may surface in the main thread: the Step 1 state-snapshot
  synthesis block, one-line gate prompts + their results, the Step 5 resolved
  resume-prompt path echo, the Step 5a auto-correction notice, failure-path log
  tails, and the Step 7 final report. Everything else stays in the logs.

## Step 0: Derive the memory home

Every memory read/write resolves against `$MEM_DIR` (the repo-root `memory/`
dir, tracked in git). Derive it once, mirroring `/land` and `/orient` (the
CWD-Discipline HARD RULE guarantees the main session never changes CWD, so
`git rev-parse` runs from repo root; the `${REPO_ROOT:-$PWD}` fallback keeps it
correct even when not in a git repo):

```bash
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
MEM_DIR="${REPO_ROOT:-$PWD}/memory"
```

## Step 1: State snapshot (one Explore subagent, under 200 words)

Dispatch ONE Explore subagent to gather ALL cross-session git/GitHub/memory
state in a single pass and return ONE synthesis block, **under 200 words**,
that the main session renders directly. No serial fan-out of gather calls from
the main thread. The subagent runs the gathers below (each redirected to
`"$LOGDIR/snapshot.log" 2>&1`, tailing + halting only on an unexpected non-zero
exit):

```bash
git branch --show-current
git status --short
git log --oneline -5
# Unpushed commits. Upstream may be unset -> treat as "no upstream", not fatal:
git rev-list --count @{upstream}..HEAD 2>/dev/null || echo "no-upstream"
git worktree list
# Remote gathers are SOFT: wind-down's job is preserving LOCAL work, so a gh
# auth/rate-limit/network outage must NOT abort. Record "unavailable", continue.
gh pr list --limit 20 --json number,title,headRefName,state,mergeable || echo "gh pr list: unavailable"
gh issue list --limit 20 --state open --json number,title,labels || echo "gh issue list: unavailable"
ls -lt "$MEM_DIR/" | head -5
```

The synthesis reports: current branch, dirty-file count, unpushed-commit count
(or "no upstream"), open PRs/issues (or "unavailable" when the soft remote
gathers failed), recently touched memory files, and the branch + memory signals
consumed by Step 2. Only a LOCAL-state or resume-prompt write failure may halt
wind-down; a remote-gather failure never does.

## Step 2: Identify the workstream

From the Step 1 synthesis, derive the workstream from three independent signals:
1. **Branch name**: `git branch --show-current`
2. **Recently touched memory files**: `ls -lt "$MEM_DIR/" | head -5`
3. **Issues referenced in conversation**: scan for `#NNN` (this scan runs in the
   main thread here -- the Step 1 subagent cannot see the conversation)

If all three agree, auto-select. If they disagree, ask the operator ONCE. The
resolved slug is `$WORKSTREAM_SLUG`, consumed by the Step 5 resume prompt and
the Step 5a phase-gate validation.

## Step 3: Handle in-progress work (one batched gate)

If uncommitted changes exist, STOP and present ONE consolidated gate for the
whole uncommitted-work class (never one prompt per file). The operator types a
single token:

```
Uncommitted work: {N} files. Choose: [c] commit / [s] stash / [d] discard
```

- `[c]` **commit**: stage specific files, conventional message.
- `[s]` **stash**: `git stash push -u -m "wind-down {slug} {ISO-date}"`.
- `[d]` **discard**: `git restore . && git clean -fd`.

Wait for the operator to choose. Do NOT auto-pick. Never run a destructive
action without this gate.

## Step 4: Verify ground truth

```bash
git rev-parse HEAD
git log origin/main..HEAD 2>/dev/null
git status --short
```

## Step 5: Write workstream-scoped resume prompt

The resume prompt lives at `$MEM_DIR/prompt_${WORKSTREAM_SLUG}.md`. ASSIGN the
path first (Step 5a's phase-gate validation reads `$PROMPT_PATH`), write the
file, then print the resolved ABSOLUTE path so the operator sees exactly where
it landed:

```bash
PROMPT_PATH="$MEM_DIR/prompt_${WORKSTREAM_SLUG}.md"
# ...write the resume prompt to "$PROMPT_PATH"...
echo "wind-down: wrote resume prompt (resolved): $PROMPT_PATH"
```

Everywhere else (Step 6 pointer, Step 7 report) display the path repo-relative
as `memory/prompt_{slug}.md` -- valid because `$MEM_DIR` is the repo-root
`memory/` dir.

Use the standard resume prompt template with VERIFIED/ASSUMED/DO-FIRST sections.

<!-- LINE-CAP-100 START (revert: git revert the commit that added this block) -->
### Line-length mandate (resume-prompt VERIFIED + Step 7 report)
Every line in the VERIFIED section of the resume prompt AND every line of the
Step 7 final report must be <=100 chars, counting leading spaces and markdown
markers. Pithiness mandate, not a wrap mandate: condense each point until it
fits on one line. Never wrap a point across continuation lines. (Terminal is
103 cols; longer lines break scanning.) Sole exemption: a line whose overflow
is one unsplittable token (URL, meta tag, path) - keep the rest of that line
minimal.
<!-- LINE-CAP-100 END -->

### Step 5a: Phase-gate validate the proposed DO-FIRST (slice #61)

Before saving the prompt, validate its DO-FIRST against the workstream ledger.
If the DO-FIRST proposes a phase-skip (e.g. `/write-a-prd` while
`phases.grill.started_at` is unset, or `/prd-to-issues` while
`phases.prd.completed_at` is unset), **auto-correct** by rewriting the
DO-FIRST to use the appropriate prerequisite command and append an
explanatory `> note: auto-corrected because <reason>` marker line directly
under the rewritten command.

`/wind-down` NEVER refuses to write a prompt. Auto-correct + note is the only
failure mode.

```bash
# Codex pass-11 MED + pass-12 HIGH: TRULY fail-closed. Helper rc switch:
# rc=0 -> no correction needed. rc=1 -> phase-skip detected, auto-correct
# via rewrite (rewrite-failure is also fatal). rc=2 -> helper error (path
# confinement reject, unreadable prompt, inode race) -- ABORT wind-down.
# A predictable /tmp/$$ fallback would be symlink-clobber bait; instead,
# require mktemp to succeed (fail-safe).
# zsh-safe wrapper: `source lib/workstream.sh` only works under bash, so call
# every workstream lib function via a `bash -c` subshell. (F11, issue #75.)
_WIND_DOWN_HELPER_LOG="$(mktemp -t wind-down-phase-skip.XXXXXX)" || {
  echo "wind-down: FATAL: mktemp failed; cannot capture helper diagnostics safely" >&2
  exit 1
}
trap 'rm -f "$_WIND_DOWN_HELPER_LOG"' EXIT
# errexit-safe capture: an unguarded `CORRECTION="$(...)"` lets `set -e` abort
# AT THE ASSIGNMENT when the helper returns rc=1/rc=2 (command-substitution
# failure), so the case switch below and its fail-closed arms would never run
# (the rc=1 auto-correct would silently no-op; codex #101 review). An `if`
# condition is exempt from errexit, so the rc is captured and switched on.
if CORRECTION="$(bash -c 'source lib/workstream.sh && _workstream_check_prompt_phase_skip "$@"' _ "$WORKSTREAM_SLUG" "$PROMPT_PATH" 2>"$_WIND_DOWN_HELPER_LOG")"; then
  _phase_skip_rc=0
else
  _phase_skip_rc=$?
fi
case "$_phase_skip_rc" in
  0)
    : # no skip detected -- DO-FIRST is OK as-is
    ;;
  1)
    if [ -n "$CORRECTION" ]; then
      REASON="proposed command requires prior-phase artifact that is not in .workstream/${WORKSTREAM_SLUG}.md"
      if ! bash -c 'source lib/workstream.sh && _workstream_rewrite_prompt_do_first "$@"' _ "$PROMPT_PATH" "$CORRECTION" "$REASON"; then
        echo "wind-down: FATAL: rewrite_prompt_do_first failed; aborting (DO-FIRST left unchanged)" >&2
        cat "$_WIND_DOWN_HELPER_LOG" >&2 || true
        exit 1
      fi
      echo "wind-down: auto-corrected DO-FIRST -> $CORRECTION (phase-skip avoided)"
    else
      # Helper said skip but did not recommend a correction -- abort, the
      # invariant is broken (rc=1 is supposed to imply non-empty stdout).
      echo "wind-down: FATAL: phase-skip detected but helper returned no correction; aborting" >&2
      cat "$_WIND_DOWN_HELPER_LOG" >&2 || true
      exit 1
    fi
    ;;
  *)
    # rc=2 (usage/validation error) or any unexpected non-zero. ABORT
    # wind-down -- DO NOT save a prompt whose DO-FIRST was never validated.
    echo "wind-down: FATAL: phase-skip helper failed (rc=$_phase_skip_rc); aborting wind-down. Helper diagnostic:" >&2
    cat "$_WIND_DOWN_HELPER_LOG" >&2 || true
    exit 1
    ;;
esac
```

## Step 6: Update MEMORY.md surgically

Edit exactly ONE line: the pointer to the resume prompt. Multi-line edits FORBIDDEN.

## Step 7: Final report

Print the fenced `{placeholder}` template below, capped at **10 lines** (blank
separators exempt) and, per the LINE-CAP-100 mandate above, every line <=100
chars. STOP after printing it: no trailing prose.

```
WIND-DOWN COMPLETE

Workstream: {slug}
Resume prompt: memory/prompt_{slug}.md

VERIFIED:
- {bullet list}

NEXT SESSION:
1. cd {project-directory}
2. claude
3. /wind-up

Safe to exit now.
```

Then STOP. Do not auto-exit, do not run /ship.
