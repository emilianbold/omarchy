#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

stub_bin="$tmp_dir/bin"
mkdir -p "$stub_bin" "$tmp_dir/applications"

# The launcher reads the Exec line out of /usr/share/applications, which the
# test cannot write to, so run it against a fake root via HOME and a stub
# uwsm-app that records what it was asked to launch.
cat >"$stub_bin/uwsm-app" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >"$tmp_dir/launched"
STUB
cat >"$stub_bin/setsid" <<'STUB'
#!/bin/bash
exec "$@"
STUB
chmod +x "$stub_bin/uwsm-app" "$stub_bin/setsid"

launch_with() {
  local default_browser="$1"

  cat >"$stub_bin/xdg-settings" <<STUB
#!/bin/bash
printf '%s\n' "$default_browser"
STUB
  chmod +x "$stub_bin/xdg-settings"

  rm -f "$tmp_dir/launched"
  PATH="$stub_bin:$PATH" HOME="$tmp_dir/home" \
    bash "$ROOT/bin/omarchy-launch-webapp" https://youtube.com/ >/dev/null 2>&1 || true
  cat "$tmp_dir/launched" 2>/dev/null || true
}

mkdir -p "$tmp_dir/home/.local/share/applications"
printf '[Desktop Entry]\nExec=/usr/bin/firefox %%u\n' \
  >"$tmp_dir/home/.local/share/applications/firefox.desktop"
printf '[Desktop Entry]\nExec=/usr/bin/chromium %%U\n' \
  >"$tmp_dir/home/.local/share/applications/chromium.desktop"

# Chromium keeps the app frame it has always had.
launched=$(launch_with "chromium.desktop")
[[ $launched == *"/usr/bin/chromium --app=https://youtube.com/"* ]] ||
  fail "a Chromium default still opens web apps as an app window" "$launched"
pass "a Chromium default still opens web apps as an app window"

launched=$(launch_with "google-chrome.desktop")
[[ $launched == *"--app=https://youtube.com/"* ]] ||
  fail "a Chrome default still opens web apps as an app window" "$launched"
pass "a Chrome default still opens web apps as an app window"

# Firefox has no --app. Before this, a Firefox default fell through to
# chromium.desktop, and on a machine without Chromium -- every armv7h one --
# the launcher execed an empty command and the web app simply did nothing.
launched=$(launch_with "firefox.desktop")
[[ $launched == *"/usr/bin/firefox --new-window https://youtube.com/"* ]] ||
  fail "a Firefox default opens web apps in a window of their own" "$launched"
pass "a Firefox default opens web apps in a window of their own"

[[ $launched != *"--app="* ]] ||
  fail "a Firefox default is not passed Chromium's --app flag" "$launched"
pass "a Firefox default is not passed Chromium's --app flag"
