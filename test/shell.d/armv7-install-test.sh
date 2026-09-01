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
