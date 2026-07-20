#!/usr/bin/env bash
# lib/substitute.sh — placeholder substitution kernel.
#
# Single source of truth for `{{KEY}}` -> value substitution across the kit.
# Same code path serves bootstrap, /audit-kit, /fill-config, and CI verify.
# Locked contract from docs/DECISIONS.md "Substitute subsystem (Issue #14)" Q3/Q4.
#
# Subcommands:
#   render <canonical> <config>
#       Read CANONICAL, replace every {{KEY}} via CONFIG (JSON object), emit
#       to stdout. Hard-fail (exit 1) if any {{KEY}} remains; warn to stderr
#       on extra config keys not present in canonical.
#
#   verify <canonical> <config> <existing>
#       Exit 0 iff EXISTING bytes equal render(canonical, config). Otherwise
#       exit 1 with a diff to stderr.
#
#   render-all <config>
#       Walk .claude/commands/, .claude/hooks/, .claude/settings.json. For
#       each real-file entry, render the canonical counterpart against
#       CONFIG and overwrite the .claude/ entry. Symlinks are skipped
#       (already correct by construction per Tier 0 invariant branch a).
#
#   verify-all <config>
#       Walk the same set. Each entry must satisfy:
#       (a) symlink whose resolved target equals canonical, OR
#       (b) real file whose bytes equal render(canonical, config), OR
#       (c) consumer-local command listed in .claude/.verify-allowlist with
#           NOTHING at its canonical path (issue #97; see
#           _subst_load_verify_allowlist). render-all skips such entries.
#           Broken symlinks and canonical type collisions (canonical exists
#           but is not a regular file) are never excused by the allowlist.
#       Exit 0 if all pass, 1 otherwise with per-failure diagnosis to stderr.
#
# Uses bash builtin ${var//pat/repl} (NOT sed) to avoid escape ceremony for
# `&`, `/`, `"`, multi-line. Uses python3 (project stack) for JSON, no jq dep.
#
# Compatible with bash 3.2 (macOS default) — no associative arrays. Config is
# kept as parallel arrays __SUBST_KEYS / __SUBST_VALS plus a null-keys list.
#
# Placeholder grammar: keys must match `[A-Z_][A-Z0-9_]*`. Config-load
# rejects non-conforming keys; the unfilled-detection regex is intentionally
# broader (`[A-Za-z_][A-Za-z0-9_]*`) so a canonical containing e.g.
# `{{lower}}` cannot ship as a literal — the contract is "no `{{KEY}}`
# pattern survives a successful render", regardless of casing.

set -u

# Bash 5.2+ enables `patsub_replacement` by default, which makes an unquoted
# `&` in the replacement string of `${var//pat/repl}` substitute the matched
# pattern. Config values legitimately contain `&` (e.g. shell `&&` chains in
# QUALITY_GATE_FAST_STEPS), so this would corrupt rendered output:
# `a && b` → `a {{KEY}}{{KEY}} b`, leaving `{{KEY}}` tokens unfilled. Disable
# the option unconditionally — it is a no-op on bash <5.2 (option does not
# exist there). The `2>/dev/null || true` guards the option-absent error on
# older bash. MUST come before any `${var//pat/repl}` execution in this
# file. Discovered via Ubuntu CI fail on PR #40 (Issue #22) where bash 5.x
# silently corrupted `&&` in config values; macOS bash 3.2 was unaffected.
shopt -u patsub_replacement 2>/dev/null || true

# Globals (parallel arrays — bash 3.2 compatible).
__SUBST_KEYS=()
__SUBST_VALS=()
__SUBST_NULL_KEYS=""
# Issue #97: newline-separated consumer-local-command allowlist, loaded from
# .claude/.verify-allowlist by `_subst_load_verify_allowlist`.
__SUBST_VERIFY_ALLOWLIST=""
# `_subst_normalize_value` writes the normalized result here so the helper
# can be called directly (no command-substitution subshell — see #76).
__SUBST_NORM_OUT=""

# -----------------------------------------------------------------------------
# Internal: normalize a single config value (#76 / locked decision #5).
#
# Call site: invoked once per K-record at `_subst_load_config` parse time,
# BEFORE the value is appended to `__SUBST_VALS`. Pairs the four equivalent
# unfilled shapes — `"key": ""`, `"key": null`, `"key": "   "` (whitespace-
# only), missing key entirely — onto a single classification (null/unfilled).
#
# Args:
#   $1 — KEY  (the placeholder name; needed for the side-effect path)
#   $2 — RAW  (the string value as extracted from the JSON parse)
#
# Behavior:
#   - Trim leading + trailing ASCII whitespace (spaces, tabs only). Do NOT
#     touch interior whitespace; legitimate multi-line / multi-word values
#     must pass through unchanged. Newlines / CR are NOT trimmed (an operator
#     who wrote `"VAL": "\nhello\n"` meant the leading + trailing newline).
#   - If the post-trim value is empty: append KEY to `__SUBST_NULL_KEYS`
#     (newline-separated, matching the format used by the python parser for
#     genuine JSON `null`s); set `__SUBST_NORM_OUT=""`; return 1 so the caller
#     knows to SKIP the `__SUBST_KEYS`/`__SUBST_VALS` append for this record.
#   - Else write the trimmed value to global `__SUBST_NORM_OUT`; return 0.
#     Caller appends key + `__SUBST_NORM_OUT` to the parallel arrays.
#
# CALLING CONVENTION (load-bearing — do NOT change):
#   - Call DIRECTLY, never inside a command substitution `$(...)` subshell.
#     The helper mutates two globals (`__SUBST_NULL_KEYS` and
#     `__SUBST_NORM_OUT`); a subshell would discard those mutations and
#     silently corrupt the parse.
#   - Use the `if _subst_normalize_value KEY VAL; then ...` pattern: rc=0
#     means "keep, read `__SUBST_NORM_OUT`"; rc=1 means "promoted to null,
#     skip the keys/vals append".
#
# Why this exists: prior behavior diverged across the four shapes — `""` and
# `"   "` substituted as literal empty/whitespace into output, while `null`
# and missing-key hard-failed render with the "unfilled placeholder"
# diagnostic. Per locked decision #5, normalize at parse time so the
# downstream detector (`_subst_render_to_stdout` § "remaining tokens") sees
# ONE classification, not four. JSON-only (`.claude/.config` parses via
# `json.load`); no YAML edge cases to consider.
#
# Bash 3.2 portability: `case` patterns for the trim loop (no extglob, no
# bash 4 `${var##... }`-with-extglob features); the `__SUBST_NULL_KEYS`
# newline-string idiom mirrors the python parser's null emission.
# -----------------------------------------------------------------------------
_subst_normalize_value() {
  local key="$1" val="$2"
  # Trim leading ASCII space/tab.
  while :; do
    case "$val" in
      ' '*|$'\t'*) val="${val#?}" ;;
      *) break ;;
    esac
  done
  # Trim trailing ASCII space/tab.
  while :; do
    case "$val" in
      *' '|*$'\t') val="${val%?}" ;;
      *) break ;;
    esac
  done
  if [ -z "$val" ]; then
    # Promote to null: record the key in the null list, return non-zero so
    # the caller knows to skip the __SUBST_KEYS/__SUBST_VALS append. The
    # newline-suffix idiom matches the python parser's emit for genuine
    # JSON `null` values (see `_subst_load_config` -> "N\t<key>" branch).
    #
    # CRITICAL: side-effect mutates a global, so the function MUST be called
    # directly (not in a command substitution `$(...)` subshell which would
    # capture stdout but discard the global mutation). Caller reads the
    # normalized value out of `__SUBST_NORM_OUT` instead.
    __SUBST_NULL_KEYS="${__SUBST_NULL_KEYS}${key}"$'\n'
    __SUBST_NORM_OUT=""
    return 1
  fi
  __SUBST_NORM_OUT="$val"
  return 0
}

# -----------------------------------------------------------------------------
# Internal: parse JSON config into the parallel arrays. Hard-fails (exit 1)
# if config is not a JSON object or python3 cannot parse it.
# -----------------------------------------------------------------------------
_subst_load_config() {
  local config_path="$1"
  if [ ! -f "$config_path" ]; then
    echo "substitute: config not found: $config_path" >&2
    exit 1
  fi
  command -v python3 >/dev/null 2>&1 || {
    echo "substitute: python3 required but not installed" >&2
    exit 1
  }
  # Stage python output in a temp file so we can deterministically check the
  # python exit status before consuming it. Process substitution + `read` does
  # NOT propagate the producer's exit status reliably (bash gives no portable
  # way to wait on the producer of `< <(...)`), so a parser/type error in
  # python would otherwise be silently masked and leave us with empty config.
  # Record formats (NUL-separated, NUL-terminated):
  #   K\t<key>\t<value>           — string value (may be empty or multi-line)
  #   N\t<key>                    — null value (unfilled)
  # Placeholder grammar: keys must match [A-Z_][A-Z0-9_]* (uppercase alphanum
  # + underscore, leading non-digit). This MUST stay in lockstep with the
  # unfilled-detection regex in _subst_render_to_stdout.
  __SUBST_KEYS=()
  __SUBST_VALS=()
  __SUBST_NULL_KEYS=""

  local stage py_rc prev_errexit
  stage="$(mktemp -t substitute-cfg.XXXXXX)" || {
    echo "substitute: mktemp failed" >&2
    exit 1
  }
  # Capture the caller's errexit state and disable it for the python call so
  # we can inspect py_rc deterministically. Restore exactly what was there.
  case "$-" in
    *e*) prev_errexit=1 ;;
    *)   prev_errexit=0 ;;
  esac
  set +e
  python3 - "$config_path" >"$stage" <<'PY'
import json, re, sys
path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception as e:
    sys.stderr.write("substitute: config is not valid JSON: %s (%s)\n" % (path, e))
    sys.exit(2)
if not isinstance(data, dict):
    sys.stderr.write("substitute: config must be a JSON object: %s\n" % path)
    sys.exit(2)
key_re = re.compile(r"^[A-Z_][A-Z0-9_]*$")
recs = []
for k, v in data.items():
    if not isinstance(k, str) or not key_re.match(k):
        sys.stderr.write(
            "substitute: invalid config key %r in %s: keys must match [A-Z_][A-Z0-9_]*\n"
            % (k, path)
        )
        sys.exit(2)
    if v is None:
        recs.append("N\t%s" % k)
    elif isinstance(v, str):
        if "\x00" in v:
            sys.stderr.write(
                "substitute: NUL byte in value for key %s in %s (not supported)\n"
                % (k, path)
            )
            sys.exit(2)
        # Issue #26 hardening: reject SOH (\x01). Used internally as the
        # escape-sentinel border byte in `\{{KEY}}` rewriting. A value
        # containing `\x01ESC{X}\x01` would substitute into a slot, slip
        # past the unfilled-detector (no `{{` shape pre-restore), then be
        # rewritten into literal `{{X}}` by the bash sentinel-restore pass —
        # bypassing the "no `{{KEY}}` survives" invariant. Pairs with the
        # canonical-side rejection in _subst_preprocess.
        if "\x01" in v:
            sys.stderr.write(
                "substitute: SOH (\\x01) byte in value for key %s in %s "
                "(reserved for internal escape sentinel)\n"
                % (k, path)
            )
            sys.exit(2)
        recs.append("K\t%s\t%s" % (k, v))
    else:
        # Coerce non-string scalars (numbers, booleans) to JSON-encoded form.
        recs.append("K\t%s\t%s" % (k, json.dumps(v)))
# Append trailing NUL so the final record is fully terminated.
sys.stdout.write("\0".join(recs))
if recs:
    sys.stdout.write("\0")
PY
  py_rc=$?
  if [ "$prev_errexit" = "1" ]; then
    set -e
  fi
  if [ "$py_rc" -ne 0 ]; then
    rm -f "$stage"
    # Diagnostic already emitted to stderr by the python script; surface the
    # deterministic non-zero exit here so callers cannot proceed silently.
    exit 1
  fi

  local rec tag rest key val
  while IFS= read -r -d '' rec; do
    [ -n "$rec" ] || continue
    tag="${rec%%$'\t'*}"
    case "$tag" in
      K)
        rest="${rec#K$'\t'}"
        key="${rest%%$'\t'*}"
        val="${rest#*$'\t'}"
        # #76 / locked decision #5: normalize-once at parse time. Called
        # DIRECTLY (no command substitution) because the helper mutates
        # `__SUBST_NULL_KEYS` as a side effect on the empty-post-trim branch
        # and writes the trimmed value into `__SUBST_NORM_OUT`. rc=0 ⇒ keep
        # the slot; rc=1 ⇒ the helper already pushed the key into the null
        # list and we skip the keys/vals append so downstream detection
        # treats this slot identically to a genuine JSON `null` or
        # missing-key.
        if _subst_normalize_value "$key" "$val"; then
          __SUBST_KEYS+=("$key")
          __SUBST_VALS+=("$__SUBST_NORM_OUT")
        fi
        ;;
      N)
        key="${rec#N$'\t'}"
        __SUBST_NULL_KEYS="${__SUBST_NULL_KEYS}${key}"$'\n'
        ;;
    esac
  done < "$stage"
  rm -f "$stage"
}

# -----------------------------------------------------------------------------
# Internal: render canonical content to stdout. Returns:
#   0 — all placeholders filled, output emitted on stdout
#   1 — at least one {{KEY}} unfilled or referenced a null config value;
#       diagnostic on stderr; partial output is NOT emitted.
# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
# Internal: preprocess canonical content via python3.
#   Issue #35 — strip `# CANONICAL-ONLY-START` / `# CANONICAL-ONLY-END` blocks
#               (markers + body removed). Markers must be on their own line;
#               leading whitespace tolerated. Unbalanced markers (START
#               without END or vice versa) → hard fail (exit 2 in python).
#               Nested markers NOT supported; first END terminates.
#   Issue #26 — replace `\{{KEY}}` with sentinel `\x01ESC{KEY}\x01` so the
#               substitution pass + unfilled-detector both skip it. Backslash
#               is consumed in output. Single-pass: `\\{{KEY}}` becomes
#               literal-`\` + escaped-`{{KEY}}` → output `\{{KEY}}`. Sentinel
#               is restored to literal `{{KEY}}` AFTER unfilled-detection,
#               just before emission.
# Stages stdout to OUT_PATH; returns python rc (0=ok, 2=unbalanced markers).
# -----------------------------------------------------------------------------
_subst_preprocess() {
  local canonical="$1" out_path="$2" prev_errexit py_rc
  case "$-" in *e*) prev_errexit=1 ;; *) prev_errexit=0 ;; esac
  set +e
  python3 - "$canonical" >"$out_path" <<'PY'
import re, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    raw = f.read()
# Issue #26 hardening: SOH (\x01) is the escape-sentinel border byte. A
# `\x01ESC{X}\x01` string sitting inside canonical text would be passed
# through preprocess unchanged (the regex below only rewrites `\{{KEY}}`),
# survive substitution + unfilled-detection (no `{{` shape), then be
# transformed into literal `{{X}}` by the bash sentinel-restore pass —
# violating the "no `{{KEY}}` survives a successful render" invariant.
# Hard-fail before any further processing. Pairs with the config-side
# \x01 rejection in _subst_load_config (closes the same bypass via config
# values). Defense-in-depth: both bytes-into-substitution channels vetted.
if "\x01" in raw:
    sys.stderr.write(
        "substitute: SOH (\\x01) byte in canonical %s "
        "(reserved for internal escape sentinel)\n" % path
    )
    sys.exit(2)
# Issue #35: strip CANONICAL-ONLY blocks. Line-leading marker, optional
# leading whitespace, must be on its own line. Track balance — first END
# closes; subsequent START before next END is allowed; any unbalanced state
# at EOF is a hard fail.
START = re.compile(r'^[ \t]*#[ \t]*CANONICAL-ONLY-START[ \t]*$')
END   = re.compile(r'^[ \t]*#[ \t]*CANONICAL-ONLY-END[ \t]*$')
out_lines = []
in_block = False
start_lineno = 0
for i, line in enumerate(raw.splitlines(keepends=True), start=1):
    body = line.rstrip('\n').rstrip('\r')
    if not in_block and START.match(body):
        in_block = True
        start_lineno = i
        continue
    if not in_block and END.match(body):
        sys.stderr.write(
            "substitute: unbalanced CANONICAL-ONLY-END (no matching START) at %s:%d\n"
            % (path, i)
        )
        sys.exit(2)
    if in_block and END.match(body):
        in_block = False
        continue
    if in_block:
        continue  # block body — skip
    out_lines.append(line)
if in_block:
    sys.stderr.write(
        "substitute: unbalanced CANONICAL-ONLY-START (no matching END) at %s:%d\n"
        % (path, start_lineno)
    )
    sys.exit(2)
text = ''.join(out_lines)
# Issue #26: replace `\{{KEY}}` with sentinel form so the substitution pass
# and unfilled-detector both skip it. Sentinel uses control byte \x01 which
# is not a valid character in placeholder grammar (safe vs detection regex)
# nor a normal token in shell/markdown canonicals. Restored post-detection
# by the bash caller via a final sed-like pass.
text = re.sub(r'\\\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}', '\x01ESC{\\1}\x01', text)
sys.stdout.write(text)
PY
  py_rc=$?
  if [ "$prev_errexit" = "1" ]; then set -e; fi
  return "$py_rc"
}

_subst_render_to_stdout() {
  local canonical="$1"
  local content key val i n
  if [ ! -f "$canonical" ]; then
    echo "substitute: canonical not found: $canonical" >&2
    return 1
  fi
  # Preprocess: strip CANONICAL-ONLY blocks (#35) and rewrite `\{{KEY}}`
  # escapes (#26) to a sentinel form. Hard-fail on unbalanced markers — the
  # python helper already emitted a diagnostic.
  local pre_path
  pre_path="$(mktemp -t substitute-pre.XXXXXX)" || {
    echo "substitute: mktemp failed" >&2
    return 1
  }
  if ! _subst_preprocess "$canonical" "$pre_path"; then
    rm -f "$pre_path"
    return 1
  fi
  # Slurp preprocessed content. Trailing-newline-preserving idiom.
  content="$(cat "$pre_path"; printf x)"
  content="${content%x}"
  rm -f "$pre_path"

  # Substitute every config key. Bash ${var//pat/repl} replaces ALL matches.
  n=${#__SUBST_KEYS[@]}
  i=0
  while [ "$i" -lt "$n" ]; do
    key="${__SUBST_KEYS[$i]}"
    val="${__SUBST_VALS[$i]}"
    content="${content//\{\{$key\}\}/$val}"
    i=$((i+1))
  done

  # Hard-fail on remaining {{KEY}} tokens. Three failure modes:
  #   1. Token references a null-valued config key (operator left it unfilled).
  #   2. Token has no entry in config at all (canonical-driven missing key).
  #   3. Token uses a key shape outside the canonical grammar (e.g. lowercase,
  #      hyphen, period). Config-key validation rejects these on the input
  #      side; this detector covers the canonical side so a lowercase
  #      {{lower}} cannot ship as a literal. Detection is intentionally
  #      broader than the canonical grammar to catch any plausibly
  #      placeholder-shaped token.
  # All surface the offending KEY and the canonical filename.
  local remaining
  remaining="$(printf '%s' "$content" | grep -oE '\{\{[A-Za-z_][A-Za-z0-9_]*\}\}' | sort -u || true)"
  if [ -n "$remaining" ]; then
    local tok name reason canonical_base
    canonical_base="$(basename "$canonical")"
    while IFS= read -r tok; do
      [ -n "$tok" ] || continue
      name="${tok#\{\{}"
      name="${name%\}\}}"
      if printf '%s' "$__SUBST_NULL_KEYS" | grep -qxF "$name"; then
        reason="null in config"
      else
        reason="not in config"
      fi
      echo "substitute: unfilled placeholder {{$name}} in $canonical_base ($reason; canonical=$canonical)" >&2
    done <<<"$remaining"
    return 1
  fi

  # Issue #26: restore escape sentinels to literal `{{KEY}}`. AFTER the
  # unfilled-detector so the literal cannot be re-detected as unfilled.
  # Bash builtin substitution; sentinel uses \x01 control-byte borders.
  # Two-step: \x01ESC{KEY}\x01 → {{KEY}}. Replace open then close so we don't
  # accidentally collide with config values. Replacements use variables to
  # avoid bash literal-`{{`/`}}` parsing ambiguities (especially `}}}` which
  # bash parses as `}}` + `}`).
  local sentinel_open sentinel_close repl_open repl_close
  sentinel_open=$'\x01ESC{'
  sentinel_close=$'}\x01'
  repl_open='{{'
  repl_close='}}'
  content="${content//$sentinel_open/$repl_open}"
  content="${content//$sentinel_close/$repl_close}"

  # Warn on extra config keys not referenced in canonical (forward-compat).
  # Compare against PREPROCESSED raw (CANONICAL-ONLY blocks stripped, escapes
  # rewritten to sentinel) so doc-only references inside a stripped block do
  # NOT suppress the warning, and `\{{KEY}}` literals are not counted as
  # references either. Cheap to recompute by re-running the preprocessor.
  local pre_raw_path raw
  pre_raw_path="$(mktemp -t substitute-pre-raw.XXXXXX)" || {
    echo "substitute: mktemp failed" >&2
    return 1
  }
  if _subst_preprocess "$canonical" "$pre_raw_path"; then
    raw="$(cat "$pre_raw_path")"
    i=0
    while [ "$i" -lt "$n" ]; do
      key="${__SUBST_KEYS[$i]}"
      if ! grep -qF "{{$key}}" <<<"$raw"; then
        echo "substitute: warning: config key '$key' not referenced in $(basename "$canonical")" >&2
      fi
      i=$((i+1))
    done
  fi
  rm -f "$pre_raw_path"

  printf '%s' "$content"
  return 0
}

# -----------------------------------------------------------------------------
# Internal: render canonical to OUT_PATH (a writable file path). Returns the
# real exit status of _subst_render_to_stdout (NOT masked by trailing
# `printf x` tricks — that idiom would have $? track printf, not render).
# Trailing-newline preservation: piping straight into a file is byte-faithful.
# Caller is responsible for cleaning up OUT_PATH on failure.
#
# Implementation note: this helper does NOT touch errexit. The script as a
# whole runs without `set -e`, so the redirected call below cannot trigger
# silent caller exit. Callers that want to ignore non-zero rc should test
# the return value explicitly.
# -----------------------------------------------------------------------------
_subst_render_to_file() {
  local canonical="$1" out_path="$2"
  _subst_render_to_stdout "$canonical" >"$out_path"
}

# -----------------------------------------------------------------------------
# Subcommand: render <canonical> <config>
# -----------------------------------------------------------------------------
cmd_render() {
  local canonical="${1:-}" config="${2:-}"
  if [ -z "$canonical" ] || [ -z "$config" ]; then
    echo "usage: substitute.sh render <canonical> <config>" >&2
    exit 2
  fi
  _subst_load_config "$config"
  if ! _subst_render_to_stdout "$canonical"; then
    exit 1
  fi
  exit 0
}

# -----------------------------------------------------------------------------
# Subcommand: verify <canonical> <config> <existing>
# -----------------------------------------------------------------------------
cmd_verify() {
  local canonical="${1:-}" config="${2:-}" existing="${3:-}"
  if [ -z "$canonical" ] || [ -z "$config" ] || [ -z "$existing" ]; then
    echo "usage: substitute.sh verify <canonical> <config> <existing>" >&2
    exit 2
  fi
  if [ ! -f "$existing" ]; then
    echo "substitute: existing file not found: $existing" >&2
    exit 1
  fi
  _subst_load_config "$config"
  # Render to a temp file so the rc check is reliable AND trailing-newline
  # preservation is byte-faithful (no command-substitution stripping). The
  # `if !` form below intentionally captures the helper's exit status without
  # using `$?` after-the-fact (which would have tracked the wrong command).
  local rendered_path
  rendered_path="$(mktemp -t substitute-rendered.XXXXXX)" || {
    echo "substitute: mktemp failed" >&2
    exit 1
  }
  if ! _subst_render_to_file "$canonical" "$rendered_path"; then
    rm -f "$rendered_path"
    # Diagnostic for the underlying render error was emitted to stderr by
    # _subst_render_to_stdout. Surface a clear umbrella message so operators
    # do not see a content-mismatch diff for a render failure.
    echo "substitute: verify failed — render(canonical) errored for $canonical" >&2
    exit 1
  fi
  if cmp -s "$rendered_path" "$existing"; then
    rm -f "$rendered_path"
    exit 0
  fi
  echo "substitute: verify mismatch: $existing differs from render($canonical)" >&2
  diff "$rendered_path" "$existing" >&2 || true
  rm -f "$rendered_path"
  exit 1
}

# -----------------------------------------------------------------------------
# Internal: enumerate (.claude_path, canonical_path) pairs to stdout, one per
# line, separated by a tab. Caller invokes from project root (CWD = repo root
# containing .claude/).
#
# Mapping rules (docs/DECISIONS.md Q4):
#   .claude/commands/<name>.md        -> commands/<name>.md
#   .claude/commands/<dir>/<name>     -> commands/<dir>/<name>   (supplements)
#   .claude/hooks/<name>              -> hooks/<name>
#   .claude/settings.json             -> templates/settings.json
# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
# Internal: read `.claude/.template-meta` (if present) and echo the captured
# `_template_dir=` absolute path. Emits empty string on any failure mode
# (file missing, key absent, value empty, file unreadable) — caller treats
# empty as "no fallback available" and preserves today's orphan behavior.
#
# Issue #30 / Option B (persistence variant). Bootstrap writes this file at
# install time so render-all / verify-all can resolve canonical paths on a
# consumer-side install where `commands/`, `hooks/`, `templates/settings.json`
# do not exist alongside `.claude/` (they live in the template-source tree
# only). On the self-host case (template-source == project root), the file
# still exists and the value resolves to the same root — in-tree lookup
# wins anyway because we try in-tree FIRST. See docs/DECISIONS.md
# "2026-05-01: Consumer-side canonical discovery (Issue #30)".
#
# Bash 3.2 compat: no `[[ -v ]]`, no associative arrays. `grep | head` is the
# tightest portable extractor for a single-line KEY= scalar.
#
# Issue #47 trust-boundary hardening (closes deferred Codex-HIGH from PR #46):
#   1. SUBSTITUTE_NO_META=1 → ignore the meta file entirely (in-tree-only
#      lookup). For hostile-multi-tenant or CI-integrity environments where
#      operator-mutable meta is unacceptable.
#   2. Allowlist-prefix check on the resolved `_template_dir`. Default prefixes:
#      $HOME/, /Users/, /opt/, /usr/local/. Override via env
#      SUBSTITUTE_TEMPLATE_DIR_ALLOWLIST (`:`-separated additional prefixes).
#      Refusing /tmp/, /var/, /dev/, /proc/, etc. as defaults blocks the
#      simplest meta-redirect attacks where an attacker drops a malicious
#      canonical tree in a world-writable scratch dir.
#   3. Path-traversal guard: `..` segments in the meta value are rejected
#      before the prefix check so an attacker cannot smuggle `/Users/../tmp/evil`
#      past a naive prefix-match.
# All rejections hard-fail (return 1) with a stderr diagnostic naming the
# offending path + the configured allowlist. Caller (`render-all` / `verify-all`)
# treats a non-zero return as a fatal error and propagates it as exit 1.
_subst_read_template_meta() {
  local meta_file=".claude/.template-meta"
  # Issue #47 AC#1: opt out of meta entirely. Honor the env var BEFORE any
  # file read so a hostile meta file (e.g. one containing SOH) cannot side-
  # effect-poison the load. Empty result = no fallback; resolver falls back
  # to in-tree-only behavior (pre-bundle-5).
  if [ "${SUBSTITUTE_NO_META:-0}" = "1" ]; then
    printf ''
    return 0
  fi
  [ -f "$meta_file" ] || { printf ''; return 0; }
  [ -r "$meta_file" ] || { printf ''; return 0; }
  local line val
  line="$(grep '^_template_dir=' "$meta_file" 2>/dev/null | head -n1 || true)"
  [ -n "$line" ] || { printf ''; return 0; }
  val="${line#_template_dir=}"
  # Codex review-2 LOW-1: trim leading + trailing ASCII whitespace (spaces,
  # tabs) BEFORE the empty-check so a value that is ONLY whitespace falls
  # through to the in-tree-only path rather than getting validated as a real
  # path (`realpath("   ")` resolves under cwd — surprising acceptance).
  # Bash 3.2-compatible trim via extglob-free `${var## }` patterns.
  while :; do
    case "$val" in
      ' '*|$'\t'*) val="${val#?}" ;;
      *) break ;;
    esac
  done
  while :; do
    case "$val" in
      *' '|*$'\t') val="${val%?}" ;;
      *) break ;;
    esac
  done
  # Empty value (`_template_dir=` with nothing after, or whitespace-only
  # post-trim) is treated as "no fallback" — bootstrap may have written a
  # placeholder line and not yet populated it. Distinct from a populated-
  # but-untrusted value (which the validator below rejects). Falling back
  # to in-tree-only here is safe because the resolver's existing
  # in-tree-first behavior is unchanged.
  [ -n "$val" ] || { printf ''; return 0; }
  # Issue #47 AC#2 + traversal guard: validate the value before returning it.
  # Failure here is a hard exit (rc=1) — the meta file exists and named a
  # path, but the path is untrusted. We refuse to silently fall through to
  # in-tree-only because that would mask a misconfiguration / attack.
  if ! _subst_validate_template_dir "$val" "$meta_file"; then
    return 1
  fi
  printf '%s' "$val"
}

# -----------------------------------------------------------------------------
# Internal: validate a `_template_dir` value (#47).
#
# Hard-fails (return 1, diagnostic on stderr) when:
#   - value contains a `..` segment (path-traversal escape)
#   - value does not begin with one of the configured allowed prefixes
#
# Allowlist:
#   - Defaults: $HOME/ (resolved), /Users/, /opt/, /usr/local/
#   - Override / extend: SUBSTITUTE_TEMPLATE_DIR_ALLOWLIST env var, `:`-sep
#     list of additional prefix strings; appended to the defaults.
#
# Bash 3.2 portability: no associative arrays, no process substitution
# beyond `<<<`, no `[[ ... =~ ]]` features that diverged with bash 4+.
# `case` patterns + explicit `..` substring scan handle every modern bash.
# -----------------------------------------------------------------------------
_subst_validate_template_dir() {
  local val="$1" source="$2"
  # Empty value: caller has already filtered this; defensive return.
  [ -n "$val" ] || return 1
  # Path-traversal guard. Reject any segment exactly equal to `..`. Surface
  # forms: `/foo/../bar`, `../bar`, `/bar/..`, the value itself == `..`.
  # Bash 3.2 case-glob handles all four with one expression.
  case "$val" in
    *"/../"*|"../"*|*"/.."|"..")
      echo "substitute: _template_dir contains path traversal segment ('..'): $val (from $source)" >&2
      return 1
      ;;
  esac
  # Codex MED-1 fix: canonicalize the value via python3 realpath BEFORE the
  # prefix check. A textual-only prefix match is bypassable via symlinks —
  # `/Users/alice/allowed-link` is a textually-allowed prefix but if it
  # symlinks to `/tmp/evil`, file reads follow the symlink. Comparing the
  # *resolved physical path* against the allowlist closes that bypass.
  #
  # Codex review-2 LOW-2: hard-fail if realpath fails. Earlier behavior fell
  # through to raw value, which would weaken symlink-bypass protection if
  # python3 misbehaves. python3 is required for the substitute kernel
  # (asserted at config-load time, line ~72) so a missing python3 would
  # already have aborted the run — but defensive hard-fail here avoids any
  # mid-flight degradation.
  local resolved
  resolved="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$val" 2>/dev/null || true)"
  if [ -z "$resolved" ]; then
    echo "substitute: _template_dir realpath resolution failed: $val (from $source)" >&2
    return 1
  fi
  # Re-run the traversal guard on the resolved path. realpath should
  # collapse `..` segments, but if realpath errored we used the raw value;
  # belt-and-suspenders.
  case "$resolved" in
    *"/../"*|"../"*|*"/.."|"..")
      echo "substitute: _template_dir contains path traversal segment ('..') after realpath: $resolved (raw=$val, from $source)" >&2
      return 1
      ;;
  esac
  # Build allowed-prefix list. Defaults first; env-supplied additions append.
  # Newline-separated to keep `case`-glob matching simple. Env value is
  # `:`-separated; prefixes containing literal `:` are out of contract.
  local allowed default_home
  default_home=""
  if [ -n "${HOME:-}" ]; then
    # Append trailing slash if absent so the prefix match is anchored.
    case "$HOME" in
      */) default_home="$HOME" ;;
      *)  default_home="$HOME/" ;;
    esac
  fi
  allowed=""
  [ -n "$default_home" ] && allowed="${allowed}${default_home}"$'\n'
  allowed="${allowed}/Users/"$'\n'
  allowed="${allowed}/opt/"$'\n'
  allowed="${allowed}/usr/local/"$'\n'
  # Env extension. Codex MED-2 fix: disable pathname expansion (`set -f`)
  # before the unquoted IFS split so wildcard chars in env values cannot
  # glob-expand against cwd files. Restore noglob state on exit. Bash 3.2
  # has no `mapfile`/`readarray`; the IFS-split idiom is the portable choice
  # but is glob-unsafe by default — `set -f` is the standard mitigation.
  if [ -n "${SUBSTITUTE_TEMPLATE_DIR_ALLOWLIST:-}" ]; then
    local oldifs="$IFS" had_noglob=0
    case "$-" in
      *f*) had_noglob=1 ;;
    esac
    set -f
    IFS=':'
    local -a extras=()
    # shellcheck disable=SC2206
    extras=( ${SUBSTITUTE_TEMPLATE_DIR_ALLOWLIST} )
    IFS="$oldifs"
    [ "$had_noglob" = "1" ] || set +f
    local extra
    for extra in "${extras[@]}"; do
      [ -n "$extra" ] || continue
      allowed="${allowed}${extra}"$'\n'
    done
  fi
  # Match: scan the prefix list, succeed on first match. Compare BOTH the
  # raw value AND the realpath-resolved value — either matching is a pass
  # (raw match preserves operator-friendly diagnostic for legitimately
  # symlinked installs whose target ALSO lives under an allowed prefix;
  # resolved match is the security-load-bearing check).
  local prefix
  while IFS= read -r prefix; do
    [ -n "$prefix" ] || continue
    case "$resolved" in
      "$prefix"*)
        return 0
        ;;
    esac
  done <<<"$allowed"
  # No prefix matched. Build a compact, human-readable allowlist for the
  # diagnostic — replace newlines with `, ` for one-line emission and strip
  # any trailing separator.
  local list
  list="$(printf '%s' "$allowed" | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
  if [ "$resolved" != "$val" ]; then
    echo "substitute: _template_dir prefix not in allowlist: $val (resolves to $resolved; from $source; allowed prefixes: $list; extend via SUBSTITUTE_TEMPLATE_DIR_ALLOWLIST)" >&2
  else
    echo "substitute: _template_dir prefix not in allowlist: $val (from $source; allowed prefixes: $list; extend via SUBSTITUTE_TEMPLATE_DIR_ALLOWLIST)" >&2
  fi
  return 1
}

# -----------------------------------------------------------------------------
# Internal: resolve a canonical path. If CANONICAL_REL exists in-tree, echo
# CANONICAL_REL (the in-tree path always wins; preserves self-host behavior).
# Else, if META_DIR is non-empty AND ${META_DIR}/CANONICAL_REL exists, echo
# the meta-dir-prefixed path. Else echo empty string (caller treats empty
# as orphan and preserves the existing diagnostic).
#
# TEST_FLAG ("-f" or "-e") selects the existence predicate:
#   - render/verify real-file branch: -f (must be a regular file we can read).
#   - verify symlink branch: -e (canonical may be a directory, e.g.
#     supplements/ subtrees pointed at by `.claude/commands/*-supplements`).
#
# Args: CANONICAL_REL META_DIR [TEST_FLAG=-f]
_subst_resolve_canonical() {
  local canonical_rel="$1" meta_dir="$2" test_flag="${3:--f}"
  if test "$test_flag" "$canonical_rel"; then
    printf '%s' "$canonical_rel"
    return 0
  fi
  if [ -n "$meta_dir" ] && test "$test_flag" "${meta_dir}/${canonical_rel}"; then
    printf '%s' "${meta_dir}/${canonical_rel}"
    return 0
  fi
  printf ''
  return 0
}

# -----------------------------------------------------------------------------
# Internal: load the consumer-local-command allowlist (Issue #97).
#
# Consumer repos may carry local commands under .claude/commands/ that have no
# canonical counterpart (e.g. AHA's 5 npm commands). Without an allowlist the
# Tier 0 gate has no vocabulary for them: verify-all / render-all fail them as
# orphans. `.claude/.verify-allowlist` (read relative to CWD, like
# `.claude/.template-meta`) declares such entries explicitly.
#
# File format (one entry per line):
#   - exact enumerated entry path, e.g. `.claude/commands/deploy.md`
#     (copy-pasteable from the orphan diagnostic)
#   - `#`-prefixed comment lines and blank lines ignored
#   - leading/trailing spaces, tabs, and CR (CRLF editors) trimmed
#
# Validation (hard fail, return 1, diagnostic on stderr):
#   - entries must live under `.claude/commands/`; allowlisting hooks or
#     settings.json would punch a much larger hole in the Tier 0 invariant
#   - entries must not contain a `..` path-traversal segment
#
# Semantics (enforced at the call sites, not here):
#   - consulted ONLY on the orphan path (no canonical resolvable); the
#     allowlist can never excuse drift, swapped symlinks, or render failures
#   - allowlisted entries do NOT count toward verify-all's non-vacuity guard
#
# Env override: SUBSTITUTE_NO_ALLOWLIST=1 ignores the file entirely
# (strict-CI / hostile-multi-tenant mode, mirroring SUBSTITUTE_NO_META).
#
# Bash 3.2 portability: case-loop trim (no extglob), newline-joined global
# string + `grep -qxF` matcher (no associative arrays). Mutates the global
# `__SUBST_VERIFY_ALLOWLIST`; call DIRECTLY, never in `$(...)`.
# -----------------------------------------------------------------------------
_subst_load_verify_allowlist() {
  __SUBST_VERIFY_ALLOWLIST=""
  local allow_file=".claude/.verify-allowlist"
  if [ "${SUBSTITUTE_NO_ALLOWLIST:-0}" = "1" ]; then
    return 0
  fi
  [ -f "$allow_file" ] || return 0
  [ -r "$allow_file" ] || return 0
  local line
  # `|| [ -n "$line" ]` keeps a final line without trailing newline.
  while IFS= read -r line || [ -n "$line" ]; do
    # Trim leading + trailing ASCII space, tab, CR.
    while :; do
      case "$line" in
        ' '*|$'\t'*|$'\r'*) line="${line#?}" ;;
        *) break ;;
      esac
    done
    while :; do
      case "$line" in
        *' '|*$'\t'|*$'\r') line="${line%?}" ;;
        *) break ;;
      esac
    done
    [ -n "$line" ] || continue
    case "$line" in
      '#'*) continue ;;
    esac
    # Path-traversal guard (same shape as _subst_validate_template_dir).
    case "$line" in
      *"/../"*|"../"*|*"/.."|"..")
        echo "substitute: invalid entry in .claude/.verify-allowlist (path traversal '..'): $line" >&2
        return 1
        ;;
    esac
    # Scope guard: only consumer-local COMMANDS are allowlistable.
    case "$line" in
      ".claude/commands/"?*) ;;
      *)
        echo "substitute: invalid entry in .claude/.verify-allowlist: $line (only .claude/commands/ entries may be allowlisted)" >&2
        return 1
        ;;
    esac
    __SUBST_VERIFY_ALLOWLIST="${__SUBST_VERIFY_ALLOWLIST}${line}"$'\n'
  done < "$allow_file"
  return 0
}

# -----------------------------------------------------------------------------
# Internal: exact-match test against the loaded allowlist. rc=0 iff ENTRY is
# allowlisted. Requires a prior _subst_load_verify_allowlist call.
# -----------------------------------------------------------------------------
_subst_entry_allowlisted() {
  local entry="$1"
  [ -n "$__SUBST_VERIFY_ALLOWLIST" ] || return 1
  printf '%s' "$__SUBST_VERIFY_ALLOWLIST" | grep -qxF "$entry"
}

_subst_enumerate_entries() {
  local entry rel canonical
  # Commands (top-level files + supplement-subdir files). Include symlinks
  # via -o -type l; exclude directory paths (we want files and symlinks).
  if [ -d ".claude/commands" ]; then
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      rel="${entry#.claude/commands/}"
      canonical="commands/$rel"
      printf '%s\t%s\n' "$entry" "$canonical"
    done < <(find ".claude/commands" -mindepth 1 \( -type f -o -type l \) | LC_ALL=C sort)
  fi
  # Hooks (flat).
  if [ -d ".claude/hooks" ]; then
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      rel="${entry#.claude/hooks/}"
      canonical="hooks/$rel"
      printf '%s\t%s\n' "$entry" "$canonical"
    done < <(find ".claude/hooks" -mindepth 1 -maxdepth 1 \( -type f -o -type l \) | LC_ALL=C sort)
  fi
  # settings.json.
  if [ -e ".claude/settings.json" ] || [ -L ".claude/settings.json" ]; then
    printf '.claude/settings.json\ttemplates/settings.json\n'
  fi
}

# -----------------------------------------------------------------------------
# Subcommand: render-all <config>
# -----------------------------------------------------------------------------
cmd_render_all() {
  local config="${1:-}"
  if [ -z "$config" ]; then
    echo "usage: substitute.sh render-all <config>" >&2
    exit 2
  fi
  _subst_load_config "$config"
  # #30: read .claude/.template-meta once at start. Empty when missing/unreadable
  # → in-tree-only lookup, current behavior preserved (orphan diagnostic fires
  # as today). Non-empty enables fallback to ${meta_dir}/<canonical_rel>.
  # #47: validation failures inside _subst_read_template_meta (path traversal
  # or disallowed prefix) return non-zero; propagate as a hard exit so a
  # poisoned meta cannot silently fall through to in-tree-only.
  local meta_dir meta_rc
  meta_dir="$(_subst_read_template_meta)"
  meta_rc=$?
  if [ "$meta_rc" -ne 0 ]; then
    echo "render-all: aborted — .claude/.template-meta failed validation (see prior error)" >&2
    exit 1
  fi
  # #97: load the consumer-local-command allowlist. Invalid entries hard-fail
  # (a malformed allowlist must never silently degrade to "no allowlist").
  # Called directly (mutates a global); same propagation shape as meta.
  if ! _subst_load_verify_allowlist; then
    echo "render-all: aborted: .claude/.verify-allowlist failed validation (see prior error)" >&2
    exit 1
  fi
  local entry canonical resolved_canonical resolved_any
  local rendered_count=0 skipped_symlinks=0 missing_canonical=0 render_errors=0
  local allowlisted_count=0
  local tmp_render
  tmp_render="$(mktemp -t substitute-render-all.XXXXXX)" || {
    echo "substitute: mktemp failed" >&2
    exit 1
  }
  while IFS=$'\t' read -r entry canonical; do
    [ -n "$entry" ] || continue
    if [ -L "$entry" ]; then
      skipped_symlinks=$((skipped_symlinks+1))
      continue
    fi
    # Resolve canonical: prefer in-tree, fall back to template-meta path.
    resolved_canonical="$(_subst_resolve_canonical "$canonical" "$meta_dir")"
    if [ -z "$resolved_canonical" ]; then
      # Review fix (#112, Codex P2): canonical exists but is not a regular
      # file (e.g. a supplement DIRECTORY): type collision, not an orphan.
      # Fail BEFORE consulting the allowlist so it cannot mask the swap.
      resolved_any="$(_subst_resolve_canonical "$canonical" "$meta_dir" "-e")"
      if [ -n "$resolved_any" ]; then
        echo "render-all: $entry: canonical $resolved_any exists but is not a regular file (type collision; expected a symlink to it)" >&2
        render_errors=$((render_errors+1))
        continue
      fi
      # #97: allowlisted consumer-local command: nothing to render; skip.
      # Consulted ONLY on this orphan path so the allowlist can never mask a
      # render failure for an entry that HAS a canonical.
      if _subst_entry_allowlisted "$entry"; then
        allowlisted_count=$((allowlisted_count+1))
        continue
      fi
      if [ -n "$meta_dir" ]; then
        echo "render-all: orphan: $entry has no canonical at $canonical or ${meta_dir}/${canonical}" >&2
      else
        echo "render-all: orphan: $entry has no canonical at $canonical" >&2
      fi
      missing_canonical=$((missing_canonical+1))
      continue
    fi
    # Render to temp file first; only commit (mv into place) on success. This
    # avoids the prior `$( ... ; printf x)` trick where $? captured printf,
    # not render — causing failed renders to silently overwrite entries with
    # empty content.
    if ! _subst_render_to_file "$resolved_canonical" "$tmp_render"; then
      echo "render-all: failed to render $resolved_canonical for $entry" >&2
      render_errors=$((render_errors+1))
      continue
    fi
    # Commit. cat → > preserves bytes faithfully (no shell expansion).
    cat "$tmp_render" > "$entry"
    if [ -x "$resolved_canonical" ]; then
      chmod +x "$entry"
    fi
    rendered_count=$((rendered_count+1))
  done < <(_subst_enumerate_entries)
  rm -f "$tmp_render"
  echo "render-all: rendered $rendered_count, skipped $skipped_symlinks symlink(s)" >&2
  if [ "$allowlisted_count" -gt 0 ]; then
    echo "render-all: skipped $allowlisted_count consumer-local entry(ies) allowlisted via .claude/.verify-allowlist" >&2
  fi
  if [ "$render_errors" -gt 0 ] || [ "$missing_canonical" -gt 0 ]; then
    echo "render-all: $render_errors render error(s), $missing_canonical orphan(s)" >&2
    exit 1
  fi
  exit 0
}

# -----------------------------------------------------------------------------
# Subcommand: verify-all <config>
# -----------------------------------------------------------------------------
cmd_verify_all() {
  local config="${1:-}"
  if [ -z "$config" ]; then
    echo "usage: substitute.sh verify-all <config>" >&2
    exit 2
  fi
  _subst_load_config "$config"
  # #30: read .claude/.template-meta once at start. See render-all comment.
  # #47: same hard-exit propagation as render-all.
  local meta_dir meta_rc
  meta_dir="$(_subst_read_template_meta)"
  meta_rc=$?
  if [ "$meta_rc" -ne 0 ]; then
    echo "verify-all: aborted — .claude/.template-meta failed validation (see prior error)" >&2
    exit 1
  fi
  # #97: load the consumer-local-command allowlist (see _subst_load_verify_
  # allowlist). Invalid entries hard-fail; the Tier 0 gate must never consult
  # a malformed allowlist. Called directly (mutates a global).
  if ! _subst_load_verify_allowlist; then
    echo "verify-all: aborted: .claude/.verify-allowlist failed validation (see prior error)" >&2
    exit 1
  fi
  local entry canonical resolved_canonical resolved canonical_real resolved_any
  local fail_count=0 ok_count=0 allowlisted_count=0
  local tmp_render
  tmp_render="$(mktemp -t substitute-verify-all.XXXXXX)" || {
    echo "substitute: mktemp failed" >&2
    exit 1
  }
  while IFS=$'\t' read -r entry canonical; do
    [ -n "$entry" ] || continue
    if [ -L "$entry" ]; then
      # Branch (a): symlink must resolve to canonical (real path equality).
      # Existence checks first — `os.path.realpath` returns a normalized path
      # even for non-existent targets, so a broken symlink would otherwise
      # appear to "match" a missing canonical. Both the resolved target and
      # the canonical must exist for branch (a) to be a valid pass.
      #
      # #30: prefer in-tree canonical, fall back to ${meta_dir}/<canonical>.
      # Symlinks under .claude/ on a self-host kit point at relative in-tree
      # paths (e.g. ../../commands/<name>); on a consumer install they cannot
      # exist as symlinks (target wouldn't resolve). Honoring the meta_dir
      # fallback here keeps the two branches symmetric — if a future tooling
      # change emits symlinks to absolute meta_dir paths, this still works.
      # Use `-e` (existence) not `-f` (regular file): supplement subtrees
      # symlink to canonical DIRECTORIES (e.g. commands/tdd-supplements/).
      resolved_canonical="$(_subst_resolve_canonical "$canonical" "$meta_dir" "-e")"
      if [ -z "$resolved_canonical" ]; then
        # #97: allowlisted consumer-local command (symlink form): declared
        # to have no canonical counterpart; pass without counting toward
        # ok_count (non-vacuity guard must not be satisfiable by allowlist).
        # Review fix (#112): a BROKEN symlink is never excusable; a local
        # command must actually resolve to something on disk.
        if _subst_entry_allowlisted "$entry"; then
          if [ ! -e "$entry" ]; then
            echo "verify-all: symlink $entry is broken (target does not exist); allowlist does not excuse broken symlinks" >&2
            fail_count=$((fail_count+1))
            continue
          fi
          allowlisted_count=$((allowlisted_count+1))
          continue
        fi
        if [ -n "$meta_dir" ]; then
          echo "verify-all: symlink $entry references missing canonical $canonical (also tried ${meta_dir}/${canonical})" >&2
        else
          echo "verify-all: symlink $entry references missing canonical $canonical" >&2
        fi
        fail_count=$((fail_count+1))
        continue
      fi
      if [ ! -e "$entry" ]; then
        echo "verify-all: symlink $entry is broken (target does not exist)" >&2
        fail_count=$((fail_count+1))
        continue
      fi
      # Use python's realpath for symlink resolution that works on
      # macOS/Linux without GNU `readlink -f`.
      resolved="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$entry" 2>/dev/null || true)"
      canonical_real="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$resolved_canonical" 2>/dev/null || true)"
      if [ -z "$resolved" ] || [ -z "$canonical_real" ] || [ "$resolved" != "$canonical_real" ]; then
        echo "verify-all: symlink $entry resolves to '$resolved', expected canonical '$canonical_real'" >&2
        fail_count=$((fail_count+1))
        continue
      fi
      ok_count=$((ok_count+1))
      continue
    fi
    # Branch (b): real file must equal render(canonical, config) byte-for-byte.
    # #30: prefer in-tree, fall back to ${meta_dir}/<canonical>.
    resolved_canonical="$(_subst_resolve_canonical "$canonical" "$meta_dir")"
    if [ -z "$resolved_canonical" ]; then
      # Review fix (#112, Codex P2): a canonical that EXISTS but is not a
      # regular file (e.g. a supplement DIRECTORY whose .claude symlink was
      # swapped for a real file) is a type collision, not an orphan. Fail it
      # BEFORE consulting the allowlist so the allowlist cannot mask it.
      resolved_any="$(_subst_resolve_canonical "$canonical" "$meta_dir" "-e")"
      if [ -n "$resolved_any" ]; then
        echo "verify-all: $entry: canonical $resolved_any exists but is not a regular file (type collision; expected a symlink to it)" >&2
        fail_count=$((fail_count+1))
        continue
      fi
      # #97: allowlisted consumer-local command: pass the orphan check.
      # Consulted ONLY here, so the allowlist can never excuse drift (branch
      # (b) byte-compare below) or a swapped symlink (branch (a) above).
      if _subst_entry_allowlisted "$entry"; then
        allowlisted_count=$((allowlisted_count+1))
        continue
      fi
      if [ -n "$meta_dir" ]; then
        echo "verify-all: orphan: $entry has no canonical at $canonical or ${meta_dir}/${canonical}" >&2
      else
        echo "verify-all: orphan: $entry has no canonical at $canonical" >&2
      fi
      fail_count=$((fail_count+1))
      continue
    fi
    # Review fix (#112): a canonical-backed entry that also appears in the
    # allowlist is inert (verified normally below). Surface a notice so stale
    # exemptions cannot accumulate silently until a canonical disappears.
    if _subst_entry_allowlisted "$entry"; then
      echo "verify-all: notice: allowlist entry $entry is canonical-backed; entry is inert (verified normally)" >&2
    fi
    # Render to a temp file for byte-faithful comparison and a reliable rc
    # check (the prior `$( ... ; printf x)` idiom captured printf's exit, not
    # render's, so render errors silently became content-mismatch reports).
    if ! _subst_render_to_file "$resolved_canonical" "$tmp_render"; then
      echo "verify-all: render failed for $resolved_canonical (referenced by $entry)" >&2
      fail_count=$((fail_count+1))
      continue
    fi
    if ! cmp -s "$tmp_render" "$entry"; then
      echo "verify-all: $entry differs from render($resolved_canonical)" >&2
      diff "$tmp_render" "$entry" >&2 || true
      fail_count=$((fail_count+1))
      continue
    fi
    ok_count=$((ok_count+1))
  done < <(_subst_enumerate_entries)
  rm -f "$tmp_render"
  # #97: audit visibility: surface the allowlisted count in CI logs even on
  # a passing run so reviewers can see exactly how many entries bypassed the
  # canonical check via .claude/.verify-allowlist.
  if [ "$allowlisted_count" -gt 0 ]; then
    echo "verify-all: $allowlisted_count consumer-local entry(ies) allowlisted via .claude/.verify-allowlist" >&2
  fi
  if [ "$fail_count" -gt 0 ]; then
    echo "verify-all: $fail_count failure(s), $ok_count ok" >&2
    exit 1
  fi
  # Non-vacuity guard: a CWD with no .claude/commands, no .claude/hooks, and
  # no .claude/settings.json would emit zero entries and trivially "pass".
  # The Tier 0 invariant gate's contract is "verify the kit's enumerated
  # entries"; zero entries means the gate verified nothing. Treat as a hard
  # failure so a malformed checkout (e.g. .claude/ deleted in CI by accident)
  # cannot ship as green. Local/CI parity: same diagnostic both places.
  # #97: allowlisted entries intentionally do NOT count toward ok_count; a
  # tree whose only entries are allowlisted consumer-local commands verified
  # nothing against canonical and must still fail here.
  if [ "$ok_count" -eq 0 ]; then
    if [ "$allowlisted_count" -gt 0 ]; then
      echo "verify-all: zero canonical-backed entries verified (all enumerated entries are allowlisted consumer-local): vacuous pass blocked" >&2
    else
      echo "verify-all: no entries enumerated under .claude/; vacuous pass blocked" >&2
    fi
    echo "verify-all: expected at least one of .claude/commands/, .claude/hooks/, .claude/settings.json" >&2
    exit 1
  fi
  exit 0
}

# -----------------------------------------------------------------------------
# Dispatch
# -----------------------------------------------------------------------------
sub="${1:-}"
shift || true
case "$sub" in
  render)     cmd_render     "$@" ;;
  verify)     cmd_verify     "$@" ;;
  render-all) cmd_render_all "$@" ;;
  verify-all) cmd_verify_all "$@" ;;
  ""|-h|--help|help)
    cat <<USAGE
usage: substitute.sh <subcommand> [args]
  render     <canonical> <config>            -> emit rendered to stdout
  verify     <canonical> <config> <existing> -> exit 0 if equal, 1 otherwise
  render-all <config>                        -> render every real-file entry
                                                under .claude/ in cwd
  verify-all <config>                        -> verify every entry under
                                                .claude/ in cwd
USAGE
    exit 0
    ;;
  *)
    echo "substitute.sh: unknown subcommand: $sub" >&2
    exit 2
    ;;
esac
