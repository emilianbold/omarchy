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
install -Dm644 "$OMARCHY_PATH/etc/tmpfiles.d/omarchy-zswap.conf" \
  /etc/tmpfiles.d/omarchy-zswap.conf
