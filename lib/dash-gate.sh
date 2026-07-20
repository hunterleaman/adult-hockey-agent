#!/usr/bin/env bash
# lib/dash-gate.sh: diff-scoped portable en/em dash gate (issue #92, PRD #90).
#
# Purpose
# -------
# Block NEWLY-ADDED U+2013 (en dash) / U+2014 (em dash) characters while
# leaving legacy occurrences on the base branch inert. The gate scans ONLY
# lines added relative to the base ref (git diff base...HEAD -U0, '+' lines),
# so the 167 legacy dash bytes in docs/PITFALLS.md, docs/DECISIONS.md and
# docs/CHANGELOG.md never trip it: no legacy sweep, no exclude-list to rot,
# full path coverage retained (2026-07-16 scope amendment on issue #92).
#
# Portability (donor: led-netsuite-mcp-sandbox fe53db0)
# -----------------------------------------------------
# BSD/macOS grep has no PCRE support: the donor's original PCRE-flag gate
# exited 2 there and an appended '|| true' swallowed it, so the gate always
# passed without scanning. This gate matches the raw UTF-8 byte pattern
# $'\xe2\x80\x93|\xe2\x80\x94' with plain grep -E under LC_ALL=C, which
# behaves identically under BSD grep, GNU grep, and ugrep. ANSI-C $'...'
# quoting requires bash; the kit already assumes bash. Regression coverage:
# tests/test-dash-gate.sh (PCRE-rejecting grep shim).
#
# Usage
# -----
#   bash lib/dash-gate.sh check [<base-ref>]
#
# Environment
# -----------
#   DASH_GATE_ROOT  Repo root to operate on (default "."). All git commands
#                   run as `git -C "$DASH_GATE_ROOT"` per the CWD-Discipline
#                   HARD RULE: callers never change CWD.
#   DASH_GATE_BASE  Base ref used when <base-ref> is omitted.
#
# Base resolution when neither <base-ref> nor DASH_GATE_BASE is given:
# origin/main if resolvable, else main, else exit 2.
#
# Exit codes
# ----------
#   0  clean (no added line carries U+2013/U+2014)
#   1  violations found; "file: line-content" pairs printed on stdout
#   2  usage or environment error (not a git repo, unresolvable base ref,
#      grep itself failed). Never silently passes on infra errors.
set -euo pipefail

# Raw UTF-8 bytes for U+2013 (0xE2 0x80 0x93) and U+2014 (0xE2 0x80 0x94),
# alternated for grep -E. Kept as escapes so this file itself carries no
# literal dash bytes (tests/test-dash-gate.sh T13).
DASH_BYTES=$'\xe2\x80\x93|\xe2\x80\x94'

_dash_gate_usage() {
  cat >&2 <<'EOF'
usage: bash lib/dash-gate.sh check [<base-ref>]

Diff-scoped en/em dash gate: fails (exit 1) when any line ADDED relative to
<base-ref> (default: origin/main, else main) contains U+2013 or U+2014.
Env: DASH_GATE_ROOT (repo root, default "."), DASH_GATE_BASE (default base).
EOF
}

dash_gate_check() {
  local root="${DASH_GATE_ROOT:-.}"
  local base="${1:-${DASH_GATE_BASE:-}}"

  if ! git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
    echo "dash-gate: not a git repository: $root" >&2
    return 2
  fi

  if [ -z "$base" ]; then
    if git -C "$root" rev-parse --verify --quiet origin/main >/dev/null 2>&1; then
      base="origin/main"
    elif git -C "$root" rev-parse --verify --quiet main >/dev/null 2>&1; then
      base="main"
    else
      echo "dash-gate: cannot resolve a base ref (no origin/main, no main); pass one explicitly" >&2
      return 2
    fi
  elif ! git -C "$root" rev-parse --verify --quiet "$base" >/dev/null 2>&1; then
    echo "dash-gate: base ref not found: $base" >&2
    return 2
  fi

  # Added lines relative to merge-base(base, HEAD), prefixed "file: ".
  # -U0 drops context lines; --no-ext-diff/--no-color/--no-prefix-tolerant
  # awk keep the stream machine-parseable regardless of repo diff config.
  # The awk tracks hunk state: '+++ ' is a file header ONLY outside hunks.
  # Inside a hunk an ADDED source line whose content begins with '++ ' is
  # emitted by git as '+++ ...' and must still be scanned, not mistaken for
  # a header (PR #111 codex review). The pipeline's exit status is captured
  # explicitly: this function runs in a '||' context where errexit is
  # suppressed, so an unchecked git-diff failure (e.g. no merge base) would
  # otherwise yield empty output and a silent pass.
  local added diff_rc
  set +e
  added="$(git -C "$root" diff --no-color --no-ext-diff -U0 "$base...HEAD" \
    | LC_ALL=C awk '
        /^diff /               { in_hunk = 0; next }
        /^@@/                  { in_hunk = 1; next }
        !in_hunk && /^\+\+\+ / { f = $0; sub(/^\+\+\+ /, "", f); sub(/^b\//, "", f); next }
        in_hunk && /^\+/       { print f ": " substr($0, 2) }
      ')"
  diff_rc=$?
  set -e
  if [ "$diff_rc" -ne 0 ]; then
    echo "dash-gate: git diff against $base failed (rc=$diff_rc); refusing to pass silently." >&2
    return 2
  fi
  if [ -z "$added" ]; then
    return 0
  fi

  local violations rc
  set +e
  violations="$(printf '%s\n' "$added" | LC_ALL=C grep -E "$DASH_BYTES")"
  rc=$?
  set -e

  case "$rc" in
    0)
      echo "dash-gate: BLOCKED: lines added relative to $base introduce en dash (U+2013) or em dash (U+2014):" >&2
      printf '%s\n' "$violations"
      echo "dash-gate: replace each flagged character with ASCII ('-', '->', or rewrite) and re-run." >&2
      echo "dash-gate: legacy dashes already on $base are inert; only added lines are scanned." >&2
      return 1
      ;;
    1)
      return 0
      ;;
    *)
      echo "dash-gate: grep failed (rc=$rc); refusing to pass silently." >&2
      return 2
      ;;
  esac
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    check)
      shift
      local rc=0
      dash_gate_check "$@" || rc=$?
      return "$rc"
      ;;
    -h|--help|help)
      _dash_gate_usage
      return 0
      ;;
    *)
      echo "dash-gate: unknown command: '${cmd}'" >&2
      _dash_gate_usage
      return 2
      ;;
  esac
}

main "$@"
