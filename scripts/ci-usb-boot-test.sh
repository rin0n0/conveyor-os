#!/usr/bin/env bash
# CI test of the real install path: partition a virtual disk, run the installer and
# boot the result as a USB drive on blank UEFI firmware, without and with Secure Boot.
# Usage: sudo scripts/ci-usb-boot-test.sh <image-ref>
set -euo pipefail

IMAGE_REF="${1:?image reference required}"
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
WORK_DIR="${PWD}/usb-test"
DISK="$WORK_DIR/disk.raw"
LUKS_PASSPHRASE="conveyor-ci-test"
USER_PASSWORD="conveyor-ci-user"
LOOP_DEVICE=""

cleanup() {
    cryptsetup close conveyor_crypt 2>/dev/null || true
    [[ -n "$LOOP_DEVICE" ]] && losetup -d "$LOOP_DEVICE" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$WORK_DIR"
truncate -s 120G "$DISK"
LOOP_DEVICE=$(losetup --find --show --partscan "$DISK")

printf 'YES\n%s\n%s\n' "$LUKS_PASSPHRASE" "$LUKS_PASSPHRASE" \
    | CONVEYOR_LUKS_BATCH=1 bash "$SCRIPT_DIR/partition-intel-545s.sh" "$LOOP_DEVICE"

printf '%s\n%s\n' "$USER_PASSWORD" "$USER_PASSWORD" \
    | CONVEYOR_EXTRA_KARGS="console=ttyS0,115200 ignore_loglevel systemd.show_status=1 systemd.log_color=0" \
      bash "$SCRIPT_DIR/repair-and-install.sh" "$LOOP_DEVICE" "$IMAGE_REF"

cleanup
LOOP_DEVICE=""
sync

python3 "$SCRIPT_DIR/ci-usb-boot-qemu.py" "$DISK" plain "$WORK_DIR/serial-plain.log" "$LUKS_PASSPHRASE"
python3 "$SCRIPT_DIR/ci-usb-boot-qemu.py" "$DISK" secureboot "$WORK_DIR/serial-secureboot.log" "$LUKS_PASSPHRASE"

echo "USB boot test passed"
