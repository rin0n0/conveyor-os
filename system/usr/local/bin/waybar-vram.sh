#!/usr/bin/env bash
# Live VRAM reader for NVIDIA, AMD, or CPU-only modes
set -euo pipefail

TEXT="GPU: N/A"
ALT="none"
CLASS=""

if command -v nvidia-smi >/dev/null 2>&1; then
    USED=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -n1 2>/dev/null || echo 0)
    TOTAL=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -n1 2>/dev/null || echo 0)
    if (( TOTAL > 0 )); then
        USED_GB=$(awk "BEGIN {printf \"%.1f\", $USED/1024}")
        TOTAL_GB=$(awk "BEGIN {printf \"%.1f\", $TOTAL/1024}")
        PERCENT=$(( USED * 100 / TOTAL ))
        TEXT="󰍹 ${USED_GB}G/${TOTAL_GB}G"
        if (( PERCENT > 90 )); then
            CLASS="critical"
        elif (( PERCENT > 75 )); then
            CLASS="warning"
        fi
    fi
elif [ -d /sys/class/drm ]; then
    for f in /sys/class/drm/card*/device/mem_info_vram_used; do
        if [ -f "$f" ]; then
            U_BYTES=$(cat "$f" 2>/dev/null || echo 0)
            T_BYTES=$(cat "${f%_used}_total" 2>/dev/null || echo 0)
            if (( T_BYTES > 0 )); then
                USED_GB=$(awk "BEGIN {printf \"%.1f\", $U_BYTES/1073741824}")
                TOTAL_GB=$(awk "BEGIN {printf \"%.1f\", $T_BYTES/1073741824}")
                TEXT="󰍹 ${USED_GB}G/${TOTAL_GB}G"
            fi
            break
        fi
    done
fi

printf '{"text":"%s","class":"%s","tooltip":"Live VRAM (Critical for local LLMs)"}\n' "$TEXT" "$CLASS"
