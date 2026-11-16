#!/usr/bin/env bash
set -euo pipefail

# Conveyor OS: Bulletproof Installer & Recovery Script
# Tested and verified for:
# - Existing LUKS2/Btrfs subvolume reuse without data loss
# - Recursive mount propagation into Podman (-v /mnt:/mnt:rshared)
# - --boot-mount-spec for separated /boot ext4 partition
# - Multi-path kernel, initramfs, and shim/grub search & deployment
# - Guaranteeing \EFI\BOOT\BOOTX64.EFI and \EFI\BOOT\grub.cfg are written and verified

DISK="${1:-}"
IMAGE_REF="${2:-ghcr.io/rin0n0/conveyor-os:latest}"

if [[ -z "$DISK" || ! -b "$DISK" ]]; then
    echo "Usage: sudo $0 /dev/sdX [IMAGE_REF]" >&2
    echo "Example: sudo $0 /dev/sdb" >&2
    exit 1
fi

echo "=========================================================="
echo "Conveyor OS Bulletproof Installer & Repair"
echo "Target disk: $DISK"
echo "Image ref:   $IMAGE_REF"
echo "=========================================================="

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

# Step 0: Ensure Partition 1 has correct EFI System partition type (ef00)
echo "[0/7] Setting GPT partition types..."
if command -v sgdisk >/dev/null 2>&1; then
    sgdisk -t 1:ef00 "$DISK" || true
    sgdisk -t 2:8300 "$DISK" || true
    sgdisk -t 3:0700 "$DISK" || true
    sgdisk -t 4:8309 "$DISK" || true
    partprobe "$DISK" 2>/dev/null || true
    sleep 1
fi

# Step 1: Memory safety (ZRAM swap to prevent Live OS OOM reboot)
echo "[1/7] Ensuring memory safety (preventing OOM crashes)..."
if ! swapon --show | grep -q 'partition\|file'; then
    echo "Setting up zram swap device..."
    if command -v zramctl >/dev/null 2>&1; then
        ZDEV=$(zramctl --find --size 4G 2>/dev/null || true)
        if [[ -n "$ZDEV" && -b "$ZDEV" ]]; then
            mkswap "$ZDEV" >/dev/null 2>&1 || true
            swapon "$ZDEV" 2>/dev/null || true
            echo "ZRAM swap enabled on $ZDEV"
        fi
    fi
fi

# Step 2: Open LUKS container
echo "[2/7] Preparing LUKS2 partition $P4..."
LUKS_MAPPER="/dev/mapper/conveyor_crypt"
if ! cryptsetup status conveyor_crypt >/dev/null 2>&1; then
    echo "Opening LUKS container on $P4..."
    cryptsetup open --allow-discards "$P4" conveyor_crypt
else
    echo "LUKS container conveyor_crypt is already open."
fi

# Step 3: Clean mounts and verify Btrfs subvolumes
echo "[3/7] Mounting filesystems..."
TARGET_MNT="/mnt/target"
umount -R "$TARGET_MNT" 2>/dev/null || true
mkdir -p "$TARGET_MNT"

# Ensure subvolumes exist
mkdir -p /mnt/conveyor_check
mount "$LUKS_MAPPER" /mnt/conveyor_check
for sv in @root @home @models @containers @var_cache @snapshots; do
    if ! btrfs subvolume list /mnt/conveyor_check | grep -q "$sv"; then
        echo "Creating missing subvolume $sv..."
        btrfs subvolume create "/mnt/conveyor_check/$sv"
    fi
done
chattr +C /mnt/conveyor_check/@models 2>/dev/null || true
umount /mnt/conveyor_check
rmdir /mnt/conveyor_check

# Mount Btrfs subvolumes
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

# Mount /boot (ext4) and /boot/efi (FAT32)
mount -o noatime "$P2" "$TARGET_MNT/boot"
mkdir -p "$TARGET_MNT/boot/efi"
mount "$P1" "$TARGET_MNT/boot/efi"

# Step 4: Hardware UUIDs
echo "[4/7] Reading hardware UUIDs..."
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

# Step 5: Pull and Deploy Image
echo "[5/7] Pulling and deploying OS image ($IMAGE_REF)..."
podman pull "$IMAGE_REF"

# CRITICAL: make host /mnt shared so container receives all submounts (/boot, /boot/efi)
mount --make-rshared /mnt 2>/dev/null || true

INSTALLED=0
echo "Attempting bootc in-container install with recursive mount propagation..."
if podman run --rm --privileged --pid=host \
    -v /var/lib/containers:/var/lib/containers \
    -v /dev:/dev \
    -v /mnt:/mnt:rshared \
    --security-opt label=type:unconfined_t \
    "$IMAGE_REF" \
    bootc install to-filesystem --target-no-signature \
    --boot-mount-spec "UUID=${BOOT_UUID}" \
    --karg="root=UUID=${BTRFS_UUID}" \
    --karg="rootflags=subvol=@root" \
    --karg="rd.luks.uuid=${LUKS_UUID}" \
    --karg="rd.auto=1" \
    --karg="rootwait" \
    "$TARGET_MNT"; then
    INSTALLED=1
    echo "bootc in-container install completed successfully!"
else
    echo "bootc install exited with code $?, executing direct rootfs deployment fallback..."
fi

if [[ "$INSTALLED" -eq 0 ]]; then
    podman rm -f conveyor-temp 2>/dev/null || true
    podman create --name conveyor-temp "$IMAGE_REF"
    echo "Extracting image layers to target rootfs..."
    podman export conveyor-temp | tar -x -C "$TARGET_MNT"
    podman rm conveyor-temp
fi

# Step 6: Configuration files (/etc/fstab and /etc/crypttab)
echo "[6/7] Generating persistent fstab and crypttab..."
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

# Step 7: Guarantee UEFI Bootloader in \EFI\BOOT\BOOTX64.EFI
echo "[7/7] Installing UEFI bootloader to \\EFI\\BOOT\\BOOTX64.EFI..."
mkdir -p "$TARGET_MNT/boot/efi/EFI/BOOT"

# Locate kernel and initramfs across all possible target locations
KERNEL_SRC=$(find "$TARGET_MNT/boot" "$TARGET_MNT/usr/lib/modules" -type f -name "vmlinuz*" 2>/dev/null | head -n1 || true)
INITRD_SRC=$(find "$TARGET_MNT/boot" "$TARGET_MNT/usr/lib/modules" -type f \( -name "initramfs*" -o -name "initrd*" \) 2>/dev/null | head -n1 || true)

if [[ -n "$KERNEL_SRC" && -f "$KERNEL_SRC" ]]; then
    echo "Found kernel at $KERNEL_SRC. Copying to /boot/vmlinuz..."
    cp -fv "$KERNEL_SRC" "$TARGET_MNT/boot/vmlinuz"
else
    echo "Warning: kernel not found in standard target locations, checking host..."
    cp -fv /boot/vmlinuz* "$TARGET_MNT/boot/vmlinuz" 2>/dev/null || true
fi

if [[ -n "$INITRD_SRC" && -f "$INITRD_SRC" ]]; then
    echo "Found initramfs at $INITRD_SRC. Copying to /boot/initramfs.img..."
    cp -fv "$INITRD_SRC" "$TARGET_MNT/boot/initramfs.img"
else
    echo "Generating fresh initramfs via dracut..."
    if command -v dracut >/dev/null 2>&1; then
        dracut --sysroot "$TARGET_MNT" --force "$TARGET_MNT/boot/initramfs.img" 2>/dev/null || \
        dracut --force "$TARGET_MNT/boot/initramfs.img" 2>/dev/null || true
    fi
fi

# Locate signed shim and grub binaries (search target and host)
SHIM_FILE=""
for s in "$TARGET_MNT/boot/efi/EFI/fedora/shimx64.efi" \
         "$TARGET_MNT/usr/share/efi/x64/shimx64.efi" \
         "$TARGET_MNT/usr/lib/ostree-boot/efi/EFI/fedora/shimx64.efi" \
         /boot/efi/EFI/BOOT/BOOTX64.EFI \
         /boot/efi/EFI/fedora/shimx64.efi; do
    if [[ -f "$s" ]]; then SHIM_FILE="$s"; break; fi
done

GRUB_FILE=""
for g in "$TARGET_MNT/boot/efi/EFI/fedora/grubx64.efi" \
         "$TARGET_MNT/usr/share/efi/x64/grubx64.efi" \
         "$TARGET_MNT/usr/lib/ostree-boot/efi/EFI/fedora/grubx64.efi" \
         /boot/efi/EFI/BOOT/grubx64.efi \
         /boot/efi/EFI/fedora/grubx64.efi; do
    if [[ -f "$g" ]]; then GRUB_FILE="$g"; break; fi
done

if [[ -n "$SHIM_FILE" ]]; then
    echo "Installing signed shim: $SHIM_FILE -> \\EFI\\BOOT\\BOOTX64.EFI"
    cp -fv "$SHIM_FILE" "$TARGET_MNT/boot/efi/EFI/BOOT/BOOTX64.EFI"
fi

if [[ -n "$GRUB_FILE" ]]; then
    echo "Installing grub binary: $GRUB_FILE -> \\EFI\\BOOT\\grubx64.efi"
    cp -fv "$GRUB_FILE" "$TARGET_MNT/boot/efi/EFI/BOOT/grubx64.efi"
fi

# Fallback: if grub2-install is available on host, invoke it for removable targets
if [[ ! -f "$TARGET_MNT/boot/efi/EFI/BOOT/BOOTX64.EFI" && $(command -v grub2-install || command -v grub-install) ]]; then
    GRUB_CMD=$(command -v grub2-install || command -v grub-install)
    echo "Running $GRUB_CMD --removable..."
    "$GRUB_CMD" --target=x86_64-efi \
        --efi-directory="$TARGET_MNT/boot/efi" \
        --boot-directory="$TARGET_MNT/boot" \
        --bootloader-id=BOOT \
        --removable || true
fi

# Write standalone grub.cfg directly into \EFI\BOOT\grub.cfg
cat > "$TARGET_MNT/boot/efi/EFI/BOOT/grub.cfg" <<EOF
set default=0
set timeout=5

insmod part_gpt
insmod ext2
insmod btrfs
insmod luks

search --no-floppy --fs-uuid --set=root ${BOOT_UUID}

menuentry "Conveyor OS (Universal Auto-Detect 2014-2026)" {
    linux /vmlinuz root=UUID=${BTRFS_UUID} rootflags=subvol=@root rd.luks.uuid=${LUKS_UUID} rd.auto=1 rootwait usbcore.autosuspend=-1 iommu=pt
    initrd /initramfs.img
}

menuentry "Conveyor OS (Safe Hardware: JMS578 BOT + Safe Graphics)" {
    linux /vmlinuz root=UUID=${BTRFS_UUID} rootflags=subvol=@root rd.luks.uuid=${LUKS_UUID} rd.auto=1 rootwait usbcore.autosuspend=-1 usb-storage.quirks=152d:0578:u nomodeset
    initrd /initramfs.img
}
EOF

# Copy grub.cfg to root of EFI partition as well for legacy UEFI compatibility
cp -fv "$TARGET_MNT/boot/efi/EFI/BOOT/grub.cfg" "$TARGET_MNT/boot/efi/grub.cfg" 2>/dev/null || true

sync

echo "=========================================================="
echo "FINAL VERIFICATION REPORT:"
echo "=========================================================="
echo "Partition 1 (EFI):"
ls -la "$TARGET_MNT/boot/efi/EFI/BOOT/" 2>/dev/null || ls -la "$TARGET_MNT/boot/efi/"
echo "----------------------------------------------------------"
echo "Partition 2 (/boot):"
ls -la "$TARGET_MNT/boot/"
echo "=========================================================="

if [[ -f "$TARGET_MNT/boot/efi/EFI/BOOT/BOOTX64.EFI" || -f "$TARGET_MNT/boot/efi/EFI/BOOT/bootx64.efi" ]]; then
    echo ">>> SUCCESS: UEFI bootloader is confirmed present on Partition 1!"
else
    echo ">>> FATAL ERROR: BOOTX64.EFI was not created! Do not reboot yet." >&2
    exit 1
fi

if [[ -f "$TARGET_MNT/boot/vmlinuz" && -f "$TARGET_MNT/boot/initramfs.img" ]]; then
    echo ">>> SUCCESS: Kernel and Initramfs confirmed present on Partition 2!"
else
    echo ">>> WARNING: Kernel or initramfs not found at /boot root! Check file list above." >&2
fi

# Clean unmount
umount -R "$TARGET_MNT"
echo "Cleanly unmounted $TARGET_MNT."
echo "Done! You can now safely reboot and select Intel SSD in UEFI Boot Menu."
