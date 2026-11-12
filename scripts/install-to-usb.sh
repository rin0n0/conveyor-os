#!/usr/bin/env bash
set -euo pipefail

# Conveyor OS Automated Installer for Intel SSD 545s 256GB
# Deploys bootc OCI image to LUKS2+Btrfs, sets up UUIDs, fstab, and installs GRUB2 --removable

DISK="${1:-}"
IMAGE_REF="${2:-ghcr.io/rin0n0/conveyor-os:latest}"

if [[ -z "$DISK" || ! -b "$DISK" ]]; then
    echo "Usage: sudo $0 /dev/sdX [IMAGE_REF]" >&2
    echo "Example: sudo $0 /dev/sdb ghcr.io/myuser/conveyor-os:latest" >&2
    exit 1
fi

echo "=========================================="
echo "Installing Conveyor OS onto $DISK"
echo "Image source: $IMAGE_REF"
echo "=========================================="

P1="${DISK}1"
P2="${DISK}2"
P3="${DISK}3"

# 1. Open LUKS container if not open
if [[ ! -e /dev/mapper/conveyor_crypt ]]; then
    echo "[1/6] Opening LUKS2 partition $P3..."
    cryptsetup open --allow-discards "$P3" conveyor_crypt
fi

LUKS_MAPPER="/dev/mapper/conveyor_crypt"
TARGET_MNT="/mnt/target"

mkdir -p "$TARGET_MNT"

# 2. Mount Btrfs root & subvolumes
echo "[2/6] Mounting Btrfs subvolumes..."
mount -o subvol=@root,noatime,compress=zstd:3 "$LUKS_MAPPER" "$TARGET_MNT"
mkdir -p "$TARGET_MNT/boot" \
         "$TARGET_MNT/var/home" \
         "$TARGET_MNT/var/lib/models" \
         "$TARGET_MNT/var/lib/containers" \
         "$TARGET_MNT/var/cache"

mount -o subvol=@home,noatime,compress=zstd:3 "$LUKS_MAPPER" "$TARGET_MNT/var/home"
mount -o subvol=@models,noatime,compress=no "$LUKS_MAPPER" "$TARGET_MNT/var/lib/models"
mount -o subvol=@containers,noatime,compress=zstd:3 "$LUKS_MAPPER" "$TARGET_MNT/var/lib/containers"
mount -o subvol=@var_cache,noatime,compress=zstd:3 "$LUKS_MAPPER" "$TARGET_MNT/var/cache"

# Mount ext4 /boot and vfat /boot/efi
mount -o noatime "$P2" "$TARGET_MNT/boot"
mkdir -p "$TARGET_MNT/boot/efi"
mount "$P1" "$TARGET_MNT/boot/efi"

# 3. Read hardware UUIDs
echo "[3/6] Reading partition UUIDs..."
LUKS_UUID=$(blkid -s UUID -o value "$P3")
BTRFS_UUID=$(blkid -s UUID -o value "$LUKS_MAPPER")
BOOT_UUID=$(blkid -s UUID -o value "$P2")
EFI_UUID=$(blkid -s UUID -o value "$P1")

echo "  LUKS UUID:  $LUKS_UUID"
echo "  BTRFS UUID: $BTRFS_UUID"
echo "  BOOT UUID:  $BOOT_UUID"
echo "  EFI UUID:   $EFI_UUID"

# 4. Deploy bootc OS image
echo "[4/6] Deploying bootc container image into filesystem..."
if command -v bootc >/dev/null 2>&1; then
    bootc install to-filesystem --target-no-signature --source "$IMAGE_REF" "$TARGET_MNT"
else
    echo "bootc utility not found on host, using podman/rsync fallback deployment..."
    podman create --name conveyor-temp "$IMAGE_REF"
    podman export conveyor-temp | tar -x -C "$TARGET_MNT"
    podman rm conveyor-temp
fi

# 5. Generate /etc/fstab with real UUIDs
echo "[5/6] Generating /etc/fstab with persistent UUIDs..."
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

# Ensure /etc/crypttab for LUKS unlock
cat > "$TARGET_MNT/etc/crypttab" <<EOF
conveyor_crypt UUID=${LUKS_UUID} none discard,fido2-device=auto
EOF

# 6. Install GRUB2 & Microsoft-signed shim strictly in --removable path
echo "[6/6] Installing UEFI bootloader to \\EFI\\BOOT\\BOOTX64.EFI (--removable)..."
mkdir -p "$TARGET_MNT/boot/efi/EFI/BOOT"

# Copy signed binaries for zero-BIOS-tamper Secure Boot compatibility
if [[ -d "$TARGET_MNT/boot/efi/EFI/fedora" ]]; then
    cp -f "$TARGET_MNT/boot/efi/EFI/fedora/shimx64.efi" "$TARGET_MNT/boot/efi/EFI/BOOT/BOOTX64.EFI"
    cp -f "$TARGET_MNT/boot/efi/EFI/fedora/grubx64.efi" "$TARGET_MNT/boot/efi/EFI/BOOT/"
    cp -f "$TARGET_MNT/boot/efi/EFI/fedora/mmx64.efi"   "$TARGET_MNT/boot/efi/EFI/BOOT/" || true
fi

# Write standalone grub configuration for removable boot
cat > "$TARGET_MNT/boot/efi/EFI/BOOT/grub.cfg" <<EOF
set default=0
set timeout=5

search --no-floppy --fs-uuid --set=root ${BOOT_UUID}

menuentry "Conveyor OS (Auto-Detect 2014-2026)" {
    linux /ostree/default/vmlinuz root=UUID=${BTRFS_UUID} rootflags=subvol=@root rd.luks.uuid=${LUKS_UUID} rd.auto=1 rootwait usbcore.autosuspend=-1 iommu=pt
    initrd /ostree/default/initramfs.img
}

menuentry "Conveyor OS (Safe Hardware: JMS578 BOT + No-GPU-Accel)" {
    linux /ostree/default/vmlinuz root=UUID=${BTRFS_UUID} rootflags=subvol=@root rd.luks.uuid=${LUKS_UUID} rd.auto=1 rootwait usbcore.autosuspend=-1 usb-storage.quirks=152d:0578:u rd.driver.blacklist=nvidia,nvidia_drm,nvidia_modeset,nvidia_uvm,nouveau nomodeset
    initrd /ostree/default/initramfs.img
}
EOF

# Clean up mounts
sync
umount -R "$TARGET_MNT"
cryptsetup close conveyor_crypt || true

echo "=========================================="
echo "Installation complete!"
echo "You can now plug Intel SSD 545s into any PC (2014-2026) and boot via UEFI Boot Menu."
echo "=========================================="
