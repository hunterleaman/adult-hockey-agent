Record a lesson learned. $ARGUMENTS is the lesson text.

## Steps

1. **Classify** the lesson:
   - Engineering lesson (code pattern, build gotcha) → append to `docs/PITFALLS.md`
   - Workflow/agent behavior lesson → create or update memory feedback file in auto-memory directory

2. **Read** the target file to find the correct insertion point.

3. **Append** using the established format:
   - docs/PITFALLS.md: `- **{Title}.** {Explanation}. {Why it matters}.`
   - Memory file: follow existing format

4. **Commit**: `docs(pitfalls): {first 50 chars of lesson}` (if pitfalls) or skip commit (if memory-only).

If $ARGUMENTS is empty, ask what the lesson is.
