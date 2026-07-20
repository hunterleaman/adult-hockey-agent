Quick project status orientation. Runs automatically at session start. Keep output compact.

## Output Discipline

HARD RULES in force: **Delegate to Subagents** (ALL state gathers run in ONE
Explore subagent, never serial raw git/gh dumps in the main thread) and
**Run In Background** (any dispatched Agent sets `run_in_background: true`).

Route noise to logs; surface only the essentials:
- Allocate ONE per-invocation log dir up front:
  `LOGDIR="$(mktemp -d -t orient.XXXXXX)"` (never a fixed
  `/tmp/orient-<step>.log`: a predictable path is symlink-clobber bait and lets
  parallel sessions truncate each other's logs). Route each sync/fetch/gather
  command to `"$LOGDIR/<step>.log" 2>&1` (e.g. `"$LOGDIR/sync.log"`,
  `"$LOGDIR/fetch.log"`, `"$LOGDIR/snapshot.log"`). On an unexpected non-zero
  exit (a no-match `grep` is not a failure), tail that log, halt, and report.
- Only these may surface in the main thread: the state-snapshot synthesis
  block, ledger-validation `WARN:` lines, the Batched Prune Gate + per-item
  review prompts, failure-path log tails, and the final report. Everything
  else stays in the logs.

## Sync Local Repo

Derive `REPO_ROOT` once so every git op runs `git -C "$REPO_ROOT" ...` per the CWD-Discipline HARD RULE (`/orient` runs in the main session and MUST NOT change CWD).

```bash
# `|| true` keeps the derivation from aborting under `set -e` when not in a git
# repo; the ${REPO_ROOT:-$PWD} fallback then anchors MEM_DIR on the launch CWD.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
# Memory home: tracked repo-root memory/ dir. All memory reads resolve here.
MEM_DIR="${REPO_ROOT:-$PWD}/memory"
```

Before gathering data, pull latest from origin to keep the local repo in sync:
```bash
git -C "$REPO_ROOT" pull --ff-only origin main > "$LOGDIR/sync.log" 2>&1 || true
# CD-6: prune stale remote-tracking refs BEFORE staleness classification.
# Unpruned refs make remote-deleted branches look live and merged branches
# look remote-backed, producing false stale/live calls downstream. A FAILED
# fetch is recorded (not swallowed): unpruned refs would silently corrupt the
# stale/live classification below.
FETCH_PRUNE_FAILED=0
git -C "$REPO_ROOT" fetch --prune origin > "$LOGDIR/fetch.log" 2>&1 || FETCH_PRUNE_FAILED=1
```
If on a feature branch, skip the pull (don't mess with in-progress work) but still run the `fetch --prune`.

If `FETCH_PRUNE_FAILED=1` (remote unreachable, auth failure, ...): surface
`WARN: fetch --prune failed; remote-derived staleness unverified (see $LOGDIR/fetch.log)`
on the report's `Warnings:` line, and treat every remote-derived signal below
(remote-merged listing, `ls-remote` verification) as uncertain -- candidates
stay in the count annotated `(uncertain: fetch failed)` and are never deleted.

## State Snapshot (one Explore subagent, under 250 words)

Dispatch ONE Explore subagent for ALL gathers -- git, gh, and memory in a
single pass -- returning ONE synthesis block, **under 250 words**, that the
main session renders directly. No serial fan-out of gather calls from the main
thread. The subagent runs the gathers below (each redirected to
`"$LOGDIR/snapshot.log" 2>&1`, tailing + halting only on an unexpected
non-zero exit):

```bash
git -C "$REPO_ROOT" branch --show-current
git -C "$REPO_ROOT" status --short | head -10
git -C "$REPO_ROOT" worktree list
git -C "$REPO_ROOT" branch --merged main | grep -v '\*\|main'
# Per-repo: extend the grep below to exclude permanent state branches (e.g., 'indexing-state\|quality-report-state\|social-state')
git -C "$REPO_ROOT" branch -r --merged main | grep -v 'origin/main\|origin/HEAD' | head -20
git -C "$REPO_ROOT" log --oneline -3
# CD-5: GitHub-remote guard. Run the gh gathers ONLY when origin is a GitHub
# remote AND the gh CLI exists; otherwise degrade gracefully (skip them, keep
# orienting) and surface the reason on the report's Remote: line.
REMOTE_URL="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
GH_STATE="github"
case "$REMOTE_URL" in
  *github.com*) : ;;
  *) GH_STATE="non-github remote (${REMOTE_URL:-no origin})" ;;
esac
command -v gh >/dev/null 2>&1 || GH_STATE="gh unavailable (gh CLI not installed)"
if [ "$GH_STATE" = "github" ]; then
  gh pr list --limit 10
  gh issue list --limit 10 --state open
fi
```

The remote-merged check catches stranded branches on origin that bypassed PR-based auto-delete (direct pushes to main, locally-merged then pushed, etc.). If the count exceeds 5, report as a stale-branch leak: name the count, list up to 5 examples, and recommend `git push origin --delete <branch>` sweep. Do NOT auto-delete.

The subagent also reads memory (`$MEM_DIR/MEMORY.md`) for active workstream
status. Its synthesis reports: branch + clean/dirty, worktrees, last commits,
merged local/remote branch candidates, PR/issue counts (or the `$GH_STATE`
reason when the gh gathers were skipped), the memory pointer, and stale-branch
leak status.

## Read the most recent workstream resume prompt (REQUIRED)

`/wind-down` writes workstream-scoped resume files at `memory/prompt_{slug}.md`
(under `$MEM_DIR`). MEMORY.md only contains one-line pointers. The
VERIFIED/ASSUMED/DO-FIRST handoff lives in the file itself.

Find the most recently modified `prompt_*.md` under `$MEM_DIR` and ASSIGN it to
`$PROMPT_PATH` (the ledger-validation step below reads `$PROMPT_PATH`):

```bash
PROMPT_PATH="$(ls -t "$MEM_DIR"/prompt_*.md 2>/dev/null | head -1 || true)"
```

Read it. If its `written_at` frontmatter is within the last 72h, its `DO FIRST
on resume` block is the authoritative next action. Surface it in the `Next:`
line of the report.

## Validate resume prompt against the workstream ledger (slice #61)

After identifying the most recent `prompt_*.md`, validate its DO-FIRST against
the per-workstream phase ledger in `.workstream/{slug}.md`. Both surfaces are
**advisory**: `/orient` warns but does not refuse.

```bash
# Resolve the active slug via the cascade (--slug -> branch -> single-open file).
# zsh-safe wrapper: `source lib/workstream.sh` only works under bash, so call
# every workstream lib function via a `bash -c` subshell. (F11, issue #75.)
# #79 Issue 2: wrapper failures must SURFACE, never silently disable ledger
# validation. Probe the lib ONCE first; on probe failure print a ONE-LINE
# warning and skip validation (advisory -- warn, never block). After a clean
# probe, helper stderr routes to "$LOGDIR/wslib.log" (never /dev/null) and each
# helper's rc is switched: documented refusals stay silent (logged only), while
# an UNDOCUMENTED rc (e.g. 127 missing function) warns. A clean probe followed
# by a documented no-slug refusal is the legitimate no-slug case: silent.
if ! bash -c 'source lib/workstream.sh' 2>"$LOGDIR/wslib.log"; then
  echo "WARN: lib/workstream.sh unavailable or broken; skipping ledger validation (advisory)"
  WSLIB_OK=0
  SLUG=""
else
  WSLIB_OK=1
  # Resolver contract (lib/workstream.sh): rc=0 slug on stdout; rc=1 cannot-
  # resolve (diagnostic on stderr); rc=2 gate N/A (absent/empty .workstream/).
  # rc 1/2 are documented refusals -- log-only. Anything else is invocation
  # breakage -> WARN.
  _slug_rc=0
  SLUG="$(bash -c 'source lib/workstream.sh && _workstream_resolve_slug "$@"' _ 2>>"$LOGDIR/wslib.log")" || _slug_rc=$?
  if [ "$_slug_rc" -gt 2 ]; then
    SLUG=""
    echo "WARN: workstream slug resolution errored (rc=$_slug_rc); see $LOGDIR/wslib.log"
  elif [ "$_slug_rc" -ne 0 ]; then
    SLUG=""
  fi
fi

# 1) Phase-skip warning. If the prompt's DO-FIRST proposes a command whose
#    prerequisite is not in the ledger, surface a one-line warning naming the
#    recommended correction.
if [ -n "$SLUG" ] && [ -n "$PROMPT_PATH" ]; then
  # $PROMPT_PATH is the newest prompt by mtime, which in parallel workstreams
  # may belong to a DIFFERENT slug. Feeding a mismatched prompt to the phase-
  # skip validator returns rc=2 with its diagnostic on stderr (discarded here),
  # so the mismatch would be silent. Guard on basename: only phase-skip this
  # slug's own prompt; warn (don't silently swallow) when the newest is another
  # workstream's.
  if [ "$(basename "$PROMPT_PATH")" = "prompt_${SLUG}.md" ]; then
    # Contract (lib/workstream.sh): rc=0 no skip; rc=1 skip detected +
    # correction on stdout; rc=2 usage/helper error. With a slug-matched
    # prompt, rc=2 or any undocumented rc means breakage -> WARN (never a
    # silent 'Warnings: none' while validation is actually broken).
    _skip_rc=0
    CORRECTION="$(bash -c 'source lib/workstream.sh && _workstream_check_prompt_phase_skip "$@"' _ "$SLUG" "$PROMPT_PATH" 2>>"$LOGDIR/wslib.log")" || _skip_rc=$?
    case "$_skip_rc" in
      0) : ;;
      1)
        if [ -n "$CORRECTION" ]; then
          echo "WARN: resume prompt proposes a phase-skip; recommended: $CORRECTION"
        else
          echo "WARN: phase-skip detected but helper returned no correction; see $LOGDIR/wslib.log"
        fi
        ;;
      *)
        echo "WARN: phase-skip validation errored (rc=$_skip_rc); see $LOGDIR/wslib.log"
        ;;
    esac
  else
    echo "WARN: newest resume prompt ($(basename "$PROMPT_PATH")) is not for the resolved workstream '$SLUG'; skipping phase-skip validation"
  fi
fi

# 2) Non-conformant workstream-file count. If >0, surface a one-line warning.
#    Skipped when the lib probe failed (the WARN above already covers it).
#    A failing invocation warns instead of masquerading as count=0.
if [ "${WSLIB_OK:-0}" -eq 1 ]; then
  _nonconf_rc=0
  NONCONF="$(bash -c 'source lib/workstream.sh && _workstream_count_nonconformant "$@"' _ 2>>"$LOGDIR/wslib.log")" || _nonconf_rc=$?
  if [ "$_nonconf_rc" -ne 0 ]; then
    echo "WARN: non-conformant count errored (rc=$_nonconf_rc); see $LOGDIR/wslib.log"
  elif [ "${NONCONF:-0}" -gt 0 ]; then
    echo "WARN: $NONCONF non-conformant .workstream/ file(s) (missing/malformed frontmatter)"
  fi
fi
```

Surface the warnings on the final report's `Warnings:` line (folded, one clause
each). Do not block on any warning; the operator decides what to do.

## Stale Classification + Batched Prune Gate

For each worktree (other than the main repo path) and each local branch
returned by `git branch --merged main`, classify staleness:

A branch/worktree is **verifiably stale** iff ALL of:
1. Local branch is merged into `main` (in `git branch --merged main` output).
2. No remote tracking branch (`git ls-remote --heads origin <name>` empty).
3. No active worktree backing it (`git worktree list --porcelain` lists no path for it), OR the worktree's path exists but has no uncommitted changes and no unpushed commits.
4. No other-session ownership signal (no recently-modified files under the worktree path within the last 30 minutes).

If any check is uncertain, the candidate stays in the count annotated
`(uncertain: review manually)`: report but do NOT delete. Note which signal
was ambiguous.

Then present ONE consolidated gate for the whole prune class (skeleton element
3; never per-item prompts up front):

```
Prune review available: {B} stale branches, {W} stale worktrees.
Review and prune now? [y/n]
```

On `n`: skip pruning, continue to the final report. On `y`: enter per-item review;
each candidate gets one line:
```
Stale: <name> (merged, no remote, no worktree). Clean? [y/n]
```

On per-item `y`: run the appropriate cleanup:
- Branch only: `git -C <repo> branch -d <name>` (the `-d` form, not `-D`; refuses unmerged as a safety net).
- Worktree path: `git -C <repo> worktree remove <path> && git -C <repo> worktree prune`, then `rm -rf <path>` if a leftover dir remains.

On per-item `n`: leave it, move on. Never execute a destructive action without
its gate.

This gate is distinct from post-merge cleanup, which runs unconditionally in
the same turn as `gh pr merge` (see `/land`). This gate handles cruft observed
at session start where the operator hasn't acted yet.

## Final Report (keep under 8 lines)

Print the fenced `{placeholder}` template below, capped at **8 lines**
(non-blank; blank separators exempt). Expand with PR/issue details only if
there are open items, still within the cap.

```
ORIENT COMPLETE

Branch: {branch} | {clean/dirty} | {worktrees: N active}
Last: {hash} {message} ({time})
PRs: {count | unavailable} open | Issues: {count | unavailable} open | Remote: {github | $GH_STATE reason}
Stale: {B} branches / {W} worktrees | remote leak: {count} (examples: {up to 5 names})
Warnings: {none | WARN clauses, folded}
Next: {single highest-priority action}
```

Then STOP. No trailing prose. Be direct. No preamble.
