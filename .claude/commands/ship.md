Run the adult-hockey-agent shipping sequence for the current feature branch. Execute ALL steps in order. Do not skip any. If any step fails, stop and report.

## 1. Full Quality Gate
```bash
npm run check
```
```bash
npm run build
```
```bash
test -f dist/index.js && test -f dist/scraper.js && test -f dist/session-identity.js && node -e "import('./dist/scraper.js').then((m) => { if (typeof m.scrapeEvents !== 'function') { console.error('scrapeEvents export missing'); process.exit(1) } })" && ! grep -rn "company=extremeice" src/scraper.ts src/evaluator.ts src/config.ts src/index.ts src/commands/
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
