Run the full verification suite. Execute all steps and report results.

**EXECUTION RULES: read before running anything.**

1. **NEVER** chain `npm run build` into a compound `&&` command. The harness auto-backgrounds slow processes; chained commands silently stall and waste 10+ minutes. Run it as a **dedicated Bash call** with explicit `timeout: 600000`.
2. Run the fast suite as a single dedicated call. Prefer an umbrella runner (`bash tests/run-all.sh`) over an `&&` chain so each suite is its own process and per-suite failures are legible.
3. Run `npm run build` alone, foreground, with `timeout: 600000`. If it gets backgrounded, **immediately** read the task output file the harness returns.
4. Run post-build checks as a third dedicated call after the build completes.
5. If the fast suite reports a failure, re-run the failing suite directly (e.g. `bash tests/<suite>.sh`) for full per-suite stdout — the umbrella's `--quiet` mode collapses passing-suite output by design.

**Step 1: fast suite (single Bash call)**
```bash
npm run check
```

**Step 2: long build (dedicated Bash call, `timeout: 600000`, never chained)**
```bash
npm run build
```

**Step 3: post-build verification + regressions (single Bash call)**
```bash
test -f dist/index.js && test -f dist/scraper.js && test -f dist/session-identity.js && node -e "import('./dist/scraper.js').then((m) => { if (typeof m.scrapeEvents !== 'function') { console.error('scrapeEvents export missing'); process.exit(1) } })" && ! grep -rn "company=extremeice" src/scraper.ts src/evaluator.ts src/config.ts src/index.ts src/commands/
```

Report which checks passed and which failed. If all pass, say "All verification checks pass." If any fail, list the failures with details.
