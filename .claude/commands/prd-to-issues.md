## Subagent delegation reminder
Before any Read/Grep/Bash in this command's main session, ask: "Can a subagent return a 3-line summary?" If yes, delegate via the `Agent` tool with subagent_type `Explore` for codebase queries or `general-purpose` for multi-step research. Reserve the main session's context for orchestration and operator-facing decisions only.

---

## Phase-2 gate (mandatory — Phase-3 entry point; PRD #57)

`/prd-to-issues` is the Phase-3 entry point of the development pipeline. Before proposing or filing any child issues, validate the workstream's Phase-2 (PRD) evidence is present.

**Override surface:** `--skip-phase-gate REASON="<text>"` is accepted at the surface to bypass validation for retrofit / emergency cases. Slice #62 lands the append-only audit log; on a valid override, `_workstream_log_override` is invoked BEFORE decomposition begins, so every accepted bypass is recorded in `.workstream/_overrides.log` (TSV, exactly four fields per line, R4-sanitized). Empty reason refuses.

### 0a. Pre-flight: validate Phase-2 evidence

1. Resolve the active workstream slug:
   ```bash
   bash -c 'source lib/workstream.sh && _workstream_resolve_slug'
   ```
   Cascade: `--slug=<foo>` arg wins, then strict branch regex `^[0-9]+-(.+)$`, then exactly-one-open `.workstream/*.md`. Exit 2 = bootstrap-empty exemption (R6); proceed without the gate. Exit 1 = refuse with the lib's diagnostic.
2. If the operator passed `--skip-phase-gate REASON="..."`:
   - Reason MUST be non-empty. Empty reason -> refuse with: `prd-to-issues: --skip-phase-gate requires a non-empty REASON= value`.
   - Slice #62: append the override to `.workstream/_overrides.log` BEFORE skipping the validate call. Reason is passed as a NON-FORMAT argument (the helper uses `printf '%s\n'` internally with reason as the data argument). No slash-command-layer eval / `$()` / backtick re-evaluation. The helper hard-fails (rc != 0) if the post-sanitize reason is empty:
     ```bash
     if ! bash -c 'source lib/workstream.sh && _workstream_log_override "$1" "$2" "$3"' _ \
         prd-to-issues "<slug>" "<reason>"; then
       echo "/prd-to-issues: REFUSED — _workstream_log_override failed (see stderr above)." >&2
       exit 1
     fi
     ```
     Then skip the validate call and note the override in your status line.
3. Otherwise, run the Phase-2 validate. Use absolute paths from the repo root:
   ```bash
   bash -c 'source lib/workstream.sh && _workstream_validate_phase <slug> issues'
   ```
   - Exit 0 -> proceed to step 1 (Locate the PRD).
   - Non-zero -> REFUSE with this message and stop:
     > `/prd-to-issues refused: workstream <slug> has no Phase-2 (PRD) evidence (phases.prd.completed_at unset or phases.prd.artifact missing). Run /write-a-prd first to formalize the PRD, or pass --skip-phase-gate REASON="..." for retrofit cases.`

Only after step 3 passes (or the override path is taken) may you proceed below.

**Canonical reason format** for grandfathering legacy in-flight branches without PRD artifacts: `RETROFIT-LEGACY-BRANCH: <branch-name> predates gate`. See PLAYBOOK §5d.

---

Break a PRD into independently-grabbable GitHub issues using vertical slices (tracer bullets).

## Process

### 1. Locate the PRD

Ask the user for the PRD GitHub issue number (or URL).

If the PRD is not already in your context window, fetch it with `gh issue view <number>` (with comments).

### 2. Explore the codebase (optional)

If you have not already explored the codebase, do so to understand the current state of the code. Issue titles and descriptions should use the project's domain glossary vocabulary, and respect ADRs in the area you're touching.

### 3. Draft vertical slices

Break the PRD into **tracer bullet** issues. Each issue is a thin vertical slice that cuts through ALL integration layers end-to-end, NOT a horizontal slice of one layer.

Slices may be 'HITL' or 'AFK'. HITL slices require human interaction, such as an architectural decision or a design review. AFK slices can be implemented and merged without human interaction. Prefer AFK over HITL where possible.

<vertical-slice-rules>
- Each slice delivers a narrow but COMPLETE path through every layer (schema, API, UI, tests)
- A completed slice is demoable or verifiable on its own
- Prefer many thin slices over few thick ones
</vertical-slice-rules>

### 4. Quiz the user

Present the proposed breakdown as a numbered list. For each slice, show:

- **Title**: short descriptive name
- **Type**: HITL / AFK
- **Blocked by**: which other slices (if any) must complete first
- **User stories covered**: which user stories from the PRD this addresses

Ask the user:

- Does the granularity feel right? (too coarse / too fine)
- Are the dependency relationships correct?
- Should any slices be merged or split further?
- Are the correct slices marked as HITL and AFK?

Iterate until the user approves the breakdown.

### 5. Create the GitHub issues

For each approved slice, create a GitHub issue using `gh issue create`. Use the issue body template below. Apply the `needs-triage` label so each issue enters the normal triage flow.

Create issues in dependency order (blockers first) so you can reference real issue numbers in the "Blocked by" field.

<issue-template>
## Parent PRD

#<prd-issue-number>

## What to build

A concise description of this vertical slice. Describe the end-to-end behavior, not layer-by-layer implementation. Reference specific sections of the parent PRD rather than duplicating content.

## Acceptance criteria

- [ ] Criterion 1
- [ ] Criterion 2
- [ ] Criterion 3

## Blocked by

- Blocked by #<issue-number> (if any)

Or "None - can start immediately" if no blockers.

## User stories addressed

Reference by number from the parent PRD:

- User story 3
- User story 7

</issue-template>

Do NOT close or modify the parent PRD issue.

### 6. Advance the workstream ledger (mandatory)

After every approved child issue has been created successfully, atomically write Phase-3 (issues) advance to the workstream file. Pass each created issue as `issue:<N>` so they land as a YAML sequence under `phases.issues.artifacts`. The library writes `started_at`, `completed_at`, and the `artifacts:` array in a single atomic frontmatter rewrite (no partial state).

```bash
bash -c 'source lib/workstream.sh && _workstream_advance <slug> issues "issue:<N1>" "issue:<N2>" ... "issue:<Nk>"'
```

- One `"issue:<N>"` argument per created child; even with a single child the library writes the plural `artifacts:` sequence (stable shape for downstream consumers like CI and `/orient`).
- Skip this step ONLY if the override path was taken in step 0a; surface that the ledger was NOT advanced in your status line so the operator can correct the override after the fact.
- If `_workstream_advance` returns non-zero, surface the diagnostic verbatim and stop. Do NOT retry-by-clobber — the rewriter is atomic by construction.
