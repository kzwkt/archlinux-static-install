#!/usr/bin/env bash

set -euo pipefail

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Error: Please run this script with root/sudo privileges." >&2
  exit 1
fi

echo "=================================================="
echo "         Arch Linux Simple Installer             "
echo "=================================================="
echo ""

# -----------------------------------------------------------------------------
# 1. Device Discovery & Clear Plain Prompts
# -----------------------------------------------------------------------------
echo "Available Storage Devices and Partitions:"
echo "--------------------------------------------------"
lsblk -p -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT | grep -E 'part|disk' || true
echo "--------------------------------------------------"
echo ""

# Prompt for ROOT Partition
while true; do
  read -r -p "Enter TARGET ROOT partition path (e.g., /dev/sda2 or /dev/nvme0n1p2): " ROOT_DEV
  if [ -b "$ROOT_DEV" ]; then
    break
  fi
  echo "Error: '$ROOT_DEV' is not a valid block device. Please try again." >&2
done

# Prompt for BOOT Partition
while true; do
  read -r -p "Enter TARGET BOOT partition path (e.g., /dev/sda1) [Leave empty for NONE]: " BOOT_DEV
  if [ -z "$BOOT_DEV" ]; then
    break
  elif [ "$BOOT_DEV" = "$ROOT_DEV" ]; then
    echo "Error: BOOT partition cannot be the same as ROOT partition!" >&2
  elif [ -b "$BOOT_DEV" ]; then
    break
  else
    echo "Error: '$BOOT_DEV' is not a valid block device. Please try again." >&2
  fi
done

# Prompt for Initramfs Generator
echo ""
echo "Select Initramfs Generator:"
echo "  1) mkinitcpio (Standard Arch default)"
echo "  2) dracut     (Fedora-style modular generator)"
echo "  3) booster    (Fast Go-based generator)"
read -r -p "Selection [1-3, Default 1]: " INIT_CHOICE
case "$INIT_CHOICE" in
  2) INITRAMFS_GENERATOR="dracut" ;;
  3) INITRAMFS_GENERATOR="booster" ;;
  *) INITRAMFS_GENERATOR="mkinitcpio" ;;
esac

# Prompt for iptables Provider
echo ""
echo "Select iptables Backend Provider:"
echo "  1) iptables        (Modern nftables backend)"
echo "  2) iptables-legacy (Legacy backend)"
read -r -p "Selection [1-2, Default 1]: " IPT_CHOICE
case "$IPT_CHOICE" in
  2) IPTABLES_PROVIDER="iptables-legacy" ;;
  *) IPTABLES_PROVIDER="iptables" ;;
esac

# Standard baseline package selection
INSTALL_PKGS=(
  "base"
  "linux"
  "$INITRAMFS_GENERATOR"
  "$IPTABLES_PROVIDER"
  "linux-firmware-whence"
  "linux-firmware"
)

# -----------------------------------------------------------------------------
# 2. Safety Review & Confirmation Prompt
# -----------------------------------------------------------------------------
echo ""
echo "=================================================="
echo "          INSTALLATION ACTION SUMMARY            "
echo "=================================================="
echo "  • TARGET ROOT (/mnt)      ==> $ROOT_DEV"
if [ -n "$BOOT_DEV" ]; then
  echo "  • TARGET BOOT (/mnt/boot) ==> $BOOT_DEV"
else
  echo "  • TARGET BOOT (/mnt/boot) ==> NONE (Root only)"
fi
echo "  • Initramfs Generator      ==> $INITRAMFS_GENERATOR"
echo "  • iptables Provider        ==> $IPTABLES_PROVIDER"
echo "  • Core Packages            ==> ${INSTALL_PKGS[*]}"
echo "=================================================="
echo ""

read -r -p "Type 'YES' to confirm and start mounting/installation: " CONFIRM
if [ "$CONFIRM" != "YES" ]; then
  echo "Installation aborted by user."
  exit 0
fi

# -----------------------------------------------------------------------------
# 3. Execution: Mounting & Pacman Setup
# -----------------------------------------------------------------------------
echo ""
echo "[1/4] Mounting ROOT ($ROOT_DEV) to /mnt..."
mount "$ROOT_DEV" /mnt

if ! mountpoint -q /mnt; then
  echo "Error: Failed to mount $ROOT_DEV to /mnt." >&2
  exit 1
fi
echo "      Successfully mounted $ROOT_DEV -> /mnt"

if [ -n "$BOOT_DEV" ]; then
  echo "[2/4] Creating /mnt/boot and mounting BOOT ($BOOT_DEV)..."
  mkdir -p /mnt/boot
  mount "$BOOT_DEV" /mnt/boot

  if ! mountpoint -q /mnt/boot; then
    echo "Error: Failed to mount $BOOT_DEV to /mnt/boot." >&2
    exit 1
  fi
  echo "      Successfully mounted $BOOT_DEV -> /mnt/boot"
else
  echo "[2/4] Skipping separate /mnt/boot mount..."
fi

echo "[3/4] Generating temporary pacman.conf and setting up /mnt environment..."
cat << 'EOF' > ./pacman.conf
[options]
HoldPkg = pacman glibc
Architecture = auto
CheckSpace
CleanMethod = KeepInstalled

[core]
SigLevel = Never DatabaseOptional
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinux/core/os/$arch

[extra]
SigLevel = Never DatabaseOptional
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinux/extra/os/$arch
EOF

STATIC_URL="https://pkgbuild.com/~morganamilo/pacman-static/x86_64/bin/pacman-static"
echo "Downloading pacman-static..."
curl -sSL -O "$STATIC_URL"
chmod +x ./pacman-static

if [ ! -x "./pacman-static" ]; then
  echo "Error: pacman-static download failed or file is not executable." >&2
  exit 1
fi

mkdir -p /mnt/var/lib/pacman
mkdir -p /mnt/etc
echo "nameserver 1.1.1.1" > /mnt/etc/resolv.conf

echo "[4/4] Installing packages into /mnt ($ROOT_DEV)..."
./pacman-static -Syu --noconfirm --needed --config ./pacman.conf --root /mnt "${INSTALL_PKGS[@]}"

echo ""
echo "=================================================="
echo "   SUCCESS: Packages installed to $ROOT_DEV!     "
echo "=================================================="
