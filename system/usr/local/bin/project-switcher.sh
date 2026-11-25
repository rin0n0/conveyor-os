#!/usr/bin/env bash
# Fast Fuzzel project switcher: scan ~/Projects and open/focus inside Foot+Zellij
set -euo pipefail

PROJECTS_DIR="${HOME}/Projects"
CURRENT_PROJECT_FILE="${XDG_RUNTIME_DIR:-/tmp}/conveyor-current-project"
CREATE_ITEM="➕ Новый проект"

mkdir -p "$PROJECTS_DIR"

resolve_layout() {
    local user_layout="${XDG_CONFIG_HOME:-$HOME/.config}/zellij/layouts/conveyor.kdl"
    local skel_layout="/etc/skel/.config/zellij/layouts/conveyor.kdl"
    if [[ -f "$user_layout" ]]; then
        printf '%s\n' "$user_layout"
    elif [[ -f "$skel_layout" ]]; then
        printf '%s\n' "$skel_layout"
    else
        printf '%s\n' "default"
    fi
}

open_project() {
    local name="$1" target="${PROJECTS_DIR}/$1" layout
    layout=$(resolve_layout)
    echo "$name" >"$CURRENT_PROJECT_FILE"

    # Clean up stale EXITED sessions with the same name so Zellij does not fail on attach
    local sessions
    sessions=$(zellij list-sessions --no-formatting 2>/dev/null || true)
    if grep -Eq "^${name}[[:space:]].*\(EXITED" <<<"$sessions"; then
        zellij delete-session "$name" >/dev/null 2>&1 || true
        sessions=$(zellij list-sessions --no-formatting 2>/dev/null || true)
    fi

    # Always run via bash wrapper so Foot never closes silently if Zellij exits with an error
    if grep -Eq "^${name}([[:space:]]|$)" <<<"$sessions"; then
        exec foot -D "$target" bash -lc \
            'zellij attach "$1" || { echo "[Conveyor] Zellij завершился с ошибкой. Открываю обычный bash..."; exec bash; }' \
            _ "$name"
    else
        exec foot -D "$target" bash -lc \
            'zellij --session "$1" --new-session-with-layout "$2" || { echo "[Conveyor] Zellij завершился с ошибкой. Открываю обычный bash..."; exec bash; }' \
            _ "$name" "$layout"
    fi
}

# Collect all project subdirectories inside ~/Projects (excluding hidden folders)
PROJECTS=$(find "$PROJECTS_DIR" -mindepth 1 -maxdepth 1 -type d ! -name ".*" -printf "%f\n" 2>/dev/null | sort -u || true)

# fuzzel exits non-zero when the menu is cancelled
SELECTED=$({ echo "$CREATE_ITEM"; [[ -z "$PROJECTS" ]] || echo "$PROJECTS"; } \
    | fuzzel --dmenu --prompt "Проект: ") || exit 0

if [[ "$SELECTED" == "$CREATE_ITEM" ]]; then
    NEW_NAME=$(fuzzel --dmenu --prompt "Название проекта: " </dev/null) || exit 0
    # Strip leading/trailing whitespace
    NEW_NAME=$(echo "$NEW_NAME" | xargs)
    if [[ -z "$NEW_NAME" || "$NEW_NAME" == *"/"* || "$NEW_NAME" == .* || "$NEW_NAME" == *" "* ]]; then
        notify-send -a "Проекты" "Недопустимое название проекта" "Используйте имя без пробелов и слэшей (например: my-app)" || true
        exit 1
    fi
    mkdir -p "${PROJECTS_DIR}/${NEW_NAME}"
    if [[ ! -e "${PROJECTS_DIR}/${NEW_NAME}/.git" && ! -e "${PROJECTS_DIR}/${NEW_NAME}/.jj" ]]; then
        (
            cd "${PROJECTS_DIR}/${NEW_NAME}"
            jj git init --colocate >/dev/null 2>&1 || git init >/dev/null 2>&1 || true
        )
    fi
    SELECTED="$NEW_NAME"
fi

[[ -n "$SELECTED" ]] && open_project "$SELECTED"
