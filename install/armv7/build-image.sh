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
# 8G filled up mid-install: the desktop set plus base-devel and the firmware
# leaves little room, and an image that runs out of space part-way produces a
# broken initramfs rather than an obvious failure. The image is zero-filled
# before compression, so unused space costs nothing in the artifact -- only a
# card of at least 16 GB.
IMAGE_SIZE="${IMAGE_SIZE:-12288M}"
PACKAGE_REPORT_FILE="${PACKAGE_REPORT_FILE:-${IMAGE_FILE%.img}-packages.report}"
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

# Innermost first, so unmounting in this order always works.
TARGET_MOUNTS=(dev/pts dev sys proc var/cache/pacman/pkg)

cleanup() {
  set +e
  rm -f "${MOUNT_DIR}/usr/bin/qemu-arm-static"
  for sub in "${TARGET_MOUNTS[@]}"; do
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

  if ! curl -fsSL --retry 3 --retry-delay 5 -o "$UBOOT_KPART" "$UBOOT_KPART_URL"; then
    cat >&2 <<EOF
ERROR: could not download the signed U-Boot from
  ${UBOOT_KPART_URL}

A /releases/latest/ URL only resolves once a release exists that is not a
prerelease, so a project publishing only snapshots answers 404 here. Check
https://github.com/emilianbold/c201p/releases, then either point
UBOOT_KPART_URL at a specific release asset or pass a local copy as
UBOOT_KPART=/path/to/debian-c201p-uboot.kpart.
EOF
    exit 1
  fi
fi

[[ -s $UBOOT_KPART ]] || { echo "ERROR: U-Boot kpart ${UBOOT_KPART} is missing or empty" >&2; exit 1; }

# A signed ChromeOS kernel partition opens with the "CHROMEOS" keyblock magic.
# Without this check a stray HTML error page or a truncated download is written
# into KERN-A, and the Chromebook reports it by not booting, with no console to
# say why.
if [[ $(head -c 8 "$UBOOT_KPART") != "CHROMEOS" ]]; then
  echo "ERROR: ${UBOOT_KPART} is not a signed ChromeOS kernel partition" >&2
  exit 1
fi

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

# Keep every package pacman downloads on the build host rather than in the
# image. The cache is gigabytes by the end of a desktop install -- it was what
# filled the image the first time -- and none of it belongs in the artifact.
install -d "$WORK_DIR/pkgcache" "${MOUNT_DIR}/var/cache/pacman/pkg"
mount -o bind "$WORK_DIR/pkgcache" "${MOUNT_DIR}/var/cache/pacman/pkg"

# Arch Linux ARM's own /boot/boot.scr and extlinux entries describe boards this
# is not; omarchy-refresh-extlinux writes the one this machine boots.
rm -f "${MOUNT_DIR}/boot/boot.scr" "${MOUNT_DIR}/boot/boot.txt"

# pacman 7 confines downloads with Landlock and drops them to the alpm user.
# qemu-user does not translate the Landlock syscalls, so inside this chroot
# every transaction dies with "Landlock is not supported by the kernel" before
# it fetches anything. Turn the sandbox off for the build only -- Step 7 takes
# this back out, so the machine that ships still has it.
if ! grep -q '^DisableSandbox' "${MOUNT_DIR}/etc/pacman.conf"; then
  sed -i '/^\[options\]/a DisableSandbox' "${MOUNT_DIR}/etc/pacman.conf"
fi

cat >"${MOUNT_DIR}/etc/fstab" <<EOF
LABEL=${ROOT_LABEL}  /  ext4  rw,relatime  0  1
EOF

echo "$HOSTNAME" >"${MOUNT_DIR}/etc/hostname"

# Resolve the machine's own name locally. Without it sudo pauses on every call
# while it fails to resolve the host, including inside the build chroot where
# setup leaves shell out to it.
cat >"${MOUNT_DIR}/etc/hosts" <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}
EOF
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" "${MOUNT_DIR}/etc/localtime"
echo "${LOCALE} UTF-8" >"${MOUNT_DIR}/etc/locale.gen"
echo "LANG=${LOCALE}" >"${MOUNT_DIR}/etc/locale.conf"
# The chroot needs a resolver it can actually reach. Copying the host's
# /etc/resolv.conf is not enough: on a systemd-resolved machine that file names
# the 127.0.0.53 stub, which resolves nothing from in here, and the rootfs ships
# /etc/resolv.conf as a symlink into a /run that nothing has populated. Prefer
# resolved's uplink file, which names the real servers, and replace the symlink
# with a regular file.
resolv_source=/etc/resolv.conf
[[ -f /run/systemd/resolve/resolv.conf ]] && resolv_source=/run/systemd/resolve/resolv.conf

rm -f "${MOUNT_DIR}/etc/resolv.conf"
install -m 0644 "$resolv_source" "${MOUNT_DIR}/etc/resolv.conf"

if ! grep -q '^nameserver' "${MOUNT_DIR}/etc/resolv.conf" ||
   grep -q '^nameserver 127\.' "${MOUNT_DIR}/etc/resolv.conf"; then
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' >"${MOUNT_DIR}/etc/resolv.conf"
fi

# ── Step 4: base system ───────────────────────────────────────────────────────
log "[4/7] Updating the base system and installing the kernel (slow under emulation)"

# Fail here, in a second, rather than eighty seconds later inside pacman with
# four "could not resolve host" lines that read like a mirror outage. The
# mirrors come from the rootfs's own /etc/pacman.d/mirrorlist, which is Arch
# Linux ARM's geo-redirecting mirror -- it is the armv7h package source, not
# something this port picks.
if ! in_target getent hosts mirror.archlinuxarm.org >/dev/null 2>&1; then
  echo "ERROR: the build chroot cannot resolve mirror.archlinuxarm.org." >&2
  echo "       Its /etc/resolv.conf reads:" >&2
  sed 's/^/       /' "${MOUNT_DIR}/etc/resolv.conf" >&2
  exit 1
fi

in_target pacman-key --init
in_target pacman-key --populate archlinuxarm
in_target pacman -Syu --noconfirm
in_target pacman -S --noconfirm --needed linux-armv7 mkinitcpio base-devel

# Firmware: this board needs Broadcom's, for the BCM4354 that is its only
# network. The full linux-firmware is mostly blobs for GPUs and NICs a
# Chromebook does not have, and on a card-sized filesystem that is worth
# skipping -- but only where the split package exists to skip it for.
if ! in_target pacman -S --noconfirm --needed linux-firmware-broadcom 2>/dev/null; then
  log "    linux-firmware-broadcom unavailable; installing the full firmware set"
  in_target pacman -S --noconfirm --needed linux-firmware
fi
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

# What omarchy-settings ships to /etc/skel on x86_64, where useradd -m is what
# puts it in a new user's home. Seeding skel rather than the home directory
# keeps that mechanism identical here, so a second user created later on the
# machine gets the same defaults.
install -d "${MOUNT_DIR}/etc/skel/.config"
bsdtar -cf - -C "${OMARCHY_SOURCE}/config" . |
  bsdtar -xf - -C "${MOUNT_DIR}/etc/skel/.config"
cat >"${MOUNT_DIR}/etc/skel/.bashrc" <<'EOF'
[ -r /usr/share/omarchy/default/bash/env-bootstrap ] && . /usr/share/omarchy/default/bash/env-bootstrap
[ -r "$OMARCHY_PATH/default/bash/rc" ] && . "$OMARCHY_PATH/default/bash/rc"
EOF

# Arch Linux ARM's default account has a published password; replace it.
in_target userdel -r alarm 2>/dev/null || true
in_target useradd -m -G wheel,audio,video,storage,input -s /bin/bash "$USERNAME"
echo "${USERNAME}:${PASSWORD}" | in_target chpasswd
echo "root:${ROOT_PASSWORD}" | in_target chpasswd
install -Dm440 /dev/stdin "${MOUNT_DIR}/etc/sudoers.d/10-omarchy-wheel" <<'EOF'
%wheel ALL=(ALL:ALL) ALL
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

# The ISO's per-user half, run as the user the same way. It is not fatal here:
# it ends in leaves that want packages armv7h may not carry (chromium for the
# default browser, mise), and an image that boots to a desktop with an
# unfinished home is worth more than no image. What it managed is visible in
# ~/.local/state/omarchy/done/finalize-user on the machine.
#
# runuser -l, not -u: -u keeps the caller's environment, so HOME stayed /root
# and the user phase wrote its dotfiles at a path it could not create ("Can't
# save user-dirs.dirs, failed to create directory"). -l builds the target
# user's login environment, HOME included.
user_finalized=ok
if ! in_target runuser -l "$USERNAME" -c \
     'OMARCHY_ARCH=armv7l omarchy-provision-user --first-install'; then
  user_finalized=incomplete
  log "    WARNING: omarchy-provision-user did not finish; the user's home is partly unconfigured"
fi

# Whatever happened above, let the machine redo it natively on first login.
#
# This phase runs graphical tools -- theme setting, icon caches -- through
# qemu-user, where some of them abort on emulation rather than on anything
# wrong with the image (std::bad_array_new_length out of a Qt binary, for one).
# A run that crashed part-way but still marked itself complete would leave the
# home half-configured with nothing to retry it, and
# omarchy-provision-first-run reruns the whole phase at first login whenever
# this marker is absent. Removing it costs one repeat of an idempotent step and
# buys a home configured by the real hardware.
in_target rm -f "/home/${USERNAME}/.local/state/omarchy/done/finalize-user"

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
# No cache to clear -- it lived on the build host (see Step 3) -- and the sync
# databases are worth keeping, so the machine can install something without a
# refresh first.

# Give the machine back pacman's download sandbox, which only had to come off
# for the emulated build (see Step 3).
sed -i '/^DisableSandbox$/d' "${MOUNT_DIR}/etc/pacman.conf"
grep -q '^DisableSandbox' "${MOUNT_DIR}/etc/pacman.conf" &&
  { echo "ERROR: the build's DisableSandbox is still in the image's pacman.conf" >&2; exit 1; }

# Arch Linux ARM ships sshd enabled. This image has a published default
# password, so leave it off until whoever flashes it has changed that.
in_target systemctl disable sshd.service >/dev/null 2>&1 || true

# Zeroing the free space costs nothing here and makes the image compress.
dd if=/dev/zero of="${MOUNT_DIR}/ZEROES" bs=1M status=none 2>/dev/null || true
rm -f "${MOUNT_DIR}/ZEROES"

cat "${MOUNT_DIR}/boot/extlinux/extlinux.conf"

# Copy the package report out beside the image. It is the answer to the
# question this port cannot answer without a build -- what armv7h actually
# carries -- and inside the image it is only readable by mounting it again.
report="${MOUNT_DIR}/var/lib/omarchy/armv7-packages.report"
if [[ -f $report ]]; then
  cat "$report"
  cp "$report" "$PACKAGE_REPORT_FILE"
  printf 'user-finalization %s\n' "$user_finalized" >>"$PACKAGE_REPORT_FILE"
fi

sync
cleanup
trap - EXIT

cat <<EOF

════════════════════════════════════════════════════════════════
  Image built: ${IMAGE_FILE}
  Package report: ${PACKAGE_REPORT_FILE}

  Flash it, then fix the GPT backup header on the card:
    dd if=${IMAGE_FILE} of=/dev/sdX bs=4M status=progress conv=fsync
    sgdisk -e /dev/sdX

  Login: ${USERNAME} / ${PASSWORD} (root: ${ROOT_PASSWORD}) - change both.
  The Chromebook needs developer mode with dev_boot_usb=1 and
  dev_boot_signed_only=0; press Ctrl+U at the developer warning screen.
════════════════════════════════════════════════════════════════
EOF
