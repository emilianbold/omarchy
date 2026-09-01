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

# Why a package did not install decides what to do about it: build it from
# source, chase the dependency that is really missing, or just retry. Reporting
# every failure as "unavailable" hides that difference -- and hides the case
# where a package Arch Linux ARM does carry failed for an unrelated reason.
package_failure_reason() {
  local output="$1" detail

  if grep -q 'target not found' <<<"$output"; then
    printf 'not in the armv7h repositories'
    return
  fi

  if grep -q 'unable to satisfy dependency\|could not satisfy dependencies' <<<"$output"; then
    detail=$(grep -m1 -o "unable to satisfy dependency '[^']*'" <<<"$output" || true)
    printf '%s' "${detail:-a dependency is unavailable}"
    return
  fi

  if grep -q 'failed retrieving file\|failed to commit transaction' <<<"$output"; then
    printf 'download failed'
    return
  fi

  detail=$(grep -m1 '^error:' <<<"$output" | sed 's/^error: //' || true)
  printf '%s' "${detail:-pacman failed with no error line}"
}

install_list() {
  local list="$1"
  local -n missing_ref="$2"
  local pkg output reason

  [[ -f $list ]] || return 0

  while read -r pkg; do
    pkg="${pkg%%#*}"
    pkg="${pkg// /}"
    [[ -n $pkg ]] || continue

    pacman -Q "$pkg" &>/dev/null && continue

    if output=$(pacman -S --noconfirm --needed "$pkg" 2>&1); then
      echo "Installed $pkg"
    else
      reason=$(package_failure_reason "$output")
      echo "Not installed: $pkg - $reason"
      missing_ref+=("$pkg - $reason")
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
  echo "WARNING: ${#missing_essential[@]} essential package(s) did not install; see $REPORT"
fi

if (( ${#missing_desktop[@]} > 0 )); then
  echo "WARNING: ${#missing_desktop[@]} desktop package(s) did not install; see $REPORT"
fi

echo "Package report written to $REPORT"
