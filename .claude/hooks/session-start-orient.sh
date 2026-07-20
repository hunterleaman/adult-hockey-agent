#!/bin/bash
set -euo pipefail

# Dynamic session context: surfaces actionable state at session start.

# Helper: clean and remove a worktree directory.
# Shared with worktree-clean-before-remove.sh. Keep in sync.
_clean_worktree_dir() {
  local wt_path="$1"
  [ -d "$wt_path" ] || return 0
  if ! git worktree remove --force "$wt_path" 2>/dev/null; then
    rm -rf "$wt_path" 2>/dev/null || true
    git worktree prune 2>/dev/null || true
  fi
}

# Ghost-cwd guard: if this session's $PWD no longer exists on disk or is
# inside a worktree directory, fail LOUDLY with recovery directive.
REAL_PWD=$(pwd -P 2>/dev/null || echo "")
if [ -z "$REAL_PWD" ] || [ ! -d "$REAL_PWD" ]; then
  echo "⚠ GHOST CWD: session cwd does not exist on disk." >&2
  echo "  MANDATORY: cd to the project root as your FIRST action before ANY other command." >&2
elif [[ "$REAL_PWD" == */.claude/worktrees/* ]]; then
  echo "⚠ WORKTREE CWD: session launched from inside a worktree: $REAL_PWD" >&2
  echo "  Worktrees are ephemeral. When removed, this session's shell dies." >&2
  echo "  MANDATORY: cd to the project root as your FIRST action before ANY other command." >&2
fi

if git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null)

  # Tiered kit-detection (issue #77, self-host-validation F2). Identifies a
  # CANONICAL KIT-SOURCE-TREE that has been partially deleted (bootstrap.sh
  # or templates/settings.json or lib/ removed). Consumer installs do not
  # have `bootstrap.sh` at the project root; suppress kit-detect there so
  # downstream sessions are not spammed with CRITICAL warnings.
  #
  # Sentinel for "I'm in a kit-source-tree": `bootstrap.sh` at root. The
  # installer script is never delivered to consumers, so its presence is
  # the strongest single distinguisher we have. (We initially considered
  # OR'ing in `templates/CLAUDE.md` as a fallback signal for the "deleted
  # bootstrap.sh" corner case, but `templates/CLAUDE.md` is a perfectly
  # legitimate path in any markdown-template-generator project and would
  # produce false-positive CRITICAL banners in downstream consumers that
  # happened to use that name. Codex round 2 LOW.)
  #
  # When the sentinel fires but `lib/kit-detect.sh` itself is missing
  # (operator deleted lib/ or just the helper), fall back to an inline
  # CORE-marker probe + helper-presence probe. The helper-presence probe
  # ensures the banner fires even when all 3 CORE markers pass but
  # `lib/kit-detect.sh` was the only file removed (codex round 2 MED).
  #
  # The hook itself NEVER exits non-zero — that would break session-start —
  # so refusal here is surfaced as a CRITICAL stderr banner, mirroring the
  # worktree CRITICAL pattern above.
  #
  # Sentinel uses `-e || -L` (rather than `-f`) so a DANGLING symlink at
  # bootstrap.sh still trips the kit-detect path. With `-f` alone, an
  # operator who replaces bootstrap.sh with a broken symlink would
  # silently suppress kit-detect entirely; kit_detect_core then classifies
  # the corruption correctly via its own -f probe. Codex pass-1 MED.
  if [ -e "$TOPLEVEL/bootstrap.sh" ] || [ -L "$TOPLEVEL/bootstrap.sh" ]; then
    if [ -f "$TOPLEVEL/lib/kit-detect.sh" ]; then
      # shellcheck source=/dev/null
      . "$TOPLEVEL/lib/kit-detect.sh"
      # Single-probe pattern: capture stderr to a temp file so we read
      # filesystem state exactly once per probe. Without this, a
      # boolean-then-message double-call opens a TOCTOU window where
      # the count and the named markers can diverge. Codex pass-1 MED.
      #
      # mktemp guarded against `set -e` exit: if mktemp fails (full disk,
      # TMPDIR unwritable), fall through silently rather than break
      # session-start. The hook MUST exit 0 even when its own auxiliary
      # facilities are unavailable. Codex pass-2 MED.
      _KD_CORE_STDERR=$(mktemp -t cpt-kd-core.XXXXXX 2>/dev/null || echo "")
      if [ -n "$_KD_CORE_STDERR" ]; then
        if ! kit_detect_core "$TOPLEVEL" 2>"$_KD_CORE_STDERR"; then
          echo "CRITICAL: kit-detect: CORE markers missing at $TOPLEVEL; kit-source-tree is partially deleted." >&2
          while IFS= read -r _line; do
            [ -z "$_line" ] && continue
            printf '  %s\n' "$_line" >&2
          done < "$_KD_CORE_STDERR"
          unset _line
          echo "  Restore the missing marker(s) before continuing." >&2
        fi
        rm -f "$_KD_CORE_STDERR"
      fi
      unset _KD_CORE_STDERR
      _KD_SOFT_STDERR=$(mktemp -t cpt-kd-soft.XXXXXX 2>/dev/null || echo "")
      if [ -n "$_KD_SOFT_STDERR" ]; then
        _SOFT_COUNT=$(kit_detect_soft "$TOPLEVEL" 2>"$_KD_SOFT_STDERR" || echo 0)
        # Numeric guard: kit_detect_soft normally writes a single integer to
        # stdout, but harden against any non-numeric leak (helper edit
        # accident, future regression) so `[ ... -gt 0 ]` cannot error.
        # Codex pass-2 MED.
        case "$_SOFT_COUNT" in
          ''|*[!0-9]*) _SOFT_COUNT=0 ;;
        esac
        if [ "$_SOFT_COUNT" -gt 0 ]; then
          echo "WARNING: kit-detect: $_SOFT_COUNT SOFT kit marker(s) missing (proceeding):" >&2
          while IFS= read -r _line; do
            [ -z "$_line" ] && continue
            printf '  %s\n' "$_line" >&2
          done < "$_KD_SOFT_STDERR"
          unset _line
        fi
        rm -f "$_KD_SOFT_STDERR"
      fi
      unset _KD_SOFT_STDERR _SOFT_COUNT
    else
      # Inline fallback: lib/kit-detect.sh missing in a kit-source-tree.
      # Probe the 3 CORE markers directly + record that the helper itself
      # is missing (a corruption signal in its own right — fires banner
      # even when CORE markers all pass and only lib/kit-detect.sh was
      # removed). Same diagnostic shape as kit_detect_core's stderr.
      _MISSING=""
      [ ! -f "$TOPLEVEL/bootstrap.sh" ]               && _MISSING="${_MISSING}  kit-detect: CORE missing: bootstrap.sh
"
      [ ! -f "$TOPLEVEL/templates/settings.json" ]    && _MISSING="${_MISSING}  kit-detect: CORE missing: templates/settings.json
"
      [ ! -d "$TOPLEVEL/lib" ]                        && _MISSING="${_MISSING}  kit-detect: CORE missing: lib/
"
      # Always-include: lib/kit-detect.sh itself (we know it's absent by
      # virtue of being in this branch). Without this line, an operator
      # who deletes only the helper sees no banner at all.
      _MISSING="${_MISSING}  kit-detect: helper missing: lib/kit-detect.sh
"
      echo "CRITICAL: kit-detect: helper/CORE markers missing at $TOPLEVEL (inline probe; lib/kit-detect.sh absent):" >&2
      printf '%s' "$_MISSING" >&2
      echo "  Restore the missing marker(s) before continuing." >&2
      unset _MISSING
    fi
  fi

  # Active worktree count
  WT_COUNT=$(git worktree list 2>/dev/null | grep -v "^${TOPLEVEL} " | grep -c . || true)
  if [ "$WT_COUNT" -gt 0 ]; then
    echo "Worktrees: $WT_COUNT active" >&2
  fi

  # Ghost-worktree detection
  if [ -d "${TOPLEVEL}/.claude/worktrees" ]; then
    # Registered worktrees whose directories are gone
    while IFS= read -r wt_path; do
      [ -z "$wt_path" ] && continue
      [ "$wt_path" = "$TOPLEVEL" ] && continue
      if [ ! -d "$wt_path" ]; then
        echo "CRITICAL: Registered worktree has no directory: $wt_path" >&2
        echo "  Run 'git worktree prune' from main repo." >&2
      fi
    done < <(git worktree list 2>/dev/null | awk '{print $1}')

    # Orphan directories not registered with git
    for entry in "${TOPLEVEL}/.claude/worktrees"/*; do
      [ -d "$entry" ] || continue
      if ! git worktree list 2>/dev/null | awk '{print $1}' | grep -qx "$entry"; then
        echo "WARNING: Orphan directory in .claude/worktrees/ not registered: $entry" >&2
        echo "  Likely crashed-session leftover. Safe to 'rm -rf' after verifying no pending work." >&2
      fi
    done
  fi

  # Garbage-collect prunable worktrees
  GC_COUNT=0
  while IFS= read -r wt_line; do
    [ -z "$wt_line" ] && continue
    echo "$wt_line" | grep -q "prunable" || continue
    wt_path=$(echo "$wt_line" | awk '{print $1}')
    [ -z "$wt_path" ] && continue
    [ "$wt_path" = "$TOPLEVEL" ] && continue
    _clean_worktree_dir "$wt_path"
    GC_COUNT=$((GC_COUNT + 1))
  done < <(git worktree list 2>/dev/null)

  if [ "$GC_COUNT" -gt 0 ]; then
    git worktree prune 2>/dev/null || true
    echo "GC: cleaned $GC_COUNT stale worktree(s)" >&2
  fi

  # Branch state
  BRANCH=$(git branch --show-current 2>/dev/null || echo "")
  if [ -n "$BRANCH" ] && [ "$BRANCH" != "main" ]; then
    DIRTY=$(git status --porcelain 2>/dev/null | head -1 || echo "")
    if [ -n "$DIRTY" ]; then
      echo "WARNING: On branch '$BRANCH' with uncommitted changes" >&2
    else
      echo "On branch '$BRANCH' (clean)" >&2
    fi
  fi

  # Pipeline sentinel check
  SENTINEL="dist/scheduler.js"
  if [ "$SENTINEL" != "dist/scheduler.js" ] && [ -n "$SENTINEL" ] && [ "$SENTINEL" != "n/a" ] && [ ! -f "$SENTINEL" ]; then
    echo "WARNING: Pipeline/build not run (missing $SENTINEL). Run /verify." >&2
  fi

  # Config-state gate (replaces pre-#29 heading-equality heuristic).
  # Anchors on `.claude/.config` null-count rather than CLAUDE.md heading text,
  # which was a false-negative trap: an operator who edited body tokens but
  # not the heading line stayed silent forever. See docs/PITFALLS.md
  # "Heading-equality is too narrow a sentinel".
  #
  # Five states:
  #   ok              — config exists, valid JSON, no null values
  #   missing         — `.claude/.config` absent (bootstrap not run)
  #   corrupt         — config exists but invalid JSON (mid-write race / hand-edit error)
  #   corrupt_unknown — python3 unavailable; integrity check degraded
  #   incomplete      — valid JSON but ≥1 unfilled (null) value
  #
  # Codex review fix (PR #42 MED-1): null-count uses python3 JSON parser, NOT
  # grep, so a string value containing the literal text `": null` cannot
  # masquerade as a top-level null and force false `incomplete`. Single
  # python3 invocation does both validity check and null-count, exit code 0
  # = ok, 1 = corrupt, count printed to stdout for the incomplete branch.
  CONFIG_STATE=ok
  UNFILLED_COUNT=0
  if [ ! -f .claude/.config ]; then
    CONFIG_STATE=missing
  elif command -v python3 >/dev/null 2>&1; then
    parse_out="$(python3 -c "
import json, sys
try:
    d = json.load(open('.claude/.config'))
except Exception:
    sys.exit(1)
if not isinstance(d, dict):
    sys.exit(1)
print(sum(1 for v in d.values() if v is None))
" 2>/dev/null)" && parse_rc=0 || parse_rc=$?
    if [ "${parse_rc:-1}" -ne 0 ]; then
      CONFIG_STATE=corrupt
    elif [ "${parse_out:-0}" -gt 0 ]; then
      CONFIG_STATE=incomplete
      UNFILLED_COUNT="$parse_out"
    fi
  else
    CONFIG_STATE=corrupt_unknown
  fi
  case "$CONFIG_STATE" in
    missing)         echo "Template setup not started: .claude/.config not found. Run: bash bootstrap.sh" >&2 ;;
    corrupt)         echo "Template config corrupt or mid-write: .claude/.config invalid JSON or wrong shape. Check .claude/.config.bak or re-run bootstrap." >&2 ;;
    corrupt_unknown) echo "Template config integrity check skipped: python3 unavailable. Install python3 to enable validation." >&2 ;;
    incomplete)      echo "Template setup incomplete: $UNFILLED_COUNT config key(s) unfilled in .claude/.config. Edit .claude/.config or run bootstrap." >&2 ;;
  esac

  # Token-leakage check: fires for `ok` AND `corrupt_unknown` (degraded mode
  # — python3 missing means we can't classify nulls, but token-leakage scan
  # is grep-only and remains useful). Suppressed for `missing`, `corrupt`,
  # `incomplete` to avoid triple-warning fatigue on configs whose primary
  # issue is upstream of placeholder rendering. Codex review fix
  # (PR #42 MED-2): preserves the leakage signal in python3-absent setups.
  if [ "$CONFIG_STATE" = "ok" ] || [ "$CONFIG_STATE" = "corrupt_unknown" ]; then
    UNFILLED=$(grep -rn '{{[A-Z_]*}}' .claude/commands/ CLAUDE.md 2>/dev/null | grep -v audit-kit.md | head -3 || true)
    if [ -n "$UNFILLED" ]; then
      UNFILLED_TOK_COUNT=$(grep -rn '{{[A-Z_]*}}' .claude/commands/ CLAUDE.md 2>/dev/null | grep -v audit-kit.md | wc -l | tr -d ' ')
      echo "NOTE: $UNFILLED_TOK_COUNT unfilled placeholder token(s) found. Run lib/substitute.sh render-all .claude/.config." >&2
    fi
  fi

  # Open PRs (timeout-guarded, non-fatal)
  PR_COUNT=$(timeout 5 gh pr list --json number --jq 'length' 2>/dev/null || echo "")
  if [ -n "$PR_COUNT" ] && [ "$PR_COUNT" != "0" ]; then
    echo "Open PRs: $PR_COUNT" >&2
  fi
fi

exit 0
