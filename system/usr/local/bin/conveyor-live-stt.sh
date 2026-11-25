#!/usr/bin/env bash
set -euo pipefail

# Conveyor OS: Antigravity Live STT Client (Push-to-Talk / Toggle Dictation)
# Records audio via PipeWire, streams/sends to Antigravity Live STT, and types text via wtype

PID_FILE="/tmp/live-stt-${UID}.pid"
AUDIO_FILE="/tmp/live-stt-${UID}.wav"

# Stop existing recording session and process STT
if [[ -f "$PID_FILE" ]]; then
    RECORD_PID=$(cat "$PID_FILE")
    rm -f "$PID_FILE"
    if kill -0 "$RECORD_PID" 2>/dev/null; then
        kill -INT "$RECORD_PID" 2>/dev/null || true
        wait "$RECORD_PID" 2>/dev/null || true
    fi

    if [[ -f "$AUDIO_FILE" && -s "$AUDIO_FILE" ]]; then
        notify-send -a "Antigravity STT" -t 1500 "Обработка..." "Распознавание речи через Antigravity Live..."

        # Call Antigravity Live STT processor
        TRANSCRIPT=$(python3 /usr/local/libexec/antigravity-stt.py "$AUDIO_FILE" 2>/dev/null || true)

        if [[ -n "$TRANSCRIPT" ]]; then
            # Copy to clipboard as backup
            echo -n "$TRANSCRIPT" | wl-copy 2>/dev/null || true

            # Inject text directly into active Wayland window via wtype
            if command -v wtype >/dev/null 2>&1; then
                wtype -- "$TRANSCRIPT" 2>/dev/null || true
            fi
            notify-send -a "Antigravity STT" -t 2000 "Готово" "$TRANSCRIPT"
        else
            notify-send -a "Antigravity STT" -t 2000 "Ошибка" "Речь не распознана или Antigravity STT не ответил"
        fi
        rm -f "$AUDIO_FILE"
    fi
    exit 0
fi

# Start new recording session
notify-send -a "Antigravity STT" -t 2000 "🎙️ Запись речи..." "Говорите. Нажмите Super+~ снова для отправки."
rm -f "$AUDIO_FILE"

if command -v pw-record >/dev/null 2>&1; then
    pw-record --channels 1 --rate 16000 "$AUDIO_FILE" >/dev/null 2>&1 &
    echo $! > "$PID_FILE"
elif command -v arecord >/dev/null 2>&1; then
    arecord -f S16_LE -r 16000 -c 1 "$AUDIO_FILE" >/dev/null 2>&1 &
    echo $! > "$PID_FILE"
else
    notify-send -a "Antigravity STT" "Ошибка" "Утилита записи звука (pw-record / arecord) не найдена"
    exit 1
fi
