#!/usr/bin/env bash
# CI boot test: install the image to a virtual disk, boot it under UEFI and
# require the graphical target with the core Conveyor services healthy.
# Usage: sudo scripts/ci-vm-test.sh <image-ref>
set -euo pipefail

IMAGE_REF="${1:?image reference required}"
WORK_DIR="${PWD}/vm-test"
DISK="$WORK_DIR/disk.raw"
SERIAL_LOG="$WORK_DIR/serial.log"
BOOT_TIMEOUT_SECONDS=480

OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
OVMF_VARS=/usr/share/OVMF/OVMF_VARS_4M.fd

mkdir -p "$WORK_DIR"
truncate -s 20G "$DISK"
cp "$OVMF_VARS" "$WORK_DIR/vars.fd"

podman pull "$IMAGE_REF"

podman run --rm --privileged --pid=host \
    -v /var/lib/containers:/var/lib/containers \
    -v /dev:/dev \
    -v "$WORK_DIR:/output" \
    --security-opt label=type:unconfined_t \
    "$IMAGE_REF" \
    bootc install to-disk --via-loopback --generic-image \
    --filesystem xfs \
    --karg console=ttyS0,115200 \
    --karg systemd.show_status=1 \
    --karg systemd.log_color=0 \
    /output/disk.raw

: >"$SERIAL_LOG"
qemu-system-x86_64 \
    -enable-kvm -cpu host -machine q35 -smp 2 -m 4096 \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$WORK_DIR/vars.fd" \
    -drive if=virtio,format=raw,file="$DISK" \
    -display none -serial "file:$SERIAL_LOG" -monitor none &
QEMU_PID=$!
trap 'kill "$QEMU_PID" 2>/dev/null || true' EXIT

deadline=$((SECONDS + BOOT_TIMEOUT_SECONDS))
booted=0
while (( SECONDS < deadline )); do
    if grep -q 'Reached target .*Graphical Interface' "$SERIAL_LOG"; then
        booted=1
        break
    fi
    kill -0 "$QEMU_PID" 2>/dev/null || break
    sleep 5
done

if (( booted == 0 )); then
    echo "VM did not reach the graphical target. Last boot messages:" >&2
    tail -n 60 "$SERIAL_LOG" >&2
    exit 1
fi

# Services may report a failure shortly after the target is reached.
sleep 20
if grep -E 'FAILED.*(greetd|llama-swap|boot-gpu-detect)' "$SERIAL_LOG" >&2; then
    echo "A core Conveyor service failed during boot" >&2
    exit 1
fi

echo "VM boot test passed"
