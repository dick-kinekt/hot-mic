#!/usr/bin/env python3
"""Build the Hot Mic disk image without Finder automation.

The script intentionally creates a writable HFS+ image for Finder metadata, then
converts it to a compressed read-only UDZO image. It needs the Python `ds_store`
package (and its `mac_alias` dependency) to write Finder's .DS_Store file.
"""

from __future__ import annotations

import argparse
import math
import plistlib
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


APP_NAME = "Hot Mic"
SCHEME = "Dictation"
REQUIRED_ARCHITECTURES = frozenset(("arm64", "x86_64"))
WINDOW_ORIGIN = (100, 100)
WINDOW_SIZE = (660, 420)
APP_LOCATION = (175, 210)
APPLICATIONS_LOCATION = (485, 210)


class PackagingError(RuntimeError):
    pass


def project_root() -> Path:
    return Path(__file__).resolve().parents[1]

def staging_parent(value: Path | None, root: Path) -> Path | None:
    if value is None:
        return None

    parent = resolve_path(value, root)
    try:
        parent.mkdir(parents=True, exist_ok=True)
    except OSError as error:
        raise PackagingError(f"Could not create temporary staging parent {parent}: {error}") from error
    if not parent.is_dir():
        raise PackagingError(f"Temporary staging parent is not a directory: {parent}")
    return parent


def finder_layout_dependencies() -> tuple[Any, Any]:
    try:
        from ds_store import DSStore
        from mac_alias import Alias
    except ImportError as error:
        raise PackagingError(
            "Finder layout requires the Python packages `ds_store` and `mac_alias`. From the repository "
            "root, create an isolated environment with `python3 -m venv .build/dmg-tools`, install the "
            "pinned dependencies with `.build/dmg-tools/bin/python -m pip install -r "
            "scripts/dmg-requirements.txt`, then rerun using `.build/dmg-tools/bin/python "
            "scripts/build_dmg.py`."
        ) from error
    return DSStore, Alias


def run(command: list[str], *, capture_output: bool = False) -> subprocess.CompletedProcess[bytes]:
    print("+", subprocess.list2cmdline(command))
    return subprocess.run(command, check=True, capture_output=capture_output)


def resolve_path(value: Path, root: Path) -> Path:
    return value.expanduser().resolve() if value.is_absolute() else (root / value).resolve()


def read_info(app: Path) -> dict[str, Any]:
    info_path = app / "Contents" / "Info.plist"
    if not app.is_dir() or app.suffix != ".app" or not info_path.is_file():
        raise PackagingError(f"Expected a macOS application bundle, got {app}")
    with info_path.open("rb") as stream:
        value = plistlib.load(stream)
    if not isinstance(value, dict):
        raise PackagingError(f"Invalid Info.plist in {app}")
    return value


def app_executable(app: Path, info: dict[str, Any]) -> Path:
    executable = info.get("CFBundleExecutable")
    if not isinstance(executable, str) or not executable:
        raise PackagingError(f"CFBundleExecutable is missing from {app / 'Contents' / 'Info.plist'}")
    path = app / "Contents" / "MacOS" / executable
    if not path.is_file():
        raise PackagingError(f"Application executable is missing: {path}")
    return path


def universal_architectures(executable: Path) -> None:
    completed = run(["/usr/bin/lipo", "-archs", str(executable)], capture_output=True)
    found = frozenset(completed.stdout.decode("utf-8").split())
    missing = REQUIRED_ARCHITECTURES - found
    if missing:
        expected = ", ".join(sorted(REQUIRED_ARCHITECTURES))
        actual = ", ".join(sorted(found)) or "none"
        raise PackagingError(f"{executable} is not universal; expected {expected}, found {actual}")


def build_release(root: Path) -> Path:
    derived_data = root / ".build" / "dmg-derived"
    run([
        "/usr/bin/xcodebuild",
        "-project", str(root / "Dictation.xcodeproj"),
        "-scheme", SCHEME,
        "-configuration", "Release",
        "-derivedDataPath", str(derived_data),
        "ARCHS=arm64 x86_64",
        "ONLY_ACTIVE_ARCH=NO",
        "build",
    ])

    app = derived_data / "Build" / "Products" / "Release" / f"{APP_NAME}.app"
    if not app.is_dir():
        raise PackagingError(f"Release build did not produce {app}")
    return app


def clean_appledouble(root: Path) -> None:
    for candidate in root.rglob("._*"):
        if candidate.is_file() or candidate.is_symlink():
            candidate.unlink()


def clear_staged_extended_attributes(path: Path) -> None:
    # ExFAT represents extended attributes as AppleDouble files. Do this only
    # to the temporary staged copy, before its final code-signing pass.
    run(["/usr/bin/xattr", "-cr", str(path)])


def copy_application(source: Path, destination: Path) -> None:
    def ignored(_directory: str, names: list[str]) -> set[str]:
        return {name for name in names if name == ".DS_Store" or name.startswith("._")}

    shutil.copytree(source, destination, symlinks=True, copy_function=shutil.copy2, ignore=ignored)


def sign_application(app: Path, signing_identity: str | None) -> None:
    identity = signing_identity or "-"
    command = [
        "/usr/bin/codesign",
        "--force",
        "--deep",
        "--preserve-metadata=identifier,entitlements,flags,runtime",
        "--sign", identity,
    ]
    if signing_identity:
        command.extend(["--options", "runtime", "--timestamp"])
    command.append(str(app))
    run(command)
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)])


def image_size_megabytes(app: Path, background: Path) -> int:
    payload = background.stat().st_size
    for entry in app.rglob("*"):
        if entry.is_file() and not entry.is_symlink():
            payload += entry.stat().st_size
    return max(80, math.ceil(payload * 1.45 / (1024 * 1024)) + 32)


def create_writable_image(image: Path, size_megabytes: int) -> None:
    run([
        "/usr/bin/hdiutil", "create",
        "-size", f"{size_megabytes}m",
        "-fs", "HFS+",
        "-volname", APP_NAME,
        "-ov",
        str(image),
    ])


def attach_image(image: Path) -> Path:
    completed = run([
        "/usr/bin/hdiutil", "attach",
        "-nobrowse",
        "-noverify",
        "-noautoopen",
        "-plist",
        str(image),
    ], capture_output=True)
    try:
        attachment = plistlib.loads(completed.stdout)
    except plistlib.InvalidFileException as error:
        raise PackagingError("hdiutil did not return attachment metadata") from error

    for entity in attachment.get("system-entities", []):
        mount_point = entity.get("mount-point")
        if isinstance(mount_point, str):
            mount = Path(mount_point)
            if mount.is_dir():
                return mount
    raise PackagingError("hdiutil attached the image without a mount point")


def detach_image(mount: Path) -> None:
    # Do not add -force: the process must never unmount an unrelated Finder disk.
    run(["/usr/bin/hdiutil", "detach", str(mount)])


def finder_layout(volume: Path, background_source: Path) -> None:
    DSStore, Alias = finder_layout_dependencies()

    background_directory = volume / ".background"
    background_directory.mkdir()
    background = background_directory / "InstallerBackground.png"
    shutil.copy2(background_source, background)

    browser_window = {
        "ShowStatusBar": False,
        "WindowBounds": f"{{{{{WINDOW_ORIGIN[0]}, {WINDOW_ORIGIN[1]}}}, {{{WINDOW_SIZE[0]}, {WINDOW_SIZE[1]}}}}}",
        "ContainerShowSidebar": False,
        "PreviewPaneVisibility": False,
        "SidebarWidth": 0,
        "ShowTabView": False,
        "ShowToolbar": False,
        "ShowPathbar": False,
        "ShowSidebar": False,
    }
    icon_view = {
        "viewOptionsVersion": 1,
        "backgroundType": 2,
        "backgroundImageAlias": Alias.for_file(str(background)).to_bytes(),
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "gridSpacing": 100.0,
        "arrangeBy": "none",
        "showIconPreview": False,
        "showItemInfo": False,
        "labelOnBottom": True,
        "textSize": 12.0,
        "iconSize": 96.0,
        "scrollPositionX": 0.0,
        "scrollPositionY": 0.0,
    }

    with DSStore.open(str(volume / ".DS_Store"), "w+") as store:
        store["."]["vSrn"] = ("long", 1)
        store["."]["bwsp"] = browser_window
        store["."]["icvp"] = icon_view
        store["."]["icvl"] = (b"type", b"icnv")
        store[f"{APP_NAME}.app"]["Iloc"] = APP_LOCATION
        store["Applications"]["Iloc"] = APPLICATIONS_LOCATION


def convert_read_only(source: Path, destination: Path) -> None:
    run([
        "/usr/bin/hdiutil", "convert",
        str(source),
        "-format", "UDZO",
        "-imagekey", "zlib-level=9",
        "-ov",
        "-o", str(destination),
    ])


def notarize(image: Path, profile: str) -> None:
    run(["/usr/bin/xcrun", "notarytool", "submit", str(image), "--keychain-profile", profile, "--wait"])
    run(["/usr/bin/xcrun", "stapler", "staple", str(image)])
    run(["/usr/bin/xcrun", "stapler", "validate", str(image)])


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Package Hot Mic as a Finder-ready DMG.")
    parser.add_argument(
        "--app",
        type=Path,
        help="Use this already-built .app bundle instead of invoking xcodebuild.",
    )
    parser.add_argument(
        "--work-dir",
        type=Path,
        metavar="PATH",
        help="Temporary staging parent (created if needed); defaults to the standard OS temporary directory.",
    )
    parser.add_argument(
        "--signing-identity",
        help="Developer ID Application identity for distribution signing. Omit for ad-hoc signing (not notarized).",
    )
    parser.add_argument(
        "--notary-profile",
        help="notarytool keychain profile. Requires --signing-identity and staples after acceptance.",
    )
    args = parser.parse_args()
    if args.notary_profile and not args.signing_identity:
        parser.error("--notary-profile requires --signing-identity")
    return args


def main() -> int:
    args = parse_arguments()
    root = project_root()
    work_parent = staging_parent(args.work_dir, root)
    finder_layout_dependencies()
    background = root / "Resources" / "InstallerBackground.png"
    if not background.is_file():
        raise PackagingError(f"Missing installer background: {background}")

    source_app = resolve_path(args.app, root) if args.app else build_release(root)
    info = read_info(source_app)
    universal_architectures(app_executable(source_app, info))

    version = info.get("CFBundleShortVersionString")
    if not isinstance(version, str) or not version.strip():
        version = "1.0"
    version = version.strip()
    if any(character not in "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz.-" for character in version):
        raise PackagingError(f"Unsafe CFBundleShortVersionString for filename: {version!r}")

    dist = root / "dist"
    dist.mkdir(exist_ok=True)
    output = dist / f"Hot-Mic-{version}.dmg"

    try:
        work = Path(tempfile.mkdtemp(prefix=f"hot-mic-{version}-", dir=work_parent))
    except OSError as error:
        location = work_parent or Path(tempfile.gettempdir())
        raise PackagingError(f"Could not create a temporary staging directory in {location}: {error}") from error
    writable = work / "Hot-Mic-writable.dmg"
    converted = work / f"Hot-Mic-{version}.dmg"
    descriptor, pending_name = tempfile.mkstemp(prefix=f".Hot-Mic-{version}-", suffix=".dmg", dir=dist)
    os.close(descriptor)
    pending = Path(pending_name)
    pending.unlink()
    mounted: Path | None = None
    complete = False

    try:
        create_writable_image(writable, image_size_megabytes(source_app, background))
        mounted = attach_image(writable)
        staged_app = mounted / f"{APP_NAME}.app"
        copy_application(source_app, staged_app)
        (mounted / "Applications").symlink_to("/Applications")
        clean_appledouble(mounted)
        clear_staged_extended_attributes(staged_app)
        sign_application(staged_app, args.signing_identity)

        finder_layout(mounted, background)
        clean_appledouble(mounted)
        detach_image(mounted)
        mounted = None

        convert_read_only(writable, converted)
        if not converted.is_file():
            raise PackagingError(f"hdiutil did not produce the compressed image: {converted}")
        shutil.copy2(converted, pending)

        if args.notary_profile:
            notarize(pending, args.notary_profile)
        os.replace(pending, output)
        complete = True

        if args.notary_profile:
            print(f"Notarized and stapled distribution DMG: {output}")
        elif args.signing_identity:
            print(f"Developer ID-signed but not notarized DMG: {output}")
            print("Notarization was not requested; do not publish this artifact as a notarized release.")
        else:
            print(f"Ad-hoc signed and not notarized DMG: {output}")
            print("No verified developer identity; Gatekeeper may block the downloaded app.")
        return 0
    finally:
        if mounted is not None:
            try:
                detach_image(mounted)
            except subprocess.CalledProcessError:
                print(
                    f"Could not detach the owned staging image at {mounted}; it was not force-unmounted. "
                    f"The staging directory is retained at {work} for safe recovery.",
                    file=sys.stderr,
                )
            else:
                mounted = None
        if mounted is None:
            shutil.rmtree(work, ignore_errors=True)
        if not complete and pending.exists():
            pending.unlink()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (PackagingError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
