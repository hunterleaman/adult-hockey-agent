#!/bin/bash
# PreToolUse hook for the `Read` matcher: when Claude reads a file >2000 lines
# without an explicit `limit`, auto-cap to first 2000 lines and inject a
# warning into additionalContext so the agent knows to use `offset` for further
# sections. Issue #32. ADR: docs/DECISIONS.md → "settings.json defensive-defaults".
#
# Output protocol (Claude Code PreToolUse hooks):
#   { "hookSpecificOutput": {
#       "hookEventName": "PreToolUse",
#       "updatedInput":  { "file_path": "<orig>", "limit": 2000 },
#       "additionalContext": "WARNING: This file has N lines. ..."
#     } }
#
# Bash 3.2 compatible. python3 only (no jq — matches all existing project
# hooks per substitute-subsystem ADR Q3 "no jq dep").
#
# Failure modes are all soft: malformed JSON, missing python3, nonexistent
# file, wc failure → exit 0 silently (let the actual Read tool surface any
# downstream error). The hook MUST NOT block reads.
set -euo pipefail

# Stage stdin to a tmp file so python3's stdin can be reused for the inline
# script while still receiving the original JSON via argv. Heredoc-driven
# python (`python3 - <<'PY'`) consumes stdin for the script body, so the
# tool-input JSON cannot also flow through stdin in the same invocation.
# Writing to a tmp file is the bash-3.2-safe portable solution.
INPUT_TMP="$(mktemp -t read-auto-limit.XXXXXX)" || exit 0
trap 'rm -f "$INPUT_TMP"' EXIT
cat > "$INPUT_TMP"

# Soft-fail if python3 unavailable. Without python3 we cannot reliably parse
# the JSON tool input, and the project's substitute subsystem already
# requires python3 for the rest of the kit, so absence here is a degraded
# environment rather than an expected steady state.
command -v python3 >/dev/null 2>&1 || exit 0

# Single python3 pass: parse input, decide whether to emit, format output.
# Stays soft on every error path (parse failure, missing fields, file stat
# failure, non-int limit). Caller's stdout receives either the
# hookSpecificOutput JSON (emit branch) or nothing (silent branch).
#
# Detection: file >2000 lines AND tool_input.limit not set. The 2000
# threshold mirrors Claude Code's documented Read default.
out="$(python3 - "$INPUT_TMP" <<'PY'
import json, os, sys

LIMIT_DEFAULT = 2000

try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        raw = f.read()
except Exception:
    sys.exit(0)

try:
    payload = json.loads(raw)
except Exception:
    sys.stderr.write("read-auto-limit: malformed input JSON; skipping\n")
    sys.exit(0)

if not isinstance(payload, dict):
    sys.exit(0)

ti = payload.get("tool_input")
if not isinstance(ti, dict):
    sys.exit(0)

# Honor explicit operator/agent intent: if `limit` is set (any non-None
# value), do nothing. The hook only fires when `limit` is absent or null.
if ti.get("limit") is not None:
    sys.exit(0)

fp = ti.get("file_path")
if not isinstance(fp, str) or not fp:
    sys.exit(0)

# Soft-fail on missing/unreadable file. Do NOT block; Read will surface the
# canonical error to the agent.
try:
    st = os.stat(fp)
except Exception:
    sys.exit(0)
# Reject non-regular files: FIFOs, devices, sockets, directories. Opening
# a FIFO or device blocks until data is available or until the hook
# timeout fires at 10s, turning every Read of such a path into a forced
# 10s stall. 0o170000 = S_IFMT mask; 0o100000 = S_IFREG. Use bitmask to
# avoid importing the stat module. Codex adversarial-review HIGH on
# PR #45.
is_regular = (st.st_mode & 0o170000) == 0o100000
if not is_regular:
    sys.exit(0)

# Count lines without slurping the entire file into memory: stream byte by
# byte at the OS level via a buffered read loop. python's `for line in f`
# already does this efficiently. Add 1 for a final unterminated line.
try:
    n = 0
    last_byte = b""
    with open(fp, "rb") as f:
        while True:
            chunk = f.read(65536)
            if not chunk:
                break
            n += chunk.count(b"\n")
            last_byte = chunk[-1:]
    # Trailing-newline-aware: if the file does not end with '\n', the final
    # line (post-last-newline) was not counted. Add 1 only if file is
    # non-empty AND last byte is not newline.
    if last_byte and last_byte != b"\n":
        n += 1
except Exception:
    sys.exit(0)

# Boundary: cap fires only when n > LIMIT_DEFAULT (2000). Exactly 2000
# lines stays silent — the agent's default Read already returns the entire
# file in that case.
if n <= LIMIT_DEFAULT:
    sys.exit(0)

msg = (
    "WARNING: This file has %d lines. Auto-limited to first %d. "
    "Use offset to read further sections." % (n, LIMIT_DEFAULT)
)
# Build updatedInput by cloning the original tool_input and only injecting
# `limit`. Preserve every other caller-provided field — notably `offset`,
# but also any future Read params — so we never silently rewrite the
# requested file region. Codex HIGH on PR #45: emitting a fresh
# file_path+limit dict drops `offset`, forcing a read from the file start
# when the agent asked for a later section.
updated_input = dict(ti)
updated_input["limit"] = LIMIT_DEFAULT
out = {
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "updatedInput": updated_input,
        "additionalContext": msg,
    }
}
sys.stdout.write(json.dumps(out))
PY
)" || true

# Emit on stdout if the python branch produced output. Empty stdout = silent
# (correct behavior for every soft-fail path above). Use printf %s to avoid
# echo's trailing-newline addition (Claude Code accepts either, but exact
# bytes are easier to reason about and to test).
if [ -n "$out" ]; then
  printf '%s' "$out"
fi

exit 0
