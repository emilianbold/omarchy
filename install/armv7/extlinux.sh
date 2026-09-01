# Boot configuration for ARM boards that U-Boot starts through extlinux.
#
# The signed payload in the ChromeOS KERN-A partition is U-Boot, not Linux, so
# a kernel upgrade never re-signs anything: U-Boot reads
# /boot/extlinux/extlinux.conf off the root filesystem and boots whatever it
# names. Everything that needs to survive a kernel upgrade is therefore in this
# config and the pacman hook that regenerates it.

SETTINGS_FILE="${OMARCHY_EXTLINUX_SETTINGS:-/etc/omarchy/extlinux.conf}"

# The root spec cannot be discovered while the image is being built: findmnt
# inside the build chroot answers for the build host's disk, not the SD card.
# The image builder passes it in; on a rerun on the machine itself the settings
# file already exists and omarchy-refresh-extlinux derives what is missing.
if [[ ! -f $SETTINGS_FILE ]]; then
  install -d "$(dirname "$SETTINGS_FILE")"
  {
    echo "# Board settings read by omarchy-refresh-extlinux."
    [[ -n ${OMARCHY_EXTLINUX_ROOT:-} ]] && echo "OMARCHY_EXTLINUX_ROOT=\"$OMARCHY_EXTLINUX_ROOT\""
    [[ -n ${OMARCHY_EXTLINUX_DTB:-} ]] && echo "OMARCHY_EXTLINUX_DTB=\"$OMARCHY_EXTLINUX_DTB\""
    echo "OMARCHY_EXTLINUX_CMDLINE=\"${OMARCHY_EXTLINUX_CMDLINE:-rw rootwait panic=10 console=tty0}\""
  } >"$SETTINGS_FILE"
  chmod 0644 "$SETTINGS_FILE"
fi

install -Dm644 "$OMARCHY_INSTALL/armv7/files/95-omarchy-extlinux.hook" \
  /etc/pacman.d/hooks/95-omarchy-extlinux.hook

omarchy-refresh-extlinux
