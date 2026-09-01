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
  -S) [[ $* != *quickshell* ]] ;;
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

grep -q "^desktop quickshell$" "$report" ||
  fail "the report names what did not install" "$(cat "$report")"
pass "the report names what did not install"

grep -qE "^(essential|desktop) (networkmanager|alsa-utils|hyprland)$" "$report" &&
  fail "the report leaves out what did install" "$(cat "$report")"
pass "the report leaves out what did install"

[[ $output == *"WARNING"*"quickshell"* ]] ||
  fail "the run says out loud what is missing" "$output"
pass "the run says out loud what is missing"

[[ $output == *"Installed alsa-utils"* ]] ||
  fail "the run reports what it installed" "$output"
pass "the run reports what it installed"
