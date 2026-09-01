#!/bin/bash

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

export PATH="$ROOT/bin:$PATH"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

OMARCHY_ARCH=armv7l omarchy-hw-armv7 ||
  fail "omarchy-hw-armv7 detects an ARMv7 machine"
pass "omarchy-hw-armv7 detects an ARMv7 machine"

OMARCHY_ARCH=x86_64 omarchy-hw-armv7 &&
  fail "omarchy-hw-armv7 rejects x86_64"
pass "omarchy-hw-armv7 rejects x86_64"

OMARCHY_ARCH=aarch64 omarchy-hw-armv7 &&
  fail "omarchy-hw-armv7 rejects 64-bit ARM"
pass "omarchy-hw-armv7 rejects 64-bit ARM"

# The kernel exposes compatible as NUL-separated strings, so the fixture is
# written the same way rather than as lines.
compatible="$TMPDIR/compatible"
printf 'google,veyron-speedy\0google,veyron\0rockchip,rk3288\0' >"$compatible"

OMARCHY_DT_COMPATIBLE_PATH="$compatible" omarchy-hw-dt-match "rockchip,rk3288" ||
  fail "omarchy-hw-dt-match matches a compatible string"
pass "omarchy-hw-dt-match matches a compatible string"

OMARCHY_DT_COMPATIBLE_PATH="$compatible" omarchy-hw-dt-match "nvidia,tegra" &&
  fail "omarchy-hw-dt-match rejects an absent compatible string"
pass "omarchy-hw-dt-match rejects an absent compatible string"

OMARCHY_DT_COMPATIBLE_PATH="$TMPDIR/none" omarchy-hw-dt-match "google,veyron" &&
  fail "omarchy-hw-dt-match returns false without a device tree"
pass "omarchy-hw-dt-match returns false without a device tree"

OMARCHY_DT_COMPATIBLE_PATH="$compatible" omarchy-hw-chromebook-veyron ||
  fail "omarchy-hw-chromebook-veyron detects a veyron board"
pass "omarchy-hw-chromebook-veyron detects a veyron board"

printf 'raspberrypi,4-model-b\0brcm,bcm2711\0' >"$TMPDIR/other"
OMARCHY_DT_COMPATIBLE_PATH="$TMPDIR/other" omarchy-hw-chromebook-veyron &&
  fail "omarchy-hw-chromebook-veyron rejects another ARM board"
pass "omarchy-hw-chromebook-veyron rejects another ARM board"
