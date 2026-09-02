#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command python3

VERIFIER="$ROOT/install/armv7/verify-image-files.py"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

# A pacman database with one package, and an image root holding its files.
root="$tmp_dir/root"
mkdir -p "$root/var/lib/pacman/local/testpkg-1.0" "$root/usr/lib" "$root/etc"

printf '\177ELF\002\001\001 a real library' >"$root/usr/lib/libgood.so.1"
printf 'the content this file is supposed to have' >"$tmp_dir/original"

good_digest=$(sha256sum "$root/usr/lib/libgood.so.1" | cut -d' ' -f1)
original_digest=$(sha256sum "$tmp_dir/original" | cut -d' ' -f1)

# The damage this exists to catch: the file keeps the size pacman recorded, and
# reads back as NULs, because its data blocks were never allocated. Neither a
# size check nor an ELF header check on a file that still starts correctly would
# see it.
head -c 41 /dev/zero >"$root/usr/lib/liblost.so.9.3"

write_mtree() {
  {
    echo "#mtree"
    echo "/set type=file mode=644"
    printf './usr/lib/libgood.so.1 time=1.0 size=%s sha256digest=%s\n' \
      "$(stat -c%s "$root/usr/lib/libgood.so.1")" "$good_digest"
    printf './usr/lib/liblost.so.9.3 time=1.0 size=41 sha256digest=%s\n' "$1"
    # Symlinks and directories carry no digest and must not be checked.
    echo "./usr/lib/libgood.so type=link link=libgood.so.1 time=1.0"
    echo "./usr/lib type=dir time=1.0"
    # /etc is setup's to edit, so a changed file there is not damage.
    printf './etc/mkinitcpio.conf time=1.0 size=9 sha256digest=%s\n' "$original_digest"
  } | gzip >"$root/var/lib/pacman/local/testpkg-1.0/mtree"
}

printf 'edited by setup\n' >"$root/etc/mkinitcpio.conf"

write_mtree "$original_digest"
if python3 "$VERIFIER" "$root" >/dev/null 2>"$tmp_dir/err"; then
  fail "a file whose blocks were lost is reported" "$(cat "$tmp_dir/err")"
fi
grep -q '/usr/lib/liblost.so.9.3' "$tmp_dir/err" ||
  fail "the damaged file is named" "$(cat "$tmp_dir/err")"
pass "a file whose blocks were lost is reported, by name"

grep -q 'libgood' "$tmp_dir/err" &&
  fail "an intact file is not reported" "$(cat "$tmp_dir/err")"
pass "an intact file is not reported"

grep -q 'mkinitcpio' "$tmp_dir/err" &&
  fail "a file setup edited under /etc is not treated as damage" "$(cat "$tmp_dir/err")"
pass "a file setup edited under /etc is not treated as damage"

# With the damaged file restored, a clean image passes.
cp "$tmp_dir/original" "$root/usr/lib/liblost.so.9.3"
write_mtree "$original_digest"
python3 "$VERIFIER" "$root" >"$tmp_dir/out" 2>&1 ||
  fail "an intact image verifies" "$(cat "$tmp_dir/out")"
grep -q 'Verified 2 installed files' "$tmp_dir/out" ||
  fail "the verifier counts what it checked" "$(cat "$tmp_dir/out")"
pass "an intact image verifies"
