## Subagent delegation reminder
Before any Read/Grep/Bash in this command's main session, ask: "Can a subagent return a 3-line summary?" If yes, delegate via the `Agent` tool with subagent_type `Explore` for codebase queries or `general-purpose` for multi-step research. Reserve the main session's context for orchestration and operator-facing decisions only.

---

## Workstream registration (mandatory — Phase-1 evidence; PRD #57)

`/grill-me` is the Phase-1 entry point of the development pipeline. Subsequent phases (`/write-a-prd`, `/prd-to-issues`) refuse to run without Phase-1 evidence. The evidence is `.workstream/<slug>.md` — a per-workstream state file that doubles as the grill transcript and the phase ledger.

**Before** beginning the interview, atomically create the workstream file:

1. Pick a kebab-case slug for the workstream. Constraints: `^[a-z0-9-]+$`, length 1..64, no leading/trailing `-`. (Operator names it; mirror their language.)
2. Distill the operator's request into a one-line topic.
3. Run, with absolute paths from the repo root:
   ```bash
   bash -c 'source lib/workstream.sh && _workstream_init <slug> "<topic>"'
   ```
4. **On collision** (`set -C` rejects an existing file), abort the grill with the lib's diagnostic. Do NOT clobber. Ask the operator whether to (a) pick a new slug, (b) resume the existing workstream, or (c) close the existing one before re-running.

The init writes minimal frontmatter (`slug`, `topic`, `created_at`, `started_at`, `phases.grill.started_at`, empty `phases.{prd,issues,closed}` stubs, `closed_at: null`). The grill transcript itself is appended to the file's body during the interview — operator-driven prose, not auto-generated.

**Why atomic:** two parallel `/grill-me` sessions on the same slug would otherwise silently clobber each other; `set -C` (O_EXCL) makes the second creation fail loudly.

### Phase-gate override (escape hatch — slice #62)

When the operator passes `--skip-phase-gate REASON="..."`, skip the workstream init/validate step AND log the bypass to the committed audit trail. Wiring rules:

- **Empty / missing REASON refused.** If `REASON=""` (empty) or the flag is present but no `REASON=` argument is passed, refuse with: `--skip-phase-gate requires a non-empty REASON="..." argument`. Do NOT silently fall back to the gated path.
- **On valid override**, append a single deterministic line to `.workstream/_overrides.log` BEFORE proceeding:
  ```bash
  bash -c 'source lib/workstream.sh && _workstream_log_override grill-me <slug-or-placeholder> "<reason>"'
  ```
  The slug for `/grill-me` is the new slug the operator wanted to use (or the literal `pending` if no slug context exists yet — the helper accepts any R1-valid slug). The reason text is forwarded verbatim to the helper (no shell-eval, no `$(...)` expansion at the slash-command layer). The helper sanitizes via R4 (strips control chars, ANSI escapes, embedded newlines/tabs) and atomically appends.
- **Canonical reason format** for grandfathering legacy in-flight branches: `RETROFIT-LEGACY-BRANCH: <branch-name> predates gate`. See PLAYBOOK §5d for the documented escape-hatch contract.
- After logging, proceed with the grill interview without the workstream-file init step. The audit log is the operator-trust evidence that this skip happened.

---

Interview me relentlessly about every aspect of this plan until we reach a shared understanding. Walk down each branch of the design tree, resolving dependencies between decisions one-by-one. For each question, provide your recommended answer.

Ask the questions one at a time.

If a question can be answered by exploring the codebase, explore the codebase instead.
