# ARMv7 system setup, run in place of the x86_64 chain by omarchy-apply-system.
#
# ARMv7 targets are built on Arch Linux ARM rather than by the Omarchy ISO, so
# they get a shorter chain: no Limine, no Snapper (the image is ext4 on an SD
# card), no NVIDIA/Intel/T2 leaves, and package installation happens here
# instead of in the ISO's pacstrap. See docs/armv7.md.

run_logged "$OMARCHY_INSTALL/armv7/packages.sh"
run_logged "$OMARCHY_INSTALL/armv7/settings.sh"
run_logged "$OMARCHY_INSTALL/armv7/veyron.sh"
run_logged "$OMARCHY_INSTALL/armv7/extlinux.sh"

run_logged "$OMARCHY_INSTALL/hardware/network.sh"
run_logged "$OMARCHY_INSTALL/hardware/set-wireless-regdom.sh"

run_logged "$OMARCHY_INSTALL/config/theme-system.sh"
run_logged "$OMARCHY_INSTALL/config/browser-policy.sh"
run_logged "$OMARCHY_INSTALL/config/locate.sh"

run_logged "$OMARCHY_INSTALL/armv7/enable-services.sh"
