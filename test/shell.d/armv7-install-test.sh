#!/bin/bash

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

INSTALL_DIR="$ROOT/install/armv7"

for script in "$INSTALL_DIR"/*.sh "$ROOT/bin/omarchy-refresh-extlinux" "$ROOT/bin/omarchy-hw-dt-match"; do
  bash -n "$script" || fail "$(basename "$script") parses"
done
pass "every ARMv7 script parses"

# A chain entry that names a script nobody wrote fails the install on the
# machine, where the only feedback is a log nobody can reach yet.
while read -r path; do
  [[ -f $path ]] || fail "install/armv7/all.sh entry exists: ${path#"$ROOT"/}"
done < <(sed -n 's|^run_logged "\$OMARCHY_INSTALL/\(.*\)"$|'"$ROOT"'/install/\1|p' "$INSTALL_DIR/all.sh")
pass "every leaf in the ARMv7 chain exists"

grep -q 'omarchy-hw-armv7' "$ROOT/bin/omarchy-apply-system" ||
  fail "omarchy-apply-system routes ARMv7 targets to their own chain"
grep -q 'armv7/all.sh' "$ROOT/bin/omarchy-apply-system" ||
  fail "omarchy-apply-system sources the ARMv7 chain"
pass "omarchy-apply-system routes ARMv7 targets to their own chain"

grep -q 'omarchy-hw-armv7' "$ROOT/bin/omarchy-provision-user" ||
  fail "omarchy-provision-user routes ARMv7 targets to their own user chain"
grep -q 'armv7/user.sh' "$ROOT/bin/omarchy-provision-user" ||
  fail "omarchy-provision-user sources the ARMv7 user chain"
pass "omarchy-provision-user routes ARMv7 targets to their own user chain"

while read -r path; do
  [[ -f $path ]] || fail "install/armv7/user.sh entry exists: ${path#"$ROOT"/}"
done < <(sed -n 's|^run_logged "\$OMARCHY_INSTALL/\(.*\)"$|'"$ROOT"'/install/\1|p' "$INSTALL_DIR/user.sh")
pass "every leaf in the ARMv7 user chain exists"

# mise reaches Omarchy as mise-bin, which is x86_64 only, and the leaves that
# use it fail on "mise: command not found" -- taking the rest of the user phase
# with them, since provision-user runs under set -e.
grep -qE '^run_logged .*mise' "$INSTALL_DIR/user.sh" &&
  fail "the ARMv7 user chain leaves out the mise leaves"
pass "the ARMv7 user chain leaves out the mise leaves"

# Board quirks must stay behind board detection: this chain also runs on any
# other ARMv7 machine Omarchy is pointed at.
grep -q 'if omarchy-hw-chromebook-veyron; then' "$INSTALL_DIR/veyron.sh" ||
  fail "veyron setup is gated on the board"
pass "veyron setup is gated on the board"

read_packages() {
  sed 's/#.*//' "$@" | tr -d ' \t' | grep -v '^$'
}

for list in essential desktop; do
  file="$INSTALL_DIR/packages/$list.packages"
  [[ -f $file ]] || fail "$list.packages exists"

  duplicates=$(read_packages "$file" | sort | uniq -d)
  [[ -z $duplicates ]] || fail "$list.packages has no duplicates" "duplicated: $duplicates"
done
pass "package lists are readable and free of duplicates"

# pkgs.omarchy.org publishes x86_64 only, so naming one of its packages here
# would just be a guaranteed entry in the missing-packages report.
omarchy_only=$(read_packages "$INSTALL_DIR/packages/essential.packages" \
  "$INSTALL_DIR/packages/desktop.packages" |
  grep -xE 'aether|cliamp|herdr|omacalc|omacut|omarchy-nvim|omawrite|tensaku|tobi-try|ttfx' || true)
[[ -z $omarchy_only ]] ||
  fail "package lists name only packages Arch Linux ARM could carry" "found: $omarchy_only"
pass "package lists name only packages Arch Linux ARM could carry"

# The ARMv7 lists are a subset of what Omarchy installs on x86_64, so a name
# that appears in neither x86 list is either a deliberate substitution or a
# name typed from memory. hyprland-qtutils was the latter: Omarchy asks for
# hyprland-guiutils, which armv7h has, and the build reported the wrong package
# as missing instead of installing the right one.
armv7_only=$(comm -23 \
  <(read_packages "$INSTALL_DIR"/packages/*.packages | sort -u) \
  <(read_packages "$ROOT/install/omarchy-base.packages" "$ROOT/install/omarchy-other.packages" | sort -u))

# Each of these stands in for something x86_64 gets another way: the base
# system the ISO pacstraps (polkit, sudo, xdg-user-dirs, xdg-utils), a
# dependency worth naming outright because this machine has no ethernet if it
# goes missing (wpa_supplicant), quickshell's QML runtime that arrives as a
# dependency there (qt6-declarative), Arch's full nerd font in place of
# Omarchy's own ttf-jetbrains-mono-nerd-basic, and the two armv7h has no
# equivalent of: firefox for chromium, adwaita-icon-theme for yaru-icon-theme.
expected_armv7_only="adwaita-icon-theme
firefox
polkit
qt6-declarative
sudo
ttf-jetbrains-mono-nerd
wpa_supplicant
xdg-user-dirs
xdg-utils"

if [[ $armv7_only != "$expected_armv7_only" ]]; then
  fail "every ARMv7 package matches an Omarchy package name or a recorded substitution" \
    "unexpected:"$'\n'"$(comm -13 <(printf '%s\n' "$expected_armv7_only") <(printf '%s\n' "$armv7_only"))"
fi
pass "every ARMv7 package matches an Omarchy package name or a recorded substitution"

grep -q 'omarchy-refresh-extlinux' "$INSTALL_DIR/files/95-omarchy-extlinux.hook" ||
  fail "the pacman hook refreshes the extlinux config after a kernel upgrade"
pass "the pacman hook refreshes the extlinux config after a kernel upgrade"

# autodetect traces the build host inside the qemu chroot, so it must stay out
# of the image builder's initramfs hooks.
grep -q '^HOOKS=' "$INSTALL_DIR/files/mkinitcpio-veyron.conf" ||
  fail "the veyron initramfs config sets HOOKS"
grep -E '^HOOKS=' "$INSTALL_DIR/files/mkinitcpio-veyron.conf" | grep -q 'autodetect' &&
  fail "the veyron initramfs config leaves autodetect out"
pass "the veyron initramfs config leaves autodetect out"
