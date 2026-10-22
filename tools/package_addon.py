#!/usr/bin/env python3
"""Build a reproducible, installable archive containing only MapTogether."""
from pathlib import Path
import hashlib
import zipfile

ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "addons/coop_collab"


def package():
    destination = ROOT / "dist"
    destination.mkdir(exist_ok=True)
    archive = destination / "MapTogether-0.1.0.zip"
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as bundle:
        for path in sorted(ADDON.rglob("*")):
            if not path.is_file():
                continue
            if path.is_symlink():
                raise SystemExit("Symlinks must not be included in the addon archive")
            info = zipfile.ZipInfo(path.relative_to(ROOT).as_posix())
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            bundle.writestr(info, path.read_bytes())
    with zipfile.ZipFile(archive) as bundle:
        assert bundle.testzip() is None
        for path in ADDON.rglob("*"):
            if path.is_file():
                assert bundle.read(path.relative_to(ROOT).as_posix()) == path.read_bytes()
    checksum = destination / "SHA256SUMS.txt"
    checksum.write_text(f"{hashlib.sha256(archive.read_bytes()).hexdigest()}  {archive.name}\n")
    return archive, checksum


if __name__ == "__main__":
    for artifact in package():
        print(artifact)
