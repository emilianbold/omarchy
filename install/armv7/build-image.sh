#!/bin/bash
# Build an SD card image of Omarchy on Arch Linux ARM for Rockchip RK3288
# "veyron" Chromebooks, initially the Asus C201P.
#
# Run as root on an x86_64 Linux host with qemu-user-static binfmt registered:
#   sudo install/armv7/build-image.sh
#
# Boot chain (see docs/armv7.md): Depthcharge loads the signed KERN-A payload,
# which holds U-Boot rather than Linux. U-Boot reads
# /boot/extlinux/extlinux.conf off the ext4 root and boots the stock Arch Linux
# ARM kernel and initramfs as ordinary files, so kernel upgrades on the machine
# re-sign nothing.
#
# The signed U-Boot comes from the emilianbold/c201p project, which built and
# verified it on this hardware; this script does not rebuild it. Point
# UBOOT_KPART at a local copy to avoid the download.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OMARCHY_SOURCE="${OMARCHY_SOURCE:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

IMAGE_FILE="${IMAGE_FILE:-omarchy-armv7-veyron.img}"
IMAGE_SIZE="${IMAGE_SIZE:-8192M}"
ROOT_LABEL="${ROOT_LABEL:-omarchy}"
HOSTNAME="${HOSTNAME:-omarchy}"
USERNAME="${USERNAME:-omarchy}"
PASSWORD="${PASSWORD:-omarchy}"
ROOT_PASSWORD="${ROOT_PASSWORD:-omarchy}"
TIMEZONE="${TIMEZONE:-Etc/UTC}"
LOCALE="${LOCALE:-en_US.UTF-8}"

ROOTFS_URL="${ROOTFS_URL:-http://os.archlinuxarm.org/os/ArchLinuxARM-armv7-latest.tar.gz}"
ROOTFS_TARBALL="${ROOTFS_TARBALL:-}"
UBOOT_KPART="${UBOOT_KPART:-}"
UBOOT_KPART_URL="${UBOOT_KPART_URL:-https://github.com/emilianbold/c201p/releases/latest/download/debian-c201p-uboot.kpart}"

# The compatible strings a booted veyron-speedy reports. Setup runs in a chroot
# where /proc/device-tree does not exist, so board detection and the device tree
# lookup read this file instead.
DT_COMPATIBLE="google,veyron-speedy
google,veyron
rockchip,rk3288"

MOUNT_DIR="$(mktemp -d /tmp/omarchy-armv7-XXXXXX)"
LOOP_DEV=""
WORK_DIR="$(mktemp -d /tmp/omarchy-armv7-work-XXXXXX)"

log() { echo "▸ $*"; }

cleanup() {
  set +e
  rm -f "${MOUNT_DIR}/usr/bin/qemu-arm-static"
  for sub in dev/pts dev sys proc; do
    mountpoint -q "${MOUNT_DIR}/${sub}" && umount -l "${MOUNT_DIR}/${sub}"
  done
  mountpoint -q "$MOUNT_DIR" && umount -l "$MOUNT_DIR"
  [[ -n $LOOP_DEV ]] && losetup -d "$LOOP_DEV" 2>/dev/null
  rm -rf "$MOUNT_DIR" "$WORK_DIR"
}
trap cleanup EXIT

in_target() {
  chroot "$MOUNT_DIR" "$@"
}

# ── Preflight ─────────────────────────────────────────────────────────────────
(( EUID == 0 )) || { echo "Run as root (sudo $0)" >&2; exit 1; }

missing=()
for cmd in sgdisk cgpt losetup mkfs.ext4 curl bsdtar qemu-arm-static; do
  command -v "$cmd" >/dev/null || missing+=("$cmd")
done
if (( ${#missing[@]} > 0 )); then
  echo "Missing tools: ${missing[*]}" >&2
  echo "  Arch:   pacman -S gptfdisk cgpt libarchive curl qemu-user-static qemu-user-static-binfmt" >&2
  echo "  Debian: apt install gdisk cgpt libarchive-tools curl qemu-user-static binfmt-support" >&2
  exit 1
fi

# ── Step 0: signed U-Boot ─────────────────────────────────────────────────────
log "[0/7] Preparing the signed U-Boot payload"
if [[ -z $UBOOT_KPART ]]; then
  UBOOT_KPART="$WORK_DIR/uboot.kpart"
  log "    Downloading ${UBOOT_KPART_URL}"
  curl -fsSL --retry 3 --retry-delay 5 -o "$UBOOT_KPART" "$UBOOT_KPART_URL"
fi
[[ -s $UBOOT_KPART ]] || { echo "U-Boot kpart ${UBOOT_KPART} is missing or empty" >&2; exit 1; }
log "    U-Boot kpart: $(du -h "$UBOOT_KPART" | cut -f1)"

# ── Step 1: rootfs tarball ────────────────────────────────────────────────────
log "[1/7] Preparing the Arch Linux ARM rootfs"
if [[ -z $ROOTFS_TARBALL ]]; then
  ROOTFS_TARBALL="$WORK_DIR/rootfs.tar.gz"
  log "    Downloading ${ROOTFS_URL}"
  curl -fsSL --retry 3 --retry-delay 5 -o "$ROOTFS_TARBALL" "$ROOTFS_URL"

  # Arch Linux ARM publishes an md5 next to the tarball. Check it when it is
  # reachable rather than skipping verification entirely.
  if curl -fsSL --retry 2 -o "$WORK_DIR/rootfs.md5" "${ROOTFS_URL}.md5" 2>/dev/null; then
    expected=$(cut -d' ' -f1 <"$WORK_DIR/rootfs.md5")
    actual=$(md5sum "$ROOTFS_TARBALL" | cut -d' ' -f1)
    [[ $expected == "$actual" ]] ||
      { echo "Rootfs checksum mismatch: expected ${expected}, got ${actual}" >&2; exit 1; }
    log "    Checksum verified (${actual})"
  else
    log "    No published checksum reachable; continuing unverified"
  fi
fi

# ── Step 2: partition ─────────────────────────────────────────────────────────
# KERN-A holds the signed U-Boot; the kernel and initramfs live on the ext4 root
# where no Depthcharge staging limit applies. cgpt sets the ChromeOS boot
# attributes sgdisk knows nothing about; sgdisk writes the GPT itself, because
# `cgpt create` on a plain file produces a table the loop driver will not parse.
log "[2/7] Creating and partitioning ${IMAGE_FILE} (${IMAGE_SIZE})"
rm -f "$IMAGE_FILE"
truncate -s "$IMAGE_SIZE" "$IMAGE_FILE"
sgdisk -o -a 8192 \
  -n 1:8192:+64M -t 1:7F00 -c 1:"KERN-A" \
  -n 2:0:0 -t 2:8300 -c 2:"ROOTFS" \
  "$IMAGE_FILE" >/dev/null
cgpt add -i 1 -S 1 -T 5 -P 10 "$IMAGE_FILE"

LOOP_DEV=$(losetup --partscan --find --show "$IMAGE_FILE")
PART_KERN="${LOOP_DEV}p1"
PART_ROOT="${LOOP_DEV}p2"

for attempt in 1 2 3; do
  [[ -b $PART_ROOT ]] && break
  sleep "$attempt"
done
[[ -b $PART_ROOT ]] || { echo "Partition device ${PART_ROOT} never appeared" >&2; exit 1; }

mkfs.ext4 -q -F -L "$ROOT_LABEL" "$PART_ROOT"
mount "$PART_ROOT" "$MOUNT_DIR"

# ── Step 3: unpack ────────────────────────────────────────────────────────────
log "[3/7] Unpacking the rootfs"
bsdtar -xpf "$ROOTFS_TARBALL" -C "$MOUNT_DIR"

cp /usr/bin/qemu-arm-static "${MOUNT_DIR}/usr/bin/"
mount -t proc proc "${MOUNT_DIR}/proc"
mount -t sysfs sysfs "${MOUNT_DIR}/sys"
mount -o bind /dev "${MOUNT_DIR}/dev"
mount -o bind /dev/pts "${MOUNT_DIR}/dev/pts"

# Arch Linux ARM's own /boot/boot.scr and extlinux entries describe boards this
# is not; omarchy-refresh-extlinux writes the one this machine boots.
rm -f "${MOUNT_DIR}/boot/boot.scr" "${MOUNT_DIR}/boot/boot.txt"

cat >"${MOUNT_DIR}/etc/fstab" <<EOF
LABEL=${ROOT_LABEL}  /  ext4  rw,relatime  0  1
EOF

echo "$HOSTNAME" >"${MOUNT_DIR}/etc/hostname"
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" "${MOUNT_DIR}/etc/localtime"
echo "${LOCALE} UTF-8" >"${MOUNT_DIR}/etc/locale.gen"
echo "LANG=${LOCALE}" >"${MOUNT_DIR}/etc/locale.conf"
cp /etc/resolv.conf "${MOUNT_DIR}/etc/resolv.conf"

# ── Step 4: base system ───────────────────────────────────────────────────────
log "[4/7] Updating the base system and installing the kernel (slow under emulation)"
in_target pacman-key --init
in_target pacman-key --populate archlinuxarm
in_target pacman -Syu --noconfirm
in_target pacman -S --noconfirm --needed linux-armv7 linux-firmware mkinitcpio base-devel
in_target locale-gen

# ── Step 5: Omarchy ───────────────────────────────────────────────────────────
log "[5/7] Installing Omarchy"
install -d "${MOUNT_DIR}/usr/share/omarchy"
bsdtar -cf - -C "$OMARCHY_SOURCE" --exclude .git . | bsdtar -xf - -C "${MOUNT_DIR}/usr/share/omarchy"

# On x86_64 the omarchy package puts these on PATH as /usr/bin/omarchy-*.
# Nothing packages them here, so link them where an unpackaged install belongs.
in_target bash -c 'for cmd in /usr/share/omarchy/bin/omarchy*; do ln -sf "$cmd" "/usr/local/bin/$(basename "$cmd")"; done'

install -d "${MOUNT_DIR}/etc/omarchy"
printf '%s\n' "$DT_COMPATIBLE" >"${MOUNT_DIR}/etc/omarchy/dt-compatible"

# Arch Linux ARM's default account has a published password; replace it.
in_target userdel -r alarm 2>/dev/null || true
in_target useradd -m -G wheel,audio,video,storage,input -s /bin/bash "$USERNAME"
echo "${USERNAME}:${PASSWORD}" | in_target chpasswd
echo "root:${ROOT_PASSWORD}" | in_target chpasswd
install -Dm600 /dev/stdin "${MOUNT_DIR}/etc/sudoers.d/10-omarchy-wheel" <<'EOF'
%wheel ALL=(ALL:ALL) ALL
EOF

# What /etc/skel would seed from omarchy-settings on x86_64.
install -d "${MOUNT_DIR}/home/${USERNAME}/.config"
bsdtar -cf - -C "${OMARCHY_SOURCE}/config" . |
  bsdtar -xf - -C "${MOUNT_DIR}/home/${USERNAME}/.config"
cat >"${MOUNT_DIR}/home/${USERNAME}/.bashrc" <<'EOF'
[ -r /usr/share/omarchy/default/bash/env-bootstrap ] && . /usr/share/omarchy/default/bash/env-bootstrap
[ -r "$OMARCHY_PATH/default/bash/rc" ] && . "$OMARCHY_PATH/default/bash/rc"
EOF
in_target chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}"

# ── Step 6: run Omarchy setup in the target ───────────────────────────────────
# The same command the ISO runs on x86_64. OMARCHY_ARCH and
# OMARCHY_DT_COMPATIBLE_PATH stand in for what the chroot cannot report:
# emulated uname, and a /proc/device-tree that only exists on the real board.
# OMARCHY_EXTLINUX_ROOT has to be passed because findmnt in here answers for the
# build host's disk, not the SD card being built.
log "[6/7] Running Omarchy setup in the target"
in_target env \
  OMARCHY_ARCH=armv7l \
  OMARCHY_DT_COMPATIBLE_PATH=/etc/omarchy/dt-compatible \
  OMARCHY_EXTLINUX_ROOT="LABEL=${ROOT_LABEL}" \
  OMARCHY_LOG_TO_STDOUT=1 \
  PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin \
  omarchy-apply-system --install-user "$USERNAME" --first-install

# ── Step 7: boot payload and checks ───────────────────────────────────────────
log "[7/7] Writing the signed U-Boot to KERN-A and verifying the boot files"
[[ -f "${MOUNT_DIR}/boot/extlinux/extlinux.conf" ]] ||
  { echo "ERROR: setup did not write /boot/extlinux/extlinux.conf" >&2; exit 1; }

# Every path the config names has to exist, or U-Boot loads nothing and this
# machine reports it with a black screen and no console.
while read -r _ path; do
  [[ -f "${MOUNT_DIR}${path}" ]] ||
    { echo "ERROR: extlinux.conf points at missing ${path}" >&2; exit 1; }
done < <(grep -E '^\s*(KERNEL|INITRD|FDT)\s' "${MOUNT_DIR}/boot/extlinux/extlinux.conf")

kpart_bytes=$(stat -c%s "$UBOOT_KPART")
(( kpart_bytes <= 64 * 1024 * 1024 )) ||
  { echo "ERROR: U-Boot kpart (${kpart_bytes} B) does not fit KERN-A" >&2; exit 1; }
dd if="$UBOOT_KPART" of="$PART_KERN" bs=1M status=none

printf 'built: %s\ncommit: %s\nkernel: %s\n' \
  "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  "$(git -C "$OMARCHY_SOURCE" rev-parse HEAD 2>/dev/null || echo unknown)" \
  "$(in_target pacman -Q linux-armv7 2>/dev/null || echo unknown)" \
  >"${MOUNT_DIR}/boot/BUILD_STAMP"

echo "nameserver 1.1.1.1" >"${MOUNT_DIR}/etc/resolv.conf"
in_target pacman -Scc --noconfirm >/dev/null 2>&1 || true

# Arch Linux ARM ships sshd enabled. This image has a published default
# password, so leave it off until whoever flashes it has changed that.
in_target systemctl disable sshd.service >/dev/null 2>&1 || true

# Zeroing the free space costs nothing here and makes the image compress.
dd if=/dev/zero of="${MOUNT_DIR}/ZEROES" bs=1M status=none 2>/dev/null || true
rm -f "${MOUNT_DIR}/ZEROES"

cat "${MOUNT_DIR}/boot/extlinux/extlinux.conf"
report="${MOUNT_DIR}/var/lib/omarchy/armv7-packages.report"
[[ -f $report ]] && cat "$report"

sync
cleanup
trap - EXIT

cat <<EOF

════════════════════════════════════════════════════════════════
  Image built: ${IMAGE_FILE}

  Flash it, then fix the GPT backup header on the card:
    dd if=${IMAGE_FILE} of=/dev/sdX bs=4M status=progress conv=fsync
    sgdisk -e /dev/sdX

  Login: ${USERNAME} / ${PASSWORD} (root: ${ROOT_PASSWORD}) - change both.
  The Chromebook needs developer mode with dev_boot_usb=1 and
  dev_boot_signed_only=0; press Ctrl+U at the developer warning screen.
════════════════════════════════════════════════════════════════
EOF
