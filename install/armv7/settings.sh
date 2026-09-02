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

# The session SDDM offers, and the greeter's own assets.
install -Dm644 "$OMARCHY_PATH/default/wayland-sessions/omarchy.desktop" \
  /usr/share/wayland-sessions/omarchy.desktop
install -Dm644 "$OMARCHY_PATH/default/sddm/hyprland.lua" /usr/share/sddm/hyprland.lua
install -d /usr/share/sddm/themes/omarchy
cp -a "$OMARCHY_PATH/default/sddm/omarchy/." /usr/share/sddm/themes/omarchy/
install -Dm644 "$OMARCHY_PATH/etc/sddm.conf.d/10-theme.conf" /etc/sddm.conf.d/10-theme.conf

# SDDM defaults to X11, and there is no X server in this image: it reports that
# as "Failed to read display number from pipe" and stops, leaving a machine that
# reaches graphical.target and shows nothing. Omarchy's own drop-in is what puts
# it on Wayland.
#
# Its CompositorCommand names start-hyprland, which comes with Omarchy's
# Hyprland rather than Arch Linux ARM's. Where that is missing, the greeter runs
# under a plain Hyprland with its own defaults instead -- a greeter that looks
# unstyled beats a machine with no way in.
if command -v start-hyprland >/dev/null; then
  install -Dm644 "$OMARCHY_PATH/etc/sddm.conf.d/10-wayland.conf" \
    /etc/sddm.conf.d/10-wayland.conf
else
  install -d /etc/sddm.conf.d
  cat >/etc/sddm.conf.d/10-wayland.conf <<'EOF'
[General]
DisplayServer=wayland

[Wayland]
CompositorCommand=Hyprland
EOF
fi

# Autologin, which on x86_64 the ISO owns because it knows whether the target is
# encrypted. Here the answer is fixed: an SD card image with a published
# password, so the greeter is not an authentication boundary worth defending,
# and skipping it means a broken greeter cannot lock anyone out of the machine.
# Delete this file to get the login screen back.
if [[ -n ${OMARCHY_INSTALL_USER:-} ]]; then
  install -d /etc/sddm.conf.d
  printf '[Autologin]\nUser=%s\nSession=omarchy.desktop\n' "$OMARCHY_INSTALL_USER" \
    >/etc/sddm.conf.d/20-omarchy-armv7-autologin.conf
  chmod 0644 /etc/sddm.conf.d/20-omarchy-armv7-autologin.conf
fi
