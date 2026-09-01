#!/bin/bash

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

export PATH="$ROOT/bin:$PATH"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

compatible="$TMPDIR/compatible"
printf 'google,veyron-speedy-rev9\0google,veyron-speedy\0google,veyron\0rockchip,rk3288\0' >"$compatible"

settings="$TMPDIR/extlinux-settings"
cat >"$settings" <<'EOF'
OMARCHY_EXTLINUX_ROOT="LABEL=omarchy"
OMARCHY_EXTLINUX_CMDLINE="rw rootwait panic=10 console=tty0"
EOF

make_boot() {
  local boot="$1"

  rm -rf "$boot"
  mkdir -p "$boot/dtbs/rockchip"
  : >"$boot/zImage"
  : >"$boot/initramfs-linux.img"
  : >"$boot/initramfs-linux-fallback.img"
  : >"$boot/dtbs/rockchip/rk3288-veyron-speedy.dtb"
}

refresh() {
  OMARCHY_BOOT_DIR="$1" \
    OMARCHY_EXTLINUX_SETTINGS="$settings" \
    OMARCHY_DT_COMPATIBLE_PATH="$compatible" \
    omarchy-refresh-extlinux
}

boot="$TMPDIR/boot"
make_boot "$boot"

refresh "$boot" >/dev/null || fail "omarchy-refresh-extlinux writes a config"
conf="$boot/extlinux/extlinux.conf"
[[ -f $conf ]] || fail "extlinux.conf is created"
pass "omarchy-refresh-extlinux writes a config"

generated=$(cat "$conf")

assert_contains() {
  local description="$1" expected="$2"

  [[ $generated == *"$expected"* ]] ||
    fail "$description" "expected to find: $expected"$'\n'"actual:"$'\n'"$generated"
  pass "$description"
}

assert_contains "boots the default entry" "DEFAULT omarchy"
assert_contains "names the kernel with an absolute path" "KERNEL /boot/zImage"
assert_contains "names the initramfs" "INITRD /boot/initramfs-linux.img"
# The most specific compatible with no dtb of its own must fall through to the
# board entry that has one, rather than to another veyron board's tree.
assert_contains "resolves the board device tree" "FDT /boot/dtbs/rockchip/rk3288-veyron-speedy.dtb"
assert_contains "passes the configured root and cmdline" "APPEND root=LABEL=omarchy rw rootwait panic=10 console=tty0"
# U-Boot falls through to the next label by itself when the default fails to
# load, which is the only recovery path on a machine with no boot console.
assert_contains "adds the fallback initramfs entry" "LABEL omarchy-fallback"

# No fallback image, no second entry: an entry pointing at a file that is not
# there would make U-Boot's fallthrough land on nothing.
boot_single="$TMPDIR/boot-single"
make_boot "$boot_single"
rm "$boot_single/initramfs-linux-fallback.img"
refresh "$boot_single" >/dev/null || fail "omarchy-refresh-extlinux works without a fallback image"
grep -q "omarchy-fallback" "$boot_single/extlinux/extlinux.conf" &&
  fail "omitting the fallback entry when the image is absent"
pass "omitting the fallback entry when the image is absent"

# The lookup is not veyron-specific: any board whose dtb is named after its
# compatible string resolves the same way.
boot_imx="$TMPDIR/boot-imx"
make_boot "$boot_imx"
mkdir -p "$boot_imx/dtbs/nxp/imx"
: >"$boot_imx/dtbs/nxp/imx/imx6q-sabresd.dtb"
printf 'fsl,imx6q-sabresd\0fsl,imx6q\0' >"$TMPDIR/compatible-imx"
OMARCHY_BOOT_DIR="$boot_imx" \
  OMARCHY_EXTLINUX_SETTINGS="$settings" \
  OMARCHY_DT_COMPATIBLE_PATH="$TMPDIR/compatible-imx" \
  omarchy-refresh-extlinux >/dev/null || fail "another board's device tree resolves"
grep -q "FDT /boot/dtbs/nxp/imx/imx6q-sabresd.dtb" "$boot_imx/extlinux/extlinux.conf" ||
  fail "another board's device tree resolves" "$(cat "$boot_imx/extlinux/extlinux.conf")"
pass "another board's device tree resolves"

boot_no_kernel="$TMPDIR/boot-no-kernel"
make_boot "$boot_no_kernel"
rm "$boot_no_kernel/zImage"
refresh "$boot_no_kernel" >/dev/null 2>&1 &&
  fail "failing when no kernel image is present"
pass "failing when no kernel image is present"

boot_no_dtb="$TMPDIR/boot-no-dtb"
make_boot "$boot_no_dtb"
rm "$boot_no_dtb/dtbs/rockchip/rk3288-veyron-speedy.dtb"
refresh "$boot_no_dtb" >/dev/null 2>&1 &&
  fail "failing when the board device tree is missing"
pass "failing when the board device tree is missing"
