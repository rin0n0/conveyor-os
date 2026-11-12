#!/usr/bin/env bash
set -euo pipefail

# Lightweight Bubblewrap sandbox (<50ms) for autonomous CLI agents & tests
# Usage: bwrap-agent-run.sh <workspace_dir> [--net] -- <command...>

WS_DIR="${1:?workspace path required}"
shift

ALLOW_NET=0
if [[ "${1:-}" == "--net" ]]; then
    ALLOW_NET=1
    shift
fi
[[ "${1:-}" == "--" ]] && shift

BWRAP_ARGS=(
    --die-with-parent
    --unshare-pid
    --unshare-ipc
    --ro-bind /usr /usr
    --ro-bind /lib /lib
    --ro-bind /lib64 /lib64
    --ro-bind /bin /bin
    --ro-bind /sbin /sbin
    --ro-bind /etc/resolv.conf /etc/resolv.conf
    --ro-bind /etc/ssl /etc/ssl
    --ro-bind-try "$HOME/.local/share/mise" "$HOME/.local/share/mise"
    --ro-bind-try "$HOME/.local/share/pnpm" "$HOME/.local/share/pnpm"
    --ro-bind-try "$HOME/.cache/uv" "$HOME/.cache/uv"
    --bind "$WS_DIR" "$WS_DIR"
    --tmpfs /tmp
    --proc /proc
    --dev /dev
    --chdir "$WS_DIR"
)

if (( ALLOW_NET == 0 )); then
    BWRAP_ARGS+=(--unshare-net)
fi

exec bwrap "${BWRAP_ARGS[@]}" "$@"
