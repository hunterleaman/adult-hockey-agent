#!/usr/bin/env bash
# lib/probe.sh
# Data-driven placeholder probe layer. Replaces ad-hoc heuristics in
# audit-kit / orient with a declarative spec (templates/PLACEHOLDER-PROBES.json).
#
# Function:
#   probe_extract PROJECT_DIR PROBE_SPEC_JSON
#     Walk the spec's placeholders in declaration order. For each placeholder,
#     evaluate its rules in order; the first matching rule yields the value.
#     Print one "PLACEHOLDER_NAME=value" line to stdout per resolved
#     placeholder. Unresolved placeholders are silently omitted (consumers
#     leave the {{TOKEN}} in place). Always returns 0.
#
# Rule types:
#   file_regex      Bash ERE match against a file's content, evaluated
#                   per line via `grep -oE`. ${1} in `value` expands to
#                   capture group 1.
#   json_path       jq selector against a JSON file. The selector must
#                   resolve to a string for the rule to fire. `value` may
#                   be a static string or contain ${value} → resolved JSON
#                   string substituted.
#   file_glob_count count files matching each candidate glob; emit the value
#                   of the candidate with the most matches (>0).
#   file_present    if the file exists, emit the static value.
#   command         run a command (cwd = PROJECT_DIR), capture stdout. The
#                   command must come from the spec, not user input — operators
#                   curate the spec, not arbitrary projects.

set -u

# Internal: substitute ${1} (capture group 1) and ${value} (resolved JSON
# string from a json_path rule) inside a value template.
_probe_subst() {
  local value="$1" cap1="${2-}" jval="${3-}"
  value="${value//\$\{1\}/$cap1}"
  value="${value//\$\{value\}/$jval}"
  printf '%s' "$value"
}

# Internal: file_regex rule. Echo resolved value on match, return 0; else 1.
# Uses bash native [[ =~ ]] / BASH_REMATCH for capture-group extraction so the
# pattern passes through verbatim — no sed-quoting hazards around `&`, `\`, `/`.
_probe_rule_file_regex() {
  local project_dir="$1" rule="$2"
  local file pattern value path cap1
  file="$(jq -r '.file' <<<"$rule")"
  pattern="$(jq -r '.pattern' <<<"$rule")"
  value="$(jq -r '.value' <<<"$rule")"
  path="$project_dir/$file"
  [ -f "$path" ] || return 1
  cap1=""
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ $pattern ]]; then
      cap1="${BASH_REMATCH[1]-}"
      if [[ "$value" == *'${1}'* ]]; then
        _probe_subst "$value" "$cap1"
      else
        printf '%s' "$value"
      fi
      return 0
    fi
  done <"$path"
  return 1
}

# Internal: json_path rule. Resolve a jq selector against a JSON file; the
# rule fires when the selector yields a non-null, non-empty string.
_probe_rule_json_path() {
  local project_dir="$1" rule="$2"
  local file path value file_path jval
  file="$(jq -r '.file' <<<"$rule")"
  path="$(jq -r '.path' <<<"$rule")"
  value="$(jq -r '.value' <<<"$rule")"
  file_path="$project_dir/$file"
  [ -f "$file_path" ] || return 1
  jval="$(jq -r "$path // empty" "$file_path" 2>/dev/null)" || return 1
  [ -n "$jval" ] || return 1
  if [[ "$value" == *'${value}'* ]]; then
    _probe_subst "$value" "" "$jval"
  else
    printf '%s' "$value"
  fi
  return 0
}

# Internal: file_present rule. Echo value on match, return 0; else 1.
_probe_rule_file_present() {
  local project_dir="$1" rule="$2"
  local file value path
  file="$(jq -r '.file' <<<"$rule")"
  value="$(jq -r '.value' <<<"$rule")"
  path="$project_dir/$file"
  [ -e "$path" ] || return 1
  printf '%s' "$value"
  return 0
}

# Internal: file_glob_count rule. Find candidate with the most matches
# (strictly > 0). On tie, the candidate declared earliest in the spec wins.
# Globs are evaluated via `find` with -name (matches basename only); leading
# "**/" is stripped. This is intentional — we want recursive basename match.
_probe_rule_file_glob_count() {
  local project_dir="$1" rule="$2"
  local n_candidates i glob value count best_count=-1 best_value=""
  n_candidates="$(jq '.candidates | length' <<<"$rule")"
  i=0
  while [ "$i" -lt "$n_candidates" ]; do
    glob="$(jq -r ".candidates[$i].glob"  <<<"$rule")"
    value="$(jq -r ".candidates[$i].value" <<<"$rule")"
    glob="${glob#'**/'}"
    count="$(find "$project_dir" -type f -name "$glob" 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$count" -gt "$best_count" ]; then
      best_count="$count"
      best_value="$value"
    fi
    i=$((i+1))
  done
  if [ "$best_count" -gt 0 ]; then
    printf '%s' "$best_value"
    return 0
  fi
  return 1
}

# Internal: command rule. Echo trimmed stdout on success and non-empty output.
# Honors the trust gate (3rd arg from _probe_eval_rule): when the spec is
# untrusted (loaded from $PROJECT_DIR), `command` rules are refused to prevent
# a tampered project-local spec from triggering arbitrary local execution.
_probe_rule_command() {
  local project_dir="$1" rule="$2" trusted="${3-0}"
  local cmd out
  if [ "$trusted" != "1" ]; then
    echo "probe_extract: refusing 'command' rule from untrusted spec" >&2
    return 1
  fi
  cmd="$(jq -r '.command' <<<"$rule")"
  [ -n "$cmd" ] && [ "$cmd" != "null" ] || return 1
  if ! out="$(cd "$project_dir" && bash -c "$cmd" 2>/dev/null)"; then
    return 1
  fi
  out="${out%"${out##*[![:space:]]}"}"
  out="${out#"${out%%[![:space:]]*}"}"
  [ -n "$out" ] || return 1
  printf '%s' "$out"
  return 0
}

# Internal: dispatch one rule. Echoes resolved value on match, returns 0.
# 3rd arg is the trust flag (1 = trusted spec, 0 = untrusted/project-local).
_probe_eval_rule() {
  local project_dir="$1" rule="$2" trusted="${3-0}"
  local rtype
  rtype="$(jq -r '.type' <<<"$rule")"
  case "$rtype" in
    file_regex)       _probe_rule_file_regex       "$project_dir" "$rule" ;;
    json_path)        _probe_rule_json_path        "$project_dir" "$rule" ;;
    file_present)     _probe_rule_file_present     "$project_dir" "$rule" ;;
    file_glob_count)  _probe_rule_file_glob_count  "$project_dir" "$rule" ;;
    command)          _probe_rule_command          "$project_dir" "$rule" "$trusted" ;;
    *) return 1 ;;
  esac
}

# probe_extract PROJECT_DIR PROBE_SPEC_JSON [TRUSTED]
#   TRUSTED: 1 if the spec was loaded from a trusted source (template cache or
#   trusted install), 0 (default) if it came from the project directory itself.
#   Untrusted specs cannot evaluate `command` rules — this prevents a tampered
#   project-local spec from triggering arbitrary local execution under audit.
probe_extract() {
  local project_dir="${1-}"
  local spec_path="${2-}"
  local trusted="${3-0}"
  if [ -z "$project_dir" ] || [ -z "$spec_path" ]; then
    echo "probe_extract: usage: probe_extract PROJECT_DIR PROBE_SPEC_JSON [TRUSTED]" >&2
    return 1
  fi
  if [ ! -d "$project_dir" ]; then
    return 0
  fi
  if [ ! -f "$spec_path" ]; then
    echo "probe_extract: spec not found: $spec_path" >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || {
    echo "probe_extract: jq required but not installed" >&2
    return 1
  }
  if ! jq -e . "$spec_path" >/dev/null 2>&1; then
    echo "probe_extract: spec is not valid JSON: $spec_path" >&2
    return 1
  fi

  local placeholders name n_rules i rule resolved
  placeholders="$(jq -r '.placeholders | keys_unsorted[]' "$spec_path")"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    n_rules="$(jq --arg n "$name" '.placeholders[$n].rules | length' "$spec_path")"
    i=0
    resolved=""
    while [ "$i" -lt "$n_rules" ]; do
      rule="$(jq --arg n "$name" --argjson i "$i" -c '.placeholders[$n].rules[$i]' "$spec_path")"
      if resolved="$(_probe_eval_rule "$project_dir" "$rule" "$trusted")"; then
        if [ -n "$resolved" ]; then
          printf '%s=%s\n' "$name" "$resolved"
          break
        fi
      fi
      resolved=""
      i=$((i+1))
    done
  done <<<"$placeholders"
  return 0
}
