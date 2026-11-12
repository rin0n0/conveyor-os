#!/usr/bin/env bash
set -euo pipefail

# Partition & format Intel SSD 545s 256GB (238.47 GiB) with LUKS2 + Btrfs subvolumes
# WARNING: DESTROYS ALL DATA ON TARGET DISK!

DISK="${1:-}"
if [[ -z "$DISK" || ! -b "$DISK" ]]; then
    echo "Usage: sudo $0 /dev/sdX" >&2
    exit 1
fi

echo "Target disk: $DISK"
lsblk -o NAME,SIZE,MODEL,TRAN "$DISK"
read -rp "Type YES to wipe $DISK and create Conveyor OS layout: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || exit 1

wipefs -af "$DISK"
sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+1GiB  -t 1:ef00 -c 1:"CONVEYOR-EFI"  "$DISK"
sgdisk -n 2:0:+2GiB  -t 2:8300 -c 2:"CONVEYOR-BOOT" "$DISK"
sgdisk -n 3:0:-25GiB -t 3:8309 -c 3:"CONVEYOR-LUKS" "$DISK" # Leaves ~25 GiB unallocated TLC over-provisioning reserve!

partprobe "$DISK"
sleep 2

P1="${DISK}1"
P2="${DISK}2"
P3="${DISK}3"

mkfs.vfat -F 32 -n EFI "$P1"
mkfs.ext4 -F -L BOOT "$P2"

cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 \
    --hash sha256 --pbkdf argon2id --sector-size 4096 "$P3"
cryptsetup open --allow-discards "$P3" conveyor_crypt

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
