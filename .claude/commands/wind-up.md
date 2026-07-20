Wind the session back up from where the last one left off (sibling of `/wind-down`).

## Output Discipline

HARD RULES in force: **Delegate to Subagents** (the Step 3 state gather is one
Explore subagent, never a raw `/orient` dump into the main thread) and
**Run In Background** (any dispatched Agent sets `run_in_background: true`).

Route noise to logs; surface only the essentials:
- Allocate ONE per-invocation log dir up front:
  `LOGDIR="$(mktemp -d -t wind-up.XXXXXX)"` (never a fixed
  `/tmp/wind-up-<step>.log`: a predictable path is symlink-clobber bait and lets
  parallel sessions truncate each other's logs). Route each gather to
  `"$LOGDIR/<step>.log" 2>&1` (e.g. `"$LOGDIR/snapshot.log"`). On an unexpected
  non-zero exit (a no-match `grep` is not a failure), tail that log, halt, and
  report.
- Only these may surface in the main thread: the `resolved slug: <X> via
  <method>` line, the Step 3 state-snapshot synthesis, drift notes, the
  recommended next action, and the Step 4 final report. Everything else stays
  in the logs.

## Step 1: Resolve the active workstream slug deterministically (slice #61)

Replace MEMORY.md-pointer guessing with the slug-resolution cascade. The
cascade resolves `--slug` flag -> branch-name regex (`^[0-9]+-(.+)$`) ->
exactly-one-open `.workstream/<slug>.md`. If multiple workstreams are active,
surface the resolution decision in the wind-up output as a single line:
`resolved slug: <X> via <method>`.

```bash
# Derive the memory home (tracked repo-root memory/ dir). CWD-Discipline: the
# main session never changes CWD, so git rev-parse runs from repo root; the
# ${REPO_ROOT:-$PWD} fallback keeps MEM_DIR correct even outside a git repo.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
MEM_DIR="${REPO_ROOT:-$PWD}/memory"

# Resolve ONCE so any interactive disambiguate prompt fires only once.
# stdout = slug, stderr = method-string. Capture both via a stderr-redirect
# tmp file (using `2>&1 >/dev/null` would reorder them and dropping stderr
# inline would lose the method surface).
# zsh-safe wrapper: `source lib/workstream.sh` only works under bash, so call
# the workstream lib function via a `bash -c` subshell. (F11, issue #75.)
METHOD_LOG="$(mktemp -t wind-up-method.XXXXXX)"
# `|| true` neutralizes the resolver's non-zero exit (rc=2 on no-slug/ambiguous)
# so the fallback `else` below is reachable even under `set -e` (mirrors the
# guarded resolver call in /orient). Without it, an errexit shell aborts on this
# assignment and the newest-prompt fallback never runs.
RESOLVED="$(bash -c 'source lib/workstream.sh && _workstream_resolve_slug_with_method "$@"' _ 2>"$METHOD_LOG" || true)"
if [ -n "$RESOLVED" ]; then
  cat "$METHOD_LOG"  # e.g. "workstream: slug 'foo' resolved via branch ..."
  PROMPT_PATH="$MEM_DIR/prompt_${RESOLVED}.md"
  # Short method label for the Step 4 report's {method} field.
  METHOD="$(sed -n 's/.*resolved via //p' "$METHOD_LOG" | head -1)"
  METHOD="${METHOD:-cascade}"
else
  # Cascade refused (no slug, ambiguous in non-TTY, etc). Fall back to the most
  # recent resume prompt under $MEM_DIR and flag the fallback explicitly. This
  # MUST assign $PROMPT_PATH -- otherwise Step 2 would read a `prompt_.md` hole.
  PROMPT_PATH="$(ls -t "$MEM_DIR"/prompt_*.md 2>/dev/null | head -1 || true)"
  echo "wind-up: slug cascade refused; falling back to newest prompt: ${PROMPT_PATH:-<none found>}"
  # Derive the report {slug}/{method} from the fallback filename so the Step 4
  # report is fully defined even when the cascade refused (RESOLVED was empty).
  if [ -n "$PROMPT_PATH" ]; then
    RESOLVED="$(basename "$PROMPT_PATH" .md | sed 's/^prompt_//')"
  fi
  METHOD="newest-prompt fallback"
fi
rm -f "$METHOD_LOG"
```

`$PROMPT_PATH` is now resolved for both the cascade-hit and the fallback paths.

## Step 2: Read the resume prompt

Read `$PROMPT_PATH` (resolved above; deterministic, no recency guess). Its
VERIFIED / ASSUMED / DO-FIRST sections are the baseline the next steps
reconcile against.

## Step 3: State snapshot (one Explore subagent, under 200 words)

Instead of dumping a raw `/orient` run into the main thread, dispatch ONE
Explore subagent that performs orient's non-interactive validation and returns
ONE synthesis block, **under 200 words** (each command redirected to
`"$LOGDIR/snapshot.log" 2>&1`, tailing + halting only on an unexpected non-zero
exit). Replacing `/orient` with a lighter gather would silently drop its safety
checks, so the subagent MUST cover, at minimum:

- **Sync + drift**: `git fetch` state, `git branch/status/log`, `gh pr list`;
  compare against the prompt's VERIFIED/ASSUMED and flag new commits, closed or
  merged PRs, and a dirty tree, one line each. (Report only; do NOT auto-pull
  or mutate -- wind-up never changes state.)
- **Ledger phase-skip validation** (orient parity): re-run the workstream
  ledger check for the resolved slug and surface any correction --
  `bash -c 'source lib/workstream.sh && _workstream_check_prompt_phase_skip "$@"' _ "$RESOLVED" "$PROMPT_PATH"`
  (rc=1 => surface the recommended correction as a `WARN:` line; rc=2 => surface
  the helper error) plus the non-conformant `.workstream/*.md` count.
- **Prompt freshness** (orient's 72h authority rule): parse the prompt's
  `written_at` frontmatter; if it is missing, invalid, or older than 72h, mark
  the DO-FIRST STALE (surface `stale: written_at <value>`) so Step 4 recommends
  a fresh orientation instead of presenting it as authoritative.
- **DO-FIRST reference liveness**: for each slash-command, file, or PR the
  prompt's DO-FIRST names, confirm it still exists (command file present, path
  on disk, PR still open). Surface any dead reference -- a branch/PR drift check
  alone can otherwise report `in-sync` while recommending an invalid action.
- **Memory conflicts**: summarize the CONTENTS (not just the inventory) of the
  most recently modified non-archive memory file and flag anything that
  contradicts or supersedes the resume prompt.

Report every drift/warning as one line each; if none, report `in-sync`.

## Step 4: Present the final report, then gate

Reconcile the Step 3 snapshot against the prompt's VERIFIED/ASSUMED/DO-FIRST. If
Step 3 flagged the prompt STALE (written_at missing/invalid/>72h), the State
line is `drift: prompt stale (written_at ...)` and NEXT ACTION recommends a
fresh orientation rather than the DO-FIRST. Otherwise print the fenced
`{placeholder}` report below as the SINGLE presentation to the operator, capped
at **10 lines** (blank separators exempt). The report ENDS
with the confirmation gate, so it is printed BEFORE waiting -- never a stale
"already-confirmed" report after the fact. STOP after printing it: no trailing
prose (the standing Context Management directive below is not report output).
Then WAIT for the operator's `[y]`; do NOT start implementing until they
confirm.

```
WIND-UP COMPLETE

Workstream: {slug} (resolved via {method})
Resume prompt: memory/prompt_{slug}.md
State: {in-sync | drift: <one-line>}

NEXT ACTION (from prompt):
{recommended-next-action}

Proceed? [y/n]
```

## Context Management (active all session)

After wind-up completes, maintain awareness of context growth throughout the session.
Proactively recommend `/wind-down` when observable signals fire (see CLAUDE.md Context discipline).
Do not wait for the operator to notice. This is YOUR responsibility.
