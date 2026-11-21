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

if ! command -v openssl >/dev/null 2>&1; then
    echo "Error: openssl is required to set the user password." >&2
    exit 1
fi

# NVMe, MMC and loop devices name partitions with a "p": /dev/nvme0n1p1
PART_PREFIX="$DISK"
[[ "$DISK" =~ [0-9]$ ]] && PART_PREFIX="${DISK}p"
P1="${PART_PREFIX}1"
P2="${PART_PREFIX}2"
P3="${PART_PREFIX}3"
P4="${PART_PREFIX}4"

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
    umount "$TARGET_MNT/proc" 2>/dev/null || true
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

# Keep the operator password across reinstalls, unless it is the old public default
PASS_HASH=""
if [[ -f "$TARGET_MNT/etc/shadow" ]]; then
    OLD_HASH=$(awk -F: '$1 == "conveyor" {print $2}' "$TARGET_MNT/etc/shadow")
    if [[ "$OLD_HASH" == \$6\$* ]]; then
        OLD_SALT=$(cut -d'$' -f3 <<<"$OLD_HASH")
        if [[ "$(openssl passwd -6 -salt "$OLD_SALT" conveyor)" != "$OLD_HASH" ]]; then
            PASS_HASH="$OLD_HASH"
        fi
    fi
fi

# Step 5: Pull and Deploy Flat Rootfs
echo "[5/7] Pulling and deploying OS image ($IMAGE_REF)..."
podman pull "$IMAGE_REF"

echo "Deploying flat rootfs to subvolume @root..."
podman rm -f conveyor-temp 2>/dev/null || true
podman create --name conveyor-temp "$IMAGE_REF"
echo "Extracting rootfs archive onto target SSD..."
# Old kernel directories must not survive: the boot step needs exactly the image kernel
rm -rf "$TARGET_MNT/usr/lib/modules"
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

# Create operator user 'conveyor' if missing
if ! grep -q "^conveyor:" "$TARGET_MNT/etc/group" 2>/dev/null; then
    echo "conveyor:x:1000:" >> "$TARGET_MNT/etc/group"
fi
if ! grep -q "^conveyor:" "$TARGET_MNT/etc/passwd" 2>/dev/null; then
    echo "Creating operator user 'conveyor'..."
    echo "conveyor:x:1000:1000:Conveyor Operator:/var/home/conveyor:/bin/bash" >> "$TARGET_MNT/etc/passwd"
fi

# There is no default password: ask for one unless a personal one was preserved
if [[ -z "$PASS_HASH" ]]; then
    while true; do
        read -rsp "Set a password for user 'conveyor': " NEW_PASSWORD; echo
        read -rsp "Repeat the password: " NEW_PASSWORD_REPEAT; echo
        if [[ -n "$NEW_PASSWORD" && "$NEW_PASSWORD" == "$NEW_PASSWORD_REPEAT" ]]; then
            break
        fi
        echo "Passwords are empty or do not match, try again."
    done
    PASS_HASH=$(printf '%s' "$NEW_PASSWORD" | openssl passwd -6 -stdin)
    unset NEW_PASSWORD NEW_PASSWORD_REPEAT
fi

SHADOW_DAYS=$(( $(date +%s) / 86400 ))
sed -i '/^conveyor:/d' "$TARGET_MNT/etc/shadow"
echo "conveyor:${PASS_HASH}:${SHADOW_DAYS}:0:99999:7:::" >> "$TARGET_MNT/etc/shadow"

# Root login stays locked: administration goes through sudo
if grep -q "^root:" "$TARGET_MNT/etc/shadow"; then
    sed -i "s|^root:[^:]*:|root:!:|" "$TARGET_MNT/etc/shadow"
fi

# Ensure conveyor is in wheel group
if ! grep -Eq '^wheel:[^:]*:[^:]*:(.*,)?conveyor(,|$)' "$TARGET_MNT/etc/group"; then
    sed -i '/^wheel:/ s/$/,conveyor/' "$TARGET_MNT/etc/group"
    sed -i '/^wheel:/ s/:,/:/' "$TARGET_MNT/etc/group"
fi

# sudo requires the operator password
mkdir -p "$TARGET_MNT/etc/sudoers.d"
echo "%wheel ALL=(ALL) ALL" > "$TARGET_MNT/etc/sudoers.d/wheel"
chmod 0440 "$TARGET_MNT/etc/sudoers.d/wheel"

# Local model storage is writable by administrators
chown root:10 "$TARGET_MNT/var/lib/models"
chmod 2775 "$TARGET_MNT/var/lib/models"

# Initialize conveyor home directory from /etc/skel
mkdir -p "$TARGET_MNT/var/home/conveyor"
if [[ -d "$TARGET_MNT/etc/skel" ]]; then
    cp -rn "$TARGET_MNT/etc/skel/." "$TARGET_MNT/var/home/conveyor/" 2>/dev/null || true
fi
chown -R 1000:1000 "$TARGET_MNT/var/home/conveyor" 2>/dev/null || true

# Ensure tuigreet cache directory exists
mkdir -p "$TARGET_MNT/var/cache/tuigreet"
chown -R 1000:1000 "$TARGET_MNT/var/cache/tuigreet" 2>/dev/null || true

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

# Step 7: Install the signed boot chain from the image onto the removable UEFI path
echo "[7/7] Installing UEFI bootloader and kernel from the image..."

fatal() {
    echo ">>> FATAL ERROR: $*" >&2
    exit 1
}

EFI_SOURCE="$TARGET_MNT/usr/lib/bootupd/updates/EFI/fedora"
ESP_EFI="$TARGET_MNT/boot/efi/EFI"
BOOT_DIR="$TARGET_MNT/boot"

mapfile -t IMAGE_KERNELS < <(find "$TARGET_MNT/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n')
(( ${#IMAGE_KERNELS[@]} == 1 )) || fatal "expected one kernel in the image, found: ${IMAGE_KERNELS[*]:-none}"
KERNEL_DIR="$TARGET_MNT/usr/lib/modules/${IMAGE_KERNELS[0]}"

for required in "$KERNEL_DIR/vmlinuz" "$KERNEL_DIR/initramfs.img" \
                "$EFI_SOURCE/shimx64.efi" "$EFI_SOURCE/grubx64.efi" "$EFI_SOURCE/mmx64.efi"; do
    [[ -s "$required" ]] || fatal "missing in image: ${required#"$TARGET_MNT"}"
done

# Replace the kernel only after the new copy is complete
cp -f "$KERNEL_DIR/vmlinuz" "$BOOT_DIR/vmlinuz.new"
cp -f "$KERNEL_DIR/initramfs.img" "$BOOT_DIR/initramfs.img.new"
sync
mv -f "$BOOT_DIR/vmlinuz.new" "$BOOT_DIR/vmlinuz"
mv -f "$BOOT_DIR/initramfs.img.new" "$BOOT_DIR/initramfs.img"

BASE_KARGS="root=UUID=${BTRFS_UUID} rootflags=subvol=@root rd.luks.name=${LUKS_UUID}=conveyor_crypt rd.auto=1 rootwait usbcore.autosuspend=-1 ${CONVEYOR_EXTRA_KARGS:-}"
NVIDIA_KARGS="rd.driver.blacklist=nouveau modprobe.blacklist=nouveau nvidia-drm.modeset=1 nvidia-drm.fbdev=1"
OPEN_GPU_KARGS="modprobe.blacklist=nvidia,nvidia_drm,nvidia_modeset,nvidia_uvm"

GRUB_CONFIG_FILE=$(mktemp)
cat >"$GRUB_CONFIG_FILE" <<EOF
set default=0
set timeout=5
set timeout_style=menu

search --no-floppy --fs-uuid --set=root ${BOOT_UUID}

set conveyor_kargs="${BASE_KARGS}"
# Unsigned NVIDIA modules cannot load under Secure Boot
if [ "\$lockdown" = "y" ]; then
    set conveyor_gpu="${OPEN_GPU_KARGS}"
else
    set conveyor_gpu="${NVIDIA_KARGS}"
fi
export conveyor_kargs conveyor_gpu

menuentry "Conveyor OS" {
    linux /vmlinuz \$conveyor_kargs \$conveyor_gpu iommu=pt quiet
    initrd /initramfs.img
}

menuentry "Conveyor OS (open NVIDIA driver: older cards)" {
    linux /vmlinuz \$conveyor_kargs ${OPEN_GPU_KARGS} iommu=pt quiet
    initrd /initramfs.img
}

menuentry "Conveyor OS (safe mode: slow USB, basic graphics)" {
    linux /vmlinuz \$conveyor_kargs usb-storage.quirks=152d:0578:u ${OPEN_GPU_KARGS} nomodeset
    initrd /initramfs.img
}
EOF

# fbx64.efi is left out on purpose: it would write boot entries into the firmware of every PC
install_efi_dir() {
    local name="$1" loader="$2" staging="$ESP_EFI/.conveyor-$1"
    rm -rf "$staging"
    mkdir -p "$staging"
    cp --no-preserve=all "$EFI_SOURCE/shimx64.efi" "$staging/$loader"
    cp --no-preserve=all "$EFI_SOURCE/grubx64.efi" "$staging/grubx64.efi"
    cp --no-preserve=all "$EFI_SOURCE/mmx64.efi" "$staging/mmx64.efi"
    cp --no-preserve=all "$GRUB_CONFIG_FILE" "$staging/grub.cfg"
    sync
    rm -rf "${ESP_EFI:?}/$name"
    mv "$staging" "$ESP_EFI/$name"
}

mkdir -p "$ESP_EFI" "$BOOT_DIR/grub2"
install_efi_dir fedora shimx64.efi
install_efi_dir BOOT BOOTX64.EFI
cp -f "$GRUB_CONFIG_FILE" "$BOOT_DIR/grub2/grub.cfg"
rm -f "$TARGET_MNT/boot/efi/grub.cfg" "$GRUB_CONFIG_FILE"

# Windows helpers and documentation go to the partition Windows can read
WINDOWS_TOOLS="$TARGET_MNT/usr/share/conveyor/windows"
DOCS_SOURCE="$TARGET_MNT/usr/share/conveyor/docs"
SHARED_MOUNT=$(mktemp -d)
if [[ -n "$SHARED_UUID" ]] && mount "$P3" "$SHARED_MOUNT"; then
    if [[ -d "$WINDOWS_TOOLS" ]]; then
        mkdir -p "$SHARED_MOUNT/ConveyorOS"
        cp --no-preserve=all "$WINDOWS_TOOLS"/* "$SHARED_MOUNT/ConveyorOS/"
    fi
    if [[ -d "$DOCS_SOURCE" ]]; then
        mkdir -p "$SHARED_MOUNT/ConveyorOS/Руководство"
        cp -rn --no-preserve=all "$DOCS_SOURCE"/* "$SHARED_MOUNT/ConveyorOS/Руководство/" 2>/dev/null || true
    fi
    umount "$SHARED_MOUNT"
else
    echo "Warning: could not copy the Windows boot helper or docs to the shared partition." >&2
fi
rmdir "$SHARED_MOUNT"

# tar drops SELinux labels, and systemd cannot start on an unlabeled root in enforcing
# mode. Label last, with the image's own tools, so this works from any live system.
echo "Applying SELinux security contexts..."
mount -t proc proc "$TARGET_MNT/proc"
if chroot "$TARGET_MNT" setfiles -F -m \
    -e /proc -e /sys -e /dev -e /run -e /tmp -e /var/tmp \
    -e /var/lib/containers -e /boot/efi \
    /etc/selinux/targeted/contexts/files/file_contexts /; then
    rm -f "$TARGET_MNT/.autorelabel"
else
    echo "Warning: labeling failed, the first boot will use permissive mode and relabel." >&2
    sed -i 's/^SELINUX=.*/SELINUX=permissive/' "$TARGET_MNT/etc/selinux/config"
    touch "$TARGET_MNT/.autorelabel"
fi
umount "$TARGET_MNT/proc"

sync

for dir in BOOT fedora; do
    loader=shimx64.efi
    [[ "$dir" == BOOT ]] && loader=BOOTX64.EFI
    cmp -s "$EFI_SOURCE/shimx64.efi" "$ESP_EFI/$dir/$loader" || fatal "\\EFI\\$dir\\$loader was not written correctly"
    cmp -s "$EFI_SOURCE/grubx64.efi" "$ESP_EFI/$dir/grubx64.efi" || fatal "\\EFI\\$dir\\grubx64.efi was not written correctly"
    [[ -s "$ESP_EFI/$dir/grub.cfg" ]] || fatal "\\EFI\\$dir\\grub.cfg is missing"
done
cmp -s "$KERNEL_DIR/vmlinuz" "$BOOT_DIR/vmlinuz" || fatal "/boot/vmlinuz does not match the image"
cmp -s "$KERNEL_DIR/initramfs.img" "$BOOT_DIR/initramfs.img" || fatal "/boot/initramfs.img does not match the image"

echo "=========================================================="
echo "Boot chain verified: \\EFI\\BOOT\\BOOTX64.EFI, kernel ${IMAGE_KERNELS[0]}"
echo "All installation steps completed successfully."
echo "Boot it from the UEFI boot menu, or from Windows with ConveyorOS\\Boot-Conveyor-OS.cmd on the SHARED drive."
echo "=========================================================="
