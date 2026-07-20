#!/bin/bash
# Auto-allow python3 -c / python -c commands (data inspection scripts)
# These trigger a false-positive security warning about "quoted newline + #-prefixed line"
COMMAND=$(jq -r '.tool_input.command // ""')
if echo "$COMMAND" | head -1 | grep -qE '^python3?\s+-c\s'; then
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"Auto-allowed python -c inline script"}}'
fi
