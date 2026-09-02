# Install the system files the omarchy-settings package ships on x86_64.
#
# ARMv7 targets are assembled from an Arch Linux ARM rootfs and this repository
# rather than from Omarchy's own packages, so the handful of system-level files
# those packages own have to be placed here instead.

# OMARCHY_PATH and the Omarchy PATH entries for login shells.
install -Dm644 "$OMARCHY_PATH/etc/profile.d/omarchy.sh" /etc/profile.d/omarchy.sh

# Swap on zram, sized the way Omarchy sizes it everywhere else. This machine has
# 2-4 GB of RAM and no swap partition, so it matters more here than on x86.
install -Dm644 "$OMARCHY_PATH/default/systemd/zram-generator.conf.d/90-omarchy.conf" \
  /usr/lib/systemd/zram-generator.conf.d/90-omarchy.conf

install -Dm644 "$OMARCHY_PATH/etc/sysctl.d/99-omarchy-sysctl.conf" \
  /etc/sysctl.d/99-omarchy-sysctl.conf

# Keep the journal across reboots. Without /var/log/journal, journald stores
# logs in /run and loses them at power-off -- and a boot that never reaches a
# usable screen is exactly the one worth reading afterwards, by taking the card
# to another machine. The only console this hardware has is the display it may
# have failed to light.
install -d -m 2755 -g systemd-journal /var/log/journal
install -Dm644 "$OMARCHY_PATH/etc/tmpfiles.d/omarchy-zswap.conf" \
  /etc/tmpfiles.d/omarchy-zswap.conf

# SDDM's session and greeter assets, but only where nothing supplies them
# already.
#
# A working image turned out to have /etc/sddm.conf.d/10-wayland.conf in place
# without this leaf ever writing it, so something outside this repository ships
# it -- Hyprland's own packaging, going by start-hyprland and
# /usr/share/sddm/hyprland.lua both belonging to it. Overwriting a file a
# package owns would only earn a .pacnew on the next upgrade, so each of these
# fills a gap rather than asserting a value.
#
# What put this leaf here was a wrong reading of "Failed to read display number
# from pipe": that message is not X11-specific. SDDM's Wayland path reads the
# display name from a pipe too, and logs the same line when the compositor dies
# on startup -- which a corrupt library does. The corruption was the fault; this
# configuration was never missing.
install_if_absent() {
  [[ -e $2 ]] || install -Dm644 "$1" "$2"
}

install_if_absent "$OMARCHY_PATH/default/wayland-sessions/omarchy.desktop" \
  /usr/share/wayland-sessions/omarchy.desktop
install_if_absent "$OMARCHY_PATH/default/sddm/hyprland.lua" /usr/share/sddm/hyprland.lua
install_if_absent "$OMARCHY_PATH/etc/sddm.conf.d/10-theme.conf" /etc/sddm.conf.d/10-theme.conf
install_if_absent "$OMARCHY_PATH/etc/sddm.conf.d/10-wayland.conf" \
  /etc/sddm.conf.d/10-wayland.conf

if [[ ! -d /usr/share/sddm/themes/omarchy ]]; then
  install -d /usr/share/sddm/themes/omarchy
  cp -a "$OMARCHY_PATH/default/sddm/omarchy/." /usr/share/sddm/themes/omarchy/
fi

# Autologin is off by default: the greeter works here, and it was only ever
# proposed as cover for a failure that turned out to be corruption. Set
# OMARCHY_ARMV7_AUTOLOGIN=1 to skip the login screen on an image whose password
# is published anyway.
if [[ ${OMARCHY_ARMV7_AUTOLOGIN:-0} == "1" && -n ${OMARCHY_INSTALL_USER:-} ]]; then
  install -d /etc/sddm.conf.d
  printf '[Autologin]\nUser=%s\nSession=omarchy.desktop\n' "$OMARCHY_INSTALL_USER" \
    >/etc/sddm.conf.d/20-omarchy-armv7-autologin.conf
  chmod 0644 /etc/sddm.conf.d/20-omarchy-armv7-autologin.conf
fi
