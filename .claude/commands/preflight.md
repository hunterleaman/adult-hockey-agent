Pre-flight verification before multi-agent dispatch or deployment. Mandatory before `/dispatch-wave`.

Run ALL checks and report pass/fail for each:

```bash
# 1. Clean tree
git status --porcelain

# 2. On main
git branch --show-current

# 3. Up to date
git fetch origin
git rev-list HEAD..origin/main --count

# 4. Default branch
git remote show origin | grep 'HEAD branch'

# 5. Stale branches
git branch --merged main | grep -v '\*\|main'

# 6. Stale worktrees
git worktree list

# 7. Open PR conflicts
gh pr list --json number,title,mergeable --limit 20
```

Then run `/verify` for the full quality gate.

## Output Format

```
Pre-Flight Results:
  [PASS] Clean tree
  [PASS] On main
  [PASS] Up to date with origin
  [PASS] Default branch is main
  [PASS] No stale branches
  [PASS] No stale worktrees
  [PASS] No conflicting PRs
  [PASS] Quality gate passes

All clear. Ready to dispatch.
```

If ANY check fails:
- Report the failure with details
- Fix it automatically if possible (clean stale branches, prune worktrees)
- Re-run the failed check to confirm
- If not auto-fixable, report what the operator needs to do

Do NOT proceed with dispatch until all checks pass.
