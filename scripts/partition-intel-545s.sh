#!/usr/bin/env bash
set -euo pipefail

# Partition & format Intel SSD 545s 256GB (238.47 GiB)
# Layout:
# 1. 1 GiB EFI System (FAT32)
# 2. 2 GiB /boot (ext4)
# 3. 50 GiB Shared Buffer (exFAT - visible in Windows & Linux out-of-the-box)
# 4. ~160 GiB LUKS2 Encrypted root (Btrfs subvolumes: @root, @home, @models, @containers, @var_cache)
# Leaves ~25 GiB unallocated TLC over-provisioning reserve at end of disk!
# WARNING: DESTROYS ALL DATA ON TARGET DISK!

DISK="${1:-}"
if [[ -z "$DISK" || ! -b "$DISK" ]]; then
    echo "Usage: sudo $0 /dev/sdX" >&2
    exit 1
fi

echo "Target disk: $DISK"
lsblk -o NAME,SIZE,MODEL,TRAN "$DISK"
read -rp "Type YES to wipe $DISK and create Conveyor OS layout with 50GB Windows-Shared Buffer: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || exit 1

wipefs -af "$DISK"
sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+1GiB   -t 1:ef00 -c 1:"CONVEYOR-EFI"   "$DISK"
sgdisk -n 2:0:+2GiB   -t 2:8300 -c 2:"CONVEYOR-BOOT"  "$DISK"
sgdisk -n 3:0:+50GiB  -t 3:0700 -c 3:"SHARED"         "$DISK" # Microsoft basic data (exFAT) for Windows exchange
# --align-end keeps the size divisible by the 4K LUKS sector. Leaves ~25 GiB unallocated over-provisioning reserve.
sgdisk --align-end -n 4:0:-25GiB -t 4:8309 -c 4:"CONVEYOR-LUKS" "$DISK"

partprobe "$DISK"
sleep 2

udevadm settle 2>/dev/null || true

# NVMe, MMC and loop devices name partitions with a "p": /dev/nvme0n1p1
PART_PREFIX="$DISK"
[[ "$DISK" =~ [0-9]$ ]] && PART_PREFIX="${DISK}p"
P1="${PART_PREFIX}1"
P2="${PART_PREFIX}2"
P3="${PART_PREFIX}3"
P4="${PART_PREFIX}4"

mkfs.vfat -F 32 -n EFI "$P1"
mkfs.ext4 -F -L BOOT "$P2"

# Format universal exchange partition (exFAT with fallback to FAT32)
if command -v mkfs.exfat >/dev/null 2>&1; then
    mkfs.exfat -n SHARED "$P3"
else
    mkfs.vfat -F 32 -n SHARED "$P3"
fi

# CONVEYOR_LUKS_BATCH skips the confirmation in the automated boot test
cryptsetup luksFormat ${CONVEYOR_LUKS_BATCH:+--batch-mode} --type luks2 --cipher aes-xts-plain64 --key-size 512 \
    --hash sha256 --pbkdf argon2id --sector-size 4096 "$P4"
cryptsetup open --allow-discards "$P4" conveyor_crypt

mkfs.btrfs -f -L CONVEYOR /dev/mapper/conveyor_crypt

mkdir -p /mnt/conveyor
mount /dev/mapper/conveyor_crypt /mnt/conveyor

for sv in @root @home @models @containers @var_cache @snapshots; do
    btrfs subvolume create "/mnt/conveyor/$sv"
done

# Critical: disable CoW and compression on @models for zero fragmentation over SATA-USB
chattr +C /mnt/conveyor/@models

umount /mnt/conveyor
echo "Done! Next: mount subvolumes and run bootc install + grub2-install --removable."
