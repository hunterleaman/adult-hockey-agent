#!/usr/bin/env bash
# lib/workstream.sh — workstream phase ledger + slug resolver
# (issue #58, parent PRD #57, design source: .workstream/pipeline-phase-gating.md
# Q1-Q7 + R1-R7).
#
# Purpose
# -------
# Single source of truth for the per-workstream state file (`.workstream/{slug}.md`).
# Dual-purpose file: grill transcript (markdown body) + phase ledger (YAML
# frontmatter). Used by gated slash commands (/grill-me, /write-a-prd,
# /prd-to-issues) and CI (slice 6/7) to enforce the Phase 1->2->3 pipeline
# contract. This slice (#58) ships the foundation — slices #59-#64 wire it
# into the slash commands, /orient, /wind-down, /wind-up, and CI.
#
# Public API (intended for sourcing)
# ----------------------------------
#   _workstream_init <slug> <topic>
#       Atomic create `.workstream/<slug>.md` via `set -C` (O_EXCL). Writes
#       initial frontmatter with slug/topic/created_at/started_at and an
#       empty phases.{prd,issues,closed} skeleton. phases.grill.started_at
#       is set on creation (loose Phase-1 evidence per PRD #57). Returns
#       non-zero with stderr diagnostic on:
#         - slug normalization rejection (R1)
#         - file already exists (collision; O_EXCL refuses to clobber)
#
#   _workstream_advance <slug> <phase> [<artifact>...]
#       Per-slug `flock`-protected ledger update. Sets
#       phases.<phase>.started_at = today() (only if not already set) and
#       phases.<phase>.completed_at = now(). Artifact handling depends on phase
#       and arg count (slice #60):
#         - phase=issues, N>=1 args -> phases.issues.artifacts: YAML sequence
#                                       (one `- "X"` item per arg).
#         - phase=issues, 0 args    -> REFUSED (issues advance must carry
#                                       at least one child issue ref).
#         - other phases, 1 arg     -> phases.<phase>.artifact: "<arg>" (scalar,
#                                       backward-compatible with slice #58).
#         - other phases, 0 args    -> no artifact key written; only dates.
#       Lock at
#       ${WORKSTREAM_LOCK_FILE:-${TMPDIR:-/tmp}/cpt-workstream-<slug>.lock}.
#       Naked-fallback + warn when flock unavailable (R2; mirrors
#       lib/dispatch.sh semantics).
#
#   _workstream_phase_complete <slug> <phase>
#       Returns 0 iff phases.<phase>.completed_at is set, else 1. Pure query;
#       no side effects.
#
#   _workstream_resolve_slug [--slug=<foo>]
#       Cascade per Q2 (R1, R3, R6 folded):
#         1. --slug=<foo> wins; subject to R1 normalization (rejects bad).
#         2. Branch regex `^[0-9]+-(.+)$`; capture group subject to R1.
#         3. R6 bootstrap-empty exemption: zero non-`.gitkeep` files in
#            `.workstream/` -> exit code 2 (gate N/A).
#         4. Exactly-one-open `.workstream/*.md` (R3 frontmatter parse:
#            `closed_at:` absent OR `closed_at: null` -> open).
#         5. Interactive disambiguate (TTY-only, `[ -t 0 ]`); non-TTY refuses.
#         6. Refuse with explicit error.
#       Echoes the resolved slug on stdout, exit 0 on success, 2 on
#       bootstrap-empty exemption, non-zero (1) otherwise.
#       Test seam: WORKSTREAM_TEST_BRANCH overrides branch detection.
#
#   _workstream_validate_phase <slug> <phase>
#       Gate check. Returns 0 if the prior phase artifact is present, non-zero
#       otherwise. Phases: grill, prd, issues (the three GATED phases).
#
#   _workstream_count_nonconformant
#       Returns count of `.workstream/*.md` files that fail the R3
#       conformance contract (no first frontmatter block, etc). Echoes the
#       integer to stdout. Used by /orient (slice #61).
#
#   _workstream_sanitize <mode> <text>
#       R4 sanitization helper. Modes:
#         pr   — interpolation-safe emission (`printf '%s\n'`); NEVER `echo -e`,
#                NEVER bare `printf "$text"`.
#         log  — strip control chars (`tr -d '[:cntrl:]'`) before append.
#         warn — strip ANSI escapes (`sed 's/\x1b\[[0-9;]*[a-zA-Z]//g'`).
#       Echoes sanitized text to stdout.
#
#   _workstream_skip_flag_reason <argv...>
#       Slice #59 surface helper for the `--skip-phase-gate REASON="..."`
#       override flag. Echoes the REASON value on stdout, exit 0 on success.
#       Exit 1 = flag absent (no override), exit 2 = present but reason empty/
#       whitespace (caller MUST refuse). Slice #62 (#67) appends every accepted
#       use to `.workstream/_overrides.log` via _workstream_log_override below.
#
#   _workstream_log_override <command> <slug> <reason>
#       Slice #62 (#62, parent PRD #57). Append a single deterministic line
#       to `.workstream/_overrides.log` recording an authorized phase-gate
#       bypass. Line format (tab-separated, exactly 4 fields):
#           <ISO-8601 UTC timestamp>\t<command>\t<slug>\t<sanitized reason>
#       Hard-rejects:
#         - Unknown command (whitelist: grill-me, write-a-prd, prd-to-issues).
#         - Bad slug (R1 normalization).
#         - Empty / whitespace-only / control-only reason (post-sanitize).
#       Sanitization rule (single collapse rule, documented in helper):
#         CONTROL CHARACTERS ARE STRIPPED, NOT REPLACED. Newlines (\n),
#         tabs (\t), ANSI ESC (\x1b), bell (\x07), DEL (\x7f), and every
#         other byte in `[:cntrl:]` is removed via `tr -d '[:cntrl:]'`. This
#         single rule guarantees: (1) one log line per call (no embedded
#         \n breaks append-only ordering); (2) TSV integrity (no embedded
#         \t corrupts the four-field shape); (3) no escape-injection into
#         downstream readers (cat / less / grep). Reason is additionally
#         capped at WORKSTREAM_OVERRIDE_REASON_MAX bytes (default 1000) to
#         prevent runaway log lines.
#       Atomic append with per-log-file `flock` when available; naked-fallback
#       + warn otherwise (R2 mirrors lib/dispatch.sh).
#       Lock file: ${WORKSTREAM_OVERRIDE_LOCK_FILE:-${TMPDIR:-/tmp}/cpt-workstream-overrides.lock}
#       Log path: .workstream/_overrides.log (relative to CWD; created on first call).
#
#       Threat model note: reason text flows from the operator's CLI through
#       slash-command argv into this helper, then to a file via `printf '%s\n'`
#       with the reason as a NON-FORMAT argument. The helper does not call
#       `eval`, `$(...)`, or backticks on reason text. Shell-metachar /
#       command-substitution payloads in the reason cannot escape the field
#       (verified by tests/test-workstream.sh T41).
#
#   _workstream_resolve_slug_with_method [--slug=<foo>]   (slice #61)
#       Same contract as _workstream_resolve_slug PLUS a stderr diagnostic
#       describing the resolution method (flag / branch / single-open file /
#       interactive). Used by /wind-up to surface "resolved slug: X via Y".
#
#   _workstream_detect_prompt_phase <prompt-file>   (slice #61)
#       Parse memory/prompt_{slug}.md DO-FIRST section; echo highest pipeline
#       phase referenced (`grill` | `prd` | `issues` | `none`). rc=0 on read
#       success, rc=1 on missing file.
#
#   _workstream_check_prompt_phase_skip <slug> <prompt-file>   (slice #61)
#       rc=0 if the proposed DO-FIRST command's prerequisite is satisfied (or
#       no command proposed). rc=1 if a phase-skip is detected; recommended-
#       correction command echoed on stdout. rc=2 on usage error. /orient
#       surfaces the warning advisory; /wind-down auto-corrects via
#       _workstream_rewrite_prompt_do_first.
#
#   _workstream_rewrite_prompt_do_first <prompt-file> <new-command> <reason>   (slice #61)
#       Rewrite DO-FIRST in place: swap any pipeline-command reference for
#       <new-command>; append `> note: auto-corrected because <reason>`
#       (via _workstream_log_override conventions — _workstream_sanitize log mode).
#       Idempotent (re-running is a no-op once the prompt is clean and the
#       marker is present). <reason> sanitized via R4 log mode.
#
# Subcommand surface (run as a script, not sourced)
# -------------------------------------------------
#   bash lib/workstream.sh ci-validate <pr#>
#       Slice #63 (PRD #57 user stories 14, 15). Three-check CI gate:
#         1. PR-Workstream-Link  — PR title or body references a slug whose
#                                  .workstream/<slug>.md file exists with
#                                  conforming frontmatter (R3 strict-leading).
#         2. Phase-1-Evidence    — that workstream's phases.grill.started_at
#                                  is set (loose Phase-1 evidence).
#         3. Override-Audit-Sane — the PR's diff against base does not
#                                  modify .workstream/_overrides.log outside
#                                  the append-only contract (no edits, no
#                                  deletions, no reorder, no rename, no
#                                  binary).
#       Bootstrap-empty exemption (R6) returns 0 with a `gate\tNA` status
#       when .workstream/ contains zero non-.gitkeep files. Failures = exit
#       non-zero; the verify-all.yml integration surfaces this as a red-X
#       check on the PR (NOT an auto-merge-block at v1).
#
#       Test seams (production CI ignores):
#         WORKSTREAM_CI_TEST_PR_JSON  PR JSON payload to use instead of
#                                     `gh pr view`. Same shape: {number,
#                                     title, body, headRefName, baseRefName}.
#         WORKSTREAM_CI_TEST_DIFF     unified diff text to use instead of
#                                     `gh pr diff`. Empty string is "no
#                                     change". Unset (vs empty) means use gh.
#
#       PR-text injection defense: every external-text interpolation flows
#       through _workstream_sanitize (warn THEN log composition — strips
#       ANSI CSI residues + bare control chars including \n/\t/ESC). PR# is
#       hard-validated as digits-only at entry (defends against argv
#       smuggling into the gh exec).
#
# Hygiene
# -------
# Library hygiene mirrors lib/dispatch.sh: no `set -u` / `set -e` at file
# scope (would mutate the sourcing shell's mode globally). Each function uses
# `${var:-}` defaults inline so it is safe under both `set -u` and unset
# modes.
#
# Bash 3.2 compatible (macOS default). No associative arrays. No `[[ ... =~ ]]`
# features that diverged with bash 4+. Replacement-string variables avoided
# in `${var//pat/repl}` to dodge the bash 3.2 quoting traps documented in
# lib/substitute.sh ("${var//pat/}}}" parses as `${var//pat/}` + `}`).

# -----------------------------------------------------------------------------
# Internal: emit a UTC ISO-8601 timestamp (e.g. 2026-05-04T18:30:00Z).
# Single source of truth so all writers share the same format. Falls back to
# `date -u +...` (BSD/GNU compatible).
# -----------------------------------------------------------------------------
_workstream_now() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# -----------------------------------------------------------------------------
# Internal: emit a UTC date (e.g. 2026-05-04). Used for created_at/started_at
# on init for human-readability parity with the existing seed file.
# -----------------------------------------------------------------------------
_workstream_today() {
  date -u '+%Y-%m-%d'
}

# -----------------------------------------------------------------------------
# Internal: validate a slug per R1.
#   Constraints: ^[a-z0-9-]+$
#                no leading or trailing `-`
#                length 1..64 (sanity cap; documented in PRD)
# Echoes nothing on success (rc=0); diagnostic on stderr on failure (rc=1).
# Defense: regex naturally rejects `..`, `/`, `;`, `|`, `&`, `$`, backticks,
# whitespace, control chars, newlines, NUL.
# -----------------------------------------------------------------------------
_workstream_validate_slug() {
  local slug="${1:-}"
  if [ -z "$slug" ]; then
    echo "workstream: slug is empty (must match ^[a-z0-9-]+\$, length 1..64)" >&2
    return 1
  fi
  # Length cap. Bash ${#var} is bytes (slug is ASCII-only by regex anyway).
  if [ "${#slug}" -gt 64 ]; then
    echo "workstream: slug too long (>64 chars): ${slug:0:64}..." >&2
    return 1
  fi
  # Leading/trailing dash check (cosmetic but documented).
  case "$slug" in
    -*|*-)
      echo "workstream: slug must not start or end with '-': $slug" >&2
      return 1
      ;;
  esac
  # Charset check (covers the rest: rejects uppercase, underscore, dot, slash,
  # space, traversal segments, glob chars, control chars). Bash 3.2-compatible
  # `case` glob matches one character at a time, so we use a negated grep
  # which is portable and unambiguous.
  if printf '%s' "$slug" | LC_ALL=C grep -qE '[^a-z0-9-]'; then
    echo "workstream: slug has invalid character (allowed: ^[a-z0-9-]+\$): $slug" >&2
    return 1
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Internal: resolve the per-slug lock file path. Honors WORKSTREAM_LOCK_FILE
# env override (CI / test isolation). Default: ${TMPDIR:-/tmp}/cpt-workstream-<slug>.lock
# Mirrors lib/dispatch.sh's _dispatch_lock_path pattern exactly.
# -----------------------------------------------------------------------------
_workstream_lock_path() {
  local slug="${1:-}"
  if [ -n "${WORKSTREAM_LOCK_FILE:-}" ]; then
    printf '%s' "$WORKSTREAM_LOCK_FILE"
    return 0
  fi
  printf '%s' "${TMPDIR:-/tmp}/cpt-workstream-${slug}.lock"
}

# -----------------------------------------------------------------------------
# Internal: extract the LEADING `^---$`-delimited frontmatter block from a
# file. Echoes the block body (lines BETWEEN the two delimiters, exclusive).
# Empty stdout means: no conforming frontmatter (file is non-conformant per R3).
#
# R3 strict-leading rule (Codex HIGH on PR #65): the OPENING `---` must be the
# very first line of the file (line 1). Files with leading prose / comments /
# blank lines before a later `---` block are NON-CONFORMANT — treating them
# as conformant would let an attacker (or an honest mistake) prepend prose to
# a workstream file and have the resolver still pick it up. Caller treats
# empty stdout as "skip silently" and the nonconformant counter surfaces it.
#
# BOM (\xEF\xBB\xBF) on line 1 is also non-conformant: byte-level comparison
# against `---\n` (or `---\r\n`; CRLF is also rejected) means a leading BOM
# yields no match, which is the intended behavior per R3.
#
# Bash 3.2 + awk only — no YAML library dependency.
# -----------------------------------------------------------------------------
_workstream_extract_frontmatter() {
  local file="$1"
  [ -f "$file" ] || { printf ''; return 0; }
  # LC_ALL=C forces byte-exact comparisons so a UTF-8 BOM (\xEF\xBB\xBF)
  # before `---` cannot smuggle a non-conformant file past the strict-
  # leading check. Without LC_ALL=C, BSD awk on macOS treats the BOM as
  # locale-dependent zero-width and `$0 == "---"` returns true on
  # `\xEF\xBB\xBF---` content. Discovered by Codex regression test T18 on PR #65.
  LC_ALL=C awk '
    BEGIN { state = 0 }
    NR == 1 {
      if ($0 == "---") { state = 1; next }
      # Line 1 is not exactly `---`. File is non-conformant per R3
      # (strict-leading rule — see header comment). Emit nothing.
      exit
    }
    /^---$/ {
      if (state == 1) { exit }
    }
    state == 1 { print }
  ' "$file"
}

# -----------------------------------------------------------------------------
# Internal: is the file at $1 an OPEN workstream file per R3?
#   - Conforming first `^---$`-delimited frontmatter block must exist.
#   - `closed_at:` line absent OR equals `closed_at: null` (whitespace-tolerant).
# rc=0 if open, rc=1 if closed OR non-conformant.
# -----------------------------------------------------------------------------
_workstream_file_is_open() {
  local file="$1"
  local fm closed_line
  fm="$(_workstream_extract_frontmatter "$file")"
  # Non-conformant => skipped (treated as "not open" for resolver purposes).
  [ -n "$fm" ] || return 1
  # Look for closed_at: <value>. Whitespace-tolerant on both sides of the colon.
  closed_line="$(printf '%s\n' "$fm" | grep -E '^[[:space:]]*closed_at[[:space:]]*:' | head -n1 || true)"
  if [ -z "$closed_line" ]; then
    # Absent => open per R3.
    return 0
  fi
  # Strip key + colon + leading whitespace; compare value to `null`.
  local value
  value="$(printf '%s' "$closed_line" | sed -E 's/^[[:space:]]*closed_at[[:space:]]*:[[:space:]]*//; s/[[:space:]]+$//')"
  if [ "$value" = "null" ] || [ -z "$value" ]; then
    return 0
  fi
  # Any other value (date, string) => closed.
  return 1
}

# -----------------------------------------------------------------------------
# Internal: enumerate slug names of all OPEN workstream files. One slug per
# stdout line. Slug derived from the filename (basename minus `.md`); if the
# filename's stem fails R1, the file is skipped (silent — caller's R3
# nonconformant counter surfaces it).
# -----------------------------------------------------------------------------
_workstream_list_open() {
  local dir=".workstream"
  [ -d "$dir" ] || return 0
  local file slug
  # `find` over `for f in glob` so we get a stable order without bash 4+ globs
  # and so we can include hidden-glob-escaped names without surprises. Skip
  # `.gitkeep` and any non-.md file by extension match.
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    [ -f "$file" ] || continue
    # Filter out .gitkeep and the override-audit-log (#10) — neither is a
    # workstream-state file.
    case "$(basename "$file")" in
      .gitkeep|_overrides.log) continue ;;
    esac
    slug="$(basename "$file" .md)"
    # If basename ends without .md, basename returns unchanged; skip in that
    # case so non-.md files cannot leak in.
    case "$file" in
      *.md) ;;
      *) continue ;;
    esac
    # R1 normalization on derived slug; silently skip non-conforming names
    # (the conformant-vs-malformed surface is what R3 nonconformant counts).
    if ! _workstream_validate_slug "$slug" >/dev/null 2>&1; then
      continue
    fi
    if _workstream_file_is_open "$file"; then
      printf '%s\n' "$slug"
    fi
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -type f | LC_ALL=C sort)
}

# -----------------------------------------------------------------------------
# Internal: count workstream files that have a `.md` extension but fail the
# R3 conformance contract (no frontmatter block present). Echoes the count.
# -----------------------------------------------------------------------------
_workstream_count_nonconformant() {
  local dir=".workstream" file count=0 fm
  if [ ! -d "$dir" ]; then
    printf '0'
    return 0
  fi
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    case "$(basename "$file")" in
      .gitkeep|_overrides.log) continue ;;
    esac
    case "$file" in
      *.md) ;;
      *) continue ;;
    esac
    fm="$(_workstream_extract_frontmatter "$file")"
    if [ -z "$fm" ]; then
      count=$((count+1))
    fi
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | LC_ALL=C sort)
  printf '%s' "$count"
}

# -----------------------------------------------------------------------------
# Internal: compute current branch. Test seam: WORKSTREAM_TEST_BRANCH wins.
# Falls back to `git rev-parse --abbrev-ref HEAD`; on detached HEAD or git
# failure, echoes empty.
# -----------------------------------------------------------------------------
_workstream_current_branch() {
  if [ -n "${WORKSTREAM_TEST_BRANCH+x}" ]; then
    printf '%s' "${WORKSTREAM_TEST_BRANCH}"
    return 0
  fi
  local b
  b="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [ "$b" = "HEAD" ]; then
    # Detached HEAD — no useful branch name.
    printf ''
    return 0
  fi
  printf '%s' "$b"
}

# -----------------------------------------------------------------------------
# Public: _workstream_init <slug> <topic>
# Atomic create `.workstream/<slug>.md` with O_EXCL semantics via `set -C`.
# Writes initial frontmatter + an empty body marker line.
# -----------------------------------------------------------------------------
_workstream_init() {
  local slug="${1:-}" topic="${2:-}"
  if [ -z "$topic" ]; then
    echo "workstream: usage: _workstream_init <slug> <topic>" >&2
    return 2
  fi
  if ! _workstream_validate_slug "$slug"; then
    return 1
  fi
  local dir=".workstream"
  mkdir -p "$dir"
  local file="$dir/${slug}.md"
  local now today
  now="$(_workstream_now)"
  today="$(_workstream_today)"
  # Sanitize the topic for safe embedding in YAML scalar context. We strip
  # control chars (R4 log mode is the closest semantic) — topic appears in a
  # quoted YAML scalar so newline/quote handling matters too.
  local safe_topic
  safe_topic="$(_workstream_sanitize log "$topic")"
  # Quote-escape any embedded `"` in the safe topic (YAML double-quoted scalar).
  # Bash 3.2: ${var//"/\"} is ambiguous; use parameter expansion via tr-free path.
  safe_topic="${safe_topic//\\/\\\\}"
  safe_topic="${safe_topic//\"/\\\"}"
  # Atomic create. `set -C` (noclobber) makes `>` fail if the file exists.
  # Save and restore the caller's noclobber state so we don't pollute the
  # sourcing shell.
  #
  # Bash 3.2 quirk: an `if !` whose condition is a brace-group/subshell whose
  # ONLY failure is a redirection (e.g. `>` blocked by `set -C`) does NOT
  # propagate non-zero into the `if` test — `if !` falls through to the
  # success branch even though `$?` is 1 immediately after the command. Avoid
  # `if !` here: capture `$?` directly and branch on the integer value.
  local prev_noclobber rc
  case "$-" in *C*) prev_noclobber=1 ;; *) prev_noclobber=0 ;; esac
  set -C
  {
    printf -- '---\n'
    printf 'slug: %s\n' "$slug"
    printf 'topic: "%s"\n' "$safe_topic"
    printf 'created_at: %s\n' "$today"
    printf 'started_at: %s\n' "$today"
    printf 'phases:\n'
    printf '  grill:\n'
    printf '    started_at: %s\n' "$today"
    printf '  prd:\n'
    printf '  issues:\n'
    printf '  closed:\n'
    printf 'implementation_pointer:\n'
    printf '  parent: null\n'
    printf '  children: []\n'
    printf 'closed_at: null\n'
    printf -- '---\n\n'
    printf '# Workstream: %s\n\n' "$slug"
    printf '<!-- Initialized %s by _workstream_init -->\n' "$now"
  } > "$file" 2>/dev/null
  rc=$?
  [ "$prev_noclobber" = "0" ] && set +C
  if [ "$rc" -ne 0 ]; then
    echo "workstream: refusing to clobber existing workstream file: $file (init must not overwrite; rc=$rc)" >&2
    return 1
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Internal: rewrite a workstream file's frontmatter so phases.<phase> gains
# started_at + completed_at + (optional) artifact(s). Body is preserved
# byte-for-byte. Caller is responsible for holding the per-slug lock around
# this call.
#
# Args:
#   $1 file       — path to the .workstream/<slug>.md file
#   $2 phase      — phase name (grill|prd|issues|closed)
#   $3 art_mode   — "scalar" | "sequence" | "none"
#                   scalar   -> write `artifact: "X"`        (one arg in $4)
#                   sequence -> write `artifacts:` YAML array (US-separated
#                               quoted+escaped scalars in $4; passed via the
#                               WORKSTREAM_ART_PAYLOAD env var, NOT via awk -v,
#                               because -v decodes backslash escape sequences
#                               and would silently undo the YAML escape).
#                   none     -> do not touch artifact / artifacts keys
#   $4 art_payload — for scalar: the (already escaped) single artifact
#                  — for sequence: US (\x1F)-separated already-escaped
#                                  artifacts (single string)
#                  — ignored for none
#
# Schema invariants (slice #58 + slice #60):
#   - phase headers at exact 2-space indent
#   - sub-keys at exact 4-space indent
#   - sequence items at exact 6-space indent (`      - "X"`)
#   - completed_at, started_at always written (started_at only inserted if
#     not already present so we don't clobber a manually-set earlier date).
#
# Implementation: awk processes the file line-by-line, tracks frontmatter
# scope and the current phase indent context. On phase-block close
# (sibling phase header / end of phases block / end of frontmatter / top-
# level key), any missing keys are inserted before the close. Atomic via
# tmp-file + mv.
# -----------------------------------------------------------------------------
_workstream_rewrite_phase() {
  local file="$1" phase="$2" art_mode="${3:-none}" art_payload="${4:-}"
  local now today tmp awk_rc target_dir
  now="$(_workstream_now)"
  today="$(_workstream_today)"
  # Codex LOW on PR #59: keep tmp in the SAME directory as the target so
  # `mv` is rename(2) on the same filesystem (POSIX-atomic). `mktemp -t`
  # places tmp under $TMPDIR (typically /tmp) which may live on a different
  # filesystem from the repo (e.g. tmpfs vs. ext4) — `mv` then degrades to
  # copy + unlink, which is NOT atomic and can leave a partially-written
  # target on a crash mid-copy.
  target_dir="$(dirname "$file")"
  tmp="$(mktemp "${target_dir}/.cpt-workstream-rewrite.XXXXXX")" || {
    echo "workstream: mktemp failed (dir=$target_dir)" >&2
    return 1
  }
  # Codex LOW on PR #59 pass-2: best-effort sweep of stale dotfile temps
  # left behind by signal-interrupted prior runs (SIGKILL/equivalent — the
  # normal success path renames $tmp over $file; failure paths `rm -f $tmp`).
  # Sweep any sibling `.cpt-workstream-rewrite.*` older than 1 hour so a
  # hard-interrupted rewrite cannot accumulate clutter in `.workstream/`.
  # Quiet on no-match. Skips the just-created $tmp by mtime.
  find "$target_dir" -maxdepth 1 -type f \
       -name '.cpt-workstream-rewrite.*' \
       -mmin +60 -delete 2>/dev/null || true
  # awk variables / env:
  #   P      = phase name                 (-v, no escapes needed)
  #   N      = now ISO timestamp          (-v, no escapes needed)
  #   T      = today YYYY-MM-DD           (-v, no escapes needed)
  #   M      = artifact mode (scalar|sequence|none)
  #
  # The artifact payload is passed via ENVIRON[] (env var) NOT via `-v`
  # because `awk -v` decodes backslash escape sequences in the assigned value
  # (`\"` -> `"`, `\\` -> `\`, `\037` -> `\x1F`, etc). Our payload already
  # contains YAML-escaped backslashes / double-quotes which the bash side
  # built carefully — `-v` would silently undo that escape and the resulting
  # YAML would have unescaped quotes, breaking parse. ENVIRON[] is byte-
  # transparent.
  #
  # LC_ALL=C: byte-exact regex matching across all parsers in this lib (Codex
  # LOW on PR #65 pass-2 — keeps locale-sensitive ranges from drifting).
  WORKSTREAM_ART_PAYLOAD="$art_payload" \
  LC_ALL=C awk -v P="$phase" -v N="$now" -v T="$today" -v M="$art_mode" '
    BEGIN {
      in_fm = 0           # 0 = pre-FM, 1 = inside, 2 = post-FM
      in_phases = 0       # 1 once we have entered the phases: block
      in_target = 0       # 1 while inside the targeted phase subblock
      seen_started = 0    # 1 if target phase already has a started_at line
      seen_completed = 0  # 1 if target phase already has a completed_at line
      wrote_completed = 0
      wrote_started = 0
      wrote_artifact = 0
      # Read payload from env (byte-transparent; see header comment).
      AP = ENVIRON["WORKSTREAM_ART_PAYLOAD"]
      AS = AP   # scalar mode just emits the payload as-is.
      # Pre-split the sequence payload on US (\x1F) so we can iterate. Bash
      # side joins on US after sanitize-log has stripped all control chars
      # from each artifact, so the separator cannot collide with item content.
      # See _workstream_advance for the join.
      n_seq = 0
      if (M == "sequence" && length(AP) > 0) {
        n_seq = split(AP, SEQ, "\037")
      }
    }

    # -------- Helpers (awk functions) --------
    function flush_target_block(   i) {
      # Insert any keys not already present in the target phase block.
      # Order: started_at -> completed_at -> artifact(s).
      if (!seen_started && !wrote_started) {
        printf("    started_at: %s\n", T)
        wrote_started = 1
      }
      if (!seen_completed && !wrote_completed) {
        printf("    completed_at: %s\n", N)
        wrote_completed = 1
      }
      if (!wrote_artifact) {
        if (M == "scalar" && length(AS) > 0) {
          printf("    artifact: \"%s\"\n", AS)
          wrote_artifact = 1
        } else if (M == "sequence" && n_seq > 0) {
          print "    artifacts:"
          for (i = 1; i <= n_seq; i++) {
            printf("      - \"%s\"\n", SEQ[i])
          }
          wrote_artifact = 1
        }
      }
    }

    # -------- Main parse --------
    /^---$/ {
      if (in_fm == 0) { in_fm = 1; print; next }
      else if (in_fm == 1) {
        # Closing frontmatter delimiter. If still inside target phase block,
        # flush any missing keys before the close.
        if (in_target) flush_target_block()
        in_fm = 2; in_target = 0; in_phases = 0
        print; next
      } else { print; next }
    }
    in_fm != 1 { print; next }
    # Inside frontmatter.
    /^phases:[[:space:]]*$/ { in_phases = 1; in_target = 0; print; next }
    # Phase header (Codex MED on PR #65: exact 2-space indent only).
    in_phases == 1 && /^  [A-Za-z_][A-Za-z0-9_]*:[[:space:]]*$/ {
      line = $0
      sub(/^  /, "", line)
      sub(/:[[:space:]]*$/, "", line)
      # Closing the previous target block if it was open.
      if (in_target) flush_target_block()
      if (line == P) {
        in_target = 1
        seen_started = 0
        seen_completed = 0
      } else {
        in_target = 0
      }
      print; next
    }
    # Top-level frontmatter key (no leading whitespace) -> exit phases scope.
    in_fm == 1 && /^[A-Za-z_]/ {
      if (in_target) flush_target_block()
      in_phases = 0; in_target = 0
      print; next
    }
    # Sub-keys of the target phase: handle started_at, completed_at, artifact,
    # artifacts. Mode determines whether we replace or pass through.
    in_target == 1 && /^    started_at:/ {
      seen_started = 1
      # If the existing started_at line is empty / null, we keep our policy of
      # inserting today via flush_target_block. Otherwise pass through.
      v = $0
      sub(/^    started_at:[[:space:]]*/, "", v)
      sub(/[[:space:]]+$/, "", v)
      if (length(v) == 0 || v == "null") {
        printf("    started_at: %s\n", T)
        wrote_started = 1
      } else {
        print
      }
      next
    }
    in_target == 1 && /^    completed_at:/ {
      seen_completed = 1
      printf("    completed_at: %s\n", N)
      wrote_completed = 1
      next
    }
    # Existing scalar artifact line.
    in_target == 1 && /^    artifact:[[:space:]]/ {
      if (M == "scalar" && length(AS) > 0) {
        printf("    artifact: \"%s\"\n", AS)
        wrote_artifact = 1
        next
      }
      if (M == "sequence") {
        # Switching to plural — drop the singular line; the sequence is
        # written by flush_target_block before the block closes.
        next
      }
      print; next
    }
    # Existing plural artifacts: header. Drop the header AND any subsequent
    # 6-space-indented `- ` items so we can rewrite cleanly.
    in_target == 1 && /^    artifacts:[[:space:]]*$/ {
      if (M == "sequence" && n_seq > 0) {
        # Replace with our fresh sequence.
        print "    artifacts:"
        for (i = 1; i <= n_seq; i++) {
          printf("      - \"%s\"\n", SEQ[i])
        }
        wrote_artifact = 1
        in_artifacts_block = 1
        next
      }
      if (M == "scalar") {
        # Switching back to scalar — drop the plural header + items.
        in_artifacts_block = 1
        next
      }
      # M == none: pass through.
      print; next
    }
    # Drop existing sequence items while we are skipping the old artifacts.
    in_target == 1 && in_artifacts_block == 1 && /^      - / { next }
    # End of artifacts items: any other indent / scope shift.
    in_target == 1 && in_artifacts_block == 1 { in_artifacts_block = 0 }
    # Sub-keys of the target phase that we do not transform — pass through.
    { print }

    END {
      # Codex MED on PR #65 pass-2: rewrite must fail loudly if the target
      # phase header was never matched. wrote_completed == 0 indicates either
      # (a) the phase header was never seen (bad indent / wrong phase) or
      # (b) we were still inside the block at EOF and flush did not run.
      # Case (b) is impossible because the closing `---$` always triggers
      # flush_target_block before END. So wrote_completed == 0 always means
      # the header was never matched.
      if (wrote_completed == 0) { exit 2 }
      exit 0
    }
  ' "$file" > "$tmp"
  awk_rc=$?
  if [ "$awk_rc" -ne 0 ] && [ "$awk_rc" -ne 2 ]; then
    rm -f "$tmp"
    echo "workstream: awk rewrite failed for $file (rc=$awk_rc)" >&2
    return 1
  fi
  if [ "$awk_rc" -eq 2 ]; then
    rm -f "$tmp"
    echo "workstream: rewrite did not match phase '$phase' in $file" >&2
    echo "workstream: hint: phase header must be 2-space-indented (e.g. '  $phase:'); sub-keys 4-space-indented" >&2
    echo "workstream: hint: hand-edits using tabs or 3-space indent are NOT supported (R3 strict-indent contract)" >&2
    return 1
  fi
  # Atomic replace.
  mv -f "$tmp" "$file" || {
    rm -f "$tmp"
    echo "workstream: failed to commit rewrite to $file" >&2
    return 1
  }
  return 0
}

# -----------------------------------------------------------------------------
# Public: _workstream_advance <slug> <phase> [<artifact>...]
#
# flock-protected ledger update. Writes phases.<phase>.{started_at, completed_at}
# and (depending on phase + arg count) one of:
#   - phase=issues with N >= 1 artifact args  -> phases.issues.artifacts: YAML
#                                                 sequence (one item per arg)
#   - phase=issues with 0 artifact args       -> REFUSED (error)
#   - other phases with 1 artifact arg        -> phases.<phase>.artifact: scalar
#   - other phases with 0 artifact args       -> no artifact written (just dates)
#
# Per slice #60 (issue #60): the `issues` phase always uses the plural
# `artifacts:` YAML sequence so downstream consumers (CI, /orient) can rely on
# a stable shape regardless of child-issue count.
# -----------------------------------------------------------------------------
_workstream_advance() {
  local slug="${1:-}" phase="${2:-}"
  if [ -z "$slug" ] || [ -z "$phase" ]; then
    echo "workstream: usage: _workstream_advance <slug> <phase> [<artifact>...]" >&2
    return 2
  fi
  shift 2
  if ! _workstream_validate_slug "$slug"; then
    return 1
  fi
  case "$phase" in
    grill|prd|issues|closed) ;;
    *)
      echo "workstream: unknown phase: $phase (allowed: grill, prd, issues, closed)" >&2
      return 1
      ;;
  esac
  local file=".workstream/${slug}.md"
  if [ ! -f "$file" ]; then
    echo "workstream: no workstream file at $file (run _workstream_init first)" >&2
    return 1
  fi
  # Decide artifact mode + payload based on phase + arg count.
  local art_mode="none" art_payload=""
  local n_args=$#
  if [ "$phase" = "issues" ]; then
    if [ "$n_args" -lt 1 ]; then
      echo "workstream: advance issues requires at least one artifact (e.g. issue:123)" >&2
      return 1
    fi
    art_mode="sequence"
    # Build a US (\x1F)-joined string of escaped artifacts. Newline cannot be
    # used as the join separator because awk's `-v` does NOT decode escape
    # sequences in the assigned value, so a literal LF in the value crashes
    # awk with "newline in string". US (Unit Separator) is safe because
    # _workstream_sanitize log strips all control chars from each artifact
    # BEFORE we join — so the separator is unambiguous and cannot collide
    # with artifact content. The awk side reads the joined payload from the
    # WORKSTREAM_ART_PAYLOAD env var (NOT via -v, which would decode the
    # backslash escapes we just inserted) and splits on US into SEQ[].
    local a esc joined=""
    for a in "$@"; do
      esc="$(_workstream_sanitize log "$a")"
      # YAML double-quoted scalar safety: escape backslash + double-quote.
      esc="${esc//\\/\\\\}"
      esc="${esc//\"/\\\"}"
      if [ -z "$joined" ]; then
        joined="$esc"
      else
        joined="$joined"$'\037'"$esc"
      fi
    done
    art_payload="$joined"
  else
    if [ "$n_args" -ge 1 ]; then
      art_mode="scalar"
      local artifact="$1"
      artifact="$(_workstream_sanitize log "$artifact")"
      artifact="${artifact//\\/\\\\}"
      artifact="${artifact//\"/\\\"}"
      art_payload="$artifact"
      if [ "$n_args" -gt 1 ]; then
        echo "workstream: phase '$phase' accepts at most one artifact; ignoring extra args" >&2
      fi
    fi
  fi
  local lock_path
  lock_path="$(_workstream_lock_path "$slug")"
  # Ensure the lock file exists so flock can open() it for writing without
  # racing on creation. Same pattern as lib/dispatch.sh.
  if ! touch "$lock_path" 2>/dev/null; then
    echo "workstream: cannot create lock file at $lock_path; falling back to naked rewrite" >&2
    _workstream_rewrite_phase "$file" "$phase" "$art_mode" "$art_payload"
    return $?
  fi
  if ! command -v flock >/dev/null 2>&1; then
    echo "workstream: flock not found on PATH; falling back to naked rewrite (single-operator race window accepted, R2)" >&2
    _workstream_rewrite_phase "$file" "$phase" "$art_mode" "$art_payload"
    return $?
  fi
  local rc
  (
    flock -x 200
    _workstream_rewrite_phase "$file" "$phase" "$art_mode" "$art_payload"
  ) 200>"$lock_path"
  rc=$?
  return "$rc"
}

# -----------------------------------------------------------------------------
# Public: _workstream_phase_complete <slug> <phase>
# Returns 0 if phases.<phase>.completed_at is set in the ledger.
# -----------------------------------------------------------------------------
_workstream_phase_complete() {
  local slug="${1:-}" phase="${2:-}"
  if [ -z "$slug" ] || [ -z "$phase" ]; then
    echo "workstream: usage: _workstream_phase_complete <slug> <phase>" >&2
    return 2
  fi
  # Codex HIGH on PR #65 (path-traversal): every public API that interpolates
  # `slug` into a filesystem path MUST validate it against R1 first. A caller
  # passing `..` / `../foo` would otherwise read arbitrary files outside
  # `.workstream/`. Defense-in-depth even though resolver also validates.
  if ! _workstream_validate_slug "$slug" >/dev/null 2>&1; then
    echo "workstream: phase_complete: invalid slug (R1): $slug" >&2
    return 1
  fi
  local file=".workstream/${slug}.md"
  [ -f "$file" ] || return 1
  local fm
  fm="$(_workstream_extract_frontmatter "$file")"
  [ -n "$fm" ] || return 1
  # Walk frontmatter lines tracking the current phase scope; report whether
  # the targeted phase has a non-empty `completed_at` value. Indentation
  # contracts (Codex MED on PR #65): phase headers MUST be exact 2-space
  # indent; sub-keys MUST be exact 4-space indent. Top-level frontmatter keys
  # (no leading whitespace) reset the phases-scope. LC_ALL=C for byte-exact
  # parsing (Codex LOW on pass-2).
  printf '%s\n' "$fm" | LC_ALL=C awk -v P="$phase" '
    BEGIN { in_phases = 0; in_target = 0; found = 0 }
    /^phases:[[:space:]]*$/ { in_phases = 1; next }
    /^[A-Za-z_]/ { in_phases = 0; in_target = 0; next }
    in_phases == 1 && /^  [A-Za-z_][A-Za-z0-9_]*:[[:space:]]*$/ {
      line = $0
      sub(/^  /, "", line)
      sub(/:[[:space:]]*$/, "", line)
      in_target = (line == P) ? 1 : 0
      next
    }
    in_target == 1 && /^    completed_at:[[:space:]]*[^[:space:]]/ {
      # Match completed_at: with a non-whitespace value (i.e. not empty/null).
      v = $0
      sub(/^    completed_at:[[:space:]]*/, "", v)
      sub(/[[:space:]]+$/, "", v)
      if (length(v) > 0 && v != "null") { found = 1 }
    }
    END { exit (found ? 0 : 1) }
  '
}

# -----------------------------------------------------------------------------
# Public: _workstream_validate_phase <slug> <phase>
# Gate check: returns 0 iff the prior phase artifact is present.
#   grill  -> always 0 if file exists (loose Phase-1 evidence per PRD)
#   prd    -> requires phases.grill present (file existence implies init,
#             which sets phases.grill.started_at)
#   issues -> requires phases.prd.completed_at
# -----------------------------------------------------------------------------
_workstream_validate_phase() {
  local slug="${1:-}" phase="${2:-}"
  if [ -z "$slug" ] || [ -z "$phase" ]; then
    echo "workstream: usage: _workstream_validate_phase <slug> <phase>" >&2
    return 2
  fi
  # Codex HIGH on PR #65 (path-traversal): see _workstream_phase_complete for
  # the same R1 enforcement rationale.
  if ! _workstream_validate_slug "$slug" >/dev/null 2>&1; then
    echo "workstream: validate_phase: invalid slug (R1): $slug" >&2
    return 1
  fi
  local file=".workstream/${slug}.md"
  if [ ! -f "$file" ]; then
    echo "workstream: validate failed: no workstream file for slug=$slug" >&2
    return 1
  fi
  case "$phase" in
    grill)
      # Phase-1 evidence is loose: file exists with conforming frontmatter.
      local fm
      fm="$(_workstream_extract_frontmatter "$file")"
      [ -n "$fm" ] || { echo "workstream: validate failed: file is non-conformant: $file" >&2; return 1; }
      return 0
      ;;
    prd)
      # Entering Phase 2 (prd) requires Phase 1 (grill) evidence. Per PRD:
      # phases.grill.started_at present => grill happened. Strict-indent
      # contract per Codex MED on PR #65: phase headers at exact 2-space
      # indent, sub-keys at exact 4-space indent.
      local _fm
      _fm="$(_workstream_extract_frontmatter "$file")"
      # LC_ALL=C for byte-exact regex (Codex LOW on PR #65 pass-2).
      if printf '%s\n' "$_fm" | LC_ALL=C awk '
            BEGIN { in_p = 0; in_g = 0; found = 0 }
            /^phases:[[:space:]]*$/ { in_p = 1; next }
            /^[A-Za-z_]/ { in_p = 0; in_g = 0; next }
            in_p == 1 && /^  grill:[[:space:]]*$/ { in_g = 1; next }
            in_p == 1 && /^  [A-Za-z_]/ { in_g = 0; next }
            in_g == 1 && /^    started_at:[[:space:]]*[^[:space:]]/ {
              v = $0
              sub(/^    started_at:[[:space:]]*/, "", v)
              sub(/[[:space:]]+$/, "", v)
              if (length(v) > 0 && v != "null") { found = 1; exit }
            }
            END { exit (found ? 0 : 1) }
          '; then
        return 0
      fi
      echo "workstream: validate failed: no phases.grill.started_at for slug=$slug" >&2
      return 1
      ;;
    issues)
      # Entering Phase 3 (issues) requires Phase 2 (prd) completion.
      _workstream_phase_complete "$slug" prd
      ;;
    *)
      echo "workstream: validate_phase: unknown phase: $phase" >&2
      return 1
      ;;
  esac
}

# -----------------------------------------------------------------------------
# Public: _workstream_resolve_slug [--slug=<foo>]
# Cascade per Q2 (R1, R3, R6 folded). See header for the full contract.
# Exit codes:
#   0 — slug echoed on stdout
#   1 — refused (ambiguous, no match, normalization failure on input)
#   2 — bootstrap-empty exemption (R6); gate is N/A
# -----------------------------------------------------------------------------
_workstream_resolve_slug() {
  # Parse optional --slug=<foo>.
  local arg slug=""
  for arg in "$@"; do
    case "$arg" in
      --slug=*) slug="${arg#--slug=}" ;;
      *) ;;  # Unknown flags ignored — caller may layer their own parser.
    esac
  done
  # Step 1: --slug wins. Subject to R1 normalization.
  if [ -n "$slug" ]; then
    if ! _workstream_validate_slug "$slug"; then
      return 1
    fi
    printf '%s' "$slug"
    return 0
  fi
  # Step 2: branch regex `^[0-9]+-(.+)$`.
  local branch capture
  branch="$(_workstream_current_branch)"
  if [ -n "$branch" ]; then
    # Bash 3.2 has =~; portable enough across the project's targeted shells.
    if [[ "$branch" =~ ^[0-9]+-(.+)$ ]]; then
      capture="${BASH_REMATCH[1]}"
      if _workstream_validate_slug "$capture" 2>/dev/null; then
        printf '%s' "$capture"
        return 0
      fi
      # Captured but R1-invalid: fall through (do not refuse here — cascade
      # might still find a single open file).
    fi
  fi
  # Step 3: R6 bootstrap-empty exemption. Count non-`.gitkeep` files in
  # `.workstream/`; zero => gate N/A (rc=2).
  local dir=".workstream" entry count=0
  if [ ! -d "$dir" ]; then
    echo "workstream: resolve failed: .workstream/ directory absent (gate N/A; rc=2)" >&2
    return 2
  fi
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$(basename "$entry")" in
      .gitkeep|_overrides.log) continue ;;
    esac
    count=$((count+1))
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -type f 2>/dev/null)
  if [ "$count" -eq 0 ]; then
    return 2
  fi
  # Step 4: enumerate open workstream files. Exactly one => pick. Multi => 5.
  local open_list open_count
  open_list="$(_workstream_list_open)"
  open_count=0
  if [ -n "$open_list" ]; then
    # Count via wc -l + 1 (last line may not have trailing newline; using
    # `printf '%s\n' "$open_list" | wc -l` normalizes).
    open_count="$(printf '%s\n' "$open_list" | grep -c '^.' || true)"
  fi
  if [ "$open_count" -eq 1 ]; then
    printf '%s' "$open_list"
    return 0
  fi
  if [ "$open_count" -eq 0 ]; then
    echo "workstream: resolve failed: no OPEN workstream files in .workstream/" >&2
    echo "workstream: hint: pass --slug=<name> or run /grill-me to start one" >&2
    return 1
  fi
  # Step 5: ambiguous. Interactive disambiguate (TTY only).
  if [ ! -t 0 ]; then
    echo "workstream: resolve failed: $open_count OPEN workstream files in non-interactive context" >&2
    echo "workstream: candidates:" >&2
    printf '  - %s\n' $open_list >&2
    echo "workstream: hint: pass --slug=<name>" >&2
    return 1
  fi
  # TTY-only interactive prompt. Kept minimal — slice #61 (/orient) may lift
  # this into a richer chooser. Echo candidates + read a slug back.
  echo "workstream: $open_count open workstream files; pick one:" >&2
  local i=1 c
  for c in $open_list; do
    printf '  %d) %s\n' "$i" "$c" >&2
    i=$((i+1))
  done
  printf 'choice (slug): ' >&2
  local choice
  IFS= read -r choice
  # Validate choice matches one of the candidates (R1 already enforced on list).
  for c in $open_list; do
    if [ "$choice" = "$c" ]; then
      printf '%s' "$c"
      return 0
    fi
  done
  echo "workstream: resolve failed: choice '$choice' not in candidate list" >&2
  return 1
}

# -----------------------------------------------------------------------------
# Public: _workstream_sanitize <mode> <text>
# Single helper covering all three R4 rules. Modes:
#   pr   — `printf '%s\n'` faithful emission (NEVER `echo -e`, NEVER `printf "$msg"`).
#   log  — strip control chars (`tr -d '[:cntrl:]'`); used before append to
#          `.workstream/_overrides.log` (slice #62) or any other persisted log.
#   warn — strip ANSI escapes (`sed 's/\x1b\[[0-9;]*[a-zA-Z]//g'`) for CLI
#          warnings (e.g. /orient, /write-a-prd refusal text).
# -----------------------------------------------------------------------------
_workstream_sanitize() {
  local mode="${1:-}" text="${2:-}"
  case "$mode" in
    pr)
      # The cardinal rule: `printf '%s\n'` so the SECOND argument cannot
      # be reinterpreted as a format string. Trailing newline included; if
      # caller wants no trailing newline, use printf '%s' directly.
      printf '%s\n' "$text"
      ;;
    log)
      # Strip control chars (NUL through US, plus DEL). Keeps printable ASCII
      # + UTF-8 multibyte (which lives above 0x7F for any continuation byte).
      # ALSO strip Unicode bidi controls + BOM via byte-level sed pass:
      # codex pass-1 (#71 / slice 6) LOW caught that `tr -d '[:cntrl:]'`
      # leaves U+200E/U+200F/U+202A-U+202E/U+2066-U+2069/U+FEFF intact,
      # which enables visual log spoofing (RTL override flips status text
      # right-to-left, BOM hides at start of strings). Strip bytewise (UTF-8
      # encodings: E2 80 8E/8F + E2 80 AA-AE + E2 81 A6-A9 + EF BB BF).
      # LC_ALL=C keeps byte-exact matching so surrounding multibyte UTF-8
      # is not misidentified.
      printf '%s' "$text" \
        | LC_ALL=C tr -d '[:cntrl:]' \
        | LC_ALL=C sed -E $'s/\xe2\x80[\x8e\x8f\xaa-\xae]//g; s/\xe2\x81[\xa6-\xa9]//g; s/\xef\xbb\xbf//g'
      ;;
    warn)
      # Strip ANSI CSI escapes per ECMA-48 §5.4. Sequence:
      #   CSI = ESC `[` <param bytes>* <intermediate bytes>* <final byte>
      #   param bytes:        0x30-0x3F  (digits + `:` `;` `<` `=` `>` `?`)
      #   intermediate bytes: 0x20-0x2F  (space + `!` `"` `#` `$` `%` `&` `'` `(` `)` `*` `+` `,` `-` `.` `/`)
      #   final byte:         0x40-0x7E  (`@` through `~`)
      # Codex MED on slice #62 pass-2: hand-picked param/intermediate classes
      # missed `:` (0x3A — used by modern SGR colon-form: e.g. `\x1b[38:2:r:g:bm`),
      # space (0x20), and `.` (0x2E). Replaced with full byte-range classes
      # so EVERY conforming CSI is consumed atomically and `log` never sees
      # CSI residue text. Codex MED on slice #58 (PR #65) mandated the
      # broader final-byte range; this expands to cover all three
      # ECMA-48 byte classes.
      # LC_ALL=C: byte-exact regex matching, so multibyte UTF-8 cannot
      # accidentally match into a CSI byte range.
      printf '%s' "$text" | LC_ALL=C sed -E $'s/\x1b\\[[\x30-\x3f]*[\x20-\x2f]*[\x40-\x7e]//g'
      ;;
    *)
      echo "workstream: sanitize: unknown mode '$mode' (use pr|log|warn)" >&2
      return 2
      ;;
  esac
}

# -----------------------------------------------------------------------------
# Public: _workstream_skip_flag_reason <argv...>
# Slice #59 — surface helper for the `--skip-phase-gate REASON="..."` override.
# Scans argv for the flag pair and echoes the REASON value on stdout.
#
# Exit codes:
#   0 — flag present + REASON value is non-empty / non-whitespace; reason on stdout
#   1 — flag absent (no override; caller should run the validate gate)
#   2 — flag present but REASON value is empty / whitespace-only / missing entirely
#       (caller MUST refuse to proceed; an audit override without a rationale
#       defeats the audit-log contract that lands in slice #62)
#
# Argv contract: the flag pair is two tokens — `--skip-phase-gate`
# followed (eventually) by `REASON="<text>"`. The quoting is shell-stripped
# before the helper sees it, so the REASON token is literally `REASON=<text>`
# in argv. Whitespace inside `<text>` is preserved (operators write multi-word
# rationales).
#
# Position contract:
#   - `--skip-phase-gate` may appear anywhere in argv.
#   - `REASON=...` is consumed ONLY if it appears AT-OR-AFTER the flag's
#     index. Stray `REASON=...` tokens earlier in argv (e.g. an unrelated
#     argument context, or a paste from some other tool) will NOT silently
#     satisfy the override. This guards against accidental gate bypass when
#     mixed argument types are present (Codex MED on PR #59 pass-2).
#   - The flag pair tokens may have other args between them (e.g.
#     `--skip-phase-gate --slug=foo REASON="..."`); adjacency is not required.
# Other args are ignored — caller layers their own parser for slug, etc.
# -----------------------------------------------------------------------------
_workstream_skip_flag_reason() {
  local i=1 flag_idx=0 reason="" found_reason=0
  # Bash 3.2 compatible argv walk by index. Two-pass semantics:
  #
  # Pass 1: locate the index of `--skip-phase-gate`. Records the position so
  # the REASON= scan can be bound to flag-position-or-later. Without this
  # binding, a stray `REASON=...` token earlier in argv (e.g. as part of an
  # unrelated argument context) could silently satisfy the override — Codex
  # MED on this PR pass-2 caught the regression.
  #
  # Pass 2: scan AT-OR-AFTER the flag for a REASON=... token. Multiple are
  # possible; honor the FIRST. This preserves adjacency-tolerance (the flag
  # pair may have other tokens between them, e.g. `--skip-phase-gate
  # --slug=foo REASON="..."`) while preventing earlier-than-flag REASON=
  # tokens from leaking into the override.
  while [ "$i" -le "$#" ]; do
    eval "local cur=\${$i}"
    if [ "$cur" = "--skip-phase-gate" ]; then
      flag_idx=$i
      break
    fi
    i=$((i+1))
  done
  if [ "$flag_idx" -eq 0 ]; then
    # Flag absent entirely; no override.
    return 1
  fi
  i="$flag_idx"
  while [ "$i" -le "$#" ]; do
    eval "local cur=\${$i}"
    case "$cur" in
      REASON=*)
        if [ "$found_reason" -eq 0 ]; then
          reason="${cur#REASON=}"
          found_reason=1
        fi
        ;;
    esac
    i=$((i+1))
  done
  # Trim leading + trailing whitespace from reason for the empty-check.
  # Bash 3.2-safe trim using parameter expansion + extglob-free pattern.
  local trimmed="$reason"
  # Strip leading whitespace.
  while [ "${trimmed# }" != "$trimmed" ] || [ "${trimmed#	}" != "$trimmed" ]; do
    trimmed="${trimmed# }"
    trimmed="${trimmed#	}"
  done
  # Strip trailing whitespace.
  while [ "${trimmed% }" != "$trimmed" ] || [ "${trimmed%	}" != "$trimmed" ]; do
    trimmed="${trimmed% }"
    trimmed="${trimmed%	}"
  done
  if [ -z "$trimmed" ]; then
    echo "workstream: --skip-phase-gate requires non-empty REASON=\"...\" (got empty/whitespace)" >&2
    return 2
  fi
  printf '%s' "$reason"
}

# -----------------------------------------------------------------------------
# Public: _workstream_log_override <command> <slug> <reason>
# Slice #62 (PRD #57 user stories 9 + 10). See header for full contract.
#
# Highest-injection-risk surface in the workstream library: reason text
# arrives from the operator's CLI via slash-command argv and is written to a
# committed audit log. Defenses (in order of execution):
#
#   1. COMMAND WHITELIST — only the three gated commands are valid. Defends
#      against typos and against `--skip-phase-gate` payloads that try to
#      smuggle a different command name.
#   2. SLUG R1 — defense-in-depth even if upstream forgot to validate.
#      Slug appears in field 3 of the log line.
#   3. REASON SANITIZE (mode=log) — strips ALL control chars, including
#      \n, \t, \x1b. Single collapse rule (documented in helper header):
#      strip, do not replace. Guarantees (a) single-line append, (b) TSV
#      integrity, (c) no escape-injection into log readers.
#   4. REASON LENGTH CAP — bytes > WORKSTREAM_OVERRIDE_REASON_MAX (default
#      1000) refused. Prevents runaway log lines from filling the audit
#      file. Cap is byte-level; UTF-8 multibyte counted as bytes.
#   5. POST-SANITIZE EMPTY CHECK — reason that collapses to empty (only
#      whitespace, only control chars, only ANSI escapes) refused. Prevents
#      vacuous overrides whose audit value is zero.
#   6. APPEND VIA `printf '%s\n'` — reason is the SECOND argument; cannot be
#      reinterpreted as a format string. No `eval`, no `$()`, no backticks
#      ever touch the reason.
#   7. ATOMIC APPEND — flock around the `>>` (when available) so two parallel
#      override calls cannot interleave bytes inside a single line.
# -----------------------------------------------------------------------------
_workstream_log_override() {
  # NOTE: variable named `cmd` not `command` because `command` shadows the
  # bash built-in command-resolver we use later (`command -v flock`).
  local cmd="${1:-}" slug="${2:-}" reason="${3-}"
  if [ "$#" -lt 3 ]; then
    echo "workstream: usage: _workstream_log_override <command> <slug> <reason>" >&2
    return 2
  fi
  # 1. Command whitelist.
  case "$cmd" in
    grill-me|write-a-prd|prd-to-issues) ;;
    *)
      echo "workstream: log_override: unknown command '$cmd' (allowed: grill-me, write-a-prd, prd-to-issues)" >&2
      return 1
      ;;
  esac
  # 2. Slug R1 enforcement (defense-in-depth — slash-command layer also
  # validates, but we do not trust the caller here).
  if ! _workstream_validate_slug "$slug" >/dev/null 2>&1; then
    echo "workstream: log_override: invalid slug (R1): $slug" >&2
    return 1
  fi
  # 3. Reason length cap (BEFORE sanitize — sanitize can only shrink).
  local cap="${WORKSTREAM_OVERRIDE_REASON_MAX:-1000}"
  # Defensive: reject non-numeric cap rather than fall through to a string
  # comparison that bash 3.2 would treat as 0.
  case "$cap" in
    ''|*[!0-9]*)
      echo "workstream: log_override: WORKSTREAM_OVERRIDE_REASON_MAX must be a non-negative integer, got '$cap'" >&2
      return 1
      ;;
  esac
  # Codex LOW on slice #62 pass-2: ${#reason} is character-count under UTF-8
  # locales, NOT byte-count, so a multibyte reason can exceed the documented
  # byte budget. Use `wc -c` with LC_ALL=C for true byte count. printf '%s'
  # so the reason is not interpreted as a format string.
  local reason_bytes
  reason_bytes="$(LC_ALL=C printf '%s' "$reason" | LC_ALL=C wc -c | tr -d ' ')"
  if [ "$reason_bytes" -gt "$cap" ]; then
    echo "workstream: log_override: reason exceeds ${cap}-byte cap (got ${reason_bytes})" >&2
    return 1
  fi
  # 4. Sanitize: COMPOSE warn THEN log so both the ESC byte and the CSI
  # parameter/intermediate/final-byte residue are removed. Codex MED on PR
  # pass-1 (slice #62): `log` mode alone strips \x1b but leaves `[31m`
  # residue text (final byte `[@-~]` survives), drifting from the documented
  # "ANSI escapes stripped" R4 contract for the override log specifically.
  # `warn` consumes the full CSI sequence (matches `\x1b\[<params>[@-~]`);
  # `log` then strips any remaining bare control chars (newlines, tabs,
  # bell, raw \x1b not part of a CSI, etc.). Both passes are byte-stable
  # and idempotent.
  local clean
  clean="$(_workstream_sanitize warn "$reason")"
  clean="$(_workstream_sanitize log "$clean")"
  # 5. Empty-after-sanitize refusal. Also strip leading/trailing whitespace
  # for the empty-check so a reason of pure spaces refuses cleanly.
  local stripped
  stripped="$(printf '%s' "$clean" | LC_ALL=C sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  if [ -z "$stripped" ]; then
    echo "workstream: log_override: reason is empty after sanitize (control chars / whitespace stripped); REASON= must contain printable content" >&2
    return 1
  fi
  # Ensure the .workstream/ dir exists. The override may be invoked from a
  # context where the slash-command did NOT first init a workstream file
  # (e.g. RETROFIT-LEGACY-BRANCH grandfathering on a repo with no ledger);
  # the directory must still be present so the log can land.
  local dir=".workstream"
  mkdir -p "$dir"
  local log_file="$dir/_overrides.log"
  local now
  now="$(_workstream_now)"
  # 6. Build the line. printf '%s' so neither argument is a format string.
  # The four fields are: timestamp \t command \t slug \t cleaned-reason.
  # `clean` (not `stripped`) is the field-value: post-sanitize text with
  # internal spaces preserved; only control chars are stripped per spec.
  # The leading/trailing whitespace strip was for the empty-check only.
  local lock_path
  lock_path="${WORKSTREAM_OVERRIDE_LOCK_FILE:-${TMPDIR:-/tmp}/cpt-workstream-overrides.lock}"
  if ! touch "$lock_path" 2>/dev/null; then
    echo "workstream: log_override: cannot create lock file at $lock_path; falling back to naked append" >&2
    printf '%s\t%s\t%s\t%s\n' "$now" "$cmd" "$slug" "$clean" >> "$log_file" || {
      echo "workstream: log_override: append failed to $log_file" >&2
      return 1
    }
    return 0
  fi
  if ! command -v flock >/dev/null 2>&1; then
    # No flock — fall back to naked append + warn (R2 fallback semantics
    # mirror lib/dispatch.sh / _workstream_advance).
    echo "workstream: log_override: flock not found on PATH; falling back to naked append (single-operator append-race window accepted, R2)" >&2
    printf '%s\t%s\t%s\t%s\n' "$now" "$cmd" "$slug" "$clean" >> "$log_file" || {
      echo "workstream: log_override: append failed to $log_file" >&2
      return 1
    }
    return 0
  fi
  local rc
  (
    flock -x 200
    printf '%s\t%s\t%s\t%s\n' "$now" "$cmd" "$slug" "$clean" >> "$log_file"
  ) 200>"$lock_path"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "workstream: log_override: flock-protected append failed (rc=$rc) for $log_file" >&2
    return 1
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Public: _workstream_resolve_slug_with_method [--slug=<foo>]
# Wrapper around _workstream_resolve_slug (slice #58) that ALSO emits the
# resolution method on stderr for /wind-up's UX surface ("resolved slug: X via
# branch / flag / single-open file"). Stdout = slug (unchanged). Exit codes
# unchanged. Method string is one of:
#   flag           — --slug=<foo> won
#   branch         — branch-name regex matched
#   single-open    — exactly-one-open .workstream/<file>.md
#   interactive    — TTY disambiguate (slice #58 path)
#
# Implementation: re-runs the cascade with the same precedence as the resolver
# but without delegating to it (the existing resolver does not surface its
# decision path; instead of bolting telemetry into the hot path, this helper
# duplicates the cascade-decision logic at READ scope only). Both paths share
# the same R1/R3/R6 guarantees.
# -----------------------------------------------------------------------------
_workstream_resolve_slug_with_method() {
  local arg slug=""
  for arg in "$@"; do
    case "$arg" in
      --slug=*) slug="${arg#--slug=}" ;;
      *) ;;
    esac
  done
  if [ -n "$slug" ]; then
    if ! _workstream_validate_slug "$slug"; then
      return 1
    fi
    echo "workstream: slug '$slug' resolved via flag (--slug)" >&2
    printf '%s' "$slug"
    return 0
  fi
  local branch capture
  branch="$(_workstream_current_branch)"
  if [ -n "$branch" ]; then
    if [[ "$branch" =~ ^[0-9]+-(.+)$ ]]; then
      capture="${BASH_REMATCH[1]}"
      if _workstream_validate_slug "$capture" 2>/dev/null; then
        echo "workstream: slug '$capture' resolved via branch ('$branch' matches ^[0-9]+-(.+)\$)" >&2
        printf '%s' "$capture"
        return 0
      fi
    fi
  fi
  # Codex pass-1 MED: distinguish single-open vs interactive resolution paths
  # so the method string is accurate. Pre-compute open_count from the same
  # source the foundation resolver uses; map count to method:
  #   0 open  → fall through to foundation (bootstrap-empty exemption rc=2 OR
  #             refusal rc=1; method "no-match" emitted on rc=1)
  #   1 open  → "single-open file"
  #   ≥2 open → "interactive disambiguate" (TTY-only) OR refusal (non-TTY)
  #
  # Codex adversarial pass-1 MED: SNAPSHOT-CONSISTENT method labeling. The
  # original wrapper called _workstream_list_open and _workstream_resolve_slug
  # separately — a TOCTOU between the two calls could let open-file state
  # change (concurrent /grill-me, file rename, etc.) and emit a wrong method.
  # Snapshot the open list ONCE here, derive method directly from snapshot
  # count, AND short-circuit the single-open case so we do not re-read the
  # filesystem (atomic decision path: snapshot → method → slug, all from one
  # source). For multi-open we still defer to _workstream_resolve_slug for
  # the interactive disambiguate UX, but the method string is already locked
  # to the snapshot count so a race cannot mislabel "single-open" after
  # disambiguate.
  local open_list open_count=0 resolved rc
  open_list="$(_workstream_list_open)"
  if [ -n "$open_list" ]; then
    open_count="$(printf '%s\n' "$open_list" | grep -c '^.' || true)"
  fi
  # Codex pass-9 P1: preserve resolver stderr diagnostics. Previously each
  # branch redirected `_workstream_resolve_slug 2>/dev/null`, swallowing the
  # foundation resolver's recovery hints (non-TTY ambiguity message, no-match
  # diagnostic, etc.). The wrapper's purpose is to ADD a method label, not
  # to suppress diagnostics. Pass through stderr verbatim — let the caller
  # see both the method label (when successful) and the recovery hint (on
  # failure).
  case "$open_count" in
    1)
      # Single-open path: derive slug from snapshot directly so the resolver
      # call below cannot disagree with the method label.
      resolved="$(printf '%s' "$open_list" | head -n1)"
      if [ -z "$resolved" ] || ! _workstream_validate_slug "$resolved" 2>/dev/null; then
        # Snapshot inconsistent — fall through to resolver for refusal path.
        resolved="$(_workstream_resolve_slug)"
        rc=$?
        if [ "$rc" -ne 0 ] || [ -z "$resolved" ]; then
          return "$rc"
        fi
      fi
      echo "workstream: slug '$resolved' resolved via single-open file (.workstream/${resolved}.md)" >&2
      printf '%s' "$resolved"
      return 0
      ;;
    0)
      # No open files — let the foundation resolver emit the correct rc/path
      # AND its stderr diagnostic (non-TTY refusal, no-match guidance, etc.).
      resolved="$(_workstream_resolve_slug)"
      rc=$?
      if [ "$rc" -ne 0 ] || [ -z "$resolved" ]; then
        return "$rc"
      fi
      echo "workstream: slug '$resolved' resolved via foundation cascade (no open files at snapshot)" >&2
      printf '%s' "$resolved"
      return 0
      ;;
    *)
      # Multi-open: defer to interactive disambiguate. Method label is locked
      # to the snapshot count — even if the resolver picks differently after
      # the user disambiguates, the labeling is honest about the ambiguity.
      resolved="$(_workstream_resolve_slug)"
      rc=$?
      if [ "$rc" -ne 0 ] || [ -z "$resolved" ]; then
        return "$rc"
      fi
      echo "workstream: slug '$resolved' resolved via interactive disambiguate ($open_count open files)" >&2
      printf '%s' "$resolved"
      return 0
      ;;
  esac
}

# -----------------------------------------------------------------------------
# Public: _workstream_detect_prompt_phase <prompt-file>
# Parse a memory/prompt_{slug}.md file and return the HIGHEST pipeline phase
# (in the partial order grill < prd < issues) referenced inside the
# `## DO FIRST...` section (or, if no such section, the whole file as a
# fallback — defensive read for prompts written before the DO-FIRST contract).
#
# Phase signals (case-sensitive — prompts always lowercase commands):
#   grill   — references /grill-me
#   prd     — references /write-a-prd
#   issues  — references /prd-to-issues
#
# Output (stdout): one of `grill`, `prd`, `issues`, `none` (no signal found).
# Exit: 0 on success (file readable). 1 if the file does not exist.
#
# Implementation: scope to lines AFTER a `^##[[:space:]]+DO[[:space:]-]?FIRST`
# header (case-insensitive on the prefix; PRD-specified header is "## DO FIRST
# on resume" but operator hand-edits drift to "## DO-FIRST" / "## Do First").
# If no such header is present, fall back to whole-file scan. Highest phase
# wins because callers want the most permissive proposed action validated
# (e.g. "/prd-to-issues" with "/grill-me skip" prose still requires Phase-2
# evidence). Codex-LOW: comments/code-fences containing the slash names will
# trigger a false positive — accepted v1 limitation, prompts in this project
# do not use code-fenced examples of pipeline commands.
# -----------------------------------------------------------------------------
_workstream_detect_prompt_phase() {
  local file="${1:-}"
  if [ -z "$file" ] || [ ! -f "$file" ]; then
    echo "workstream: detect_prompt_phase: file not readable: ${file:-<empty>}" >&2
    return 1
  fi
  # Extract DO-FIRST scope. awk pattern: case-insensitive on the literal
  # prefix `## DO ` (allowing `-` separator). `tolower($0) ~ ...` handles the
  # case-insensitive match without bash 4+ ${var^^}.
  #
  # Codex pass-3 MED: distinguish "header found, body empty" (return `none`)
  # from "header missing, fall back to whole-file" (defensive scan). Without
  # this distinction, a DO-FIRST header with empty body would fall through to
  # whole-file scan and pick up unrelated section content as if it were the
  # proposed action. Dedicated marker line printed first by awk acts as the
  # discriminator: `__HEADER_FOUND__` appears iff the header was matched.
  local scope_raw scope header_found=0
  # Codex adversarial pass-1 MED: strip a UTF-8 BOM (EF BB BF) from line 1 so
  # a BOM-prefixed prompt file is not misclassified (header missed → whole-
  # file fallback → unrelated section drives phase signal).
  scope_raw="$(LC_ALL=C awk '
    BEGIN { found = 0 }
    NR == 1 { sub(/^\xef\xbb\xbf/, "") }
    /^##/ {
      lower = tolower($0)
      if (lower ~ /^##[[:space:]]+do[[:space:]-]?first/) {
        found = 1
        print "__HEADER_FOUND__"
        next
      }
      if (found == 1) { exit }
    }
    found == 1 { print }
  ' "$file")"
  if printf '%s' "$scope_raw" | head -n1 | LC_ALL=C grep -qF '__HEADER_FOUND__'; then
    header_found=1
    # Strip the discriminator line from the scope.
    scope="$(printf '%s\n' "$scope_raw" | tail -n +2)"
  else
    scope=""
  fi
  # If header was found but body is empty (or whitespace-only), there is no
  # phase-skip signal in the proposed action. Return `none` immediately —
  # do NOT fall back to whole-file scan (would pollute the result).
  if [ "$header_found" -eq 1 ]; then
    if [ -z "$scope" ] || [ -z "$(printf '%s' "$scope" | tr -d '[:space:]')" ]; then
      printf 'none'
      return 0
    fi
  else
    # No DO-FIRST header at all → fall back to whole-file scan (defensive,
    # for prompts written before the DO-FIRST contract).
    scope="$(cat "$file")"
  fi
  # Highest-phase wins. Anchor on slash-prefixed command tokens; require a
  # word boundary after the command name so e.g. /write-a-prd-extra does not
  # match. Bash 3.2 grep -E with `[^a-z0-9-]` works as a portable boundary.
  if printf '%s\n' "$scope" | LC_ALL=C grep -qE '/prd-to-issues([^a-z0-9-]|$)'; then
    printf 'issues'
    return 0
  fi
  if printf '%s\n' "$scope" | LC_ALL=C grep -qE '/write-a-prd([^a-z0-9-]|$)'; then
    printf 'prd'
    return 0
  fi
  if printf '%s\n' "$scope" | LC_ALL=C grep -qE '/grill-me([^a-z0-9-]|$)'; then
    printf 'grill'
    return 0
  fi
  printf 'none'
  return 0
}

# -----------------------------------------------------------------------------
# Internal: _workstream_prompt_path_validation_enabled
# Codex adversarial pass-3 HIGH-1: production-safe bypass policy. Returns 0
# (validation enabled) by default. Returns 1 (skip) ONLY when BOTH
# WORKSTREAM_TEST_MODE=1 AND WORKSTREAM_VALIDATE_PROMPT_PATH=0 are set.
# Inherited shell env that sets only the bypass flag without the test-mode
# flag is IGNORED — confinement remains on. This prevents an adversarial
# or misconfigured shell from defeating the trust boundary in production.
# -----------------------------------------------------------------------------
_workstream_prompt_path_validation_enabled() {
  if [ "${WORKSTREAM_TEST_MODE:-0}" = "1" ] && \
     [ "${WORKSTREAM_VALIDATE_PROMPT_PATH:-1}" = "0" ]; then
    return 1  # bypass
  fi
  return 0  # enforce
}

# -----------------------------------------------------------------------------
# Internal: _workstream_validate_prompt_path <prompt-path>
# Codex adversarial pass-1 HIGH: prompt-handling helpers (
# _workstream_check_prompt_phase_skip, _workstream_rewrite_prompt_do_first)
# accepted any -f path. A caller bug or crafted argv could direct read/write
# at unrelated repo files. This helper enforces the trust boundary:
#   - basename MUST match `prompt_<r1-slug>.md`
#   - resolved path MUST NOT contain `/../` segments
#   - allowed parent directories: `memory/`, `.claude/memory/`,
#     `${HOME}/.claude-lx/projects/<project>/memory/` (the per-project dir
#     used by the harness). Override via WORKSTREAM_PROMPT_DIR_ALLOW (colon-
#     separated absolute paths). Symlink targets are NOT followed for the
#     parent-allowance check (defense-in-depth: a symlink under memory/ that
#     points outside is still caught by the basename requirement, but we
#     also reject the symlink case explicitly to avoid surprise).
#
# Returns rc=0 on accept, rc=1 on reject (with stderr diagnostic).
# Designed to be cheap (no `realpath` dependency — bash 3.2 portable).
# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
# Internal: _workstream_inode_id <path>
# Codex adversarial pass-7 MED: TOCTOU defense. Returns a stable
# device-inode identifier ("dev:inode") for the path on stdout. Empty
# stdout if file does not exist or stat is unavailable. Used by callers to
# pin the inode after validation and re-check before each read/write.
# -----------------------------------------------------------------------------
_workstream_inode_id() {
  local p="${1:-}"
  if [ -z "$p" ] || [ ! -e "$p" ]; then
    return 0
  fi
  # Linux GNU `stat -c '%d:%i'` first. GNU's `stat -f` is "filesystem info"
  # (multi-line output) — NOT BSD-style format — so `stat -f '%d:%i'` on
  # Linux silently produces a multi-line filesystem dump that breaks
  # equality comparisons. Try GNU `-c` first, then BSD `-f`. Final fallback:
  # `ls -li` field-1 is the inode.
  local id=""
  id="$(stat -c '%d:%i' "$p" 2>/dev/null)" || id=""
  if [ -z "$id" ]; then
    id="$(stat -f '%d:%i' "$p" 2>/dev/null)" || id=""
  fi
  if [ -z "$id" ]; then
    id="$(ls -li "$p" 2>/dev/null | awk '{print $1}')"
  fi
  printf '%s' "$id"
}

# -----------------------------------------------------------------------------
# Internal: _workstream_project_slug <abs-path>
# Derive the Claude-harness per-project slug for a repo path: EVERY character
# outside [a-zA-Z0-9] maps to `-`. Contract verified against the installed
# Claude Code 2.1.210 binary (`e.replace(/[^a-zA-Z0-9]/g,"-")`) and the
# on-disk slugs under `$HOME/.claude-lx/projects/` (case preserved, no
# lowercasing; e.g. `/U/h/GitHub/buy.vodka-v3` -> `-U-h-GitHub-buy-vodka-v3`,
# `/x/repo/.claude/y` -> `-x-repo--claude-y`). Issue #94 shipped the `.`
# mapping; codex adversarial review surfaced that the real contract is the
# full non-alphanumeric class (`_`, space, `+`, ... all map to `-` too), and
# that a partial mapping could trust a directory the harness never writes.
#
# Over-long paths: the harness truncates slugs > 200 chars to
# `slice(0,200)-<base36 hash of the original path>`. The hash is a
# Bun/wyhash value not reproducible portably in bash, so we FAIL CLOSED
# (rc=1, no output) rather than derive a dir the harness would never use.
# Operators with such paths can allowlist explicitly via
# WORKSTREAM_PROMPT_DIR_ALLOW.
#
# Collisions: the mapping is lossy BY HARNESS DESIGN (`/x/a.b`, `/x/a_b`,
# `/x/a-b` share a slug). Deriving exactly the slug the harness derives
# means we admit exactly the one directory the harness itself reads/writes
# for this repo path: a trust domain owned by the harness convention, not a
# widening introduced here.
#
# Non-ASCII: FAIL CLOSED (rc=1, no output). The harness contract operates on
# JavaScript UTF-16 code units (astral chars map to TWO dashes; slug length
# counts UTF-16 units), which bash cannot reproduce portably: under UTF-8
# locales bash replaces per character (one dash), under C per byte (two to
# four dashes). Worse, bash range classification is collation-aware, so
# under e.g. LC_COLLATE=en_US.UTF-8 an accented letter can match [a-z] and
# survive unmapped. Rather than trust a directory the harness may never
# write (or reject the one it does), non-ASCII paths return rc=1 and the
# operator allowlists explicitly via WORKSTREAM_PROMPT_DIR_ALLOW. All
# classification runs under LC_ALL=C so the result is locale-independent.
#
# Output (stdout): the slug. Exit: 0 on success; 1 on empty input, on any
# non-ASCII character in the input, or on a slug exceeding the harness
# 200-char pre-hash budget.
# -----------------------------------------------------------------------------
_workstream_project_slug() {
  local p="${1:-}"
  [ -n "$p" ] || return 1
  local slug=""
  # Subshell pins LC_ALL=C: byte-wise, collation-free classification. The
  # ASCII gate and the [!a-zA-Z0-9] ranges are then exact ASCII semantics
  # on every host locale (a caller's UTF-8 collation cannot leak accented
  # letters through [a-z], and multi-byte input cannot silently produce a
  # slug the harness would derive differently).
  slug="$(
    LC_ALL=C
    export LC_ALL
    # Balanced-paren clause form: bash 3.2 re-parses `$(...)` bodies and
    # chokes on a bare `pattern)` (docs/PITFALLS.md, bash-3.2 scan quirks).
    case "$p" in
      (*[![:ascii:]]*) exit 1 ;;
    esac
    printf '%s' "${p//[!a-zA-Z0-9]/-}"
  )" || return 1
  [ -n "$slug" ] || return 1
  if [ "${#slug}" -gt 200 ]; then
    return 1
  fi
  printf '%s' "$slug"
  return 0
}

_workstream_validate_prompt_path() {
  local p="${1:-}"
  if [ -z "$p" ]; then
    echo "workstream: validate_prompt_path: empty path" >&2
    return 1
  fi
  # Reject path-traversal segments anywhere in the path. `/..` and `/../`
  # both caught; lone `..` filename is caught by basename pattern.
  case "$p" in
    *"/.."|*"/../"*|*"/.."/*|".."|"../"*)
      echo "workstream: validate_prompt_path: path traversal segment in: $p" >&2
      return 1
      ;;
  esac
  # Codex adversarial pass-3 HIGH-2: directory-symlink escape — a `memory/`
  # entry that is itself a symlink to /tmp/foo would pass textual allowlist
  # comparison while I/O lands outside the project. Canonicalize via `cd`
  # + `pwd -P` (resolves all parent-component symlinks) and use the
  # canonicalized path for allowlist matching. We also reject if any
  # parent-directory entry is a symlink (defense-in-depth — `cd .. && pwd
  # -P` already collapses, but we want to refuse the suspicious case
  # outright so a future allowlist entry that points through a symlink
  # cannot match accidentally).
  # Basename MUST match `prompt_<r1-slug>.md`. Slug pattern mirrors R1:
  # `^[a-z0-9-]+$` (already enforced for the workstream file family).
  local base="${p##*/}"
  case "$base" in
    prompt_*.md) ;;
    *)
      echo "workstream: validate_prompt_path: basename must be 'prompt_<slug>.md', got: $base" >&2
      return 1
      ;;
  esac
  local stem="${base#prompt_}"
  stem="${stem%.md}"
  if ! _workstream_validate_slug "$stem" >/dev/null 2>&1; then
    echo "workstream: validate_prompt_path: slug portion of basename fails R1: $stem" >&2
    return 1
  fi
  # Reject symlink to defeat directory-escape via link.
  if [ -L "$p" ]; then
    echo "workstream: validate_prompt_path: refusing symlink: $p" >&2
    return 1
  fi
  # Codex adversarial pass-6 HIGH: REJECT hard-linked files. A hard link
  # under memory/ to an unrelated inode would pass basename + parent +
  # symlink checks but writes would mutate the OTHER inode's content. Use
  # `stat` to check link count >1; portable across BSD (stat -f) and GNU
  # (stat -c). If both fail (e.g. minimal busybox), fall back to `ls -l`
  # link-count parse. If the file does not yet exist (rewrite-create case),
  # there are no inodes to count — skip silently.
  if [ -e "$p" ] && [ -f "$p" ] && [ ! -L "$p" ]; then
    local _nlink=""
    # GNU `stat -c '%h'` first (Linux), then BSD `stat -f '%l'` (macOS).
    # Same rationale as _workstream_inode_id: GNU `stat -f` is filesystem-
    # stat, not format, so leading with `-f` produces wrong output on Linux.
    _nlink="$(stat -c '%h' "$p" 2>/dev/null)" || _nlink=""
    if [ -z "$_nlink" ]; then
      _nlink="$(stat -f '%l' "$p" 2>/dev/null)" || _nlink=""
    fi
    if [ -z "$_nlink" ]; then
      # Last-resort: ls -l field-2 is link count on most coreutils.
      _nlink="$(ls -ld "$p" 2>/dev/null | awk '{print $2}')"
    fi
    if [ -n "$_nlink" ] && [ "$_nlink" != "1" ]; then
      echo "workstream: validate_prompt_path: refusing hard-linked file (link-count=$_nlink): $p" >&2
      return 1
    fi
  fi
  # Codex adversarial pass-2 HIGH-1: NO bare-basename fast-path. A path with
  # no `/` is treated as current-directory-relative; we MUST resolve it against
  # a known project root and verify the resolved parent is allowlisted. Bare
  # accept was a confinement bypass.
  local parent
  if [ "${p#/}" != "$p" ]; then
    # Absolute path. Strip filename to get parent dir.
    parent="${p%/*}"
  else
    # Relative path. Resolve against PWD (the slash-command CWD is always the
    # repo root or an explicit chdir target — bare relative paths are normal).
    case "$p" in
      */*) parent="${p%/*}" ;;
      *)   parent="." ;;
    esac
  fi
  # Strip trailing slash for comparison.
  parent="${parent%/}"
  # Codex adversarial pass-2 HIGH-2: project-scoped allowlist. Suffix matching
  # like `*/memory` is not a trust decision — it admits `/tmp/memory/...` or
  # another repo's memory dir. Build the allowlist from KNOWN PROJECT ROOTS:
  #   1) ${WORKSTREAM_PROJECT_ROOT}/memory and /.claude/memory (if env set)
  #   2) The repo root located via `git rev-parse --show-toplevel` (best-
  #      effort; non-fatal if not a git repo)
  #   3) PWD/memory and PWD/.claude/memory (the slash-command CWD)
  #   4) WORKSTREAM_PROMPT_DIR_ALLOW colon-list (operator override)
  # Resolve all candidate paths to absolutes BEFORE comparison so relative-
  # vs-absolute and trailing-slash variants normalize identically.
  local resolved_parent
  # Use `cd ... && pwd -P` to canonicalize parent (follows AND collapses all
  # symlinks; `pwd -P` returns the physical path). If `cd` fails (parent does
  # not exist or is unreadable), refuse — we cannot safely canonicalize a
  # ghost path.
  if [ "${parent#/}" = "$parent" ]; then
    # Relative parent — anchor on PWD.
    resolved_parent="$(cd "$parent" 2>/dev/null && pwd -P 2>/dev/null)"
  else
    resolved_parent="$(cd "$parent" 2>/dev/null && pwd -P 2>/dev/null)"
  fi
  if [ -z "$resolved_parent" ]; then
    echo "workstream: validate_prompt_path: parent dir does not exist or is not readable: $parent" >&2
    return 1
  fi
  resolved_parent="${resolved_parent%/}"
  # Build allowed set. Each candidate root is canonicalized the SAME WAY
  # (cd + pwd -P) so symlinked /memory dirs resolve identically.
  #
  # Codex adversarial pass-4 HIGH: REJECT symlinked memory dirs by default.
  # If `<root>/memory` (or `.claude/memory`) is a symlink, canonicalization
  # would let the symlink target match the candidate's canonical path —
  # admitting out-of-project I/O even with the textual allowlist check.
  # Defense: skip any allowlist root whose `memory` or `.claude/memory`
  # entry is a symlink. The operator can override by setting
  # WORKSTREAM_PROMPT_DIR_ALLOW with the explicit canonical target —
  # an intentional, audit-trailed permission decision.
  _ws_add_canon_root() {
    # $1 = candidate dir; if it exists, is not a symlink, and canonicalizes,
    # append to $allowed. Inline helper (defined within enclosing fn scope
    # so we don't pollute global namespace).
    local d="$1"
    [ -z "$d" ] && return
    if [ -L "$d" ]; then
      return  # symlinked memory root → reject by default
    fi
    if [ ! -d "$d" ]; then
      return
    fi
    local canon
    canon="$(cd "$d" 2>/dev/null && pwd -P 2>/dev/null)"
    [ -n "$canon" ] && allowed="${allowed:+$allowed:}${canon%/}"
  }
  local allowed=""
  local cwd repo_root
  cwd="$(pwd -P 2>/dev/null)"
  cwd="${cwd%/}"
  if [ -n "$cwd" ]; then
    _ws_add_canon_root "$cwd/memory"
    _ws_add_canon_root "$cwd/.claude/memory"
  fi
  if repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -n "$repo_root" ]; then
    repo_root="${repo_root%/}"
    _ws_add_canon_root "$repo_root/memory"
    _ws_add_canon_root "$repo_root/.claude/memory"
    # Codex pass-10 P1: the Claude harness stores prompts at
    # `${HOME}/.claude-lx/projects/<project-slug>/memory/prompt_*.md` by
    # default. Without this entry, /wind-down + /wind-up in normal setups
    # cannot read or rewrite prompts (the production-path bypass is what
    # the test harness uses, but production has no test-mode flag).
    if [ -n "${HOME:-}" ] && [ -d "$HOME/.claude-lx/projects" ]; then
      local _claude_lx_root="$HOME/.claude-lx/projects"
      # Build the project-slug from repo_root the way the Claude harness
      # does: every non-alphanumeric character maps to `-` (e.g.
      # `/X/buy.vodka-v3` becomes `-X-buy-vodka-v3`). Replacing only `/`
      # (pre-#94) left `.` and every other special character unmatched, so
      # the HARNESS memory dir was silently omitted from the allowlist for
      # any repo path containing a dot (repo-local memory/ roots above
      # still applied). Full contract + fail-closed over-length policy:
      # see _workstream_project_slug.
      local _project_slug=""
      _project_slug="$(_workstream_project_slug "$repo_root")" || _project_slug=""
      if [ -n "$_project_slug" ]; then
        _ws_add_canon_root "$_claude_lx_root/$_project_slug/memory"
      fi
    fi
  fi
  if [ -n "${WORKSTREAM_PROJECT_ROOT:-}" ]; then
    local proj="${WORKSTREAM_PROJECT_ROOT%/}"
    _ws_add_canon_root "$proj/memory"
    _ws_add_canon_root "$proj/.claude/memory"
  fi
  if [ -n "${WORKSTREAM_PROMPT_DIR_ALLOW:-}" ]; then
    # Operator override: each colon-entry canonicalized too. The override
    # IS allowed to point at a symlink target (operator's explicit decision
    # to trust that path).
    #
    # Codex adversarial pass-5 HIGH: REQUIRE absolute paths only. A relative
    # entry like `.` or `../tmp/memory` would canonicalize to whatever the
    # current PWD resolves to — turning an inherited / leaked env var into
    # a runtime trust grant. Absolute-only enforcement makes the override
    # auditable and prevents accidental over-grant.
    local IFS_o="$IFS"
    IFS=':'
    local op_path canon_op
    for op_path in $WORKSTREAM_PROMPT_DIR_ALLOW; do
      IFS="$IFS_o"
      [ -z "$op_path" ] && { IFS=':'; continue; }
      case "$op_path" in
        /*)
          ;;
        *)
          echo "workstream: validate_prompt_path: WORKSTREAM_PROMPT_DIR_ALLOW entry must be absolute path, got: '$op_path' (rejected)" >&2
          IFS=':'
          continue
          ;;
      esac
      canon_op="$(cd "$op_path" 2>/dev/null && pwd -P 2>/dev/null)"
      [ -n "$canon_op" ] && allowed="${allowed:+$allowed:}${canon_op%/}"
      IFS=':'
    done
    IFS="$IFS_o"
  fi
  unset -f _ws_add_canon_root
  # Iterate allowed list (colon-separated). EXACT match on resolved_parent.
  local IFS_save="$IFS"
  IFS=':'
  local allow_path
  for allow_path in $allowed; do
    IFS="$IFS_save"
    [ -z "$allow_path" ] && { IFS=':'; continue; }
    allow_path="${allow_path%/}"
    if [ "$resolved_parent" = "$allow_path" ]; then
      return 0
    fi
    IFS=':'
  done
  IFS="$IFS_save"
  echo "workstream: validate_prompt_path: parent dir not in project-scoped allowlist: $resolved_parent (allowed: $allowed)" >&2
  return 1
}

# -----------------------------------------------------------------------------
# Public: _workstream_check_prompt_phase_skip <slug> <prompt-file>
# Validates that the proposed DO-FIRST command in the prompt has its required
# prerequisite in the workstream ledger.
#
# Returns:
#   0  — prompt is OK (proposed command's prereq is satisfied, OR no pipeline
#        command is proposed at all)
#   1  — phase-skip detected; recommended-correction command echoed to stdout
#   2  — usage error (slug or prompt arg missing/invalid)
#
# Mapping (proposed phase → required prereq → recommended correction):
#   grill   — never a skip (grill IS the entry point)
#   prd     — requires phases.grill.started_at (loose Phase-1 evidence). On
#             miss: recommend `/grill-me`
#   issues  — requires phases.prd.completed_at. On miss: recommend `/write-a-prd`
#
# Cold-start case: if `.workstream/<slug>.md` does NOT exist and the proposed
# phase is prd or issues, that is a phase-skip — recommend `/grill-me`.
# -----------------------------------------------------------------------------
_workstream_check_prompt_phase_skip() {
  local slug="${1:-}" prompt="${2:-}"
  if [ -z "$slug" ] || [ -z "$prompt" ]; then
    echo "workstream: usage: _workstream_check_prompt_phase_skip <slug> <prompt-file>" >&2
    return 2
  fi
  if ! _workstream_validate_slug "$slug" >/dev/null 2>&1; then
    echo "workstream: check_prompt_phase_skip: invalid slug (R1): $slug" >&2
    return 2
  fi
  # Codex adversarial pass-5 MED: BIND slug to prompt basename. Prevent
  # cross-workstream confusion: caller passes `slug=A` with `prompt_B.md`
  # → phase decisions for A would be driven by B's DO-FIRST. Require
  # basename match `prompt_<slug>.md` exactly.
  if [ "${WORKSTREAM_TEST_MODE:-0}" = "1" ] && \
     [ "${WORKSTREAM_VALIDATE_PROMPT_PATH:-1}" = "0" ]; then
    :  # test-mode bypass also skips slug-binding (legacy fixtures)
  else
    local _base="${prompt##*/}"
    case "$_base" in
      "prompt_${slug}.md")
        ;;
      *)
        echo "workstream: check_prompt_phase_skip: prompt basename ('$_base') does not match expected 'prompt_${slug}.md' for slug '$slug'" >&2
        return 2
        ;;
    esac
  fi
  # Codex adversarial pass-1 HIGH: enforce prompt-path confinement BEFORE any
  # read happens. Defense-in-depth — slash-command callers also vet, but the
  # lib must not trust them.
  #
  # Codex adversarial pass-3 HIGH-1: production-safe bypass policy. The
  # WORKSTREAM_VALIDATE_PROMPT_PATH=0 flag is honored ONLY when
  # WORKSTREAM_TEST_MODE=1 is also set. In production (no test-mode flag),
  # confinement is ALWAYS on regardless of inherited env. This prevents an
  # adversarial or misconfigured shell from disabling the trust boundary.
  if ! _workstream_prompt_path_validation_enabled; then
    :  # explicit test-mode bypass; skip
  else
    if ! _workstream_validate_prompt_path "$prompt"; then
      return 2
    fi
  fi
  if [ ! -f "$prompt" ]; then
    echo "workstream: check_prompt_phase_skip: prompt file not readable: $prompt" >&2
    return 2
  fi
  # Codex adversarial pass-7 MED: TOCTOU defense. Pin the inode at this
  # moment; after the read inside _workstream_detect_prompt_phase, re-stat
  # and refuse if the (dev,inode) drifted. A concurrent actor swapping
  # prompt_<slug>.md between validate and read would change the identifier.
  local _inode_pre _inode_post
  _inode_pre="$(_workstream_inode_id "$prompt")"
  local phase
  phase="$(_workstream_detect_prompt_phase "$prompt")" || return 2
  if [ "${WORKSTREAM_TEST_MODE:-0}" = "1" ] && \
     [ "${WORKSTREAM_VALIDATE_PROMPT_PATH:-1}" = "0" ]; then
    :  # test-mode bypass also skips inode-pin recheck
  else
    _inode_post="$(_workstream_inode_id "$prompt")"
    # Codex adversarial pass-8 MED: FAIL-CLOSED on empty inode ID. A
    # concurrent unlink/recreate during sampling can force an empty pre/post
    # value; the previous `[ -n pre ] && [ -n post ] && drift` guard would
    # silently skip enforcement, leaving the TOCTOU window open. Treat
    # empty IDs as a hard error.
    if [ -z "$_inode_pre" ] || [ -z "$_inode_post" ]; then
      echo "workstream: check_prompt_phase_skip: inode sample empty (pre=[$_inode_pre] post=[$_inode_post]); refusing — possible TOCTOU race during stat" >&2
      return 2
    fi
    if [ "$_inode_pre" != "$_inode_post" ]; then
      echo "workstream: check_prompt_phase_skip: inode drift detected ($_inode_pre -> $_inode_post); refusing — possible TOCTOU race" >&2
      return 2
    fi
  fi
  case "$phase" in
    none|grill)
      # Nothing to flag. /grill-me is always permitted; absence of any
      # pipeline command is advisory-pass.
      return 0
      ;;
    prd)
      # Need phases.grill.started_at — i.e. workstream file exists +
      # validate_phase prd succeeds.
      if _workstream_validate_phase "$slug" prd >/dev/null 2>&1; then
        return 0
      fi
      printf '%s' '/grill-me'
      return 1
      ;;
    issues)
      # Need phases.prd.completed_at.
      if _workstream_validate_phase "$slug" issues >/dev/null 2>&1; then
        return 0
      fi
      # If the workstream file is missing entirely OR grill is not present,
      # the right correction is /grill-me. Otherwise (file + grill present
      # but prd missing), the right correction is /write-a-prd.
      if ! _workstream_validate_phase "$slug" prd >/dev/null 2>&1; then
        printf '%s' '/grill-me'
      else
        printf '%s' '/write-a-prd'
      fi
      return 1
      ;;
  esac
  # Unknown detect output — defensive return.
  return 2
}

# -----------------------------------------------------------------------------
# Public: _workstream_rewrite_prompt_do_first <prompt-file> <new-command> <reason>
# Rewrite the DO-FIRST section of a memory/prompt_{slug}.md so that any
# offending pipeline-command reference is replaced by `<new-command>` and an
# explanatory `> note: auto-corrected because <reason>` marker is appended on
# the line directly under the corrected command.
#
# Idempotence: if the prompt already contains a `> note: auto-corrected ...`
# marker AND no longer contains a phase-skipping reference, this function is a
# no-op (the marker is not duplicated).
#
# Sanitization: <reason> is sanitized via `_workstream_sanitize log`
# (control-char strip, including ANSI ESC).
#
# Returns:
#   0  — rewrite succeeded (or was a no-op)
#   1  — file missing / unwritable / mktemp failed
#   2  — usage error
#
# Implementation: awk over the file. Two-pass sentinel to keep state simple:
#   pass 1 (in-section): replace the FIRST line containing /grill-me,
#                        /write-a-prd, or /prd-to-issues with the same line
#                        but with the matched command swapped for new_command;
#                        immediately emit the note marker
#   - subsequent occurrences of pipeline commands inside the section are
#     ALSO swapped (so a "1. /write-a-prd 2. /prd-to-issues" prompt collapses
#     correctly to a single recommended action). The note marker is emitted
#     once after the first replacement.
# -----------------------------------------------------------------------------
_workstream_rewrite_prompt_do_first() {
  local file="${1:-}" newcmd="${2:-}" reason="${3:-}"
  if [ -z "$file" ] || [ -z "$newcmd" ]; then
    echo "workstream: usage: _workstream_rewrite_prompt_do_first <prompt-file> <new-command> [<reason>]" >&2
    return 2
  fi
  # Codex adversarial pass-1 HIGH: prompt-path confinement BEFORE write.
  # Codex pass-3 HIGH-1: bypass requires test-mode + bypass flag both set.
  if ! _workstream_prompt_path_validation_enabled; then
    :  # explicit test-mode bypass
  else
    if ! _workstream_validate_prompt_path "$file"; then
      return 1
    fi
  fi
  if [ ! -f "$file" ]; then
    echo "workstream: rewrite_prompt_do_first: file not found: $file" >&2
    return 1
  fi
  # Codex adversarial pass-7 MED: TOCTOU defense. Pin (dev,inode) at
  # validation time. The full read-modify-write cycle re-stats before mv;
  # any drift means a concurrent actor swapped the file between validate
  # and use. Refuse with a clear diagnostic — a path-swap race must NOT
  # silently mutate the wrong inode.
  local _inode_validated
  _inode_validated="$(_workstream_inode_id "$file")"
  # R4 sanitize the reason (control-char strip).
  reason="$(_workstream_sanitize log "$reason")"
  # Sanitize newcmd similarly — defends against operator-piped recommendations
  # that include ANSI codes from a `tput`-aware caller.
  newcmd="$(_workstream_sanitize log "$newcmd")"
  local tmp
  tmp="$(mktemp -t cpt-workstream-prompt.XXXXXX)" || {
    echo "workstream: mktemp failed in rewrite_prompt_do_first" >&2
    return 1
  }
  # Pre-check idempotence — Codex pass-2 MED: scope the check to the DO-FIRST
  # section ONLY. Whole-file scan would yield false positives when a sibling
  # section (e.g. "## Other") legitimately mentions a pipeline command, which
  # would re-enter the rewrite loop and DROP the existing note marker without
  # re-emitting it (no swap happens in DO-FIRST → emit_note never fires).
  # Extract DO-FIRST scope first, then check both invariants against it.
  local dofirst_scope
  # Codex adversarial pass-1 MED: BOM-aware NR==1 strip (mirrors the
  # _workstream_detect_prompt_phase BOM handling).
  dofirst_scope="$(LC_ALL=C awk '
    BEGIN { found = 0 }
    NR == 1 { sub(/^\xef\xbb\xbf/, "") }
    /^##/ {
      lower = tolower($0)
      if (lower ~ /^##[[:space:]]+do[[:space:]-]?first/) { found = 1; next }
      if (found == 1) { exit }
    }
    found == 1 { print }
  ' "$file")"
  local has_target=0 has_note=0 has_other=0 has_newcmd=0
  if printf '%s\n' "$dofirst_scope" | LC_ALL=C grep -qE '/(grill-me|write-a-prd|prd-to-issues)([^a-z0-9-]|$)'; then
    has_target=1
  fi
  if printf '%s\n' "$dofirst_scope" | LC_ALL=C grep -qF 'note: auto-corrected'; then
    has_note=1
  fi
  # Codex adversarial pass-1 HIGH: tighten idempotence guard. The original
  # `has_target=0 && has_note=1` check fired only when DO-FIRST contained NO
  # pipeline-command token at all — but post-rewrite DO-FIRST contains the
  # newcmd token, so re-running this helper re-stripped the existing note
  # and re-emitted it (silent prompt churn). Tighten to: DO-FIRST contains
  # exactly the intended newcmd, the note marker is present, and NO OTHER
  # pipeline-command tokens exist. In that state, skip the rewrite entirely.
  # The newcmd argument is sanitized above (log-mode strip), so it is safe
  # to embed as a literal in grep -F.
  if printf '%s\n' "$dofirst_scope" | LC_ALL=C grep -qF -- "$newcmd"; then
    has_newcmd=1
  fi
  # has_other: a pipeline-command token OTHER than newcmd appears in DO-FIRST.
  # Cheap check: strip newcmd literally (no regex) and re-scan for any
  # remaining pipeline-command token.
  local without_newcmd
  without_newcmd="$(printf '%s\n' "$dofirst_scope" | LC_ALL=C awk -v NC="$newcmd" '{
    s = $0
    while ((p = index(s, NC)) > 0) {
      s = substr(s, 1, p - 1) substr(s, p + length(NC))
    }
    print s
  }')"
  if printf '%s\n' "$without_newcmd" | LC_ALL=C grep -qE '/(grill-me|write-a-prd|prd-to-issues)([^a-z0-9-]|$)'; then
    has_other=1
  fi
  # No-op cases:
  #  (1) Original guard: no pipeline-command target AND note already present
  #      → already clean, return.
  #  (2) Tightened guard: DO-FIRST already contains the intended newcmd, the
  #      note marker is present, no other pipeline tokens exist → already
  #      clean, return.
  if [ "$has_target" -eq 0 ] && [ "$has_note" -eq 1 ]; then
    rm -f "$tmp"
    return 0
  fi
  if [ "$has_newcmd" -eq 1 ] && [ "$has_note" -eq 1 ] && [ "$has_other" -eq 0 ]; then
    rm -f "$tmp"
    return 0
  fi
  # awk passes: NEW=new command, REASON=auto-corrected reason text.
  LC_ALL=C awk -v NEW="$newcmd" -v REASON="$reason" '
    BEGIN {
      in_dofirst = 0
      note_emitted = 0
    }
    function emit_note() {
      if (note_emitted == 0) {
        printf("> note: auto-corrected because %s\n", REASON)
        note_emitted = 1
      }
    }
    # Codex pass-1 LOW: tighten the rewrite so substrings like
    # `/write-a-prd-extra` are NOT mutated. Use match() in a loop so we can
    # check the trailing boundary character (must be EOL or NOT in [a-z0-9-]).
    # Returns the rewritten line; mutates `swapped` global side-effect var.
    function swap_cmd(line, cmd, repl,    out, idx, after, ch) {
      out = ""
      while ((idx = index(line, cmd)) > 0) {
        # Boundary check: char immediately after cmd must be NOT [a-z0-9-]
        # OR end-of-line.
        after = idx + length(cmd)
        if (after > length(line)) {
          # End of line — boundary OK.
          out = out substr(line, 1, idx - 1) repl
          line = ""
          swapped = 1
          break
        }
        ch = substr(line, after, 1)
        if (ch ~ /[a-z0-9-]/) {
          # Not a real boundary — skip past this occurrence without swap.
          out = out substr(line, 1, after - 1)
          line = substr(line, after)
        } else {
          out = out substr(line, 1, idx - 1) repl
          line = substr(line, after)
          swapped = 1
        }
      }
      return out line
    }
    {
      line = $0
      # Codex adversarial pass-1 MED: BOM-aware NR==1 strip so a BOM-prefixed
      # files first-line `## DO FIRST` header is recognized.
      if (NR == 1) { sub(/^\xef\xbb\xbf/, "", line) }
      lower = tolower(line)
      # Track DO-FIRST section scope.
      if (line ~ /^##/) {
        if (lower ~ /^##[[:space:]]+do[[:space:]-]?first/) {
          in_dofirst = 1
          print line; next
        } else if (in_dofirst == 1) {
          # Closing the DO-FIRST section.
          in_dofirst = 0
          print line; next
        }
      }
      if (in_dofirst == 1) {
        # If the line already IS a previously-emitted note marker, drop it
        # (idempotence — we will re-emit at most one fresh marker).
        if (line ~ /^>[[:space:]]+note:[[:space:]]+auto-corrected/) {
          next
        }
        # Boundary-aware swap of each pipeline command token.
        swapped = 0
        line = swap_cmd(line, "/grill-me",      NEW)
        line = swap_cmd(line, "/write-a-prd",   NEW)
        line = swap_cmd(line, "/prd-to-issues", NEW)
        if (swapped == 1) {
          print line
          emit_note()
          next
        }
      }
      print line
    }
  ' "$file" > "$tmp" || {
    rm -f "$tmp"
    echo "workstream: awk rewrite failed in rewrite_prompt_do_first" >&2
    return 1
  }
  # Codex adversarial pass-7 MED: TOCTOU defense. Re-stat before commit and
  # refuse if the inode drifted between validation and now. A concurrent
  # path-swap (e.g. unlink + relink to a different inode) would otherwise
  # cause `mv -f $tmp $file` to overwrite the WRONG inode.
  if [ "${WORKSTREAM_TEST_MODE:-0}" = "1" ] && \
     [ "${WORKSTREAM_VALIDATE_PROMPT_PATH:-1}" = "0" ]; then
    :  # test-mode bypass also skips inode-pin recheck
  else
    local _inode_now
    _inode_now="$(_workstream_inode_id "$file")"
    # Codex adversarial pass-8 MED: FAIL-CLOSED on empty inode ID (mirrors
    # the same fix in _workstream_check_prompt_phase_skip).
    if [ -z "$_inode_validated" ] || [ -z "$_inode_now" ]; then
      rm -f "$tmp"
      echo "workstream: rewrite_prompt_do_first: inode sample empty (validated=[$_inode_validated] now=[$_inode_now]); refusing — possible TOCTOU race during stat" >&2
      return 1
    fi
    if [ "$_inode_validated" != "$_inode_now" ]; then
      rm -f "$tmp"
      echo "workstream: rewrite_prompt_do_first: inode drift detected ($_inode_validated -> $_inode_now); refusing — possible TOCTOU race" >&2
      return 1
    fi
  fi
  # Atomic replace.
  if ! mv -f "$tmp" "$file"; then
    rm -f "$tmp"
    echo "workstream: failed to commit rewrite to $file" >&2
    return 1
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Internal: emit a sanitized one-line CI status. R4 rules collapsed into a
# single helper so every status sink in cmd_ci_validate is consistent.
# Strips ANSI CSI escapes (warn) THEN strips bare control chars (log) — the
# composition matches _workstream_log_override and prevents both leakage of
# raw ESC bytes AND embedded \n/\t corrupting output ordering.
# -----------------------------------------------------------------------------
_ci_status() {
  local check="$1" verdict="$2" detail="${3:-}"
  local clean_detail=""
  if [ -n "$detail" ]; then
    clean_detail="$(_workstream_sanitize warn "$detail")"
    clean_detail="$(_workstream_sanitize log "$clean_detail")"
  fi
  if [ -n "$clean_detail" ]; then
    printf '%s\t%s\t%s\n' "$check" "$verdict" "$clean_detail"
  else
    printf '%s\t%s\n' "$check" "$verdict"
  fi
}

# -----------------------------------------------------------------------------
# Internal: extract a slug candidate from PR title+body+headRefName.
#
# Strategy (highest precedence first):
#   1. Scan title+body for a `\.workstream/<slug>\.md` token where <slug>
#      passes R1 normalization (^[a-z0-9-]+$, length 1..64). First match wins.
#   2. Branch regex `^[0-9]+-(.+)$` on headRefName extracts a candidate, then:
#      (a) If `.workstream/<candidate>.md` exists and the candidate passes R1,
#          return it (exact match, current behavior).
#      (b) Otherwise scan `.workstream/*.md` for files whose slug is a prefix
#          of the candidate (excludes `.gitkeep` + `_overrides.log`). If
#          exactly one matches, return that slug. If zero or multiple match,
#          fall through to refuse and emit a `EXTRACT_SLUG_HINT: ...` line on
#          stderr so the caller can surface `no unique prefix match for
#          branch slug <candidate>` in its FAIL diagnostic.
#   3. Refuse: echo nothing, rc=1. Step-1 token-scan precedence is preserved.
#
# Inputs: title body headRefName (each pre-sanitized via R4 log mode by caller).
# Output (stdout): the slug, or empty on no-match.
# Output (stderr): `EXTRACT_SLUG_HINT: <message>\n` line when Step-2 prefix
#   scan was attempted but resolved to zero or multiple matches; nothing
#   otherwise. The caller captures stderr and greps for the prefix.
# Exit: 0 on found, 1 on no-match.
#
# Defensive: the regex match step uses `LC_ALL=C grep -oE` so locale changes
# cannot drift the character class. The R1 validate is then re-applied to the
# extracted token so `.workstream/../../etc/passwd.md`-shaped strings cannot
# slip through (the embedded `/` and `..` are excluded by R1's `[a-z0-9-]+`).
# Prefix candidates are themselves R1-validated before being accepted, so a
# malformed on-disk filename cannot poison the resolution.
# -----------------------------------------------------------------------------
_ci_extract_slug() {
  local title="$1" body="$2" head_ref="$3"
  local combined="${title}"$'\n'"${body}"
  # Step 1: scan combined text for `.workstream/<slug>.md` tokens. Use
  # `grep -oE` to enumerate every match; pick the first that passes R1.
  local match cand
  while IFS= read -r match; do
    [ -n "$match" ] || continue
    # match looks like `.workstream/<slug>.md`. Strip prefix/suffix.
    cand="${match#.workstream/}"
    cand="${cand%.md}"
    if _workstream_validate_slug "$cand" >/dev/null 2>&1; then
      printf '%s' "$cand"
      return 0
    fi
  done < <(printf '%s\n' "$combined" | LC_ALL=C grep -oE '\.workstream/[a-zA-Z0-9._-]+\.md' || true)
  # Step 2: branch regex fallback. Extract the post-number suffix without
  # pinning the charclass so we can prefix-tolerate suffixes that the on-disk
  # slug strips. The candidate itself is validated via R1; on R1 failure we
  # still try the prefix scan because the on-disk filename is the source of
  # truth, not the branch suffix.
  if [ -n "$head_ref" ]; then
    if [[ "$head_ref" =~ ^[0-9]+-(.+)$ ]]; then
      cand="${BASH_REMATCH[1]}"
      # 2a: exact-match path (current behavior).
      if _workstream_validate_slug "$cand" >/dev/null 2>&1 \
         && [ -f ".workstream/${cand}.md" ]; then
        printf '%s' "$cand"
        return 0
      fi
      # 2b: prefix-tolerant scan. Enumerate `.workstream/*.md` filenames,
      # collect slugs that are a strict prefix of `cand`. Skip the well-known
      # sidecar files. Each on-disk slug is R1-validated before being
      # considered, so malformed filenames are ignored.
      local f base slug_on_disk
      local matches=()
      for f in .workstream/*.md; do
        [ -e "$f" ] || continue
        base="${f##*/}"
        case "$base" in
          .gitkeep|_overrides.log) continue ;;
        esac
        slug_on_disk="${base%.md}"
        _workstream_validate_slug "$slug_on_disk" >/dev/null 2>&1 || continue
        # Strict prefix: the on-disk slug is a leading substring of the
        # candidate. Equality is impossible here because 2a would have hit.
        case "$cand" in
          "${slug_on_disk}"*) matches+=("$slug_on_disk") ;;
        esac
      done
      if [ "${#matches[@]}" -eq 1 ]; then
        printf '%s' "${matches[0]}"
        return 0
      fi
      # Zero or multiple matches: refuse + emit a HINT line on stderr the
      # caller can capture and surface in its FAIL diagnostic. The hint is
      # marked with a fixed prefix the caller greps for; this avoids the
      # subshell-globals problem (variables set inside `$(...)` do not
      # propagate to the parent shell).
      printf 'EXTRACT_SLUG_HINT: no unique prefix match for branch slug %s\n' "$cand" >&2
    fi
  fi
  return 1
}

# -----------------------------------------------------------------------------
# Internal: parse a PR JSON document and emit four lines on stdout in this
# exact order:
#   <title>
#   <body>
#   <headRefName>
#   <baseRefName>
# Each value is sanitized via R4 (warn THEN log composition — strips ANSI
# CSI residues + bare control chars including newlines, tabs, ESC bytes).
# Newlines inside body fields are stripped by the log mode tr, so the
# four-line emission is unambiguous.
#
# Implementation: python3 reads JSON from stdin and emits the four fields
# joined by US (\x1F) which the bash side then splits into a 4-element array.
# python3 ships on every CI runner targeted by this project (ubuntu-latest +
# macOS dev hosts). On `python3` absence (extremely unlikely in CI), the
# helper refuses with a clear diagnostic.
#
# Exit: 0 on success, 1 on JSON-parse failure or python3 absent.
# -----------------------------------------------------------------------------
_ci_parse_pr_json() {
  local json="$1"
  if ! command -v python3 >/dev/null 2>&1; then
    echo "ci-validate: python3 not found on PATH (required to parse PR JSON)" >&2
    return 1
  fi
  # Use python3 for robust JSON parsing. Pass JSON via stdin so shell-quoting
  # cannot corrupt the payload. The script extracts the four fields and emits
  # them US-separated. Empty fields are emitted as empty strings (not absent).
  local raw
  raw="$(printf '%s' "$json" | LC_ALL=C python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception as e:
    sys.stderr.write("ci-validate: PR JSON parse error: " + str(e) + "\n")
    sys.exit(1)
fields = ["title", "body", "headRefName", "baseRefName"]
out = []
for f in fields:
    v = d.get(f, "")
    if v is None:
        v = ""
    if not isinstance(v, str):
        v = str(v)
    out.append(v)
sys.stdout.write("\x1f".join(out))
' 2>&1)"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    # python3 emitted its own diagnostic on stderr; re-emit to caller stderr.
    printf '%s\n' "$raw" >&2
    return 1
  fi
  # Split US-separated payload into 4 fields, sanitize each.
  # Codex pass-1 (#71 / slice 6) MED: the previous `parts=( $raw )` triggers
  # bash pathname expansion (`*` `?` `[]`) on PR-text content against the
  # CWD, even with `IFS=$'\x1f'`. A PR title containing `*` would expand
  # against CWD files and corrupt the parsed title field. Disable glob
  # locally with `set -f` for the split; restore previous setting after.
  local _glob_was_off=0
  case "$-" in
    *f*) _glob_was_off=1 ;;
  esac
  set -f
  local IFS_save="$IFS"
  IFS=$'\x1f'
  local -a parts
  # shellcheck disable=SC2206
  parts=( $raw )
  IFS="$IFS_save"
  if [ "$_glob_was_off" -eq 0 ]; then
    set +f
  fi
  # Pad to 4 fields if python3 emitted fewer (e.g. trailing empty fields lost).
  while [ "${#parts[@]}" -lt 4 ]; do
    parts+=("")
  done
  # Sanitize each via warn THEN log.
  local i out
  for i in 0 1 2 3; do
    out="$(_workstream_sanitize warn "${parts[$i]}")"
    out="$(_workstream_sanitize log "$out")"
    printf '%s\n' "$out"
  done
  return 0
}

# -----------------------------------------------------------------------------
# Internal: parse a unified-diff text and verify that any change to the
# `.workstream/_overrides.log` file is APPEND-ONLY.
#
# Append-only contract:
#   - Empty diff -> OK
#   - File untouched in diff -> OK
#   - File CREATED (new file mode, --- /dev/null) -> OK (entire content is
#     "appended" from nothing)
#   - File MODIFIED -> OK iff every hunk has zero `-` lines AND no ` ` (context)
#     or `-` line appears AFTER a `+` line within any hunk (i.e. additions are
#     all at the tail of each hunk's range)
#   - File DELETED (deleted file mode) -> REJECT
#   - File RENAMED (rename to/rename from) -> REJECT
#   - BINARY diff (Binary files ... differ) -> REJECT (treat-as-opaque)
#   - File MODE changed only -> OK (no content change)
#
# Returns:
#   0  - append-only contract satisfied
#   1  - violation; reason echoed on stdout (sanitized)
# -----------------------------------------------------------------------------
_ci_check_override_append_only() {
  local diff_text="$1"
  if [ -z "$diff_text" ]; then
    return 0
  fi
  # Locate the diff block for `.workstream/_overrides.log`. The block starts
  # at `diff --git a/<path> b/<path>` and runs until the next `diff --git`
  # header or EOF. We use awk to extract the block, byte-stable LC_ALL=C.
  #
  # Codex pass-2 P2: EXACT-path match on the diff header. The previous
  # `index($0, ".workstream/_overrides.log") > 0` substring check admitted
  # sibling paths like `.workstream/_overrides.log.bak` AND any rename whose
  # `from` or `to` contained the substring (e.g. `.workstream/_overrides.log
  # .new`). Match against the canonical `diff --git a/<path> b/<path>`
  # header tokens for the exact path, with no trailing characters before the
  # space/EOL boundary. The `\b`-style boundary is encoded with `( |$)`
  # at the end since awk POSIX ERE doesn't have `\b`.
  local block
  block="$(printf '%s\n' "$diff_text" | LC_ALL=C awk '
    BEGIN { in_block = 0 }
    /^diff --git / {
      if (in_block) { exit }
      # Require BOTH a/<path> AND b/<path> tokens to match exactly. This
      # admits genuine renames (a/<oldpath> b/<newpath>) only when at least
      # one side is the exact override-log path; rename detection further
      # downstream rejects renames as a contract violation.
      if ($0 ~ /(^| )a\/\.workstream\/_overrides\.log( |$)/ || \
          $0 ~ /(^| )b\/\.workstream\/_overrides\.log( |$)/) {
        in_block = 1
        print
        next
      }
      in_block = 0
      next
    }
    in_block == 1 { print }
  ')"
  if [ -z "$block" ]; then
    # File untouched.
    return 0
  fi
  # Reject rename / delete / binary.
  if printf '%s\n' "$block" | LC_ALL=C grep -qE '^rename (from|to) '; then
    printf '%s' "rename of _overrides.log not allowed (append-only contract)"
    return 1
  fi
  if printf '%s\n' "$block" | LC_ALL=C grep -qE '^deleted file mode'; then
    printf '%s' "deletion of _overrides.log not allowed (append-only contract)"
    return 1
  fi
  if printf '%s\n' "$block" | LC_ALL=C grep -qE '^Binary files .* differ$'; then
    printf '%s' "binary diff for _overrides.log not allowed (treat-as-opaque, fail safe)"
    return 1
  fi
  # Walk the hunks. Algorithm:
  #   - Track per-hunk state. After first `+` line, any subsequent ` ` or
  #     `-` line is a violation (additions must be tail-only per hunk).
  #   - Any `-` line anywhere is a violation (no deletion / replacement).
  # Note: the `\ No newline at end of file` marker (starts with `\`) is
  # benign and does not affect the contract.
  local violation
  violation="$(printf '%s\n' "$block" | LC_ALL=C awk '
    BEGIN { in_hunk = 0; seen_plus = 0; rc = 0; reason = "" }
    /^@@/ {
      in_hunk = 1
      seen_plus = 0
      next
    }
    in_hunk == 0 { next }
    /^\\/ { next }              # `\ No newline at end of file` marker
    /^-/ {
      reason = "deletion-or-modification line in _overrides.log diff"
      rc = 1
      exit
    }
    /^\+/ {
      seen_plus = 1
      next
    }
    /^ / {
      if (seen_plus == 1) {
        reason = "addition is not tail-only (context line follows + line)"
        rc = 1
        exit
      }
      next
    }
    END {
      if (rc == 1) { print reason }
    }
  ')"
  if [ -n "$violation" ]; then
    printf '%s' "$violation"
    return 1
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Subcommand: ci-validate <pr#>
# Three checks against the referenced workstream:
#   1. PR-Workstream-Link  - PR title or body references a slug whose
#                            `.workstream/<slug>.md` file exists with conforming
#                            frontmatter.
#   2. Phase-1-Evidence    - that workstream's frontmatter has
#                            phases.grill.started_at set (loose Phase-1
#                            evidence per PRD #57).
#   3. Override-Audit-Sane - the PR's diff against base does not modify
#                            `.workstream/_overrides.log` outside the
#                            append-only contract (no edits, no deletions,
#                            no reorder, no rename, no binary).
#
# Bootstrap-empty exemption (R6): when `.workstream/` contains zero
# non-`.gitkeep` files (and no `_overrides.log`), the gate is N/A and the
# subcommand exits 0 with a `not-applicable` status emitted on stdout.
#
# Test seams (production CI ignores these):
#   WORKSTREAM_CI_TEST_PR_JSON  - if set, parsed instead of `gh pr view`.
#   WORKSTREAM_CI_TEST_DIFF     - if set, used instead of `gh pr diff`.
#
# Failures = non-zero exit, surfacing as a red-X CI check on the PR. Each
# check emits a tab-separated status line on stdout
# (`<Check>\t<verdict>[\t<sanitized-detail>]`) so log readers can parse the
# verdict without color or formatting.
# -----------------------------------------------------------------------------
cmd_ci_validate() {
  local pr="${1:-}"
  if [ -z "$pr" ]; then
    echo "ci-validate: usage: ci-validate <pr#>" >&2
    return 2
  fi
  # PR# must be all digits — defends against argv injection that smuggles
  # shell metachars into the gh exec.
  case "$pr" in
    ''|*[!0-9]*)
      echo "ci-validate: PR# must be a positive integer, got: $pr" >&2
      return 2
      ;;
  esac
  # R6 bootstrap-empty exemption check FIRST (no `.workstream/` files at all
  # means the gate is N/A even if the PR doesn't reference one).
  local ws_dir=".workstream"
  local count=0 entry
  if [ -d "$ws_dir" ]; then
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      case "$(basename "$entry")" in
        .gitkeep|_overrides.log) continue ;;
      esac
      count=$((count+1))
    done < <(find "$ws_dir" -mindepth 1 -maxdepth 1 -type f 2>/dev/null)
  fi
  if [ "$count" -eq 0 ]; then
    _ci_status 'gate' 'NA' 'bootstrap-empty exemption (R6): no workstream files'
    return 0
  fi
  # Test-seam guard. Codex pass-1 (#71 / slice 6) HIGH:
  # `WORKSTREAM_CI_TEST_PR_JSON` / `WORKSTREAM_CI_TEST_DIFF` were trusted
  # whenever set, so any accidental/malicious env injection in CI could
  # force PASS with attacker-chosen fixtures. Two-layer defense:
  #   1. Seams require `WORKSTREAM_TEST_MODE=1` to activate.
  #   2. When running on GitHub Actions (`GITHUB_ACTIONS=true`), seams
  #      are HARD-DISABLED regardless of `WORKSTREAM_TEST_MODE`. Tests
  #      run locally / in dev sandboxes; production CI must always go
  #      through real `gh` calls.
  # Codex pass-2 (#71 / slice 6) HIGH: `[ "$GITHUB_ACTIONS" != "true" ]` was
  # case/whitespace-brittle. `GITHUB_ACTIONS=TRUE`, `GITHUB_ACTIONS=1`, or
  # `GITHUB_ACTIONS="true "` (trailing space) all bypass the hard-disable.
  # Fail-closed: if GITHUB_ACTIONS is set to ANY non-empty value, seams are
  # hard-disabled. Local dev runs do not set GITHUB_ACTIONS at all, so they
  # are unaffected.
  local _seams_active=0
  if [ -z "${GITHUB_ACTIONS:-}" ] && [ "${WORKSTREAM_TEST_MODE:-}" = "1" ]; then
    _seams_active=1
  fi
  # 1. Fetch PR JSON. Test seam first (seams gate-checked above).
  local pr_json=""
  if [ "$_seams_active" -eq 1 ] && [ -n "${WORKSTREAM_CI_TEST_PR_JSON:-}" ]; then
    pr_json="$WORKSTREAM_CI_TEST_PR_JSON"
  else
    if ! command -v gh >/dev/null 2>&1; then
      echo "ci-validate: gh CLI not found on PATH (required to fetch PR metadata)" >&2
      return 2
    fi
    if ! pr_json="$(gh pr view "$pr" --json title,body,headRefName,baseRefName,number 2>&1)"; then
      echo "ci-validate: gh pr view failed: $pr_json" >&2
      return 2
    fi
  fi
  # 2. Parse PR JSON into 4 sanitized fields.
  local _parsed
  if ! _parsed="$(_ci_parse_pr_json "$pr_json")"; then
    return 2
  fi
  # Read 4 lines into vars. The fields are emitted one-per-line by
  # _ci_parse_pr_json AFTER R4 sanitize, so newlines have been stripped from
  # each field's value already (log mode tr -d '[:cntrl:]').
  local pr_title pr_body pr_head pr_base
  {
    IFS= read -r pr_title || true
    IFS= read -r pr_body || true
    IFS= read -r pr_head || true
    IFS= read -r pr_base || true
  } <<EOF
$_parsed
EOF
  # 3. CHECK #1 — PR-Workstream-Link.
  # Run `_ci_extract_slug` capturing stdout (the slug) and stderr (the
  # optional `EXTRACT_SLUG_HINT:` line emitted when Step-2 prefix scan
  # resolved to zero or multiple matches). The hint is appended to the FAIL
  # diagnostic so operators can see WHY the branch slug failed to resolve.
  local slug="" extract_stderr="" extract_rc=0 extract_hint=""
  local _slug_tmp; _slug_tmp="$(mktemp 2>/dev/null || echo "/tmp/ci-extract-slug.$$")"
  slug="$(_ci_extract_slug "$pr_title" "$pr_body" "$pr_head" 2>"$_slug_tmp")"
  extract_rc=$?
  extract_stderr="$(cat "$_slug_tmp" 2>/dev/null || true)"
  rm -f "$_slug_tmp"
  if [ "$extract_rc" -ne 0 ]; then
    # Parse the hint line out of stderr (fixed prefix; preserves whatever
    # message follows the colon-space marker).
    extract_hint="$(printf '%s\n' "$extract_stderr" | LC_ALL=C grep -m1 '^EXTRACT_SLUG_HINT: ' | sed 's/^EXTRACT_SLUG_HINT: //' || true)"
    local msg='no .workstream/<slug>.md reference in title/body and branch did not match ^[0-9]+-(slug)$'
    if [ -n "$extract_hint" ]; then
      msg="${msg}; ${extract_hint}"
    fi
    _ci_status 'PR-Workstream-Link' 'FAIL' "$msg"
    return 1
  fi
  local ws_file="${ws_dir}/${slug}.md"
  if [ ! -f "$ws_file" ]; then
    _ci_status 'PR-Workstream-Link' 'FAIL' "$(printf 'referenced workstream file does not exist: %s' "$ws_file")"
    return 1
  fi
  # Frontmatter must parse (R3 strict-leading).
  local fm
  fm="$(_workstream_extract_frontmatter "$ws_file")"
  if [ -z "$fm" ]; then
    _ci_status 'PR-Workstream-Link' 'FAIL' "$(printf 'workstream file is non-conformant (no leading --- frontmatter): %s' "$ws_file")"
    return 1
  fi
  _ci_status 'PR-Workstream-Link' 'PASS' "$(printf 'slug=%s file=%s' "$slug" "$ws_file")"
  # 4. CHECK #2 — Phase-1-Evidence (phases.grill.started_at set).
  if ! _workstream_validate_phase "$slug" prd >/dev/null 2>&1; then
    _ci_status 'Phase-1-Evidence' 'FAIL' "$(printf 'phases.grill.started_at not set in %s (run /grill-me to seed)' "$ws_file")"
    return 1
  fi
  _ci_status 'Phase-1-Evidence' 'PASS' "$(printf 'phases.grill.started_at present in %s' "$ws_file")"
  # 5. CHECK #3 — Override-Audit-Sane.
  local diff_text=""
  if [ "$_seams_active" -eq 1 ] && [ -n "${WORKSTREAM_CI_TEST_DIFF+x}" ]; then
    # Test seam (gated): explicit empty string IS distinct from unset
    # (caller wants to assert "no override-log changes in PR diff"). Use
    # ${VAR+x} idiom to detect "set" vs "unset". Gated on _seams_active per
    # the test-seam guard above.
    diff_text="$WORKSTREAM_CI_TEST_DIFF"
  else
    if ! command -v gh >/dev/null 2>&1; then
      echo "ci-validate: gh CLI not found on PATH (required to fetch PR diff)" >&2
      return 2
    fi
    # Codex pass-2 P1: FAIL-CLOSED on `gh pr diff` failure. The original
    # `|| true` swallowed auth/API/transient errors and treated the unfetched
    # diff as empty — which silently SKIPPED Override-Audit-Sane on every
    # broken-fetch scenario. A bad actor could engineer a transient failure
    # (or rely on intermittent gh outages) to slip in-place edits past the
    # gate. Capture stderr separately, fail with rc=2 on any non-zero exit.
    local _gh_diff_err
    _gh_diff_err="$(mktemp -t cpt-civ-diff-err.XXXXXX)"
    if ! diff_text="$(gh pr diff "$pr" --patch 2>"$_gh_diff_err")"; then
      local _err_msg
      _err_msg="$(cat "$_gh_diff_err" 2>/dev/null || true)"
      rm -f "$_gh_diff_err"
      _err_msg="$(_workstream_sanitize warn "$_err_msg")"
      _err_msg="$(_workstream_sanitize log "$_err_msg")"
      _ci_status 'Override-Audit-Sane' 'FAIL' "$(printf 'gh pr diff failed (fail-closed): %s' "$_err_msg")"
      return 2
    fi
    rm -f "$_gh_diff_err"
  fi
  local violation
  if violation="$(_ci_check_override_append_only "$diff_text")"; then
    _ci_status 'Override-Audit-Sane' 'PASS' 'append-only contract satisfied'
  else
    _ci_status 'Override-Audit-Sane' 'FAIL' "$violation"
    return 1
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Dispatch (script mode). When sourced (most cases), this block is skipped:
# `${BASH_SOURCE[0]}` differs from `$0` so we know we are sourced.
# -----------------------------------------------------------------------------
# Use a guard that works under bash 3.2: BASH_SOURCE may be unbound under
# very old shells, but every bash >= 3.0 supports it. We compare the script
# path basename to argv0 basename to detect script-mode robustly.
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  sub="${1:-}"
  shift || true
  case "$sub" in
    ci-validate)
      cmd_ci_validate "$@"
      exit $?
      ;;
    ""|-h|--help|help)
      cat <<USAGE
usage: workstream.sh <subcommand> [args]
  ci-validate <pr#>   Three-check CI gate: PR-Workstream-Link,
                      Phase-1-Evidence, Override-Audit-Sane.
                      Returns 0 on PASS / NA, non-zero on any FAIL.
                      Test seams: WORKSTREAM_CI_TEST_PR_JSON,
                      WORKSTREAM_CI_TEST_DIFF.
USAGE
      exit 0
      ;;
    *)
      echo "workstream.sh: unknown subcommand: $sub" >&2
      exit 2
      ;;
  esac
fi
