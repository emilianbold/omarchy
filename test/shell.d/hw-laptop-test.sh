#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

# /proc/bus/input/devices as the kernel prints it, trimmed to the lines that
# decide this: the switch bitmap on the "B: SW=" line. SW_LID is bit 0.
cat >"$tmp_dir/with-lid" <<'EOF'
I: Bus=0019 Vendor=0000 Product=0005 Version=0000
N: Name="Lid Switch"
H: Handlers=event0
B: EV=21
B: SW=1

I: Bus=0011 Vendor=0001 Product=0001 Version=ab41
N: Name="AT Translated Set 2 keyboard"
B: EV=120013
EOF

cat >"$tmp_dir/tablet-mode-only" <<'EOF'
I: Bus=0019 Vendor=0000 Product=0006 Version=0000
N: Name="Video Bus"
B: EV=21
B: SW=10
EOF

cat >"$tmp_dir/no-switches" <<'EOF'
I: Bus=0011 Vendor=0001 Product=0001 Version=ab41
N: Name="AT Translated Set 2 keyboard"
B: EV=120013
EOF

laptop() {
  OMARCHY_INPUT_DEVICES_PATH="$1" "$ROOT/bin/omarchy-hw-laptop"
}

# On a real laptop the ACPI lid answers first; these fixtures cover the
# machines that have no ACPI at all, where the lid is only an input switch.
if [[ -e /proc/acpi/button/lid ]]; then
  pass "skipping input-device lid detection: this machine has an ACPI lid button"
  exit 0
fi

laptop "$tmp_dir/with-lid" || fail "a lid switch input device means a laptop"
pass "a lid switch input device means a laptop"

# SW=10 is SW_TABLET_MODE, not SW_LID: a switch is not automatically a lid.
laptop "$tmp_dir/tablet-mode-only" && fail "another switch is not a lid"
pass "another switch is not a lid"

laptop "$tmp_dir/no-switches" && fail "a machine with no switches is not a laptop"
pass "a machine with no switches is not a laptop"

laptop "$tmp_dir/absent" && fail "a machine with no input device list is not a laptop"
pass "a machine with no input device list is not a laptop"
