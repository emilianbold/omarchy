# Rockchip RK3288 "veyron" Chromebook quirks (Asus C201P and relatives).

if omarchy-hw-chromebook-veyron; then
  echo "Configuring Rockchip veyron Chromebook support"

  # rk3288-veyron.dtsi sets backlight-boot-off, so pwm_bl comes up with the
  # GPIO low and PWM at 0 and the panel only lights when DRM calls
  # backlight_enable(). Write a brightness the moment the device appears, so
  # the screen is not black while waiting on DRM.
  mkdir -p /etc/udev/rules.d
  cat >/etc/udev/rules.d/10-omarchy-veyron-backlight.rules <<'EOF'
ACTION=="add", SUBSYSTEM=="backlight", ATTR{brightness}="200"
EOF

  # btsdio crashes this hardware on suspend, and the BCM4354 patchram firmware
  # it would need is not redistributable anyway, so Bluetooth stays off.
  mkdir -p /etc/modprobe.d
  cat >/etc/modprobe.d/omarchy-veyron-blacklist.conf <<'EOF'
blacklist btsdio
EOF

  # The C201P has no ethernet port: the BCM4354 over SDIO is the only network.
  # firmware-veyron carries the per-board NVRAM calibration that linux-firmware
  # does not, and without it the adapter is unreliable or absent.
  if ! firmware_output=$(pacman -S --noconfirm --needed firmware-veyron 2>&1); then
    echo "WARNING: firmware-veyron did not install; Wi-Fi may not come up"
    sed 's/^/  /' <<<"$firmware_output" | tail -n 5
  fi

  if ! compgen -G "/usr/lib/firmware/brcm/brcmfmac4354-sdio*" >/dev/null &&
     ! compgen -G "/usr/lib/firmware/updates/brcm/brcmfmac4354-sdio*" >/dev/null; then
    echo "WARNING: no brcmfmac4354-sdio firmware found; Wi-Fi will not work"
  fi

  install -Dm644 "$OMARCHY_INSTALL/armv7/files/mkinitcpio-veyron.conf" \
    /etc/mkinitcpio.conf.d/omarchy-veyron.conf

  # Rebuild both images so the module list above is actually in them. The
  # fallback image is what the second extlinux entry boots.
  mkinitcpio -P
fi
