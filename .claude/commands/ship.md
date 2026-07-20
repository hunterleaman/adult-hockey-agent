# CANONICAL-ONLY-START
<!-- TEMPLATE PLACEHOLDERS:
  {{PROJECT_NAME}}:            human-readable project name.
  {{QUALITY_GATE_FAST_STEPS}}: fast test/validate commands.
  {{LONG_BUILD_COMMAND}}:      slow build command (run as dedicated Bash call).
  {{POST_BUILD_CHECKS}}:       post-build verification + regression greps.
-->
# CANONICAL-ONLY-END
Run the {{PROJECT_NAME}} shipping sequence for the current feature branch. Execute ALL steps in order. Do not skip any. If any step fails, stop and report.

## 1. Full Quality Gate
```bash
{{QUALITY_GATE_FAST_STEPS}}
```
```bash
{{LONG_BUILD_COMMAND}}
```
```bash
{{POST_BUILD_CHECKS}}
```

## 2. Docs Update
Update these files if any changes were made this session:
- `CLAUDE.md` "Current State" section
- `docs/PITFALLS.md` (if new lessons learned)
- `docs/DECISIONS.md` (if architectural decisions were made)
- `docs/CHANGELOG.md` (if user-visible changes were made)

## 3. Commit and Push
```bash
git add -A
git status
```
Commit with conventional format: `{type}({scope}): {description}`
Push: `git push origin HEAD`

## 4. Create/Update PR

If no PR exists for this branch, create one:
```bash
gh pr create --title "{title}" --body "Closes #{issue}"
```

## 5. Report
Summarize: what was accomplished, which tests passed, what the operator should do next.
