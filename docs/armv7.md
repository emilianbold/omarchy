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

## Why Arch Linux ARM, and which of its rootfs images

Arch Linux itself is x86_64 only. There is no ARM build from archlinux.org —
ARM is the separate Arch Linux ARM project (archlinuxarm.org), which tracks
Arch's PKGBUILDs but is its own distribution with its own repositories, keyring
and mirrors. So there are not two ARM Arches to choose between: for `armv7h`
there is exactly one, and this port depends on it. That dependency is the first
thing to raise upstream — it is what makes an ARM target structurally different
from x86_64, where Omarchy sits on Arch proper plus its own repo.

Arch Linux ARM ships two rootfs images that could serve here, and this port uses
the generic one:

- **`ArchLinuxARM-armv7-latest.tar.gz`** (used) — the generic ARMv7 rootfs,
  which carries the mainline `linux-armv7` kernel. Mainline is what makes a
  Wayland session possible at all on this hardware: Panfrost for the Mali T764,
  atomic KMS, a current DRM stack.
- **`ArchLinuxARM-veyron-latest.tar.gz`** (not used) — a board-specific image
  for veyron Chromebooks. It is the better-trodden path for simply getting
  *something* booting on a C201, but it is built around the vendor kernel line
  and the Chromebook convention of signing the kernel itself into `KERN-A` and
  re-flashing that partition on every kernel upgrade. Neither suits a desktop
  that updates weekly through `omarchy update`, and the vendor kernel cannot
  drive the compositor.

The builder takes `ROOTFS_URL`, so the board image is one environment variable
away if it is ever worth comparing.

The image builder is a substrate, not a second installer. It does what the ISO's
pacstrap phase does — partition, unpack a rootfs, install a kernel — and then
hands over to Omarchy's own entry points, unchanged:

- `omarchy-apply-system --install-user U --first-install`, the same command the
  ISO runs in the target chroot, which routes to `install/armv7/all.sh`.
- `omarchy-provision-user --first-install`, run as the user, the same per-user
  finalization the ISO runs. It is allowed to fail here, because it ends in
  leaves that want packages `armv7h` may not carry; the result is recorded in
  the package report.
- `/etc/skel` is seeded from this repo's `config/` tree and `useradd -m` copies
  it into the new user's home — the same mechanism, with the repo standing in
  for the `omarchy-settings` package.
- The ARMv7 chain is built from ordinary setup leaves: sourced, no shebang,
  addressed through `$OMARCHY_INSTALL`, orchestrated by `run_logged`. It reuses
  the x86 leaves that apply as-is — `hardware/network.sh`,
  `hardware/set-wireless-regdom.sh`, `config/theme-system.sh`,
  `config/browser-policy.sh`, `config/locate.sh`.
- `omarchy-refresh-extlinux` mirrors `omarchy-refresh-limine`, down to the
  pacman hook that reruns it after a kernel upgrade, and the `hw-` commands
  follow the same metadata and routing conventions as their x86 counterparts.

Two things are genuinely substituted, and both are the work an upstream port
would have to finish:

1. **No packages.** On x86_64 the `omarchy` and `omarchy-settings` packages put
   `bin/` on `PATH` as `/usr/bin/omarchy-*` and own the `/etc` drop-ins and
   `/etc/skel`. Nothing builds those for `armv7h`, so the builder copies the
   repository to `/usr/share/omarchy`, symlinks the commands into
   `/usr/local/bin`, and `install/armv7/settings.sh` places the handful of
   system files `omarchy-settings` would own. Building those two packages for
   `armv7h` is what would replace this.
2. **No ISO.** Installation orchestration lives in the separate ISO repository
   and is archiso-based, so it cannot produce an ARM image. `build-image.sh`
   covers only the part the ISO would otherwise do before setup runs.

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

A second entry is generated for the fallback initramfs when the kernel package
ships one, so that U-Boot can walk to it by itself if the default entry fails to
load — the only recovery this machine has, since U-Boot drives no display here
and a boot menu would be invisible. It covers failures *before* the jump into
Linux; a kernel that loads and then panics is past U-Boot's reach.

On this board there is one entry, because `linux-armv7` defines only the
`default` preset. Little is lost: the veyron drop-in takes `autodetect` out of
`HOOKS`, so the image that entry boots already carries every module rather than
the trimmed set a fallback image would exist to backstop.

Note the device tree lands at `/boot/dtbs/rk3288-veyron-speedy.dtb`, flat rather
than under a `rockchip/` vendor directory. That is why the lookup searches for
the file instead of assuming a layout.

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

Two files come out: the image, and `*-packages.report` copied out of it — the
list of packages `armv7h` could not resolve, which is what says how much of the
desktop this build actually got.

### In CI

`.github/workflows/armv7-image.yml` runs the same script on a GitHub runner
(qemu-user-static, same as the c201p project's workflow), because nothing here
can be validated without building it. It runs the ARMv7 tests first so a typo
fails in a minute rather than an hour into emulated `pacman`, uploads the
package report even when the build fails, and uploads the compressed image.
Pushing a tag starting with `armv7-` publishes a prerelease with the image
attached.

It is paths-scoped to the ARMv7 port: this is the repository's only workflow,
and nothing outside the port should pay for a one-to-two hour emulated build.

The image is 12 GB, so it wants a card of at least 16 GB. That is mostly empty
space on purpose: the desktop set, `base-devel` and the firmware filled an 8 GB
image mid-install, and there has to be room left for the machine to build the
packages `armv7h` does not carry. Free space is zeroed before compression, so
the artifact stays small regardless.

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

What a real build found, which is better than the lists above assume: `hyprland`,
`quickshell`, `uwsm`, `sddm`, `foot`, both portals, the Qt6 stack, `mpv`,
`gnome-keyring` and the shell tools all install from `armv7h`. Only
`xdg-terminal-exec` and `yaru-icon-theme` are genuinely absent, alongside the
Omarchy-repo packages that were never going to be there.

The third name that run reported, `hyprland-qtutils`, was this port's own
mistake rather than a gap: it is deprecated upstream in favour of
`hyprland-guiutils`, which is what Omarchy asks for on x86_64 and which
`armv7h` has. A test now holds the ARMv7 lists to names Omarchy's own lists use,
so a package typed from memory is caught before it costs a build.

Read the report's reasons rather than its list of names. "not in the armv7h
repositories" is the one that means build from source; "a dependency is
unavailable" points at a package to chase instead; and the build stops outright
on "no space left in the image", because a full disk otherwise files every
remaining package as missing and leaves `mkinitcpio` no room for an initramfs.

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
- **Reaching a session.** SDDM is enabled only if it installed. When it did not,
  the machine boots to a TTY and the session starts by hand with
  `uwsm start hyprland`; `/var/lib/omarchy/armv7-packages.report` says which of
  the two is the case.
- **Performance.** A dual-core Cortex-A17 with 2-4 GB of RAM and Panfrost is not
  what the desktop was tuned for; compositing works, video and the browser are
  modest.
- **No snapshots, no hibernation, no Secure Boot story.** ext4 root, no swap
  partition (zram only).
- **Not upstream-ready as a supported target.** It is a working shape for one
  board, with the parts that generalize (device-tree detection, extlinux, the
  ARMv7 chain) kept separate from the parts that do not.
