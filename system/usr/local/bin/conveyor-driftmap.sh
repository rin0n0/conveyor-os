#!/usr/bin/env bash
# Driftmap: minimap overlay for DriftWM (github.com/rywby-dot/driftwm-minimap).
# Installed as a single file; this wrapper provides the "driftmap" command.
exec python3 /usr/local/lib/conveyor/driftmap.py "$@"
