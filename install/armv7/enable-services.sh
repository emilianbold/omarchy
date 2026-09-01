# Enable services only. Setup is followed by a reboot, so nothing is started
# here. Unlike the x86_64 chain this asks whether each unit exists first:
# armv7h is a partial repository, so a package whose service this would enable
# may legitimately not be installed (see install/armv7/packages.sh).

enable_if_present() {
  local unit="$1"

  if [[ -n $(systemctl list-unit-files --no-legend "$unit" 2>/dev/null) ]]; then
    systemctl enable "$unit"
  else
    echo "Skipping $unit: not installed"
  fi
}

enable_if_present NetworkManager.service
enable_if_present systemd-resolved.service
enable_if_present avahi-daemon.service
enable_if_present sddm.service
enable_if_present power-profiles-daemon.service
enable_if_present ufw.service
enable_if_present systemd-oomd.service

# Don't let network-online.target hold up graphical.target waiting for Wi-Fi
# association, the same way the x86_64 chain does.
systemctl mask NetworkManager-wait-online.service
