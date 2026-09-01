# Omarchy on ARMv7

How the 32-bit ARM port is shaped, starting with the Asus C201P Chromebook
(Rockchip RK3288, "veyron-speedy"). This is a proof of concept: it establishes
the boot chain, the setup path and the package story, and it is honest about
what an armv7h machine cannot have.

## What is different from x86_64

| | x86_64 | ARMv7 |
| --- | --- | --- |
| Installer | Omarchy ISO (pacstrap + `omarchy-apply-system`) | `install/armv7/build-image.sh` writes an SD card image |
| Distribution | Arch Linux + `pkgs.omarchy.org` | Arch Linux ARM (`armv7h`); no Omarchy repo |
| Bootloader | Limine (UEFI) | Depthcharge → signed U-Boot → extlinux |
| Filesystem | Btrfs with Snapper snapshots | ext4, no snapshots |
| Kernel | `linux` / `linux-ptl` | `linux-armv7` |
| GPU | Intel/AMD/NVIDIA drivers | Mali T764 through Panfrost, in the kernel already |
| Setup chain | `install/config` + `install/hardware` + `install/login` + `install/post-install` | `install/armv7/all.sh` |

`omarchy-apply-system` picks the chain: `omarchy-hw-armv7` is true, so it sources
`install/armv7/all.sh` and none of the x86 leaves run. Nothing in the x86 path
changes.

## Boot chain

The C201P boots ChromeOS's verified boot firmware, which will only start a
signed payload out of the `KERN-A` partition. Putting Linux there directly works
but caps the whole signed body at Depthcharge's staging buffer (~16 MB in
practice), which a real initramfs does not fit, and it means re-signing on every
kernel upgrade.

So `KERN-A` holds **U-Boot** instead, signed once:

```
Depthcharge → U-Boot (signed KERN-A payload, flags=7 keyblock)
            → /boot/extlinux/extlinux.conf on the ext4 root
            → zImage + initramfs-linux.img + rk3288-veyron-speedy.dtb
```

Kernel upgrades then re-sign nothing: `omarchy-refresh-extlinux` rewrites the
config to describe whatever is in `/boot`, and a pacman hook
(`95-omarchy-extlinux.hook`) runs it after any transaction that touches the
kernel, the initramfs or the device trees.

The signed U-Boot binary itself is **not** built here. It comes from the
[c201p](https://github.com/emilianbold/c201p) project, which established and
verified this chain on the hardware; its `BOOTCOMMAND` looks for
`/boot/extlinux/extlinux.conf` on partition 2 of the SD card and then of the
eMMC, which is the layout the image builder writes.

Two entries are always generated, the second pointing at the fallback
initramfs. If the default entry fails to load, U-Boot walks the remaining
labels by itself. That matters here: U-Boot on this machine drives no display,
so a boot menu would be invisible, but the automatic fallthrough still works. It
only covers failures *before* the jump into Linux — a kernel that loads and then
panics is past U-Boot's reach.

## Building an image

On an x86_64 Linux host with `qemu-user-static` binfmt registered:

```bash
sudo install/armv7/build-image.sh
```

Useful overrides: `IMAGE_FILE`, `IMAGE_SIZE`, `USERNAME`, `PASSWORD`,
`TIMEZONE`, `ROOTFS_TARBALL` (a local Arch Linux ARM tarball), and
`UBOOT_KPART` (a local signed U-Boot, otherwise downloaded from the c201p
releases).

The build runs the real `omarchy-apply-system` inside the target through
qemu-user. Three things the chroot cannot answer are passed in, because
answering them from inside would describe the build host instead of the
Chromebook:

- `OMARCHY_ARCH` — uname is emulated.
- `OMARCHY_DT_COMPATIBLE_PATH` — `/proc/device-tree` only exists on the board,
  so a file with the board's compatible strings stands in for it.
- `OMARCHY_EXTLINUX_ROOT` — `findmnt /` answers for the build host's disk.

Flash it, then fix the GPT backup header, which Depthcharge checks:

```bash
sudo dd if=omarchy-armv7-veyron.img of=/dev/sdX bs=4M status=progress conv=fsync
sudo sgdisk -e /dev/sdX
```

The Chromebook needs developer mode with `dev_boot_usb=1` and
`dev_boot_signed_only=0`; press **Ctrl+U** at the developer warning screen.

## Packages

This is the part that decides how much of Omarchy actually shows up.

Arch Linux ARM builds `armv7h` from Arch's PKGBUILDs, but not everything builds,
and `pkgs.omarchy.org` publishes x86_64 only — so every Omarchy-built package
(`aether`, `cliamp`, `herdr`, `omacalc`, `omacut`, `omarchy-nvim`, `omawrite`,
`tensaku`, `tobi-try`, `ttfx`) is absent by construction, as are the x86-only
ones (`dotnet-runtime`, `moonlight-qt`, `gpu-screen-recorder`).

`install/armv7/packages.sh` therefore installs **best effort**, one package at a
time, and never fails the setup: a machine missing an application should still
boot to a desktop. What did not install is listed in
`/var/lib/omarchy/armv7-packages.report`, which is the list to build from
source. Two lists feed it:

- `packages/essential.packages` — network, audio, session basics. Anything
  missing here is reported as a warning.
- `packages/desktop.packages` — the Omarchy desktop surface.

Nothing in this repository can confirm what `armv7h` currently carries; the
report from a real run is the authority.

## Board support

`install/armv7/veyron.sh` holds what is specific to RK3288 veyron Chromebooks,
behind `omarchy-hw-chromebook-veyron` so the chain stays usable on other ARMv7
machines:

- **Backlight.** `rk3288-veyron.dtsi` sets `backlight-boot-off`, so `pwm_bl`
  starts with the GPIO low and PWM at 0 and the panel only lights when DRM calls
  `backlight_enable()`. A udev rule writes a brightness as soon as the device
  appears.
- **Wi-Fi.** The BCM4354 over SDIO is the machine's only network (there is no
  ethernet port). `firmware-veyron` carries the per-board NVRAM calibration that
  `linux-firmware` does not.
- **Bluetooth.** `btsdio` crashes this hardware on suspend and the BCM4354
  patchram firmware is not redistributable, so it is blacklisted and Bluetooth
  is unavailable.
- **initramfs.** The module list in `files/mkinitcpio-veyron.conf` is the one
  derived on a booted C201P. Do not trim it by guessing: a shorter hand-picked
  list left the kernel unable to mount root, and it panicked before any console
  existed to say so. `autodetect` is deliberately absent from `HOOKS`, because
  the image is built in a foreign chroot where it traces the build host's
  devices.

## Hardware detection without DMI

DMI is x86 firmware. ARM boards identify themselves through
`/proc/device-tree/compatible`, so `omarchy-hw-dt-match` is the counterpart of
`omarchy-hw-match`, and `omarchy-hw-chromebook-veyron` is built on it.

For the same reason `omarchy-hw-laptop` also reads `SW_LID` from the input
devices (there is no ACPI lid button), and `omarchy-battery-present` matches
batteries on what the device reports rather than on an `BAT0` name — this
machine's smart battery arrives as `sbs-20-000b`.

## Known gaps

- **The Omarchy shell.** Quickshell and the Omarchy-built packages have to come
  from source. Until then the session is Hyprland with whatever of the desktop
  list installed.
- **Performance.** A dual-core Cortex-A17 with 2-4 GB of RAM and Panfrost is not
  what the desktop was tuned for; compositing works, video and the browser are
  modest.
- **No snapshots, no hibernation, no Secure Boot story.** ext4 root, no swap
  partition (zram only).
- **Not upstream-ready as a supported target.** It is a working shape for one
  board, with the parts that generalize (device-tree detection, extlinux, the
  ARMv7 chain) kept separate from the parts that do not.
