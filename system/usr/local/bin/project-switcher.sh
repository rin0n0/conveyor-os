#!/usr/bin/env bash
# Fast Fuzzel project switcher: scan ~/Projects and open/focus inside Foot+Zellij
set -euo pipefail

PROJECTS_DIR="${HOME}/Projects"
CURRENT_PROJECT_FILE="${XDG_RUNTIME_DIR:-/tmp}/conveyor-current-project"
CREATE_ITEM="➕ Новый проект"

mkdir -p "$PROJECTS_DIR"

open_project() {
    local name="$1" target="${PROJECTS_DIR}/$1"
    echo "$name" >"$CURRENT_PROJECT_FILE"
    if zellij list-sessions --short 2>/dev/null | grep -Fxq -- "$name"; then
        exec foot -D "$target" zellij attach "$name"
    fi
    exec foot -D "$target" zellij --session "$name" --layout conveyor
}

# Collect active projects (directories containing .git or .jj)
PROJECTS=$(find "$PROJECTS_DIR" -mindepth 2 -maxdepth 2 \( -name ".git" -o -name ".jj" \) -printf "%h\n" 2>/dev/null \
    | xargs -r -d '\n' -n1 basename | sort -u)

# fuzzel exits non-zero when the menu is cancelled
SELECTED=$({ echo "$CREATE_ITEM"; [[ -z "$PROJECTS" ]] || echo "$PROJECTS"; } \
    | fuzzel --dmenu --prompt "Проект: ") || exit 0

if [[ "$SELECTED" == "$CREATE_ITEM" ]]; then
    NEW_NAME=$(fuzzel --dmenu --prompt "Название проекта: " </dev/null) || exit 0
    if [[ -z "$NEW_NAME" || "$NEW_NAME" == *"/"* || "$NEW_NAME" == .* ]]; then
        notify-send -a "Проекты" "Недопустимое название проекта" "$NEW_NAME" || true
        exit 1
    fi
    mkdir -p "${PROJECTS_DIR}/${NEW_NAME}"
    if [[ ! -e "${PROJECTS_DIR}/${NEW_NAME}/.git" && ! -e "${PROJECTS_DIR}/${NEW_NAME}/.jj" ]]; then
        (cd "${PROJECTS_DIR}/${NEW_NAME}" && jj git init --colocate)
    fi
    SELECTED="$NEW_NAME"
fi

[[ -n "$SELECTED" ]] && open_project "$SELECTED"
