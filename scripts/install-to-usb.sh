#!/usr/bin/env bash
# Kept for compatibility: there is one supported installer.
set -euo pipefail
exec "$(dirname "$(readlink -f "$0")")/repair-and-install.sh" "$@"
