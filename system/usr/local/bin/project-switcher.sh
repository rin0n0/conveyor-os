#!/usr/bin/env bash
# Fast Fuzzel project switcher: scan ~/Projects and open/focus inside Foot+Zellij
set -euo pipefail

PROJECTS_DIR="${HOME}/Projects"
mkdir -p "$PROJECTS_DIR"

# Collect list of active projects (directories containing .git or .jj)
CANDIDATES=$(find "$PROJECTS_DIR" -maxdepth 2 \( -name ".git" -o -name ".jj" \) -printf "%h\n" 2>/dev/null | sort -u)

if [[ -z "$CANDIDATES" ]]; then
    # Offer to initialize a new project slot
    NAME=$(echo -e "➕ Create New Project\n" | fuzzel --dmenu --prompt "Project: ")
    if [[ "$NAME" == "➕ Create New Project"* ]]; then
        NEW_NAME=$(echo "" | fuzzel --dmenu --prompt "New project name: ")
        if [[ -n "$NEW_NAME" ]]; then
            TARGET="${PROJECTS_DIR}/${NEW_NAME}"
            mkdir -p "$TARGET"
            (cd "$TARGET" && jj git init --colocate)
            echo "$NEW_NAME" > /run/current-project
            exec footclient -D "$TARGET" zellij -s "$NEW_NAME" --layout conveyor
        fi
    fi
    exit 0
fi

SELECTED=$(echo "$CANDIDATES" | while read -r p; do basename "$p"; done | fuzzel --dmenu --prompt "Switch Project: ")

if [[ -n "$SELECTED" ]]; then
    TARGET="${PROJECTS_DIR}/${SELECTED}"
    echo "$SELECTED" > /run/current-project
    # If Zellij session exists, attach; else start conveyor layout
    if command -v footclient >/dev/null 2>&1; then
        footclient -D "$TARGET" zellij attach -c "$SELECTED" --layout conveyor &
    else
        foot -D "$TARGET" zellij attach -c "$SELECTED" --layout conveyor &
    fi
fi
