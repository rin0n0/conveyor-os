#!/usr/bin/env bash
# Live pueue background task status (hidden when idle)
set -euo pipefail

if ! command -v pueue >/dev/null 2>&1; then
    echo '{"text":""}'
    exit 0
fi

STATUS_JSON=$(pueue status --json 2>/dev/null || echo "{}")
RUNNING=$(grep -o '"Running"' <<<"$STATUS_JSON" | wc -l || echo 0)
QUEUED=$(grep -o '"Queued"' <<<"$STATUS_JSON" | wc -l || echo 0)

if (( RUNNING == 0 && QUEUED == 0 )); then
    echo '{"text":""}'
    exit 0
fi

CLASS=""
if (( RUNNING > 0 )); then
    CLASS="running"
fi

TEXT="⏳ Tasks: ${RUNNING} run | ${QUEUED} queued"
printf '{"text":"%s","class":"%s","tooltip":"Background pueue tasks"}\n' "$TEXT" "$CLASS"
