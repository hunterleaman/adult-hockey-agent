Surgical 3-way merge between this project's installed dev kit and the canonical template, using `.claude/.template-version` as the ancestor anchor. Replaces the legacy 2-way diff workflow.

The audit walks every kit-tracked file, classifies each as OK / MODIFIED / MISSING / NEW / EXTRA / DEPRECATED, and for MODIFIED files runs a 3-way merge. Clean merges write directly. Conflicts are resolved with an inline per-hunk picker (`template` / `project` / `manual`) before any project file is touched.

If you pass `--no-overwrite`, the audit becomes purely advisory: classify and report, but do not write merged files, do not copy MISSING/NEW, do not delete DEPRECATED. Operators use this for read-only drift inspection.

## 0. Source the lib

The helper modules live at the template root under `lib/`. Source them once at the top so every later step can call into them.

Before sourcing, run the tiered kit-detection helper (`lib/kit-detect.sh`, issue #77). The audit needs a usable kit-source-tree to read canonical content from; CORE marker absence at the resolved kit root means the audit has nothing to compare against and must refuse. SOFT marker absence (`commands/` + `hooks/` + `tests/` + `docs/hard-rules/`) is a customization signal; warn but proceed.

```bash
TEMPLATE_REPO="https://github.com/hunterleaman/claude-project-template.git"
CACHE_DIR="$HOME/.cache/claude-project-template"
PROJECT_DIR="$(pwd)"

# Two-stage resolution to decouple "where to source helpers from" (LIB_DIR)
# from "which tree IS the canonical kit-source-tree" (KIT_DIR).
#
# (a) LIB_DIR — where ALL audit-kit helpers live. Prefer the project copy
#     (fast path; works for self-host where PROJECT_DIR IS the kit-source-
#     tree). Fall back to the cache. A candidate is accepted only when
#     EVERY required helper is present at it — otherwise a stale project
#     `lib/` (post-rename of any helper) would be picked and later `. ...`
#     would hard-fail before the audit can start. Required helper set is
#     the complete sourcing list at the bottom of this Step 0 plus
#     `kit-detect.sh` itself.
LIB_DIR=""
_AK_REQUIRED_HELPERS="kit-detect.sh template-version.sh template-cache.sh merge-engine.sh classify.sh probe.sh"
for candidate in "$PROJECT_DIR/lib" "$CACHE_DIR/lib"; do
  _all_present=1
  for _h in $_AK_REQUIRED_HELPERS; do
    if [ ! -f "$candidate/$_h" ]; then
      _all_present=0
      break
    fi
  done
  if [ "$_all_present" -eq 1 ]; then
    LIB_DIR="$candidate"
    break
  fi
done
unset _h _all_present
if [ -z "$LIB_DIR" ]; then
  echo "audit-kit: no lib/ with the full helper set ($_AK_REQUIRED_HELPERS) found locally or in cache. Re-run bootstrap.sh in this project or ensure $CACHE_DIR is populated (Step 2 below) before auditing."
  exit 1
fi
unset _AK_REQUIRED_HELPERS

# Source kit-detect first so we can apply the tiered refuse/warn contract
# before touching anything else.
# shellcheck source=/dev/null
. "$LIB_DIR/kit-detect.sh"

# (b) KIT_DIR — the canonical kit-source-tree the audit will compare against.
#     PROJECT_DIR is a kit-source-tree only in the self-host case (running
#     /audit-kit FROM the template repo itself); in normal consumer use,
#     PROJECT_DIR is a downstream install and has no bootstrap.sh at root.
#     Probe PROJECT_DIR first via kit_detect_core; on miss, fall back to
#     the cache (which IS a clone of the canonical template).
KIT_DIR=""
if kit_detect_core "$PROJECT_DIR" 2>/dev/null; then
  KIT_DIR="$PROJECT_DIR"
elif kit_detect_core "$CACHE_DIR" 2>/dev/null; then
  KIT_DIR="$CACHE_DIR"
fi

# CORE refusal: neither PROJECT_DIR nor CACHE_DIR passes the CORE check.
# Without a usable canonical kit there is nothing to audit against. Re-emit
# the missing-marker names from the better candidate (PROJECT_DIR if its
# lib/ exists; otherwise CACHE_DIR) so the operator sees actionable detail.
if [ -z "$KIT_DIR" ]; then
  echo "audit-kit: REFUSED — no canonical kit-source-tree found." >&2
  if [ -d "$PROJECT_DIR/lib" ]; then
    echo "audit-kit: PROJECT_DIR=$PROJECT_DIR CORE markers:" >&2
    kit_detect_core "$PROJECT_DIR" 2>&1 >/dev/null | while IFS= read -r _line; do
      printf '  %s\n' "$_line" >&2
    done
    unset _line
  fi
  echo "audit-kit: CACHE_DIR=$CACHE_DIR CORE markers:" >&2
  kit_detect_core "$CACHE_DIR" 2>&1 >/dev/null | while IFS= read -r _line; do
    printf '  %s\n' "$_line" >&2
  done
  unset _line
  echo "audit-kit: re-clone the template (rm -rf $CACHE_DIR + re-run) or restore the missing markers before auditing." >&2
  exit 1
fi

# SOFT check: WARN-only. Run against KIT_DIR (the canonical-kit tree).
# Capture missing-marker names from stderr so the operator sees the
# deviation without aborting.
SOFT_STDERR="$(mktemp -t audit-kit-soft.XXXXXX)"
SOFT_MISSING_COUNT="$(kit_detect_soft "$KIT_DIR" 2>"$SOFT_STDERR")"
if [ "${SOFT_MISSING_COUNT:-0}" -gt 0 ]; then
  echo "audit-kit: WARNING — $SOFT_MISSING_COUNT SOFT kit marker(s) missing at $KIT_DIR (proceeding):" >&2
  while IFS= read -r _line; do
    [ -z "$_line" ] && continue
    printf '  %s\n' "$_line" >&2
  done < "$SOFT_STDERR"
  unset _line
fi
rm -f "$SOFT_STDERR"

# shellcheck source=/dev/null
. "$LIB_DIR/template-version.sh"
. "$LIB_DIR/template-cache.sh"
. "$LIB_DIR/merge-engine.sh"
. "$LIB_DIR/classify.sh"
. "$LIB_DIR/probe.sh"

# Resolve the placeholder probe spec. Prefer the project copy (post-T1.3
# kits ship templates/PLACEHOLDER-PROBES.json under the project root via
# the same delivery mechanism as other templates/), fall back to the cache.
# PROBE_SPEC_TRUSTED tracks the source: 1 = template cache (curated by the
# template repo, vetted to be safe), 0 = project-local copy (could be
# tampered with by anyone who can commit to the project). lib/probe.sh
# refuses to evaluate `command` rules from untrusted specs.
PROBE_SPEC=""
PROBE_SPEC_TRUSTED=0
if [ -f "$PROJECT_DIR/templates/PLACEHOLDER-PROBES.json" ]; then
  PROBE_SPEC="$PROJECT_DIR/templates/PLACEHOLDER-PROBES.json"
  PROBE_SPEC_TRUSTED=0
elif [ -f "$CACHE_DIR/templates/PLACEHOLDER-PROBES.json" ]; then
  PROBE_SPEC="$CACHE_DIR/templates/PLACEHOLDER-PROBES.json"
  PROBE_SPEC_TRUSTED=1
fi
```

Argument parsing: `--no-overwrite` switches the audit into report-only mode for the whole run.

```bash
NO_OVERWRITE=0
for arg in "$@"; do
  case "$arg" in
    --no-overwrite) NO_OVERWRITE=1 ;;
    *) echo "audit-kit: unknown arg $arg" >&2; exit 1 ;;
  esac
done
```

## 1. Resolve ancestor SHA

Read `.claude/.template-version` — the SHA this project was last synced from. Without it, the audit cannot run a 3-way merge and must fall back to the loud-warning 2-way path (see §11).

```bash
ANCESTOR_SHA="$(tv_read "$PROJECT_DIR")"

if [ -z "$ANCESTOR_SHA" ]; then
  echo "WARNING: .claude/.template-version is missing. 3-way merge unavailable."
  echo "         Falling back to 2-way diff for all files."
  echo "         To unlock proper 3-way merges, backfill the SHA — see PLAYBOOK §4b."
  TWO_WAY_FALLBACK_ALL=1
else
  if ! tv_validate "$ANCESTOR_SHA"; then
    echo "ERROR: .claude/.template-version contains a malformed SHA: '$ANCESTOR_SHA'"
    echo "       Expected exactly 40 lowercase hex chars. Fix the file and re-run."
    exit 1
  fi
  TWO_WAY_FALLBACK_ALL=0
fi
```

## 2. Sync template cache

`cache_ensure` deepens the cache repo (full clone on first use, fetch otherwise) and prints the template HEAD SHA. `cache_resolve_ancestor` then ensures the ancestor SHA is reachable, lazy-fetching all refs if needed.

```bash
TEMPLATE_HEAD="$(cache_ensure "$TEMPLATE_REPO" "$CACHE_DIR")" || {
  echo "ERROR: cache_ensure failed. Check network or delete $CACHE_DIR and re-run."
  exit 1
}

if [ "$TWO_WAY_FALLBACK_ALL" -eq 0 ]; then
  if ! cache_resolve_ancestor "$CACHE_DIR" "$ANCESTOR_SHA"; then
    echo "WARNING: ancestor SHA $ANCESTOR_SHA not reachable in $CACHE_DIR"
    echo "         (the template may have force-pushed or pruned that history)."
    echo "         Falling back to 2-way diff for all files."
    TWO_WAY_FALLBACK_ALL=1
  fi
fi

ANCESTOR_SHORT="${ANCESTOR_SHA:0:7}"
TEMPLATE_HEAD_SHORT="${TEMPLATE_HEAD:0:7}"
echo "Audit base: ancestor=$ANCESTOR_SHORT  template-head=$TEMPLATE_HEAD_SHORT"
```

## 3. Classify all kit files

Build the file inventory by scanning the template's known kit paths in the cache:

- `commands/*.md` and `command-supplements/<name>/*` (top-level slash commands + their supplements)
- `hooks/*.sh`
- `lib/*.sh`
- `templates/settings.json`, `templates/PLACEHOLDER-PROBES.json`, `templates/PLACEHOLDER-PROBES.schema.json`, `templates/.claude.config.schema.json`
- Root + canonical doc-kit source files (cache-side paths): `CLAUDE.md`, `docs/DECISIONS.md`, `docs/CHANGELOG.md`, `docs/PITFALLS.md`. Project-side mapping is identity post the doc-layout-standardization sweep (#37 #12 #49); legacy root-level files are preserved verbatim with a one-time migration warning at bootstrap time.

For each path, call `classify_one`. Aggregate by class.

```bash
# Build the inventory from the cache (template-head reality), not from the
# project (otherwise we miss NEW files that haven't been copied yet).
# Per #37/#12/#49 doc-layout standardization, design-history docs live under
# docs/ in both cache and project; project-side mapping is identity.
inventory=()
while IFS= read -r p; do inventory+=("$p"); done < <(
  git -C "$CACHE_DIR" ls-tree -r --name-only origin/main \
    | grep -E '^(commands/.*\.md|command-supplements/[^/]+/.+|hooks/.*\.sh|lib/.*\.sh|templates/(settings\.json|PLACEHOLDER-PROBES\.json|PLACEHOLDER-PROBES\.schema\.json|\.claude\.config\.schema\.json)|CLAUDE\.md|docs/DECISIONS\.md|docs/CHANGELOG\.md|docs/PITFALLS\.md|docs/hard-rules/.*\.md)$'
)

# Also scan for project-side files that exist but aren't in the template
# inventory — they classify as EXTRA. Limited to the kit dirs.
while IFS= read -r p; do
  case " ${inventory[*]} " in *" $p "*) ;; *) inventory+=("$p");; esac
done < <(
  cd "$PROJECT_DIR" && {
    [ -d .claude/commands ] && find .claude/commands -type f -name '*.md' | sed 's|^.claude/||'
    [ -d .claude/commands-supplements ] && find .claude/commands-supplements -type f | sed 's|^.claude/commands-supplements/|command-supplements/|'
    [ -d .claude/hooks ]    && find .claude/hooks    -type f -name '*.sh' | sed 's|^.claude/||'
  }
)

declare -A CLASS_OF META_OF PROJECT_REL_OF
for rel in "${inventory[@]}"; do
  # Project-side resolution.
  # - commands/hooks live under .claude/.
  # - templates/settings.json maps to .claude/settings.json.
  # - docs/* files map identity (canonical doc-layout post-#37/#12/#49 sweep;
  #   legacy root copies preserved verbatim by bootstrap with a migration
  #   warning, but the audit walks the canonical docs/ inventory).
  case "$rel" in
    commands/*|hooks/*) project_rel=".claude/$rel" ;;
    command-supplements/*) project_rel=".claude/commands-supplements/${rel#command-supplements/}" ;;
    templates/settings.json) project_rel=".claude/settings.json" ;;
    *) project_rel="$rel" ;;
  esac
  PROJECT_REL_OF["$rel"]="$project_rel"
  out="$(classify_one "$rel" "$CACHE_DIR" "$PROJECT_DIR" "$ANCESTOR_SHA" "$project_rel" 2>/dev/null || echo 'EXTRA')"
  cls="${out%% *}"
  meta=""; case "$out" in *' '*) meta="${out#* }";; esac
  CLASS_OF["$rel"]="$cls"
  META_OF["$rel"]="$meta"
done
```

(The exact inventory-building code is illustrative — adapt to handle the project's `.claude/`-vs-root path mapping. The contract: every kit file gets a class.)

## 4. Per-class action

| Class | Default action | `--no-overwrite` action | Notes |
|---|---|---|---|
| OK | none | none | Report only. |
| MODIFIED | `merge_file` → inline per-hunk picker (§5) | classify only; report OUT-OF-DATE | Carries forward bootstrap B8 semantics. |
| MISSING | copy from template-head | flag, don't copy | |
| NEW | copy with provenance prompt (§7) | flag, don't copy | |
| EXTRA | report-only | report-only | Project-specific. Skip. |
| DEPRECATED | KEEP by default; prompt to delete (§6) | report-only | Template removed; project still has it. |

For B10 custom-named-doc collisions encountered during file resolution (e.g. `docs/CHANGELOG.md` exists but no `CHANGELOG.md`), refuse-or-warn consistent with `bootstrap.sh`: print the warning, skip the default-location write. Operator must reconcile manually before re-running.

## 5. Inline 3-way conflict picker (per hunk)

For every MODIFIED file, run `merge_file` and branch on the outcome:

```bash
for rel in "${!CLASS_OF[@]}"; do
  [ "${CLASS_OF[$rel]}" = "MODIFIED" ] || continue
  if [ "$NO_OVERWRITE" -eq 1 ]; then
    echo "[OUT-OF-DATE] $rel — template differs (no-overwrite: skipped)"
    continue
  fi

  if [ "$TWO_WAY_FALLBACK_ALL" -eq 1 ]; then
    handle_two_way_fallback "$rel"   # see §11
    continue
  fi

  proj_rel="${PROJECT_REL_OF[$rel]}"
  outcome="$(merge_file "$rel" "$ANCESTOR_SHA" "$CACHE_DIR" "$PROJECT_DIR" "$proj_rel")"
  case "$outcome" in
    CLEAN)
      echo "✓ $rel  (clean 3-way merge)"
      MERGED=$((${MERGED:-0}+1))
      ;;
    NO_ANCESTOR)
      echo "⚠️  $rel  (no ancestor for this file — falling back to 2-way diff)"
      handle_two_way_fallback "$rel"
      ;;
    ERROR)
      echo "✗ $rel  (merge engine error — project file untouched; investigate before re-running)" >&2
      MERGE_ERROR=$((${MERGE_ERROR:-0}+1))
      ;;
    "CONFLICT "*)
      n_hunks="$(echo "$outcome" | awk '{print $2}')"
      conflict_path="$(echo "$outcome" | awk '{print $3}')"
      run_inline_picker "$rel" "$n_hunks" "$conflict_path"
      ;;
  esac
done
```

### `run_inline_picker` UX

For each conflict hunk in the merge-file output (delimited by `<<<<<<<` / `|||||||` / `=======` / `>>>>>>>`), display:

```
### {rel_path}  hunk {i}/{N} (lines {start}-{end})

<<<<<<< project
{project version of hunk}
||||||| ancestor ({ANCESTOR_SHORT})
{ancestor version of hunk}
======= template
{template version of hunk}
>>>>>>>

RECOMMEND: {template|project} — {1-3 sentence rationale}.

Pick: template / project / manual?
```

**Recommendation generator.** Apply the `/decide` priority ladder (accuracy > maintainability > scalability > future-proofing > client-readiness > minimal intervention) to choose one of three biases:

- **Default `template`** when the divergence looks like trivial drift the template has since moved past — comments rephrased, log-line wording tweaked, whitespace, dependency version bumps. Maintainability wins; pick up the template's evolution.
- **Default `project`** when the project hunk reads as a deliberate local customization — a placeholder filled in, a project-specific path or invariant added, a domain-specific rule. Accuracy and operator intent win.
- **Default `manual`** when both sides look intentional and substantive — both have new logic, the merge needs human judgment.

State the bias in 1-3 sentences citing the relevant priority. Operator may override.

**Pick handling.**

- `template` → extract the template-side hunk into the staging file at `conflict_path`, replacing the conflict block.
- `project`  → extract the project-side hunk; replace the conflict block.
- `manual`   → leave the entire conflict-marker block intact in `conflict_path`. Stop processing this file's remaining hunks. Skip writing the merged file to the project; instead, copy the marker-bearing file straight into `$PROJECT_DIR/$rel`. Mark this file SKIPPED in the summary so the operator can hand-edit it later.

After all hunks for a file are decided (and no `manual` chosen), write the resolved staging file to `$PROJECT_DIR/$rel` and increment `RESOLVED`.

```bash
run_inline_picker() {
  local rel="$1" n_hunks="$2" conflict_path="$3"
  local i=0 chose_manual=0
  # Iterate the diff3 conflict blocks. For each, render the hunk to the
  # operator with the recommendation, read 'template'/'project'/'manual',
  # then rewrite conflict_path with the chosen side or leave the markers
  # intact (for 'manual').
  # ...implementation: parse <<<<<<< / ||||||| / ======= / >>>>>>> blocks
  # iteratively, e.g. with awk or python3 helper.
  if [ "$chose_manual" -eq 1 ]; then
    cp "$conflict_path" "$PROJECT_DIR/$rel"
    echo "↻ $rel  (manual hand-edit required — markers written)"
    SKIPPED=$((${SKIPPED:-0}+1))
  else
    cp "$conflict_path" "$PROJECT_DIR/$rel"
    echo "✓ $rel  ($n_hunks hunks resolved interactively)"
    RESOLVED=$((${RESOLVED:-0}+1))
  fi
}
```

## 6. DEPRECATED prompt

For each DEPRECATED file (template removed it, project still has it), default to keep. Show provenance from `META_OF` so the operator knows the removal commit:

```
### {rel_path}: DEPRECATED
Template removed this file in {removed_in_sha} ({commit subject}).
Project still has it. Review for migration before deleting.

Action: keep / delete?
```

Default: keep. Track deletes via `DEPRECATED_DELETED` count, keeps via `DEPRECATED_KEPT`. Under `--no-overwrite`, report only — no prompt, no delete.

## 7. NEW with provenance

For each NEW file (added to template after ancestor), prompt to copy. Default: copy. Show the provenance from `META_OF`:

```
### {rel_path}: NEW
Added in {added_in_sha}: {commit subject}

Action: copy / skip?
```

Default: copy. Track copies via `NEW_COPIED`, skips via `NEW_SKIPPED`. Under `--no-overwrite`, report only — no prompt, no copy.

When copying, the source is the template-head version: `git -C "$CACHE_DIR" show "origin/main:$rel" > "$PROJECT_DIR/$rel"`. Honor B10 collision detection for root docs.

## 8. Unfilled placeholder audit (probe-driven)

After file classification and per-class action, run the structured probe
layer (`lib/probe.sh`) against the project to derive a placeholder map
from declarative rules in `templates/PLACEHOLDER-PROBES.json`. Then scan
the project for any `{{[A-Z_]*}}` tokens still present and partition them
into RESOLVABLE (probe has a value) and UNFILLED (no probe match — real
operator bug).

**Why probe-driven.** Heuristic inline greps over `package.json` /
`pyproject.toml` are ambiguous (B5). The spec is declarative: every
placeholder rule is data, every value is reproducible, and adding a new
placeholder only requires editing `templates/PLACEHOLDER-PROBES.json`.

**Self-exclusion (B6).** `audit-kit.md` itself documents placeholders by
example. Scanning audit-kit.md would flag those documentation references
as unfilled bugs. Exclude it by filename via `grep -v audit-kit.md`.

```bash
# Run the probe. Empty map is fine — many placeholders (LONG_BUILD_TIMEOUT_MS,
# APPEND_ONLY_FILES, etc.) are operator-only and never resolved by the spec.
# Consumers leave those tokens for manual fill. (REPO_ROOT was eliminated per
# docs/DECISIONS.md → Substitute subsystem Q2.5: use $CLAUDE_PROJECT_DIR at runtime.)
#
# Capture probe output to a temp file so we can check exit status. Process
# substitution does not propagate the producer's exit code; if probe_extract
# fails (malformed JSON, missing jq), an empty PROBE_MAP would silently
# misclassify every token as UNFILLED. Emit a hard warning instead.
declare -A PROBE_MAP
PROBE_FAILED=0
if [ -n "$PROBE_SPEC" ]; then
  _probe_out="$(mktemp -t audit-kit-probe.XXXXXX)"
  if probe_extract "$PROJECT_DIR" "$PROBE_SPEC" "$PROBE_SPEC_TRUSTED" >"$_probe_out" 2>&1; then
    while IFS='=' read -r key value; do
      [ -n "$key" ] || continue
      PROBE_MAP["$key"]="$value"
    done <"$_probe_out"
  else
    PROBE_FAILED=1
    echo "WARNING: probe_extract failed (spec=$PROBE_SPEC). Output:"
    sed 's/^/  /' "$_probe_out"
    echo "WARNING: continuing with empty probe map; all tokens will report as UNFILLED."
  fi
  rm -f "$_probe_out"
else
  echo "NOTE: no PLACEHOLDER-PROBES.json found in project or cache; falling back to non-probe audit."
fi

UNFILLED_RAW=$(grep -rn '{{[A-Z_]*}}' "$PROJECT_DIR/.claude/commands/" "$PROJECT_DIR/CLAUDE.md" 2>/dev/null | grep -v audit-kit.md || true)
RESOLVABLE_COUNT=0
UNFILLED_COUNT=0

if [ -n "$UNFILLED_RAW" ]; then
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    # Extract the \{{TOKEN}} name(s) on this line.
    while IFS= read -r token; do
      [ -n "$token" ] || continue
      key="${token#\{\{}"; key="${key%\}\}}"
      if [ -n "${PROBE_MAP[$key]+x}" ]; then
        echo "  RESOLVABLE: {{$key}} → ${PROBE_MAP[$key]}  (${hit%%:*})"
        RESOLVABLE_COUNT=$((RESOLVABLE_COUNT+1))
      else
        echo "  UNFILLED:   $hit"
        UNFILLED_COUNT=$((UNFILLED_COUNT+1))
      fi
    done < <(printf '%s\n' "$hit" | grep -oE '\{\{[A-Z_]+\}\}' | sort -u)
  done <<<"$UNFILLED_RAW"
fi
```

Resolvable placeholders are presented to the operator as a single fill
recommendation per token (the probe has already determined the right
value). Truly UNFILLED entries are real bugs — the operator must supply
them, or they indicate a placeholder the spec doesn't yet cover (file an
issue against `templates/PLACEHOLDER-PROBES.json`).

Report `RESOLVABLE_COUNT` and `UNFILLED_COUNT` in the Step 9 summary.
Under `--no-overwrite`, behavior is unchanged — the audit is read-only
by definition; resolutions are surfaced but not applied.

## 9. Report

Print the audit summary with all class counters. The CONFLICT line is the **total hunks across all merged files** — useful for sizing follow-up work.

```
Audit Summary:
  OK:           $OK
  MERGED:       $MERGED       (clean 3-way)
  RESOLVED:     $RESOLVED     (operator picked template/project)
  SKIPPED:      $SKIPPED      (manual / NO_ANCESTOR fallback declined)
  MERGE_ERROR:  $MERGE_ERROR  (git merge-file hard failure; project untouched)
  MISSING:      $MISSING_COPIED copied / $MISSING_FLAGGED flagged
  NEW:          $NEW_COPIED copied / $NEW_SKIPPED skipped
  EXTRA:        $EXTRA        (project-specific)
  DEPRECATED:   $DEPRECATED_KEPT kept / $DEPRECATED_DELETED deleted
  CONFLICT:     $TOTAL_HUNKS hunks total
  RESOLVABLE:   $RESOLVABLE_COUNT placeholder references (probe has values; see §8)
  UNFILLED:     $UNFILLED_COUNT placeholder references (operator must supply; see §8)
```

## 10. Advance `.template-version`

Bump the project's anchor only when the audit completed cleanly with **zero outstanding skipped files**. Per Q5 design lock (option B): SKIPPED includes `manual`, declined NO_ANCESTOR fallbacks, and any operator-skipped MODIFIED. `--no-overwrite` mode never advances the anchor.

```bash
if [ "$NO_OVERWRITE" -eq 1 ]; then
  echo "Version anchor not advanced — --no-overwrite mode (report-only)."
elif [ "${SKIPPED:-0}" -eq 0 ] && [ "${MERGE_ERROR:-0}" -eq 0 ] && [ "$TWO_WAY_FALLBACK_ALL" -eq 0 ]; then
  tv_write "$PROJECT_DIR" "$TEMPLATE_HEAD"
  echo "✓ .template-version advanced to $TEMPLATE_HEAD_SHORT"
else
  echo "Version anchor not advanced — ${SKIPPED:-0} skipped, ${MERGE_ERROR:-0} merge errors outstanding."
  echo "  Re-run /audit-kit after resolving them to bump the anchor."
fi
```

If the anchor doesn't advance, the next audit re-classifies the same files against the same ancestor — no harm done, just unfinished business.

## 11. 2-way fallback section

Reach this path when:
- `.claude/.template-version` is missing or malformed (whole-run fallback), OR
- A specific file's ancestor blob isn't in the cache (per-file fallback via `merge_file`'s `NO_ANCESTOR` outcome).

Behavior in both cases is the same per file: print a loud warning, show the full 2-way diff between the project copy and the template HEAD copy, and let the operator pick `template` / `project` / `manual`. There is no per-hunk granularity in 2-way mode — the file is replaced wholesale or left as-is.

```bash
handle_two_way_fallback() {
  local rel="$1"
  local project_rel
  case "$rel" in
    commands/*|hooks/*) project_rel=".claude/$rel" ;;
    command-supplements/*) project_rel=".claude/commands-supplements/${rel#command-supplements/}" ;;
    templates/settings.json) project_rel=".claude/settings.json" ;;
    *) project_rel="$rel" ;;
  esac

  echo "─── 2-WAY FALLBACK: $rel ───"
  echo "Ancestor unreachable. No per-hunk granularity available — pick whole-file."
  diff -u "$PROJECT_DIR/$project_rel" <(git -C "$CACHE_DIR" show "origin/main:$rel") || true
  read -r -p "Pick: template / project / manual? " pick
  case "$pick" in
    template) git -C "$CACHE_DIR" show "origin/main:$rel" > "$PROJECT_DIR/$project_rel" ;;
    project)  : ;;  # leave as-is
    manual|*) echo "  (no change; operator will hand-edit)"; SKIPPED=$((${SKIPPED:-0}+1)) ;;
  esac
}
```

If the whole-run fallback path was taken (ANCESTOR_SHA missing), see PLAYBOOK §4b for the one-time backfill procedure to unlock 3-way merges going forward.
