#!/usr/bin/env bash
# Live agent status monitor (agy, opencode, claude, aider)
set -euo pipefail

RUNNING_AGENTS=0
WAITING_HUMAN=0

# Check process table for active CLI agent instances
RUNNING_AGENTS=$(pgrep -fc 'agy|opencode|claude|aider' 2>/dev/null || echo 0)

# Check if any agent has flagged a pending human decision
if [ -f /run/agent-waiting-human ]; then
    WAITING_HUMAN=1
fi

CLASS=""
if (( WAITING_HUMAN > 0 )); then
    CLASS="waiting"
    TEXT="🤖 ⚠ AGENT WAITING HUMAN"
elif (( RUNNING_AGENTS > 0 )); then
    TEXT="🤖 ${RUNNING_AGENTS} active"
else
    TEXT="🤖 Idle"
fi

printf '{"text":"%s","class":"%s","tooltip":"Active coding agents"}\n' "$TEXT" "$CLASS"
