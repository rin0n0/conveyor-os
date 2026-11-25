#!/usr/bin/env bash
set -euo pipefail

# Conveyor OS: User Documentation & Help Browser
DOCS_DIR="/usr/share/conveyor/docs"

# Fallback for running from git checkout directly
if [[ ! -d "$DOCS_DIR" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -d "$SCRIPT_DIR/../../share/conveyor/docs" ]]; then
        DOCS_DIR="$(cd "$SCRIPT_DIR/../../share/conveyor/docs" && pwd)"
    fi
fi

ARG="${1:-}"

case "$ARG" in
    --web|--gui|-w)
        if command -v firefox >/dev/null 2>&1; then
            exec firefox "$DOCS_DIR/INDEX.md"
        elif command -v xdg-open >/dev/null 2>&1; then
            exec xdg-open "$DOCS_DIR/INDEX.md"
        fi
        ;;
    models|ai|модели)
        exec "${EDITOR:-micro}" "$DOCS_DIR/02-локальные-модели-и-ии/01-установка-и-разметка.md"
        ;;
    keys|hotkeys|клавиши)
        exec "${EDITOR:-micro}" "$DOCS_DIR/01-быстрый-старт/03-горячие-клавиши.md"
        ;;
    projects|project|проекты)
        exec "${EDITOR:-micro}" "$DOCS_DIR/03-программы-и-инструменты/06-работа-с-проектами.md"
        ;;
    stt|voice|голос)
        exec "${EDITOR:-micro}" "$DOCS_DIR/02-локальные-модели-и-ии/04-распознавание-голоса.md"
        ;;
    comfy|comfyui)
        exec "${EDITOR:-micro}" "$DOCS_DIR/02-локальные-модели-и-ии/05-генерация-comfyui.md"
        ;;
    net|network|сеть)
        exec "${EDITOR:-micro}" "$DOCS_DIR/04-системное-руководство/03-сеть-и-профили.md"
        ;;
    gpu|cuda|nvidia)
        exec "${EDITOR:-micro}" "$DOCS_DIR/04-системное-руководство/05-видеокарты-и-cuda.md"
        ;;
    linux|cli|команды)
        exec "${EDITOR:-micro}" "$DOCS_DIR/04-системное-руководство/01-шпаргалка-linux.md"
        ;;
    --pager|-p)
        if command -v less >/dev/null 2>&1; then
            exec less "$DOCS_DIR/INDEX.md"
        else
            exec cat "$DOCS_DIR/INDEX.md"
        fi
        ;;
    *)
        # Default interactive browser: launch yazi on docs dir if available
        if command -v yazi >/dev/null 2>&1 && [[ -t 0 ]]; then
            exec yazi "$DOCS_DIR"
        elif command -v micro >/dev/null 2>&1 && [[ -t 0 ]]; then
            exec micro "$DOCS_DIR/INDEX.md"
        elif command -v less >/dev/null 2>&1 && [[ -t 0 ]]; then
            exec less "$DOCS_DIR/INDEX.md"
        else
            cat "$DOCS_DIR/INDEX.md"
        fi
        ;;
esac
