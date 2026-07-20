# CANONICAL-ONLY-START
<!-- TEMPLATE PLACEHOLDERS:
  {{QUALITY_GATE_FAST_STEPS}}: fast test/lint/validate command(s). Prefer a single umbrella runner (e.g. `bash tests/run-all.sh`) over a chained `&&` invocation — chained slow commands silently stall under harness auto-backgrounding.
  {{LONG_BUILD_COMMAND}}:      the slow build command (e.g., "npm run build").
  {{LONG_BUILD_TIMEOUT_MS}}:   timeout in ms for the long build (e.g., 600000).
  {{POST_BUILD_CHECKS}}:       post-build verification + regression greps, chained with &&.
-->
# CANONICAL-ONLY-END
Run the full verification suite. Execute all steps and report results.

**EXECUTION RULES: read before running anything.**

1. **NEVER** chain `{{LONG_BUILD_COMMAND}}` into a compound `&&` command. The harness auto-backgrounds slow processes; chained commands silently stall and waste 10+ minutes. Run it as a **dedicated Bash call** with explicit `timeout: {{LONG_BUILD_TIMEOUT_MS}}`.
2. Run the fast suite as a single dedicated call. Prefer an umbrella runner (`bash tests/run-all.sh`) over an `&&` chain so each suite is its own process and per-suite failures are legible.
3. Run `{{LONG_BUILD_COMMAND}}` alone, foreground, with `timeout: {{LONG_BUILD_TIMEOUT_MS}}`. If it gets backgrounded, **immediately** read the task output file the harness returns.
4. Run post-build checks as a third dedicated call after the build completes.
5. If the fast suite reports a failure, re-run the failing suite directly (e.g. `bash tests/<suite>.sh`) for full per-suite stdout — the umbrella's `--quiet` mode collapses passing-suite output by design.

**Step 1: fast suite (single Bash call)**
```bash
{{QUALITY_GATE_FAST_STEPS}}
```

**Step 2: long build (dedicated Bash call, `timeout: {{LONG_BUILD_TIMEOUT_MS}}`, never chained)**
```bash
{{LONG_BUILD_COMMAND}}
```

**Step 3: post-build verification + regressions (single Bash call)**
```bash
{{POST_BUILD_CHECKS}}
```

Report which checks passed and which failed. If all pass, say "All verification checks pass." If any fail, list the failures with details.
