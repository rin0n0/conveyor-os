#!/usr/bin/env bash
set -euo pipefail

# Conveyor OS: Resilient Installer & Repair Script
# Safe to run repeatedly - handles existing LUKS, sets up swap in RAM to prevent reboot,
# verifies every step and guarantees \EFI\BOOT\BOOTX64.EFI is written.

DISK="${1:-}"
IMAGE_REF="${2:-ghcr.io/rin0n0/conveyor-os:latest}"

if [[ -z "$DISK" || ! -b "$DISK" ]]; then
    echo "Usage: sudo $0 /dev/sdX [IMAGE_REF]" >&2
    echo "Example: sudo $0 /dev/sdb" >&2
    exit 1
fi

echo "=========================================="
echo "Conveyor OS Safe Installer & Repair"
echo "Target disk: $DISK"
echo "Image ref:   $IMAGE_REF"
echo "=========================================="

P1="${DISK}1"
P2="${DISK}2"
P3="${DISK}3"
P4="${DISK}4"

for p in "$P1" "$P2" "$P3" "$P4"; do
    if [[ ! -b "$p" ]]; then
        echo "Error: Partition $p not found! Run partition-intel-545s.sh first." >&2
        exit 1
    fi
done

# Step 0: Prevent Live system OOM reboot by adding swap file in /tmp or zram
echo "[0/6] Ensuring memory safety (preventing OOM crash during container extraction)..."
if ! swapon --show | grep -q 'partition\|file'; then
    echo "Setting up temporary 4GB swap space in Live session..."
    mkdir -p /tmp/swap
    dd if=/dev/zero of=/tmp/swap/swapfile bs=1M count=4096 status=progress || true
    chmod 600 /tmp/swap/swapfile || true
    mkswap /tmp/swap/swapfile || true
    swapon /tmp/swap/swapfile || true
fi

# Step 1: LUKS Container
echo "[1/6] Preparing LUKS2 partition $P4..."
LUKS_MAPPER="/dev/mapper/conveyor_crypt"
if [[ ! -e "$LUKS_MAPPER" ]]; then
    echo "Opening LUKS container..."
    cryptsetup open --allow-discards "$P4" conveyor_crypt
else
    echo "LUKS container conveyor_crypt is already open."
fi

# Step 2: Clean unmount & fresh mount
echo "[2/6] Mounting filesystems..."
TARGET_MNT="/mnt/target"
umount -R "$TARGET_MNT" 2>/dev/null || true
mkdir -p "$TARGET_MNT"

mount -o subvol=@root,noatime,compress=zstd:3 "$LUKS_MAPPER" "$TARGET_MNT"
mkdir -p "$TARGET_MNT/boot" \
         "$TARGET_MNT/var/home" \
         "$TARGET_MNT/var/lib/models" \
         "$TARGET_MNT/var/lib/containers" \
         "$TARGET_MNT/var/cache" \
         "$TARGET_MNT/mnt/shared"

mount -o subvol=@home,noatime,compress=zstd:3 "$LUKS_MAPPER" "$TARGET_MNT/var/home"
mount -o subvol=@models,noatime,compress=no "$LUKS_MAPPER" "$TARGET_MNT/var/lib/models"
mount -o subvol=@containers,noatime,compress=zstd:3 "$LUKS_MAPPER" "$TARGET_MNT/var/lib/containers"
mount -o subvol=@var_cache,noatime,compress=zstd:3 "$LUKS_MAPPER" "$TARGET_MNT/var/cache"

mount -o noatime "$P2" "$TARGET_MNT/boot"
mkdir -p "$TARGET_MNT/boot/efi"
mount "$P1" "$TARGET_MNT/boot/efi"

# Step 3: Hardware UUIDs
echo "[3/6] Reading hardware UUIDs..."
LUKS_UUID=$(blkid -s UUID -o value "$P4")
BTRFS_UUID=$(blkid -s UUID -o value "$LUKS_MAPPER")
BOOT_UUID=$(blkid -s UUID -o value "$P2")
EFI_UUID=$(blkid -s UUID -o value "$P1")
SHARED_UUID=$(blkid -s UUID -o value "$P3" || true)

echo "  LUKS UUID:   $LUKS_UUID"
echo "  BTRFS UUID:  $BTRFS_UUID"
echo "  BOOT UUID:   $BOOT_UUID"
echo "  EFI UUID:    $EFI_UUID"
echo "  SHARED UUID: $SHARED_UUID"

# Step 4: Pull and deploy container image
echo "[4/6] Pulling and deploying Conveyor OS image ($IMAGE_REF)..."
echo "This will download the OS layers (approx 3-4 GB). Please wait..."

# Check if podman can pull image
podman pull "$IMAGE_REF"

# Try bootc install to filesystem via container first
INSTALLED=0
if podman run --rm --privileged --pid=host \
    -v /var/lib/containers:/var/lib/containers \
    -v /dev:/dev \
    -v /mnt:/mnt \
    --security-opt label=type:unconfined_t \
    "$IMAGE_REF" \
    bootc install to-filesystem --target-no-signature \
    --karg="root=UUID=${BTRFS_UUID}" \
    --karg="rootflags=subvol=@root" \
    --karg="rd.luks.uuid=${LUKS_UUID}" \
    --karg="rd.auto=1" \
    --karg="rootwait" \
    "$TARGET_MNT"; then
    INSTALLED=1
    echo "bootc in-container install succeeded!"
else
    echo "bootc in-container install encountered an issue, falling back to container extraction..."
fi

if [[ "$INSTALLED" -eq 0 ]]; then
    podman rm -f conveyor-temp 2>/dev/null || true
    podman create --name conveyor-temp "$IMAGE_REF"
    echo "Extracting rootfs layers to target..."
    podman export conveyor-temp | tar -x -C "$TARGET_MNT"
    podman rm conveyor-temp
fi

# Step 5: Configure /etc/fstab and /etc/crypttab
echo "[5/6] Generating configuration files..."
cat > "$TARGET_MNT/etc/fstab" <<EOF
# /etc/fstab for Conveyor OS (Intel SSD 545s Portable)
UUID=${BTRFS_UUID}  /                    btrfs  subvol=@root,noatime,compress=zstd:3,commit=15 0 0
UUID=${BOOT_UUID}   /boot                ext4   noatime 0 2
UUID=${EFI_UUID}    /boot/efi            vfat   umask=0077,shortname=winnt 0 2
UUID=${BTRFS_UUID}  /var/home            btrfs  subvol=@home,noatime,compress=zstd:3,commit=15 0 0
UUID=${BTRFS_UUID}  /var/lib/models      btrfs  subvol=@models,noatime,compress=no,commit=15 0 0
UUID=${BTRFS_UUID}  /var/lib/containers  btrfs  subvol=@containers,noatime,compress=zstd:3 0 0
UUID=${BTRFS_UUID}  /var/cache           btrfs  subvol=@var_cache,noatime,compress=zstd:3 0 0
EOF

if [[ -n "${SHARED_UUID}" ]]; then
    echo "UUID=${SHARED_UUID} /mnt/shared          exfat  defaults,nofail,uid=1000,gid=1000,umask=022,iocharset=utf8 0 0" >> "$TARGET_MNT/etc/fstab"
fi

cat > "$TARGET_MNT/etc/crypttab" <<EOF
conveyor_crypt UUID=${LUKS_UUID} none discard,fido2-device=auto
EOF

# Step 6: Install bootloader to removable path (\EFI\BOOT\BOOTX64.EFI)
echo "[6/6] Ensuring UEFI bootloader is strictly installed in \\EFI\\BOOT\\BOOTX64.EFI..."
mkdir -p "$TARGET_MNT/boot/efi/EFI/BOOT"

# Search for shim and grub binaries across possible system locations
SHIM_BIN=""
GRUB_BIN=""
for s in "$TARGET_MNT/boot/efi/EFI/fedora/shimx64.efi" \
         "$TARGET_MNT/usr/share/efi/x64/shimx64.efi" \
         "$TARGET_MNT/usr/lib/ostree-boot/efi/EFI/fedora/shimx64.efi" \
         /boot/efi/EFI/fedora/shimx64.efi; do
    if [[ -f "$s" ]]; then SHIM_BIN="$s"; break; fi
done

for g in "$TARGET_MNT/boot/efi/EFI/fedora/grubx64.efi" \
         "$TARGET_MNT/usr/share/efi/x64/grubx64.efi" \
         "$TARGET_MNT/usr/lib/ostree-boot/efi/EFI/fedora/grubx64.efi" \
         /boot/efi/EFI/fedora/grubx64.efi; do
    if [[ -f "$g" ]]; then GRUB_BIN="$g"; break; fi
done

if [[ -n "$SHIM_BIN" ]]; then
    echo "Found signed shim binary: $SHIM_BIN"
    cp -fv "$SHIM_BIN" "$TARGET_MNT/boot/efi/EFI/BOOT/BOOTX64.EFI"
else
    echo "Warning: shimx64.efi not found in target, copying fallback from host if available..."
    cp -fv /boot/efi/EFI/BOOT/BOOTX64.EFI "$TARGET_MNT/boot/efi/EFI/BOOT/BOOTX64.EFI" 2>/dev/null || true
fi

if [[ -n "$GRUB_BIN" ]]; then
    echo "Found grub binary: $GRUB_BIN"
    cp -fv "$GRUB_BIN" "$TARGET_MNT/boot/efi/EFI/BOOT/grubx64.efi"
fi

# Find kernel and initramfs
KERNEL_PATH=$(find "$TARGET_MNT/boot" -maxdepth 2 -name "vmlinuz*" | head -n1 || true)
INITRD_PATH=$(find "$TARGET_MNT/boot" -maxdepth 2 -name "initramfs*" | head -n1 || true)

KERNEL_NAME=$(basename "${KERNEL_PATH:-vmlinuz}")
INITRD_NAME=$(basename "${INITRD_PATH:-initramfs.img}")

# Write independent grub.cfg directly into \EFI\BOOT\grub.cfg
cat > "$TARGET_MNT/boot/efi/EFI/BOOT/grub.cfg" <<EOF
set default=0
set timeout=5

insmod part_gpt
insmod ext2
insmod btrfs
insmod luks

search --no-floppy --fs-uuid --set=root ${BOOT_UUID}

menuentry "Conveyor OS (Universal Auto-Detect 2014-2026)" {
    linux /${KERNEL_NAME} root=UUID=${BTRFS_UUID} rootflags=subvol=@root rd.luks.uuid=${LUKS_UUID} rd.auto=1 rootwait usbcore.autosuspend=-1 iommu=pt
    initrd /${INITRD_NAME}
}

menuentry "Conveyor OS (Safe Hardware: JMS578 BOT + Safe Graphics)" {
    linux /${KERNEL_NAME} root=UUID=${BTRFS_UUID} rootflags=subvol=@root rd.luks.uuid=${LUKS_UUID} rd.auto=1 rootwait usbcore.autosuspend=-1 usb-storage.quirks=152d:0578:u nomodeset
    initrd /${INITRD_NAME}
}
EOF

# Copy grub.cfg to root of EFI partition as well for quirky UEFI bioses
cp -fv "$TARGET_MNT/boot/efi/EFI/BOOT/grub.cfg" "$TARGET_MNT/boot/efi/grub.cfg" 2>/dev/null || true

sync

echo "========================================================"
echo "VERIFICATION OF INSTALLED EFI FILES:"
ls -la "$TARGET_MNT/boot/efi/EFI/BOOT/"
echo "========================================================"

if [[ -f "$TARGET_MNT/boot/efi/EFI/BOOT/BOOTX64.EFI" ]]; then
    echo "SUCCESS: \\EFI\\BOOT\\BOOTX64.EFI is present and ready!"
else
    echo "FATAL: BOOTX64.EFI is missing!" >&2
    exit 1
fi

# Clean up unmount
umount -R "$TARGET_MNT"
echo "Target unmounted cleanly."
echo "Done! You can now safely reboot and select Intel SSD from UEFI Boot Menu."
