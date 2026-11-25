#!/usr/bin/env bash
# Live CLI coding agent status monitor (hidden when no agents are running)
set -euo pipefail

# Match exact binary names to avoid false positives from shell wrappers or unrelated processes
EXACT_COUNT=$(pgrep -xc 'agy|opencode|claude' 2>/dev/null || true)
EXACT_COUNT=${EXACT_COUNT:-0}
AIDER_COUNT=$(pgrep -fc '/bin/aider([[:space:]]|$)' 2>/dev/null || true)
AIDER_COUNT=${AIDER_COUNT:-0}

RUNNING_AGENTS=$(( EXACT_COUNT + AIDER_COUNT ))
WAITING_HUMAN=0

if [[ -f /run/agent-waiting-human ]]; then
    WAITING_HUMAN=1
fi

if (( WAITING_HUMAN > 0 )); then
    printf '{"text":"🤖 ⚠ AGENT WAITING","class":"waiting","tooltip":"Agent waiting for confirmation"}\n'
elif (( RUNNING_AGENTS > 0 )); then
    printf '{"text":"🤖 %d active","class":"","tooltip":"Active CLI coding agents (agy, opencode, aider, claude)"}\n' "$RUNNING_AGENTS"
else
    echo '{"text":""}'
fi
