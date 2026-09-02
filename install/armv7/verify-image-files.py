#!/usr/bin/env python3
"""Verify every pacman-installed file under /usr against its recorded checksum.

Run on the build host against a mounted image root, natively, where hashing a
few gigabytes takes seconds rather than minutes under emulation:

    verify-image-files.py /mnt/omarchy-image

Every package records a sha256 for each file it installs, in
/var/lib/pacman/local/<pkg>/mtree. Comparing against those catches the damage a
build can do after installation without noticing -- a file whose data blocks
were never allocated reads back as NULs at its recorded size, which no size or
header check would see in the middle of a file.

Only /usr is checked. Everything under /etc is meant to be edited by setup, and
files this build creates outside a package (the Omarchy tree in
/usr/share/omarchy, symlinks in /usr/local/bin) appear in no mtree and are
skipped by construction.
"""

import gzip
import hashlib
import re
import sys
from pathlib import Path

MAX_REPORTED = 20


def unescape(path: str) -> str:
    """mtree escapes spaces and friends as octal (\\040), and backslash as \\\\."""
    return re.sub(r"\\(\d{3}|\\)", lambda m: "\\" if m.group(1) == "\\" else chr(int(m.group(1), 8)), path)


def entries(mtree: Path):
    with gzip.open(mtree, "rt", errors="replace") as handle:
        for line in handle:
            if not line.startswith("./"):
                continue

            fields = line.split()
            digest = next((f[13:] for f in fields if f.startswith("sha256digest=")), None)
            if digest:
                yield unescape(fields[0][1:]), digest


def main() -> int:
    root = Path(sys.argv[1])
    local = root / "var/lib/pacman/local"
    if not local.is_dir():
        print(f"error: {local} is not a pacman database", file=sys.stderr)
        return 2

    checked = 0
    damaged = []

    for mtree in sorted(local.glob("*/mtree")):
        for relative, digest in entries(mtree):
            if not relative.startswith("/usr/"):
                continue

            path = root / relative.lstrip("/")
            if not path.is_file() or path.is_symlink():
                continue

            digester = hashlib.sha256()
            with path.open("rb") as handle:
                for block in iter(lambda: handle.read(1 << 20), b""):
                    digester.update(block)

            checked += 1
            if digester.hexdigest() != digest:
                damaged.append(relative)

    if damaged:
        print(f"{len(damaged)} of {checked} installed files under /usr do not match "
              "the checksum their package recorded:", file=sys.stderr)
        for relative in damaged[:MAX_REPORTED]:
            print(f"  {relative}", file=sys.stderr)
        if len(damaged) > MAX_REPORTED:
            print(f"  ... and {len(damaged) - MAX_REPORTED} more", file=sys.stderr)
        return 1

    print(f"Verified {checked} installed files under /usr")
    return 0


if __name__ == "__main__":
    sys.exit(main())
