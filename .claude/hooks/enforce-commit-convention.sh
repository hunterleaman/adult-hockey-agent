#!/bin/bash
set -euo pipefail

# Read JSON from stdin (Claude Code passes tool input as JSON)
INPUT=$(cat)

# Extract the bash command using grep/sed (no jq dependency)
# The JSON has "command": "..." in tool_input
COMMAND=$(echo "$INPUT" | grep -oE '"command"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' | head -1 | sed 's/^"command"[[:space:]]*:[[:space:]]*"//;s/"$//')

# Only check git commit commands
if ! echo "$COMMAND" | grep -qE '^\s*git\s+commit'; then
  exit 0
fi

# Extract commit message from -m flag
# Handle both double-quoted and single-quoted messages
MSG=""
if echo "$COMMAND" | grep -qE '\-m[[:space:]]+"'; then
  MSG=$(echo "$COMMAND" | sed -n 's/.*-m[[:space:]]*"\([^"]*\)".*/\1/p')
elif echo "$COMMAND" | grep -qE "\-m[[:space:]]+'" ; then
  MSG=$(echo "$COMMAND" | sed -n "s/.*-m[[:space:]]*'\([^']*\)'.*/\1/p")
fi

if [ -z "$MSG" ]; then
  # No -m flag or can't parse; might be using editor, allow it
  exit 0
fi

# Validate conventional commit format: type(scope): description
# Types: feat, fix, docs, refactor, deploy, test, chore
if ! echo "$MSG" | grep -qE '^(feat|fix|docs|refactor|deploy|test|chore)(\([a-z0-9/-]+\))?: .+'; then
  echo "BLOCKED: Commit message does not follow conventional format." >&2
  echo "Required: {type}({scope}): {description}" >&2
  echo "Types: feat, fix, docs, refactor, deploy, test, chore" >&2
  echo "Got: '$MSG'" >&2
  exit 2
fi

exit 0
