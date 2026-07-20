#!/bin/bash
set -euo pipefail

if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  exit 0
fi

BRANCH=$(git branch --show-current 2>/dev/null || echo "")
DIRTY=$(git status --porcelain 2>/dev/null | head -1 || echo "")

if [ "$BRANCH" != "main" ] && [ -n "$DIRTY" ]; then
  echo "" >&2
  echo "╔══════════════════════════════════════════════════════════╗" >&2
  echo "║  WARNING: Uncommitted changes on branch '$BRANCH'" >&2
  echo "║                                                          ║" >&2
  echo "║  Before ending this session:                             ║" >&2
  echo "║    1. npm run check && npm run build" >&2
  echo "║    2. Update CLAUDE.md + docs/{DECISIONS,CHANGELOG}.md   ║" >&2
  echo "║    3. git add -A && git commit (conventional format)     ║" >&2
  echo "║    4. git push origin $BRANCH" >&2
  echo "║                                                          ║" >&2
  echo "║  Or run /ship to execute the full sequence.              ║" >&2
  echo "╚══════════════════════════════════════════════════════════╝" >&2
  echo "" >&2
fi

PITFALLS="docs/PITFALLS.md"
HAS_FIXES=$(git log --oneline --since="4 hours ago" 2>/dev/null | grep -c '^[a-f0-9]* fix(' || true)
if [ -e "$PITFALLS" ]; then
  PITFALLS_TOUCHED=$(git diff --name-only HEAD~"${HAS_FIXES:-0}" 2>/dev/null | grep -c "$(basename "$PITFALLS")" || true)
  if [ "${HAS_FIXES:-0}" -gt 0 ] && [ "${PITFALLS_TOUCHED:-0}" -eq 0 ]; then
    echo "NOTE: This session had fix commits but no $PITFALLS update. Run /learn if a lesson was discovered." >&2
  fi
fi

exit 0
