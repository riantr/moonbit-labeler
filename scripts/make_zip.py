#!/usr/bin/env python3
"""Build a portable zip of a staged Proton application directory.

Why this script exists
----------------------
Two tools that look like they should do this job both fail, in ways that
are easy to miss because the file name still ends in ``.zip``:

* ``tar -a -cf out.zip dir`` — Windows' bsdtar ignores the ``-a``
  extension hint for zip and writes a **tar** archive. The result is a
  file named ``out.zip`` whose first bytes are the tar header's name
  field, not the ``PK`` signature, so ``unzip`` and Windows Explorer
  both reject it. This is what the 0.2.17 release shipped.
* ``Compress-Archive`` (what Proton's own zip step uses) deflates, but
  it writes entry names with **backslash** separators
  (``moonbit-labeler\\app.exe``). That violates the ZIP spec and breaks
  extraction with anything that is not Windows Explorer — python's
  ``zipfile``, macOS Archive Utility and ``unzip`` all mis-handle it.

This script writes a spec-compliant archive instead: forward-slash entry
names, the ``PK`` signature, and deflate compression. The result is both
portable across tools and about 2.2x smaller than the tar that ``tar -a``
produces, because the payload is compressed rather than stored.

Usage
-----
    python scripts/make_zip.py <staged_dir> <output_zip>

``<staged_dir>`` is included in the archive under its own base name, so
``target/proton-dist/moonbit-labeler`` becomes ``moonbit-labeler/...``
inside the zip.
"""

from __future__ import annotations

import os
import sys
import zipfile
from pathlib import Path

# 1 MiB chunks: large enough to keep the syscall count down, small enough
# that a 275 MB DLL never has to be held in memory.
CHUNK = 1024 * 1024


def add_tree(archive: zipfile.ZipFile, root: Path) -> int:
    """Write every file under ``root`` into ``archive``; return the count."""
    written = 0
    base = root.resolve()
    prefix = root.name

    # The directory entry itself, so an empty extraction still creates the
    # folder. ZipFile writes the trailing slash for us.
    info = zipfile.ZipInfo(prefix + "/")
    info.external_attr = (0o40775 << 16) | 0x10  # drwxrwxr-x
    archive.writestr(info, b"")

    for dirpath, dirnames, filenames in os.walk(base):
        dirnames.sort()
        filenames.sort()
        here = Path(dirpath)
        for name in filenames:
            source = here / name
            if source.is_symlink() or not source.is_file():
                continue
            # PurePosixPath keeps the separators forward-slashed on Windows,
            # which is the whole point of this script.
            arcname = Path(prefix) / here.relative_to(base) / name
            arcname = arcname.as_posix()
            with archive.open(arcname, "w", force_zip64=True) as target:
                with source.open("rb") as handle:
                    while True:
                        block = handle.read(CHUNK)
                        if not block:
                            break
                        target.write(block)
            written += 1
    return written


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        sys.stderr.write("usage: make_zip.py <staged_dir> <output_zip>\n")
        return 2

    root = Path(argv[1])
    output = Path(argv[2])
    if not root.is_dir():
        sys.stderr.write("not a directory: " + str(root) + "\n")
        return 1
    if output.exists():
        output.unlink()
    output.parent.mkdir(parents=True, exist_ok=True)

    # ZIP_DEFLATED with the default level: the payload is mostly CEF
    # binaries, which are already partly compressed, so the win comes
    # from the native code inside libcef.dll rather than from the .pak
    # files. Expect roughly 45% of the uncompressed size.
    with zipfile.ZipFile(
        output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9
    ) as archive:
        count = add_tree(archive, root)

    size = output.stat().st_size
    print("zip: " + str(output))
    print("files: " + str(count))
    print("bytes: " + str(size))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
