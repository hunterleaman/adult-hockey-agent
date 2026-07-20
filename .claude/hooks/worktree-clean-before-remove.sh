#!/bin/bash
set -euo pipefail

# Helper: clean a worktree directory, then remove it via git.
# Called by session-start-orient.sh during GC and available for
# manual cleanup of stuck worktrees.
#
# Usage: bash worktree-clean-before-remove.sh <worktree-path>
#
# Steps:
#   1. git worktree remove --force <path>
#   2. Fallback: rm -rf <path> && git worktree prune

WT_PATH="${1:-}"

if [ -z "$WT_PATH" ]; then
  echo "Usage: worktree-clean-before-remove.sh <worktree-path>" >&2
  exit 1
fi

# Resolve to absolute path
if [[ "$WT_PATH" != /* ]]; then
  WT_PATH="$(cd "$(dirname "$WT_PATH")" 2>/dev/null && pwd)/$(basename "$WT_PATH")"
fi

# Safety: only operate on paths under .claude/worktrees/
case "$WT_PATH" in
  */.claude/worktrees/*)
    ;;
  *)
    echo "BLOCKED: worktree-clean-before-remove.sh only operates on .claude/worktrees/ paths" >&2
    echo "  Got: $WT_PATH" >&2
    exit 1
    ;;
esac

if [ ! -d "$WT_PATH" ]; then
  # Directory already gone, just prune the registration
  git worktree prune 2>/dev/null || true
  exit 0
fi

# Try git worktree remove
if git worktree remove --force "$WT_PATH" 2>/dev/null; then
  exit 0
fi

# Fallback: nuke and prune
rm -rf "$WT_PATH" 2>/dev/null || true
git worktree prune 2>/dev/null || true
exit 0
