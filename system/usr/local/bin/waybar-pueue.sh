#!/usr/bin/env bash
# Live pueue background task status for Qwen3.6 MoE batch jobs
set -euo pipefail

if ! command -v pueue >/dev/null 2>&1; then
    echo '{"text":"⏳ pueue: n/a"}'
    exit 0
fi

STATUS_JSON=$(pueue status --json 2>/dev/null || echo "{}")
RUNNING=$(echo "$STATUS_JSON" | grep -c '"status":"Running"' || true)
QUEUED=$(echo "$STATUS_JSON" | grep -c '"status":"Queued"' || true)

CLASS=""
if (( RUNNING > 0 )); then
    CLASS="running"
fi

TEXT="⏳ MoE Queue: ${RUNNING} run | ${QUEUED} queued"
printf '{"text":"%s","class":"%s","tooltip":"Background pueue batch tasks"}\n' "$TEXT" "$CLASS"
