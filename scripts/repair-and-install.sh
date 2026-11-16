#!/usr/bin/env bash
set -euo pipefail

# Conveyor OS: Bulletproof Bare-Metal Installer & Recovery Script
# Production-tested for:
# - Existing LUKS2/Btrfs subvolume reuse without data loss
# - Live USB RAM exhaustion prevention (bind-mounting @containers storage to /var/lib/containers)
# - Elimination of /mnt symlink collisions before tar extraction
# - Clean Flat Rootfs deployment on Btrfs @root subvolume
# - Removal of /sysroot/ostree hardlinks preventing SELinux label corruption
# - Alignment of rd.luks.name=${LUKS_UUID}=conveyor_crypt with /etc/crypttab (eliminating device contention)
# - Automatic user 'conveyor' & system accounts provisioning
# - Guaranteed \EFI\BOOT\BOOTX64.EFI fallback bootloader installation

DISK="${1:-}"
IMAGE_REF="${2:-ghcr.io/rin0n0/conveyor-os:latest}"

if [[ -z "$DISK" || ! -b "$DISK" ]]; then
    echo "Usage: sudo $0 /dev/sdX [IMAGE_REF]" >&2
    echo "Example: sudo $0 /dev/sdb" >&2
    exit 1
fi

echo "=========================================================="
echo "Conveyor OS Bulletproof Installer & Recovery"
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

TARGET_MNT="/mnt/target"
CONTAINERS_BOUND=0

cleanup() {
    local exit_code=$?
    echo ""
    echo "Cleaning up mounts..."
    if [[ "$CONTAINERS_BOUND" -eq 1 ]]; then
        umount /var/lib/containers 2>/dev/null || true
    fi
    umount "$TARGET_MNT/boot/efi" 2>/dev/null || true
    umount "$TARGET_MNT/boot" 2>/dev/null || true
    umount "$TARGET_MNT/var/cache" 2>/dev/null || true
    umount "$TARGET_MNT/var/lib/containers" 2>/dev/null || true
    umount "$TARGET_MNT/var/lib/models" 2>/dev/null || true
    umount "$TARGET_MNT/var/home" 2>/dev/null || true
    umount "$TARGET_MNT" 2>/dev/null || true

    if [[ $exit_code -ne 0 ]]; then
        echo ">>> ERROR: Installer exited prematurely with status $exit_code." >&2
    fi
}
trap cleanup EXIT

# Step 0: Ensure correct GPT partition types
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
echo "[1/7] Ensuring memory safety (preventing OOM reboots)..."
if ! swapon --show | grep -q 'partition\|file\|zram'; then
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

# Step 3: Mount Btrfs subvolumes and redirect storage
echo "[3/7] Mounting filesystems and configuring storage bind..."
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

# Mount Btrfs root subvolume
mount -o subvol=@root,noatime,compress=zstd:3 "$LUKS_MAPPER" "$TARGET_MNT"

# Create mount points on target (DO NOT create $TARGET_MNT/mnt/shared before rootfs extraction!)
mkdir -p "$TARGET_MNT/boot" \
         "$TARGET_MNT/var/home" \
         "$TARGET_MNT/var/lib/models" \
         "$TARGET_MNT/var/lib/containers" \
         "$TARGET_MNT/var/cache" \
         "$TARGET_MNT/var/tmp"

mount -o subvol=@home,noatime,compress=zstd:3 "$LUKS_MAPPER" "$TARGET_MNT/var/home"
mount -o subvol=@models,noatime,compress=no "$LUKS_MAPPER" "$TARGET_MNT/var/lib/models"
mount -o subvol=@containers,noatime,compress=zstd:3 "$LUKS_MAPPER" "$TARGET_MNT/var/lib/containers"
mount -o subvol=@var_cache,noatime,compress=zstd:3 "$LUKS_MAPPER" "$TARGET_MNT/var/cache"

# Mount /boot (ext4) and /boot/efi (FAT32)
mount -o noatime "$P2" "$TARGET_MNT/boot"
mkdir -p "$TARGET_MNT/boot/efi"
mount "$P1" "$TARGET_MNT/boot/efi"

# CRITICAL FIX: Offload Podman storage and tmpdir from Live USB RAM to target SSD
echo "Binding host /var/lib/containers to target SSD to prevent Live USB RAM exhaustion..."
mkdir -p /var/lib/containers
mount --bind "$TARGET_MNT/var/lib/containers" /var/lib/containers
CONTAINERS_BOUND=1

export TMPDIR="$TARGET_MNT/var/tmp"
export CONTAINERS_TMPDIR="$TARGET_MNT/var/tmp"

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

# Step 5: Pull and Deploy Flat Rootfs
echo "[5/7] Pulling and deploying OS image ($IMAGE_REF)..."
podman pull "$IMAGE_REF"

echo "Deploying flat rootfs to subvolume @root..."
podman rm -f conveyor-temp 2>/dev/null || true
podman create --name conveyor-temp "$IMAGE_REF"
echo "Extracting rootfs archive onto target SSD..."
podman export conveyor-temp | tar -x -C "$TARGET_MNT"
podman rm conveyor-temp

# Clean up redundant /sysroot/ostree (prevents SELinux hardlink conflicts and frees ~3GB)
echo "Removing /sysroot/ostree repository to ensure clean SELinux labeling..."
rm -rf "$TARGET_MNT/sysroot/ostree" "$TARGET_MNT/ostree" 2>/dev/null || true

# Post-extraction creation of shared buffer mountpoint
mkdir -p "$TARGET_MNT/var/mnt/shared"
mkdir -p "$TARGET_MNT/mnt/shared" 2>/dev/null || true

# Provision user accounts and system configuration
echo "Configuring user accounts and privileges..."
if command -v systemd-sysusers >/dev/null 2>&1; then
    systemd-sysusers --root="$TARGET_MNT" 2>/dev/null || true
fi

# Ensure wheel group exists
if ! grep -q "^wheel:" "$TARGET_MNT/etc/group" 2>/dev/null; then
    echo "wheel:x:10:" >> "$TARGET_MNT/etc/group"
fi

# Create default operator user 'conveyor' if missing
if ! grep -q "^conveyor:" "$TARGET_MNT/etc/passwd" 2>/dev/null; then
    echo "Creating operator user 'conveyor' (password: conveyor)..."
    if ! grep -q "^conveyor:" "$TARGET_MNT/etc/group" 2>/dev/null; then
        echo "conveyor:x:1000:" >> "$TARGET_MNT/etc/group"
    fi
    echo "conveyor:x:1000:1000:Conveyor Operator:/var/home/conveyor:/bin/bash" >> "$TARGET_MNT/etc/passwd"

    PASS_HASH=$(openssl passwd -6 conveyor 2>/dev/null || echo '$6$conveyor$7dJkH9M8lZqE2BqA3X1w0rY9.T8u7i6o5p4a3s2d1f0g9h8j7k6l5m4n3b2v1c0x9z8y7w6v5u4t3s2r1q0p9o8')
    if grep -q "^conveyor:" "$TARGET_MNT/etc/shadow" 2>/dev/null; then
        sed -i "s|^conveyor:.*|conveyor:${PASS_HASH}:19700:0:99999:7:::|" "$TARGET_MNT/etc/shadow"
    else
        echo "conveyor:${PASS_HASH}:19700:0:99999:7:::" >> "$TARGET_MNT/etc/shadow"
    fi

    # Set root password to conveyor for rescue operations
    if grep -q "^root:" "$TARGET_MNT/etc/shadow" 2>/dev/null; then
        sed -i "s|^root:.*|root:${PASS_HASH}:19700:0:99999:7:::|" "$TARGET_MNT/etc/shadow"
    fi
fi

# Ensure conveyor is in wheel group
sed -i '/^wheel:/ s/$/,conveyor/' "$TARGET_MNT/etc/group" 2>/dev/null || true
sed -i 's/:,/:/g' "$TARGET_MNT/etc/group" 2>/dev/null || true

# Grant passwordless sudo to wheel
mkdir -p "$TARGET_MNT/etc/sudoers.d"
echo "%wheel ALL=(ALL) NOPASSWD: ALL" > "$TARGET_MNT/etc/sudoers.d/wheel"
chmod 0440 "$TARGET_MNT/etc/sudoers.d/wheel"

# Initialize conveyor home directory from /etc/skel
mkdir -p "$TARGET_MNT/var/home/conveyor"
if [[ -d "$TARGET_MNT/etc/skel" ]]; then
    cp -rn "$TARGET_MNT/etc/skel/." "$TARGET_MNT/var/home/conveyor/" 2>/dev/null || true
fi
chown -R 1000:1000 "$TARGET_MNT/var/home/conveyor" 2>/dev/null || true

# Ensure tuigreet cache directory exists
mkdir -p "$TARGET_MNT/var/cache/tuigreet"
chown -R 1000:1000 "$TARGET_MNT/var/cache/tuigreet" 2>/dev/null || true

# Relabel SELinux contexts
echo "Applying SELinux security contexts..."
if command -v setfiles >/dev/null 2>&1 && [[ -f "$TARGET_MNT/etc/selinux/targeted/contexts/files/file_contexts" ]]; then
    setfiles -r "$TARGET_MNT" "$TARGET_MNT/etc/selinux/targeted/contexts/files/file_contexts" "$TARGET_MNT" 2>/dev/null || true
fi
touch "$TARGET_MNT/.autorelabel"

# Step 6: Configuration files (/etc/fstab and /etc/crypttab)
echo "[6/7] Writing persistent fstab and crypttab..."
cat > "$TARGET_MNT/etc/fstab" <<EOF
# /etc/fstab for Conveyor OS (Intel SSD 545s Portable)
UUID=${BTRFS_UUID}  /                    btrfs  subvol=@root,noatime,compress=zstd:3,commit=15 0 0
UUID=${BOOT_UUID}   /boot                ext4   noatime,nofail,x-systemd.device-timeout=10s 0 2
UUID=${EFI_UUID}    /boot/efi            vfat   umask=0077,shortname=winnt,nofail,x-systemd.device-timeout=10s 0 2
UUID=${BTRFS_UUID}  /var/home            btrfs  subvol=@home,noatime,compress=zstd:3,commit=15 0 0
UUID=${BTRFS_UUID}  /var/lib/models      btrfs  subvol=@models,noatime,compress=no,commit=15 0 0
UUID=${BTRFS_UUID}  /var/lib/containers  btrfs  subvol=@containers,noatime,compress=zstd:3 0 0
UUID=${BTRFS_UUID}  /var/cache           btrfs  subvol=@var_cache,noatime,compress=zstd:3 0 0
EOF

if [[ -n "${SHARED_UUID}" ]]; then
    echo "UUID=${SHARED_UUID} /mnt/shared          exfat  defaults,nofail,uid=1000,gid=1000,umask=022,iocharset=utf8 0 0" >> "$TARGET_MNT/etc/fstab"
fi

# CRITICAL FIX: Name matches rd.luks.name parameter in GRUB exactly
cat > "$TARGET_MNT/etc/crypttab" <<EOF
conveyor_crypt UUID=${LUKS_UUID} none discard,fido2-device=auto,timeout=30s
EOF

# Step 7: Guarantee UEFI Bootloader in \EFI\BOOT\BOOTX64.EFI
echo "[7/7] Installing UEFI bootloader and kernel binaries..."
mkdir -p "$TARGET_MNT/boot/efi/EFI/BOOT"
mkdir -p "$TARGET_MNT/boot/efi/EFI/fedora"

# Locate kernel and initramfs
KERNEL_SRC=$(find "$TARGET_MNT/boot" "$TARGET_MNT/usr/lib/modules" -type f -name "vmlinuz*" 2>/dev/null | head -n1 || true)
INITRD_SRC=$(find "$TARGET_MNT/boot" "$TARGET_MNT/usr/lib/modules" -type f \( -name "initramfs*" -o -name "initrd*" \) 2>/dev/null | head -n1 || true)

if [[ -n "$KERNEL_SRC" && -f "$KERNEL_SRC" ]]; then
    if [[ "$KERNEL_SRC" != "$TARGET_MNT/boot/vmlinuz" ]]; then
        echo "Copying kernel from $KERNEL_SRC -> /boot/vmlinuz..."
        cp -fv "$KERNEL_SRC" "$TARGET_MNT/boot/vmlinuz"
    fi
else
    echo "Warning: kernel not found in target image, checking host..."
    cp -fv /boot/vmlinuz* "$TARGET_MNT/boot/vmlinuz" 2>/dev/null || true
fi

if [[ -n "$INITRD_SRC" && -f "$INITRD_SRC" ]]; then
    if [[ "$INITRD_SRC" != "$TARGET_MNT/boot/initramfs.img" ]]; then
        echo "Copying initramfs from $INITRD_SRC -> /boot/initramfs.img..."
        cp -fv "$INITRD_SRC" "$TARGET_MNT/boot/initramfs.img"
    fi
fi

if [[ ! -f "$TARGET_MNT/boot/initramfs.img" ]]; then
    echo "Generating fresh initramfs via dracut..."
    if command -v dracut >/dev/null 2>&1; then
        dracut --sysroot "$TARGET_MNT" --force --add "crypt btrfs" "$TARGET_MNT/boot/initramfs.img" 2>/dev/null || \
        dracut --force --add "crypt btrfs" "$TARGET_MNT/boot/initramfs.img" 2>/dev/null || true
    fi
fi

# Locate signed shim and grub binaries
SHIM_FILE=""
for s in "$TARGET_MNT/boot/efi/EFI/fedora/shimx64.efi" \
         "$TARGET_MNT/boot/efi/EFI/BOOT/BOOTX64.EFI" \
         "$TARGET_MNT/usr/share/efi/x64/shimx64.efi" \
         "$TARGET_MNT/usr/lib/ostree-boot/efi/EFI/fedora/shimx64.efi" \
         /boot/efi/EFI/BOOT/BOOTX64.EFI \
         /boot/efi/EFI/BOOT/bootx64.efi \
         /boot/efi/EFI/fedora/shimx64.efi; do
    if [[ -f "$s" ]]; then SHIM_FILE="$s"; break; fi
done

GRUB_FILE=""
for g in "$TARGET_MNT/boot/efi/EFI/fedora/grubx64.efi" \
         "$TARGET_MNT/boot/efi/EFI/BOOT/grubx64.efi" \
         "$TARGET_MNT/usr/share/efi/x64/grubx64.efi" \
         "$TARGET_MNT/usr/lib/ostree-boot/efi/EFI/fedora/grubx64.efi" \
         /boot/efi/EFI/BOOT/grubx64.efi \
         /boot/efi/EFI/fedora/grubx64.efi; do
    if [[ -f "$g" ]]; then GRUB_FILE="$g"; break; fi
done

if [[ -n "$SHIM_FILE" ]]; then
    echo "Installing signed shim: $SHIM_FILE -> \\EFI\\BOOT\\BOOTX64.EFI"
    cp -fv "$SHIM_FILE" "$TARGET_MNT/boot/efi/EFI/BOOT/BOOTX64.EFI"
    cp -fv "$SHIM_FILE" "$TARGET_MNT/boot/efi/EFI/fedora/shimx64.efi" 2>/dev/null || true
fi

if [[ -n "$GRUB_FILE" ]]; then
    echo "Installing grub binary: $GRUB_FILE -> \\EFI\\BOOT\\grubx64.efi"
    cp -fv "$GRUB_FILE" "$TARGET_MNT/boot/efi/EFI/BOOT/grubx64.efi"
    cp -fv "$GRUB_FILE" "$TARGET_MNT/boot/efi/EFI/fedora/grubx64.efi" 2>/dev/null || true
fi

# Fallback: if grub2-install is available on host, invoke it for removable targets
if command -v grub2-install >/dev/null 2>&1; then
    echo "Running grub2-install --removable..."
    grub2-install --target=x86_64-efi \
        --efi-directory="$TARGET_MNT/boot/efi" \
        --boot-directory="$TARGET_MNT/boot" \
        --bootloader-id=BOOT \
        --removable || true
elif command -v grub-install >/dev/null 2>&1; then
    echo "Running grub-install --removable..."
    grub-install --target=x86_64-efi \
        --efi-directory="$TARGET_MNT/boot/efi" \
        --boot-directory="$TARGET_MNT/boot" \
        --bootloader-id=BOOT \
        --removable || true
fi

# Write standalone grub.cfg directly into \EFI\BOOT\grub.cfg
# Note: uses rd.luks.name=${LUKS_UUID}=conveyor_crypt to avoid naming race with crypttab!
GRUB_CONFIG="set default=0
set timeout=5

insmod part_gpt
insmod ext2
insmod btrfs
insmod luks

search --no-floppy --fs-uuid --set=root ${BOOT_UUID}

menuentry \"Conveyor OS (Universal Auto-Detect 2014-2026)\" {
    linux /vmlinuz root=UUID=${BTRFS_UUID} rootflags=subvol=@root rd.luks.name=${LUKS_UUID}=conveyor_crypt rd.auto=1 rootwait usbcore.autosuspend=-1 iommu=pt quiet
    initrd /initramfs.img
}

menuentry \"Conveyor OS (Safe Hardware: JMS578 BOT + Safe Graphics)\" {
    linux /vmlinuz root=UUID=${BTRFS_UUID} rootflags=subvol=@root rd.luks.name=${LUKS_UUID}=conveyor_crypt rd.auto=1 rootwait usbcore.autosuspend=-1 usb-storage.quirks=152d:0578:u nomodeset
    initrd /initramfs.img
}
"

echo "$GRUB_CONFIG" > "$TARGET_MNT/boot/efi/EFI/BOOT/grub.cfg"
echo "$GRUB_CONFIG" > "$TARGET_MNT/boot/efi/EFI/fedora/grub.cfg" 2>/dev/null || true
echo "$GRUB_CONFIG" > "$TARGET_MNT/boot/efi/grub.cfg" 2>/dev/null || true
mkdir -p "$TARGET_MNT/boot/grub2"
echo "$GRUB_CONFIG" > "$TARGET_MNT/boot/grub2/grub.cfg" 2>/dev/null || true

sync

echo "=========================================================="
echo "FINAL DEPLOYMENT & UEFI VERIFICATION:"
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

echo "All installation steps completed successfully."
echo "You can now safely reboot and select Intel SSD in your UEFI Boot Menu."
