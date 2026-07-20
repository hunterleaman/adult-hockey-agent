#!/bin/bash
# Context Tracker: SessionStart hook
# Creates a session-specific state file for context monitoring.
# State file: /tmp/claude-ctx-{session_id}
#   line 1: transcript path
#   line 2: warn state (0-2)
#   line 3: session_id
#   line 4: enabled (1=enabled, 2=disabled)
#   line 5: budget_tokens

# Disable entirely via env var (add export CTX_ENABLED=0 to shell profile)
[ "${CTX_ENABLED:-1}" = "0" ] && exit 0

# State directory (default /tmp). Overridable via CTX_STATE_DIR so tests/sandboxes
# can isolate state instead of sharing /tmp. All three ctx-tracker hooks honor it.
CTX_STATE_DIR="${CTX_STATE_DIR:-/tmp}"

# Purge stale state files older than 1 day (housekeeping; no-op if dir absent).
find "$CTX_STATE_DIR" -maxdepth 1 -name 'claude-ctx-*' -mtime +1 -delete 2>/dev/null || true

INPUT=$(cat)
_after="${INPUT#*\"session_id\":\"}"
[ "$_after" = "$INPUT" ] && exit 0
SESSION_ID="${_after%%\"*}"
[ -z "$SESSION_ID" ] && exit 0

# Create the state dir only once we have a valid session to write (init is the
# writer, so an advertised non-existent CTX_STATE_DIR does not silently disable
# tracking; check/compact only read from it). Session-less invocations exit
# above without side-effecting the directory.
mkdir -p "$CTX_STATE_DIR" 2>/dev/null || true
# Fail OBSERVABLY, not silently: a misconfigured CTX_STATE_DIR (uncreatable or
# unwritable parent) would otherwise let the state write fail with only a cryptic
# redirect error, leaving check/compact to no-op forever with no signal that the
# tracker is off. Warn to stderr and exit 0 (SessionStart must never break the
# session). The default /tmp is always writable, so this never fires unless the
# operator overrode CTX_STATE_DIR to a broken path.
if [ ! -d "$CTX_STATE_DIR" ] || [ ! -w "$CTX_STATE_DIR" ]; then
  echo "context-tracker: CTX_STATE_DIR not writable (${CTX_STATE_DIR}); context tracking disabled this session" >&2
  exit 0
fi
CTX_FILE="${CTX_STATE_DIR}/claude-ctx-${SESSION_ID}"

# Transcript: ~/.claude-lx/projects/{slug}/{session_id}.jsonl
CONFIG_DIR="${HOME}/.claude-lx"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
SLUG="${PROJECT_DIR//[^a-zA-Z0-9-]/-}"
TRANSCRIPT="${CONFIG_DIR}/projects/${SLUG}/${SESSION_ID}.jsonl"

# Atomic write: always-on with default budget. Default is a Tier-0 substitute
# placeholder (issue #99): CTX_BUDGET_TOKENS env override wins; else the
# kit-config default rendered from .claude/.config (125000 unless overridden).
# The raw placeholder is kept OUTSIDE the `${...}` expansion: bash closes a
# parameter expansion at the FIRST `}`, so nesting the double-brace token in the
# `:-` default would corrupt an env-set override to e.g. `200000}}` on an
# unrendered fresh install, silently dropping it. The two-step form honors the
# env override verbatim in BOTH rendered and unrendered hooks; the default
# (rendered 125000, or the raw token pre-`render-all`) applies only when the
# override is unset, and the guard below coerces the raw token.
BUDGET="${CTX_BUDGET_TOKENS:-}"
[ -z "$BUDGET" ] && BUDGET="125000"
# Guard: if BUDGET is not a positive integer (e.g. an unrendered
# CTX_BUDGET_TOKENS placeholder before `render-all`, or a malformed env/config
# value), fall back to a safe numeric default so context-tracker-check.sh
# arithmetic never breaks. Digit-only values <=10 digits are base-10 normalized
# so a leading zero is not misread as octal (0125000, or an invalid 008 that
# would abort arithmetic); >10 digits (implausible, ~10B tokens) are rejected to
# avoid 64-bit overflow wraparound. Bash 3.2-compatible.
case "$BUDGET" in
  '' | *[!0-9]* ) BUDGET=125000 ;;
  * ) if [ "${#BUDGET}" -le 10 ]; then BUDGET=$((10#$BUDGET)); else BUDGET=125000; fi ;;
esac
[ "$BUDGET" -gt 0 ] 2>/dev/null || BUDGET=125000
_tmp="${CTX_FILE}.$$"
printf '%s\n0\n%s\n1\n%s\n' "$TRANSCRIPT" "$SESSION_ID" "$BUDGET" > "$_tmp"
mv "$_tmp" "$CTX_FILE"

exit 0
