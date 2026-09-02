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

## What is missing compared to x86_64 Omarchy

Four different reasons, and only the first two are permanent:

**Not built for armv7h.** `chromium` (Arch Linux ARM builds it for aarch64
only), `xdg-terminal-exec`, `yaru-icon-theme`. Firefox stands in for Chromium
and Adwaita for Yaru; both are recorded as substitutions in
`test/shell.d/armv7-install-test.sh`.

**Built by Omarchy for x86_64 only.** Everything from `pkgs.omarchy.org`:
`aether`, `cliamp`, `herdr`, `omacalc`, `omacut`, `omawrite`, `omarchy-nvim`,
`tensaku`, `tobi-try`, `ttfx`, `hyprland-preview-share-picker`, and `mise-bin`
— which takes the whole agent CLI set with it, since claude, codex, gh and
opencode publish x86_64 and aarch64 binaries. These need building from source
against `armv7h`, which is the main body of work between this proof of concept
and a real port.

**Left out on purpose for this hardware.** Bluetooth (`bluez*` — `btsdio`
crashes this board on suspend), printing (`cups*`), Docker and `lazydocker`,
`plymouth` (this boot chain shows no splash), `snapper`/`limine` tooling (ext4,
no snapshots), and the builds no quad-core Cortex-A17 should attempt:
`libreoffice-fresh`, `kdenlive`, `obs-studio`, `obsidian`, `dotnet-runtime`,
`moonlight-qt`, `gpu-screen-recorder`.

**Simply not listed yet.** The rest is a trimmed list, not a limitation —
`install/armv7/packages/desktop.packages` is easy to grow, and everything added
to it so far has installed.

The practical differences on the machine: Firefox rather than Chromium, so web
app launchers open a window instead of a Chromium app frame; no AI tooling; no
Bluetooth; and `omarchy update` upgrades packages without touching the
bootloader, since U-Boot in KERN-A never changes.

## When it does not reach a desktop

Boot stopping at "Reached target Graphical Interface" means systemd is fine and
the display manager is not: the session either never started or died. The power
button shutting the machine down cleanly confirms systemd is still answering.

`Failed to read display number from pipe` in SDDM's log is not the X11-specific
message it looks like. SDDM's Wayland path reads the display name from a pipe
too, and logs that line whenever the compositor exits during startup — so it
says "Hyprland did not come up", not "there is no X server". The one time it
appeared here, the cause was a corrupt library in the image, and the fix was to
the build rather than to any configuration.

On the machine, a virtual terminal usually still works — **Ctrl+Alt+F2**, log
in, then:

```bash
systemctl status sddm --no-pager
journalctl -b -u sddm --no-pager | tail -50
journalctl -b -p err --no-pager | tail -50
cat /boot/BUILD_STAMP        # which build, and which kernel/Mesa/compositor
```

If no terminal responds, take the card to another machine. The image keeps a
persistent journal (`/var/log/journal`), so the failed boot is readable there:

```bash
journalctl -D /mnt/var/log/journal -b -1 -p err
```

To boot without a display manager, edit `boot/extlinux/extlinux.conf` on the
card and append `systemd.unit=multi-user.target` to the `APPEND` line. U-Boot on
this board shows no menu, so the config's default entry is the only choice it
offers — a rescue entry has to be made the default rather than picked at boot.

`rockchip-pm-domain … sync_state() pending due to ff9c0000.video-codec` is not
a fault. The power-domain controller defers `sync_state()` until every consumer
has probed, and the video codec has no driver here; it appears on healthy boots
too.

Two things worth ruling out before suspecting the port: every build syncs
against live Arch Linux ARM repositories, so a kernel or Mesa update alone can
change behaviour between two images built from the same commit — compare their
`/boot/BUILD_STAMP` files. And a session that fails only on battery is a
power/clock problem in the kernel rather than anything Omarchy installed.

## Checking graphics acceleration

Panfrost drives the Mali T764 out of the mainline kernel, with nothing to
install — but it is worth confirming rather than assuming, since a session that
fell back to software rendering looks the same until it has to draw something.
On the machine:

```bash
sudo dmesg | grep -i panfrost                       # driver bind and GPU id
cat /sys/class/drm/card*/device/uevent | grep DRIVER # DRIVER=panfrost
hyprctl systeminfo | grep -i 'GL ver'               # GLES version in use
```

Read the GL version rather than looking for a GPU name. `hyprctl systeminfo`
builds its GPU section from `lspci`, and an RK3288 has no PCI bus, so that
section is empty on this board and on every other ARM one — its absence says
nothing.

`GL ver: 3.0` is the answer you want: OpenGL ES 3.0 is what Panfrost advertises
on Midgard hardware. Software rendering would report a *higher* number, not a
lower one — llvmpipe advertises ES 3.2 — so a 3.0 here means the Mali is doing
the work. `backend: drm` in the same output confirms Hyprland is driving KMS
directly rather than running nested. `mesa-utils` (not installed by default)
adds `eglinfo` if a full renderer string is wanted.

Measured on a C201P: `panfrost` bound, `backend: drm`, `GL ver: 3.0`.

### Rounded corners render wrong in Firefox

Seen on the C201P: rounded corners in web content come out broken — visible
across sites, YouTube included. Rounded corners are WebRender's clip-mask path,
and Panfrost's Midgard support is where that path is most likely to be at
fault, so the first question is whether the GL stack is at fault at all.
Hyprland draws its own rounded window corners; if those look right while
Firefox's do not, the shaders are the suspect rather than Mesa generally.

Confirmed on the hardware: setting `gfx.webrender.software = true` in
`about:config` and restarting Firefox fixes the corners, which places the fault
in the GPU path rather than in Firefox's layout. Mesa was 1:26.2.1-1 at the
time — current, not stale — so this is a live Panfrost Midgard bug rather than
something a newer Mesa already fixes, and it is worth reporting upstream with a
screenshot. A C201P is a reproducible target for it.

The port does not set that preference. It only moves page rasterization onto
four Cortex-A17 cores, and the GPU path is otherwise doing useful work here —
which of correct corners or faster pages matters more is the machine owner's
call, not the image's. To keep it, either set it per profile:

```bash
echo 'user_pref("gfx.webrender.software", true);' >> ~/.mozilla/firefox/*/user.js
```

or set it for every profile through Firefox's `Preferences` policy, for which
Omarchy already ships `default/firefox/policies.json` — a file this port does
not yet install.

Worth knowing when comparing against another distribution on the same machine:
Firefox reaches this path on Wayland, where it composites through DMABUF and
WebRender by default. The same machine running Firefox ESR on X11 may never
exercise the broken shaders at all, so "it looked fine on Debian" does not
mean the GPU was doing the work there.

## Omarchy's Hyprland configuration runs unmodified

`hyprctl systeminfo` reports `configProvider: lua` on Arch Linux ARM's stock
Hyprland, which settles a question worth settling: Omarchy configures Hyprland
through Lua (`config/hypr/*.lua`, `default/hypr/**`), and that is an upstream
Hyprland feature rather than something Omarchy patches in. The desktop this port
produces is therefore configured by Omarchy's own files, not a stock Hyprland
wearing Omarchy's name — and no custom compositor build stands between this
proof of concept and a real port.

In Firefox, `about:support` reports "Compositing: WebRender" when accelerated
and "WebRender (Software)" when not, and `WEBGL_RENDERER` names the GPU
Panfrost exposes.

Hardware *video* decode is a separate question and is not set up: the RK3288's
VPU needs a VA-API driver speaking the V4L2 request API, which `armv7h` has no
package for. Video plays through the CPU.

## The per-user phase

`omarchy-provision-user` routes ARMv7 to `install/armv7/user.sh` the same way
the system chain is routed. What it leaves out is `mise-work.sh` and `mise.sh`:
mise reaches Omarchy as `mise-bin`, which pkgs.omarchy.org builds for x86_64
only, and the agent CLIs that leaf then installs — claude, codex, gh, opencode —
publish x86_64 and aarch64 binaries, not armv7h. Left in the chain it fails on
`mise: command not found` and, because the phase runs under `set -e`, takes
every leaf after it down too. The x86 hardware leaves are absent for a duller
reason: each is gated on a DMI match for a laptop this is not.

The image builder runs this phase in the chroot but does not trust it. Graphical
tools — theme setting, icon caches — sometimes abort under qemu-user on
emulation rather than on anything wrong with the image, so the builder deletes
the `finalize-user` marker afterwards. `omarchy-provision-first-run` reruns the
whole phase at first login whenever that marker is absent, which puts the
authoritative run on the real hardware and costs one repeat of an idempotent
step.

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
- **Performance.** A quad-core Cortex-A17 with 2 or 4 GB of RAM and Panfrost is not
  what the desktop was tuned for; compositing works, video and the browser are
  modest.
- **No snapshots, no hibernation, no Secure Boot story.** ext4 root, no swap
  partition (zram only).
- **Not upstream-ready as a supported target.** It is a working shape for one
  board, with the parts that generalize (device-tree detection, extlinux, the
  ARMv7 chain) kept separate from the parts that do not.
