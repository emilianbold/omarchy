#!/bin/bash

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

lists="$TMPDIR/packages"
mkdir -p "$lists"
cat >"$lists/essential.packages" <<'EOF'
# a comment, and a blank line follow

networkmanager
alsa-utils
EOF
cat >"$lists/desktop.packages" <<'EOF'
hyprland
quickshell   # trailing comments are stripped too
EOF

# pacman that has networkmanager installed already, can resolve alsa-utils and
# hyprland, and knows nothing about quickshell -- the armv7h situation the leaf
# exists for.
stub_bin="$TMPDIR/bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/pacman" <<'STUB'
#!/bin/bash
case "$1" in
  -Q) [[ $2 == "networkmanager" ]] ;;
  -S)
    if [[ $* == *quickshell* ]]; then
      echo "error: target not found: quickshell" >&2
      exit 1
    fi
    if [[ $* == *hyprland* ]]; then
      echo "error: unable to satisfy dependency 'libwlroots.so=13' required by hyprland" >&2
      exit 1
    fi
    ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$stub_bin/pacman"

# The leaf runs the way run_logged runs it: sourced under bash -eE, where an
# unguarded failure would take the whole install down with it.
output=$(PATH="$stub_bin:$PATH" \
  OMARCHY_ARMV7_PACKAGE_DIR="$lists" \
  OMARCHY_ARMV7_REPORT_DIR="$TMPDIR/state" \
  bash -eE -c 'source "$1"' bash "$ROOT/install/armv7/packages.sh" 2>&1) ||
  fail "a package pacman cannot resolve does not fail setup" "$output"
pass "a package pacman cannot resolve does not fail setup"

report="$TMPDIR/state/armv7-packages.report"
[[ -f $report ]] || fail "the package report is written"

grep -q "^desktop quickshell - not in the armv7h repositories$" "$report" ||
  fail "the report says a package is not built for armv7h" "$(cat "$report")"
pass "the report says a package is not built for armv7h"

# A package Arch Linux ARM does carry, failing for its own reason, must not be
# filed as "unavailable": the fix for it is a dependency, not a source build.
grep -q "^desktop hyprland - unable to satisfy dependency 'libwlroots.so=13'$" "$report" ||
  fail "the report distinguishes a missing dependency from a missing package" "$(cat "$report")"
pass "the report distinguishes a missing dependency from a missing package"

grep -qE "^(essential|desktop) (networkmanager|alsa-utils) " "$report" &&
  fail "the report leaves out what did install" "$(cat "$report")"
pass "the report leaves out what did install"

[[ $output == *"WARNING"*"desktop package(s) did not install"* ]] ||
  fail "the run says out loud that something is missing" "$output"
pass "the run says out loud that something is missing"

[[ $output == *"Not installed: quickshell - not in the armv7h repositories"* ]] ||
  fail "the run names each failure with its reason" "$output"
pass "the run names each failure with its reason"

[[ $output == *"Installed alsa-utils"* ]] ||
  fail "the run reports what it installed" "$output"
pass "the run reports what it installed"
