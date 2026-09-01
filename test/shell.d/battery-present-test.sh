#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

present() {
  OMARCHY_POWER_SUPPLY_PATH="$1" "$ROOT/bin/omarchy-battery-present"
}

make_supply() {
  local dir="$1"
  shift

  mkdir -p "$dir"
  while (( $# > 1 )); do
    printf '%s\n' "$2" >"$dir/$1"
    shift 2
  done
}

acpi="$tmp_dir/acpi"
make_supply "$acpi/BAT0" type Battery present 1
make_supply "$acpi/AC" type Mains online 1
present "$acpi" || fail "an ACPI battery is present"
pass "an ACPI battery is present"

# An ARM Chromebook's smart battery is named after the driver and bus that
# found it, not BAT0, and it is exactly the case this had to grow to cover.
sbs="$tmp_dir/sbs"
make_supply "$sbs/sbs-20-000b" type Battery present 1 scope System
present "$sbs" || fail "a device-tree battery is present"
pass "a device-tree battery is present"

# A desktop with a wireless mouse has a battery in the mouse, not in itself.
peripheral="$tmp_dir/peripheral"
make_supply "$peripheral/hidpp_battery_0" type Battery scope Device
make_supply "$peripheral/AC" type Mains online 1
present "$peripheral" && fail "a peripheral battery is not the machine's battery"
pass "a peripheral battery is not the machine's battery"

empty_bay="$tmp_dir/empty-bay"
make_supply "$empty_bay/BAT1" type Battery present 0
present "$empty_bay" && fail "an empty battery bay reports no battery"
pass "an empty battery bay reports no battery"

desktop="$tmp_dir/desktop"
make_supply "$desktop/AC" type Mains online 1
present "$desktop" && fail "a machine with no battery reports none"
pass "a machine with no battery reports none"
