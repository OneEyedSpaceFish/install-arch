#!/bin/bash
# Optimized for:
# - Intel Desktop CPU
# - NVIDIA GPU
# - Wired Ethernet
# - NVMe SSD
# - Wayland (Sway) preparation
# - US Keyboard Layout

set -e

confirm() {
    read -p "$1 (y/n): " response
    case "$response" in
        [yY]) return 0 ;;
        *) echo "Exiting script."; exit 1 ;;
    esac
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

# Check for NVMe drive
if [ ! -b /dev/nvme0n1 ]; then
  echo "NVMe drive /dev/nvme0n1 not found!"
  exit 1
fi

# Check for UEFI boot mode
if ! [ -d /sys/firmware/efi ]; then
    echo "Not booted in UEFI mode!"
    exit 1
fi

# Verify Intel CPU
if ! grep -q "Intel" /proc/cpuinfo; then
    echo "No Intel CPU detected!"
    exit 1
fi

# Verify NVIDIA GPU
if ! lspci | grep -i nvidia > /dev/null; then
    echo "No NVIDIA GPU detected!"
    exit 1
fi

# Set keyboard layout and time
loadkeys us
timedatectl set-ntp true

# Calculate drive sizes
DRIVE_SIZE_MB=$(blockdev --getsize64 /dev/nvme0n1 | awk '{print int($1/1024/1024)}')
EFI_SIZE=1024                    # 1GB for EFI
SWAP_SIZE=32768                  # 32GB for swap
USABLE_SPACE=$(echo "$DRIVE_SIZE_MB * 0.85" | bc | awk '{print int($1)}')  # 85% of total space
MAIN_SPACE=$(echo "$USABLE_SPACE - $EFI_SIZE - $SWAP_SIZE" | bc)
RESERVED_SIZE=$(echo "$DRIVE_SIZE_MB - $USABLE_SPACE" | bc)

echo "Drive layout:"
echo "Total drive size: ${DRIVE_SIZE_MB}MB"
echo "EFI partition: ${EFI_SIZE}MB"
echo "Swap partition: ${SWAP_SIZE}MB"
echo "Main space: ${MAIN_SPACE}MB"
echo "Reserved for over-provisioning: ${RESERVED_SIZE}MB"

confirm "Are these partition sizes acceptable?"

# Create partitions
parted -s /dev/nvme0n1 mklabel gpt
parted -s /dev/nvme0n1 mkpart ESP fat32 1MiB ${EFI_SIZE}MiB
parted -s /dev/nvme0n1 set 1 boot on
parted -s /dev/nvme0n1 mkpart primary linux-swap ${EFI_SIZE}MiB $((EFI_SIZE + SWAP_SIZE))MiB
parted -s /dev/nvme0n1 mkpart primary $((EFI_SIZE + SWAP_SIZE))MiB ${USABLE_SPACE}MiB

confirm "Partitions created. Continue with formatting?"

# Format partitions
mkfs.fat -F32 /dev/nvme0n1p1
mkswap -L swap /dev/nvme0n1p2
swapon /dev/nvme0n1p2

confirm "Swap setup complete. Continue with encryption setup?"

# Setup encryption
cryptsetup luksFormat --type luks2 -c aes-xts-plain64 -s 512 -h sha512 /dev/nvme0n1p3
cryptsetup open /dev/nvme0n1p3 cryptlvm

confirm "Encryption setup complete. Continue with LVM setup?"

# Setup LVM
pvcreate /dev/mapper/cryptlvm
vgcreate vg0 /dev/mapper/cryptlvm
lvcreate -L 30G vg0 -n root
lvcreate -l 100%FREE vg0 -n home

confirm "LVM setup complete. Continue with formatting LVM volumes?"

# Format LVM volumes with SSD optimizations
mkfs.ext4 -O "^has_journal" /dev/vg0/root
mkfs.ext4 -O "^has_journal" /dev/vg0/home

confirm "LVM volumes formatted. Continue with mounting partitions?"

# Mount partitions
mount /dev/vg0/root /mnt
mkdir /mnt/boot
mount /dev/nvme0n1p1 /mnt/boot
mkdir /mnt/home
mount /dev/vg0/home /mnt/home

confirm "Partitions mounted. Continue with base system installation?"

# Install base system - optimized package selection
pacstrap /mnt base base-devel linux linux-headers linux-firmware \
    intel-ucode nvidia nvidia-utils \
    neovim git \
    cpupower nfs-utils hdparm

# Generate and optimize fstab
genfstab -U /mnt > /mnt/etc/fstab
sed -i 's/relatime/noatime,discard=async,commit=60,lazytime,errors=remount-ro/' /mnt/etc/fstab

confirm "Base system installed and fstab generated. Continue with system configuration?"

# Chroot configuration
arch-chroot /mnt /bin/bash << 'EOF'
# Set timezone and clock
ln -sf /usr/share/zoneinfo/Europe/London /etc/localtime
hwclock --systohc

# Set locale
echo "en_GB.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_GB.UTF-8" > /etc/locale.conf

# Set keyboard layout
echo "KEYMAP=us" > /etc/vconsole.conf

# Set hostname
echo "usagi" > /etc/hostname

# Configure hosts file
cat << HOSTS > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   usagi.localdomain    usagi
HOSTS

# Set root password
echo "Please set root password:"
passwd

# Configure ethernet
cat << NETWORK > /etc/systemd/network/20-wired.network
[Match]
Name=en*

[Network]
DHCP=yes
IPv6PrivacyExtensions=true

[DHCP]
RouteMetric=10
UseDNS=no
NETWORK

# Enable networking services
systemctl enable systemd-networkd
systemctl enable systemd-resolved

# Create symlink for DNS resolution
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# Install and configure bootloader
bootctl install
cat << BOOTLOADER > /boot/loader/loader.conf
default arch
timeout 3
editor 0
BOOTLOADER

# Configure kernel parameters - optimized for Intel CPU and NVIDIA GPU
PARTUUID=$(blkid -s PARTUUID -o value /dev/nvme0n1p3)
cat << BOOTLOADER > /boot/loader/entries/arch.conf
title Arch Linux
linux /vmlinuz-linux
initrd /intel-ucode.img
initrd /initramfs-linux.img
options cryptdevice=PARTUUID=$PARTUUID:cryptlvm:allow-discards root=/dev/vg0/root quiet rw nvidia-drm.modeset=1 nouveau.modeset=0 nmi_watchdog=0 audit=0 nowatchdog nvidia.NVreg_PreserveVideoMemoryAllocations=1 nvidia-drm.fbdev=1 intel_pstate=active intel_iommu=on iommu=pt pcie_aspm=off
BOOTLOADER

# Configure environment variables
cat << ENVVARS > /etc/environment
LIBVA_DRIVER_NAME=nvidia
XDG_SESSION_TYPE=wayland
GBM_BACKEND=nvidia-drm
__GLX_VENDOR_LIBRARY_NAME=nvidia
WLR_NO_HARDWARE_CURSORS=1
EDITOR=nvim
VISUAL=nvim
ENVVARS

# Configure mkinitcpio
sed -i 's/^MODULES=()/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=(base udev autodetect modconf block filesystems keyboard fsck)/HOOKS=(base udev autodetect modconf block encrypt lvm2 filesystems keyboard fsck)/' /etc/mkinitcpio.conf
mkinitcpio -p linux

# Enable essential services
systemctl enable nvidia-persistenced.service
systemctl enable cpupower.service

# Configure CPU for desktop performance
cat << CPU > /etc/default/cpupower
governor='performance'
min_freq="default"
max_freq="default"
CPU

# System optimizations for desktop
cat << SYSCTL > /etc/sysctl.d/99-desktop-performance.conf
# I/O optimizations
vm.swappiness=1
vm.vfs_cache_pressure=50
vm.dirty_background_ratio=5
vm.dirty_ratio=10
vm.dirty_writeback_centisecs=1500
vm.dirty_expire_centisecs=3000

# Network optimizations
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 8192
net.core.rmem_default = 1048576
net.core.rmem_max = 16777216
net.core.wmem_default = 1048576
net.core.wmem_max = 16777216
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_slow_start_after_idle = 0

# File system optimizations
fs.inotify.max_user_watches = 524288
fs.file-max = 2097152

# CPU and process optimizations
kernel.nmi_watchdog = 0
kernel.sched_autogroup_enabled = 0
SYSCTL

# NVMe I/O scheduler optimization
cat << IO > /etc/udev/rules.d/60-scheduler.rules
# Set none scheduler for NVMe
ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="none"
IO

# Thermal configuration for Intel CPU
cat << THERMAL > /etc/tmpfiles.d/thermal-performance.conf
# Enable Intel turbo boost for desktop performance
w /sys/devices/system/cpu/intel_pstate/no_turbo - - - - 0
THERMAL

# Disk performance service
cat << POWER > /etc/systemd/system/disk-performance.service
[Unit]
Description=Disk Performance Settings
After=multi-user.target

[Service]
Type=oneshot
# Optimize write back timing for NVMe
ExecStart=/usr/bin/bash -c 'echo 1500 > /proc/sys/vm/dirty_writeback_centisecs'
# Set relatively aggressive write back for desktop performance
ExecStart=/usr/bin/bash -c 'echo 10 > /proc/sys/vm/dirty_ratio'
ExecStart=/usr/bin/bash -c 'echo 5 > /proc/sys/vm/dirty_background_ratio'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
POWER

# Enable the disk performance service
systemctl enable disk-performance.service

# Add NVIDIA hook
mkdir -p /etc/pacman.d/hooks
cat << HOOK > /etc/pacman.d/hooks/nvidia.hook
[Trigger]
Operation=Install
Operation=Upgrade
Operation=Remove
Type=Package
Target=nvidia
Target=linux

[Action]
Description=Update NVIDIA module in initcpio
Depends=mkinitcpio
When=PostTransaction
NeedsTargets
Exec=/bin/sh -c 'while read -r trg; do case $trg in linux) exit 0; esac; done; /usr/bin/mkinitcpio -P'
HOOK

# Configure crypttab with TRIM support
echo "cryptlvm UUID=$(blkid -s UUID -o value /dev/nvme0n1p3) none luks,discard" >> /etc/crypttab

# Configure pacman
sed -i 's/#ParallelDownloads = 5/ParallelDownloads = 15/' /etc/pacman.conf
sed -i '/\[multilib\]/,/Include/s/^#//' /etc/pacman.conf

# Optimize makepkg for desktop CPU
sed -i "s/#MAKEFLAGS=\"-j2\"/MAKEFLAGS=\"-j\$(nproc)\"/" /etc/makepkg.conf
sed -i "s/COMPRESSXZ=(xz -c -z -)/COMPRESSXZ=(xz -c -z - --threads=0)/" /etc/makepkg.conf

# Create user
useradd -m -G wheel,video,audio -s /bin/bash senpai
echo "Please set password for user senpai:"
passwd senpai

# Configure sudo
echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/wheel

EOF

confirm "System configuration complete. Ready to unmount and reboot?"

# Cleanup and reboot
umount -R /mnt
swapoff -a
cryptsetup close cryptlvm
sync
reboot
