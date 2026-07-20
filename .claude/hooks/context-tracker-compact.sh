#!/bin/bash
# Context Tracker: PostCompact hook
# Resets warn state after automatic context compression.
# Always-on: skips if manually disabled.

# --- Resolve session ID ---
_sid="${CLAUDE_SESSION_ID:-}"
if [ -z "$_sid" ]; then
  INPUT=$(cat 2>/dev/null) || true
  if [ -n "${INPUT:-}" ]; then
    _after="${INPUT#*\"session_id\":\"}"
    [ "$_after" != "$INPUT" ] && _sid="${_after%%\"*}"
  fi
fi

# State directory (default /tmp). Overridable via CTX_STATE_DIR so tests and
# sandboxes can isolate state; all three ctx-tracker hooks honor it.
CTX_STATE_DIR="${CTX_STATE_DIR:-/tmp}"
if [ -n "$_sid" ]; then
  CTX_FILE="${CTX_STATE_DIR}/claude-ctx-${_sid}"
else
  _dir="${CLAUDE_PROJECT_DIR:-$(pwd)}"
  CTX_FILE="${CTX_STATE_DIR}/claude-ctx-${_dir//[^a-zA-Z0-9]/-}"
fi

[ ! -f "$CTX_FILE" ] && exit 0

# Read all 5 fields
TRANSCRIPT="" _fsid="" ENABLED="" FILE_BUDGET=""
{ read -r TRANSCRIPT; read -r _; read -r _fsid; read -r ENABLED; read -r FILE_BUDGET; } < "$CTX_FILE" 2>/dev/null || true

# Skip if not opted in
[ "${ENABLED:-0}" != "1" ] && exit 0
[ -z "$TRANSCRIPT" ] && exit 0

# Reset warn state to 0 (compression gives fresh headroom), preserve other fields
_tmp="${CTX_FILE}.$$"
printf '%s\n0\n%s\n%s\n%s\n' "$TRANSCRIPT" "${_fsid:-}" "${ENABLED:-1}" "${FILE_BUDGET:-0}" > "$_tmp"
mv "$_tmp" "$CTX_FILE"

echo "CONTEXT COMPRESSED: automatic compression occurred. Earlier conversation state may be degraded." >&2
printf '{"hookSpecificOutput":{"hookEventName":"PostCompact","additionalContext":"CONTEXT COMPRESSED: Automatic context compression just occurred. Earlier conversation state may be lost. Run /wind-down NOW to preserve current work state. Do not start new work."}}'

exit 0
