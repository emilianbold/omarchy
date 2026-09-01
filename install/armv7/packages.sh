# Install the Omarchy package set that Arch Linux ARM carries for armv7h.
#
# Deliberately not omarchy-pkg-add: that aborts the install on the first package
# pacman cannot resolve, and armv7h is a partial repository. Arch Linux ARM
# builds what it can from Arch's PKGBUILDs, and the Omarchy repo
# (pkgs.omarchy.org) has no armv7h at all, so a machine that is missing an
# application should still finish setup and boot to a desktop. Every package
# that did not install is named in the report this writes, which is the list of
# things to build from source next.

REPORT_DIR="${OMARCHY_ARMV7_REPORT_DIR:-/var/lib/omarchy}"
REPORT="$REPORT_DIR/armv7-packages.report"
LIST_DIR="${OMARCHY_ARMV7_PACKAGE_DIR:-$OMARCHY_INSTALL/armv7/packages}"

missing_essential=()
missing_desktop=()

install_list() {
  local list="$1"
  local -n missing_ref="$2"
  local pkg

  [[ -f $list ]] || return 0

  while read -r pkg; do
    pkg="${pkg%%#*}"
    pkg="${pkg// /}"
    [[ -n $pkg ]] || continue

    pacman -Q "$pkg" &>/dev/null && continue

    if pacman -S --noconfirm --needed "$pkg" >/dev/null 2>&1; then
      echo "Installed $pkg"
    else
      echo "Unavailable for armv7h: $pkg"
      missing_ref+=("$pkg")
    fi
  done <"$list"
}

install_list "$LIST_DIR/essential.packages" missing_essential
install_list "$LIST_DIR/desktop.packages" missing_desktop

install -d "$REPORT_DIR"
{
  echo "# Omarchy armv7h package report - $(date '+%Y-%m-%d %H:%M:%S')"
  echo "# Packages listed here are not installed. Build them from source (AUR"
  echo "# PKGBUILDs, or the Omarchy package sources) to complete the desktop."
  (( ${#missing_essential[@]} > 0 )) && printf 'essential %s\n' "${missing_essential[@]}"
  (( ${#missing_desktop[@]} > 0 )) && printf 'desktop %s\n' "${missing_desktop[@]}"
  :
} >"$REPORT"

if (( ${#missing_essential[@]} > 0 )); then
  echo "WARNING: essential packages unavailable for armv7h: ${missing_essential[*]}"
fi

if (( ${#missing_desktop[@]} > 0 )); then
  echo "WARNING: desktop packages unavailable for armv7h: ${missing_desktop[*]}"
fi

echo "Package report written to $REPORT"
