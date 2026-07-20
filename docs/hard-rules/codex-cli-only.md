# Codex from Nested Agents: CLI ONLY (HARD RULE)

`codex` review from inside a worktree-isolated `Agent` MUST go through the `codex` CLI directly via `Bash`. Do NOT invoke the `codex:rescue` / `codex:setup` Skills, and do NOT dispatch the `codex:codex-rescue` subagent from a nested Agent. The rescue subagent silently no-ops on env-var mismatch (`CLAUDE_PLUGIN_ROOT` is not propagated to nested subprocesses -> `node "${CLAUDE_PLUGIN_ROOT}/scripts/codex-companion.mjs"` resolves to `/scripts/...` -> `MODULE_NOT_FOUND` -> exit 1, then `codex-rescue.md:42`'s "if Bash fails return nothing" rule swallows the failure). Empty output from a nested-Agent codex run is observationally identical to "codex found nothing": masking real defects under a false-clean signal.

- **Rule:** Inside any worktree-isolated Agent, invoke codex via `codex exec ...` (or `node "$CODEX" review ...` once `$CODEX` is resolved per `commands/review-pr.md`). Never the `codex:rescue` Skill, never the `codex:codex-rescue` subagent.
- **Verification:** Every nested-Agent's status report MUST quote the exact `codex` CLI command it ran. An empty codex result without a CLI transcript is the silent-failure signature and invalidates the review.
- **Main session:** the rescue Skill / subagent route still works in the main session (where `CLAUDE_PLUGIN_ROOT` is set): see `commands/review-pr.md` Stage 3 fallback's `MAIN-SESSION-ONLY` block.
- **Why it matters:** the project's collapsed-review pipeline depends on Codex catching real issues (8 consecutive MED+ catches as of bundle 7). A silent-failure regression masquerading as a clean review breaks that signal.
- **Pitfall reference:** `docs/PITFALLS.md` -> "Codex review must use CLI in nested Agent subprocesses (silent-failure trap)".
