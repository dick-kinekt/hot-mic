#!/usr/bin/env python3
"""Archive committed source for downstream packaging; print the release version."""

import argparse
import gzip
import hashlib
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent


def git(*arguments: str) -> bytes:
    return subprocess.check_output(["git", *arguments], cwd=ROOT)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", default="", help="Release tag (vX.Y or vX.Y.Z); omit for a dry run")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "dist")
    args = parser.parse_args()

    commit = git("rev-parse", "HEAD^{commit}").decode().strip()
    info = plistlib.loads(git("show", f"{commit}:Resources/Info.plist"))
    version = info["CFBundleShortVersionString"]
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*))?", version):
        parser.error("CFBundleShortVersionString must be X.Y or X.Y.Z without leading zeroes")
    if args.tag:
        if args.tag != f"v{version}":
            parser.error(f"Tag {args.tag!r} does not match the committed app version v{version}")
        tagged_commit = git("rev-parse", f"refs/tags/{args.tag}^{{commit}}").decode().strip()
        if tagged_commit != commit:
            parser.error(f"Tag {args.tag} does not point to HEAD")

    args.output_dir.mkdir(parents=True, exist_ok=True)
    archive = args.output_dir / f"hot-mic-{version}.tar.gz"
    with tempfile.TemporaryFile() as source:
        subprocess.run(
            ["git", "archive", "--format=tar", f"--prefix=hot-mic-{version}/", commit],
            cwd=ROOT, stdout=source, check=True,
        )
        source.seek(0)
        with archive.open("wb") as destination:
            # Exclude the output path and wall clock from the gzip header.
            with gzip.GzipFile(filename="", mode="wb", fileobj=destination, mtime=0) as compressed:
                shutil.copyfileobj(source, compressed)

    digest = hashlib.sha256()
    with archive.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    (args.output_dir / "SHA256SUMS").write_text(f"{digest.hexdigest()}  {archive.name}\n", encoding="utf-8")
    print(version)


if __name__ == "__main__":
    main()
