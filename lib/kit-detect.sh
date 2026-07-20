#!/usr/bin/env bash
# lib/kit-detect.sh — tiered kit-detection (issue #77, self-host-validation F2).
#
# Replaces the legacy narrow 2-marker check (`{commands/, templates/settings.json}`
# at bootstrap.sh:333-336) which silently passes when a consumer deletes either
# `bootstrap.sh` or `lib/` while keeping the other markers. Per the workstream
# grill decision #4 (locked post-codex, 2026-05-11), the kit-source-identity
# signature is split into two tiers:
#
#   CORE (REFUSE if any missing): bootstrap.sh + templates/settings.json + lib/
#     -> defines a kit. Conjunction-of-marker: ALL three required.
#     -> Missing = the consumer is operating without a usable kit. Caller refuses.
#
#   SOFT (WARN-only): commands/ + hooks/ + tests/ + docs/hard-rules/ + memory/
#     -> nice-to-have; intentional consumer omissions (deleted commands/, skipped
#        hooks/, no tests/, no docs/hard-rules/, no memory/) are legitimate
#        customizations. Caller warns but proceeds. docs/hard-rules/ joined the
#        SOFT set in PRD #86 / issue #87 when the HARD RULE bodies relocated out
#        of CLAUDE.md into per-rule body files. memory/ joined in issue #100
#        (cpt-kit-harvest W2) when bootstrap began seeding the tracked memory/
#        home; its absence signals a pre-#100 or hand-stripped kit.
#
# Functions:
#   kit_detect_core ROOT
#     Exit 0 if all 3 CORE markers present at ROOT; exit 1 otherwise.
#     Names of missing markers are written to stderr (one per line, prefixed
#     `kit-detect: CORE missing: `). Safe to call with a non-existent ROOT
#     (classifies as all-missing, no traceback).
#
#   kit_detect_soft ROOT
#     Prints the count of MISSING soft markers to stdout (0..5); exits 0
#     unconditionally. Names of missing markers are written to stderr
#     (one per line, prefixed `kit-detect: SOFT missing: `). Safe to call
#     with a non-existent ROOT (count = 5, no traceback).
#
# Side effects: none beyond stdout/stderr. No global variable pollution
# beyond the function definitions themselves.
#
# Contract notes:
# - ROOT is treated as a literal directory prefix; no symlink dereferencing
#   beyond the implicit dereference performed by `test -e` / `test -d`. The
#   markers themselves can be symlinks (matches the self-host case where
#   `.claude/commands/*` are symlinks to `commands/*`).
# - Empty ROOT argument is treated as missing-everything (defensive; would
#   otherwise resolve to current-CWD-relative paths and surprise the caller).

# CORE markers: conjunction-of-marker; all three required for the kit to be
# considered installed. File presence test for the two leaf files, directory
# presence test for `lib/` (because every consumer of `lib/` sources at least
# one file from it).
kit_detect_core() {
  local root="${1-}"
  if [ -z "$root" ]; then
    printf 'kit-detect: CORE missing: bootstrap.sh\n' >&2
    printf 'kit-detect: CORE missing: templates/settings.json\n' >&2
    printf 'kit-detect: CORE missing: lib/\n' >&2
    return 1
  fi
  local missing=0
  if [ ! -f "$root/bootstrap.sh" ]; then
    printf 'kit-detect: CORE missing: bootstrap.sh\n' >&2
    missing=1
  fi
  if [ ! -f "$root/templates/settings.json" ]; then
    printf 'kit-detect: CORE missing: templates/settings.json\n' >&2
    missing=1
  fi
  if [ ! -d "$root/lib" ]; then
    printf 'kit-detect: CORE missing: lib/\n' >&2
    missing=1
  fi
  return "$missing"
}

# SOFT markers: directory-presence; warn-only. Counts missing markers and
# emits each missing name to stderr (caller can pipe stderr to user-facing
# warnings, while stdout is the integer count for control flow).
kit_detect_soft() {
  local root="${1-}"
  local count=0
  if [ -z "$root" ] || [ ! -d "$root/commands" ]; then
    printf 'kit-detect: SOFT missing: commands/\n' >&2
    count=$((count + 1))
  fi
  if [ -z "$root" ] || [ ! -d "$root/hooks" ]; then
    printf 'kit-detect: SOFT missing: hooks/\n' >&2
    count=$((count + 1))
  fi
  if [ -z "$root" ] || [ ! -d "$root/tests" ]; then
    printf 'kit-detect: SOFT missing: tests/\n' >&2
    count=$((count + 1))
  fi
  if [ -z "$root" ] || [ ! -d "$root/docs/hard-rules" ]; then
    printf 'kit-detect: SOFT missing: docs/hard-rules/\n' >&2
    count=$((count + 1))
  fi
  if [ -z "$root" ] || [ ! -d "$root/memory" ]; then
    printf 'kit-detect: SOFT missing: memory/\n' >&2
    count=$((count + 1))
  fi
  printf '%d\n' "$count"
  return 0
}
