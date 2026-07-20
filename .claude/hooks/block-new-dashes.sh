#!/bin/bash
# PreToolUse hook for the `Write|Edit` matcher: block NEWLY-INTRODUCED
# U+2013 (en dash) / U+2014 (em dash) characters at write time (issue #92,
# parent PRD #90, 2026-07-16 scope-amendment deliverable 2).
#
# Decision table (per-codepoint OCCURRENCE COUNTS, not mere presence, so a
# single legacy dash in the baseline can never exempt additional new ones;
# PR #111 codex review):
#   Write: content carries MORE U+2013s or MORE U+2014s than the existing
#          file at file_path (missing file counts as zero of each)
#          -> BLOCK (exit 2, corrective message on stderr).
#   Edit:  new_string carries MORE U+2013s or MORE U+2014s than old_string
#          -> BLOCK (exit 2, corrective message on stderr).
#   Everything else -> PASS (exit 0, silent). In particular, edits merely
#   preserving or quoting legacy dashes (counts unchanged or reduced) pass,
#   so the 167 legacy dash bytes in docs/PITFALLS.md, docs/DECISIONS.md and
#   docs/CHANGELOG.md stay editable.
#
# Complements lib/dash-gate.sh (the diff-scoped /land gate): the gate catches
# anything that slipped into commits; this hook stops agents from writing new
# dashes in the first place.
#
# Block protocol (Claude Code PreToolUse hooks): exit 2 cancels the tool call
# and feeds stderr back to the agent. Every infra-error path soft-fails with
# exit 0 instead (malformed JSON, missing python3, unreadable file): the hook
# must never block a write for reasons other than the char policy.
#
# Bash 3.2 compatible. python3 only (no jq; matches all existing project
# hooks per substitute-subsystem ADR Q3 "no jq dep"). Stdin is staged to a
# tmp file so the heredoc-driven python can receive the original JSON via
# argv (same pattern as hooks/read-auto-limit.sh).
#
# This file itself must stay free of literal dash bytes (the characters are
# spelled as code points / chr() only); tests/test-block-new-dashes.sh T14.
set -euo pipefail

INPUT_TMP="$(mktemp -t block-new-dashes.XXXXXX)" || exit 0
trap 'rm -f "$INPUT_TMP"' EXIT
cat > "$INPUT_TMP"

# Soft-fail if python3 unavailable: we cannot reliably parse the tool-input
# JSON without it, and the kit already requires python3 elsewhere, so absence
# is a degraded environment rather than a policy violation.
command -v python3 >/dev/null 2>&1 || exit 0

rc=0
python3 - "$INPUT_TMP" <<'PY' || rc=$?
import json, os, stat, sys

EN = chr(0x2013)
EM = chr(0x2014)


def dash_counts(s):
    # Per-codepoint occurrence counts. Presence alone is not enough: one
    # legacy dash in the baseline must never exempt ADDITIONAL new dashes
    # (or the other codepoint) in the replacement.
    if not isinstance(s, str):
        return (0, 0)
    return (s.count(EN), s.count(EM))


def file_dash_counts(path):
    # Baseline counts from disk. Missing file -> (0, 0). Non-regular files
    # (a FIFO would block the read until the hook timeout) and unreadable
    # files -> None: the caller soft-passes, per the infra-error contract.
    try:
        st = os.stat(path)
    except FileNotFoundError:
        return (0, 0)
    except OSError:
        return None
    if not stat.S_ISREG(st.st_mode):
        return None
    en = em = 0
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            while True:
                chunk = f.read(1 << 20)
                if not chunk:
                    break
                en += chunk.count(EN)
                em += chunk.count(EM)
    except OSError:
        return None
    return (en, em)


try:
    with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as f:
        payload = json.loads(f.read())
except Exception:
    sys.exit(0)

if not isinstance(payload, dict):
    sys.exit(0)

tool = payload.get("tool_name")
ti = payload.get("tool_input")
if not isinstance(ti, dict):
    sys.exit(0)

if tool == "Write":
    new_counts = dash_counts(ti.get("content"))
    # Baseline: the file being overwritten. Equal-or-fewer counts mean the
    # Write is preserving legacy content, not introducing new dashes.
    base_counts = (0, 0)
    fp = ti.get("file_path")
    if isinstance(fp, str) and fp:
        base_counts = file_dash_counts(fp)
        if base_counts is None:
            sys.exit(0)
elif tool == "Edit":
    new_counts = dash_counts(ti.get("new_string"))
    # Baseline: the text being replaced. Quoting a legacy dash in both
    # old_string and new_string passes (counts unchanged).
    base_counts = dash_counts(ti.get("old_string"))
else:
    # Defensive: matcher is Write|Edit, but never misfire if invoked wider.
    sys.exit(0)

if new_counts[0] <= base_counts[0] and new_counts[1] <= base_counts[1]:
    sys.exit(0)

target = ti.get("file_path") or "<unknown target>"
sys.stderr.write(
    "BLOCKED: this %s introduces new en dash (U+2013) or em dash (U+2014) "
    "characters into %s.\n"
    "Char policy (issue #92): never add these characters. Use ASCII instead: "
    "'-' for ranges/asides, '->' for arrows, or rewrite the sentence.\n"
    "Legacy dashes already present in the replaced text or existing file "
    "pass unchanged; only newly-introduced dashes are blocked.\n"
    % (tool, target)
)
sys.exit(2)
PY

# Only the deliberate block path (python exit 2) blocks the tool call; any
# unexpected python failure degrades to pass so infra errors never block.
if [ "$rc" -eq 2 ]; then
  exit 2
fi
exit 0
