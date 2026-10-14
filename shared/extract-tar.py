"""Extract a .tar.gz into a directory, dropping the archive's single top-level
directory (what rattler-build does for a url source). Used by
shared/configure-smoke.nu: the smoke environment has no tar or gzip binary.

usage: python extract-tar.py <archive> <dest>
"""
import os
import sys
import tarfile


def main() -> None:
    archive, dest = sys.argv[1], sys.argv[2]
    os.makedirs(dest, exist_ok=True)
    with tarfile.open(archive) as tar:
        for member in tar.getmembers():
            parts = member.name.split("/", 1)
            if len(parts) < 2 or not parts[1]:
                continue  # the top-level directory entry itself
            member.name = parts[1]
            # Symlink targets inside the archive are relative to the tree.
            tar.extract(member, dest, filter="fully_trusted")


if __name__ == "__main__":
    main()
