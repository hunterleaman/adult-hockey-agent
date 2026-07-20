## Subagent delegation reminder
Before any Read/Grep/Bash in this command's main session, ask: "Can a subagent return a 3-line summary?" If yes, delegate via the `Agent` tool with subagent_type `Explore` for codebase queries or `general-purpose` for multi-step research. Reserve the main session's context for orchestration and operator-facing decisions only.

---

## Phase-1 gate (mandatory — PRD #57, slice #59)

`/write-a-prd` is the Phase-2 entry point of the development pipeline. It REFUSES to run cold. Phase-1 evidence (`.workstream/<slug>.md` with `phases.grill.started_at` set) MUST exist first — produced by `/grill-me` (or `/grill-with-docs`).

### Override flag (escape hatch — slice #62)

Operators may bypass the gate with `--skip-phase-gate REASON="<rationale>"`. The reason MUST be non-empty; an empty reason is refused. On valid override, the helper appends a single TSV line to the append-only `.workstream/_overrides.log` BEFORE PRD synthesis proceeds. The reason is forwarded verbatim to `_workstream_log_override` (no slash-command-layer eval); the helper applies R4 sanitization (strips control chars + ANSI escapes), enforces a byte cap (default 1000), and refuses empty-after-sanitize. Canonical reason format for grandfathering legacy in-flight branches without grill artifacts: `RETROFIT-LEGACY-BRANCH: <branch-name> predates gate`. See PLAYBOOK §5d.

### Pre-flight sequence (run BEFORE any interview / synthesis work)

Run, with absolute paths from the repo root. `"$@"` MUST be threaded into the resolver and the override-parser so the operator's `--slug=<foo>` and `--skip-phase-gate REASON="..."` flags are honored:

```bash
# Step 1 — resolve the active workstream slug. Cascade per lib/workstream.sh:
#   --slug=<foo> wins; else branch regex `^[0-9]+-(.+)$`; else exactly-one-open;
#   else interactive disambiguate (TTY); else refuse.
# Pass "$@" so a caller-supplied --slug=<foo> is respected (Codex MED on PR #59).
SLUG="$(bash -c 'source lib/workstream.sh && _workstream_resolve_slug "$@"' _ "$@")" || {
  echo "/write-a-prd: cannot resolve workstream slug (lib stderr above)." >&2
  echo "Hint: pass --slug=<name> or run /grill-me to start a new workstream." >&2
  exit 1
}

# Step 2 — honor the --skip-phase-gate REASON="..." override if present in
# this command invocation's argv. The helper exits 0 with reason on stdout if
# valid, exit 2 if reason is empty/whitespace (REFUSE), exit 1 if no override.
# Capture stdout (reason) but let stderr surface to the operator (Codex MED).
SKIP_REASON="$(bash -c 'source lib/workstream.sh && _workstream_skip_flag_reason "$@"' _ "$@" 2>/dev/null)"
SKIP_RC=$?
case "$SKIP_RC" in
  0)
    echo "/write-a-prd: phase gate SKIPPED via --skip-phase-gate" >&2
    echo "             reason: $SKIP_REASON" >&2
    # Slice #62: append the override to .workstream/_overrides.log BEFORE
    # proceeding to synthesis. Reason is passed as a NON-FORMAT argument to
    # _workstream_log_override (the helper uses `printf '%s\n'` internally
    # with reason as the data argument). No slash-command-layer eval / $() /
    # backtick re-evaluation of the reason. The helper hard-fails if the
    # post-sanitize reason is empty, so a vacuous override is impossible to log.
    if ! bash -c 'source lib/workstream.sh && _workstream_log_override "$1" "$2" "$3"' _ \
        write-a-prd "$SLUG" "$SKIP_REASON"; then
      echo "/write-a-prd: REFUSED — _workstream_log_override failed (see stderr above)." >&2
      echo "             Override audit log was NOT written; refusing to skip the gate" >&2
      echo "             without a valid audit entry." >&2
      exit 1
    fi
    ;;
  2)
    echo "/write-a-prd: --skip-phase-gate requires non-empty REASON=\"...\"" >&2
    echo "             refusing — supply a rationale or run /grill-me first" >&2
    exit 1
    ;;
  *)
    # No override flag — run the validate gate. Surface lib stderr verbatim
    # so the operator sees the SPECIFIC failure (missing file vs. invalid
    # slug vs. nonconformant frontmatter) instead of a one-size-fits-all
    # message (Codex MED on PR #59 — refusal-message clarity).
    if ! bash -c "source lib/workstream.sh && _workstream_validate_phase '$SLUG' prd"; then
      echo "" >&2
      echo "/write-a-prd: REFUSED — Phase-1 gate failed for slug='$SLUG' (see lib diagnostic above)." >&2
      echo "Most common cause: no .workstream/$SLUG.md yet. Run /grill-me first to" >&2
      echo "produce the grill transcript + phase ledger, then re-run /write-a-prd." >&2
      echo "" >&2
      echo "Emergency bypass: --skip-phase-gate REASON=\"<rationale>\"" >&2
      exit 1
    fi
    ;;
esac
```

The validate call is **read-only** (Q5 contract): it never mutates the workstream file. The post-success advance (below) is the only writer in this command for the workstream ledger; `_workstream_log_override` writes only to `.workstream/_overrides.log` and is invoked only on the override branch.

---

Take the current conversation context and codebase understanding and produce a PRD, then submit it as a GitHub issue. Do NOT interview the user — synthesize what you already know from prior `/grill-me` or `/grill-with-docs` sessions. If the conversation has no spec context, ask the user for one paragraph describing the problem and proposed solution before proceeding.

## Process

1. Explore the repo to understand the current state of the codebase, if you haven't already. Use the project's domain glossary vocabulary throughout the PRD, and respect any ADRs in the area you're touching.

2. Sketch out the major modules you will need to build or modify to complete the implementation. Actively look for opportunities to extract deep modules that can be tested in isolation.

A deep module (as opposed to a shallow module) is one which encapsulates a lot of functionality in a simple, testable interface which rarely changes.

Check with the user that these modules match their expectations. Check with the user which modules they want tests written for.

3. Write the PRD using the template below, then create a GitHub issue with `gh issue create`. Apply the `needs-triage` label so it enters the normal triage flow.

4. **Post-success ledger advance (mandatory).** Immediately after `gh issue create` returns the new PRD issue number, atomically advance the workstream ledger so subsequent gates (slice #60 `/prd-to-issues`) can see Phase-2 completion:

```bash
# PRD_ISSUE=<the integer gh issue create returned>. Guard the value as numeric
# BEFORE interpolating into the bash -c command — `gh` can return non-issue
# stderr text on misconfiguration; without the guard, a non-numeric value
# could break the single-quoted artifact string (Codex LOW on this PR).
# Trim ONLY leading/trailing whitespace (not interior) so " 123 " normalizes
# to "123" but "1 2 3" still fails the guard. `tr -d` would strip interior
# whitespace and admit garbage like "1 2 3" → "123" (Codex LOW pass-3).
PRD_ISSUE_TRIMMED="$(printf '%s' "$PRD_ISSUE" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
case "$PRD_ISSUE_TRIMMED" in
  ''|*[!0-9]*)
    echo "WARNING: PRD_ISSUE is not numeric ('$PRD_ISSUE'); refusing to advance ledger." >&2
    echo "         Verify the gh issue create output and re-run advance manually." >&2
    ;;
  *)
    bash -c "source lib/workstream.sh && _workstream_advance '$SLUG' prd 'issue:$PRD_ISSUE_TRIMMED'"
    ;;
esac
```

The advance writes `phases.prd.started_at`, `phases.prd.completed_at`, and `phases.prd.artifact = "issue:$PRD_ISSUE"` in a single atomic frontmatter rewrite (per-slug `flock`-protected on hosts with `flock`; naked-fallback otherwise per R2). No partial writes — on failure, the original file is preserved byte-for-byte.

If the advance fails, surface a loud warning so the operator can re-run it manually:

```
WARNING: PRD issue #$PRD_ISSUE was created but the workstream ledger advance failed.
         Manually run:  bash -c "source lib/workstream.sh && _workstream_advance '$SLUG' prd 'issue:$PRD_ISSUE'"
```

<prd-template>

## Problem Statement

The problem that the user is facing, from the user's perspective.

## Solution

The solution to the problem, from the user's perspective.

## User Stories

A LONG, numbered list of user stories. Each user story should be in the format of:

1. As an <actor>, I want a <feature>, so that <benefit>

<user-story-example>
1. As a mobile bank customer, I want to see balance on my accounts, so that I can make better informed decisions about my spending
</user-story-example>

This list of user stories should be extremely extensive and cover all aspects of the feature.

## Implementation Decisions

A list of implementation decisions that were made. This can include:

- The modules that will be built/modified
- The interfaces of those modules that will be modified
- Technical clarifications from the developer
- Architectural decisions
- Schema changes
- API contracts
- Specific interactions

Do NOT include specific file paths or code snippets. They may end up being outdated very quickly.

## Testing Decisions

A list of testing decisions that were made. Include:

- A description of what makes a good test (only test external behavior, not implementation details)
- Which modules will be tested
- Prior art for the tests (i.e. similar types of tests in the codebase)

## Out of Scope

A description of the things that are out of scope for this PRD.

## Further Notes

Any further notes about the feature.

</prd-template>
