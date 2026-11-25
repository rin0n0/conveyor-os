#!/usr/bin/env bash
set -euo pipefail

# Ensure the user panel service is active and open the web UI
systemctl --user start conveyor-panel.service >/dev/null 2>&1 || true

for _ in {1..15}; do
    if curl -fsS -m 1 http://127.0.0.1:7070/api/system >/dev/null 2>&1; then
        break
    fi
    sleep 0.2
done

if command -v firefox >/dev/null 2>&1; then
    exec firefox http://127.0.0.1:7070
fi
exec xdg-open http://127.0.0.1:7070
