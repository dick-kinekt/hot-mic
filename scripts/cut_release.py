#!/usr/bin/env python3
"""Cut a release from the remote default branch without changing this checkout."""

import argparse
from datetime import date
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time


VERSION = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*))?")
RUN_WAIT_SECONDS = 300


class ReleaseError(Exception):
    pass


def run(
    *command: str, cwd: Path, optional: bool = False, identity: dict[str, str] | None = None,
) -> str:
    env = os.environ.copy()
    # A caller's Git plumbing environment must never redirect the temporary clone.
    for key in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR",
                "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES"):
        env.pop(key, None)
    if identity:
        env.update(identity)
    result = subprocess.run(command, cwd=cwd, env=env, text=True, capture_output=True)
    if result.returncode:
        if optional and result.returncode == 1:
            return ""
        detail = result.stderr.strip() or result.stdout.strip()
        raise ReleaseError(f"{' '.join(command)} failed: {detail or result.returncode}")
    return result.stdout.strip()


def gh_json(*arguments: str, cwd: Path):
    return json.loads(run("gh", *arguments, cwd=cwd))


def github_repo(url: str) -> str:
    match = re.fullmatch(
        r"(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)"
        r"([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?/?",
        url,
    )
    if not match:
        raise ReleaseError("Expected a conventional github.com SSH or HTTPS remote without embedded credentials")
    return match[1]


def version_tuple(value: str) -> tuple[int, int, int]:
    if not isinstance(value, str) or not VERSION.fullmatch(value):
        raise ReleaseError(f"Version {value!r} must be X.Y or X.Y.Z without leading zeros")
    parts = [int(part) for part in value.split(".")]
    return tuple(parts + [0] * (3 - len(parts)))


def author_identity(root: Path) -> tuple[str, str]:
    name = run("git", "config", "--get", "user.name", cwd=root, optional=True)
    email = run("git", "config", "--get", "user.email", cwd=root, optional=True)
    if (not name or not email) and (root / ".jj").is_dir() and shutil.which("jj"):
        if not name:
            name = run("jj", "config", "get", "user.name", cwd=root, optional=True)
        if not email:
            email = run("jj", "config", "get", "user.email", cwd=root, optional=True)
    return name, email


def prepare_release(checkout: Path, version: str) -> tuple[str, str]:
    plist_path = checkout / "Resources/Info.plist"
    original = plist_path.read_text(encoding="utf-8")
    info = plistlib.loads(original.encode("utf-8"))
    current = info["CFBundleShortVersionString"]
    if version_tuple(version) <= version_tuple(current):
        raise ReleaseError(f"Release version {version} must be strictly greater than {current}")
    build = info["CFBundleVersion"]
    if not isinstance(build, str) or not re.fullmatch(r"[0-9]+", build):
        raise ReleaseError("CFBundleVersion must be a numeric string")
    next_build = str(int(build) + 1)
    updated = original
    for key, value in (("CFBundleShortVersionString", version), ("CFBundleVersion", next_build)):
        pattern = rf"(<key>{key}</key>\s*<string>)[^<]*(</string>)"
        updated, count = re.subn(pattern, lambda match: match[1] + value + match[2], updated)
        if count != 1:
            raise ReleaseError(f"Expected exactly one XML string for {key} in Resources/Info.plist")

    changelog_path = checkout / "CHANGELOG.md"
    changelog = changelog_path.read_text(encoding="utf-8")
    sections = list(re.finditer(r"^## Unreleased[ \t]*$", changelog, re.MULTILINE))
    if len(sections) != 1:
        raise ReleaseError("CHANGELOG.md must have exactly one '## Unreleased' section")
    section = sections[0]
    following = re.search(r"^## ", changelog[section.end():], re.MULTILINE)
    end = section.end() + following.start() if following else len(changelog)
    notes = changelog[section.end():end].strip()
    content = re.sub(r"<!--.*?-->", "", notes, flags=re.DOTALL)
    content = re.sub(r"^#{1,6} .*?$", "", content, flags=re.MULTILINE).strip()
    if not content:
        raise ReleaseError("CHANGELOG.md Unreleased section must contain release notes")
    promoted = (
        changelog[:section.start()]
        + f"## Unreleased\n\n## {version} — {date.today().isoformat()}\n\n{notes}\n"
        + ("\n" + changelog[end:] if end < len(changelog) else "")
    )
    plist_path.write_text(updated, encoding="utf-8")
    changelog_path.write_text(promoted, encoding="utf-8")
    return current, next_build


def wait_for_release(repo: str, tag: str, commit: str, cwd: Path) -> str:
    deadline = time.monotonic() + RUN_WAIT_SECONDS
    while True:
        runs = gh_json(
            "run", "list", "--repo", repo, "--workflow", "release.yml", "--event", "push",
            "--branch", tag, "--commit", commit, "--json", "databaseId,status,headSha",
            "--limit", "20", cwd=cwd,
        )
        matching = [item for item in runs if item["headSha"] == commit]
        if matching:
            run_id = str(max(matching, key=lambda item: int(item["databaseId"]))["databaseId"])
            # Keep watch interactive so build progress is visible while the release runs.
            subprocess.run(
                ["gh", "run", "watch", run_id, "--repo", repo, "--exit-status", "--interval", "10"],
                cwd=cwd, check=True,
            )
            release = gh_json("release", "view", tag, "--repo", repo, "--json", "url", cwd=cwd)
            if not release.get("url"):
                raise ReleaseError(f"Workflow succeeded but release {tag} has no publication URL")
            return release["url"]
        if time.monotonic() >= deadline:
            raise ReleaseError(f"No push workflow appeared for {tag} at {commit} within {RUN_WAIT_SECONDS}s")
        time.sleep(5)


def cut_release(args: argparse.Namespace) -> None:
    version_tuple(args.version)
    root = Path(run("git", "rev-parse", "--show-toplevel", cwd=Path.cwd()))
    url = run("git", "config", "--get", f"remote.{args.remote}.url", cwd=root, optional=True)
    if not url:
        raise ReleaseError(f"Remote {args.remote!r} has no configured URL")
    repo = github_repo(url)
    push_urls = run(
        "git", "config", "--get-all", f"remote.{args.remote}.pushurl", cwd=root, optional=True,
    ).splitlines()
    if len(push_urls) > 1:
        raise ReleaseError("Multiple push URLs cannot be released atomically; configure a single destination")
    push_url = push_urls[0] if push_urls else url
    if github_repo(push_url).lower() != repo.lower():
        raise ReleaseError("The remote push URL must point to the same GitHub repository as its fetch URL")
    metadata = gh_json(
        "repo", "view", repo, "--json", "nameWithOwner,defaultBranchRef,viewerPermission", cwd=root,
    )
    if metadata["nameWithOwner"].lower() != repo.lower():
        raise ReleaseError("GitHub resolved the remote to a different repository; update the remote URL first")
    if not args.dry_run and metadata.get("viewerPermission") not in {"ADMIN", "MAINTAIN", "WRITE"}:
        raise ReleaseError(f"GitHub push permission is required to release {repo}")
    branch = (metadata.get("defaultBranchRef") or {}).get("name")
    if not branch:
        raise ReleaseError(f"{repo} has no default branch")
    workflow = gh_json("api", f"repos/{repo}/actions/workflows/release.yml", cwd=root)
    if workflow.get("state") != "active":
        raise ReleaseError("The release.yml GitHub Actions workflow must be active")
    tag = f"v{args.version}"
    if run("git", "ls-remote", "--tags", url, f"refs/tags/{tag}", cwd=root):
        raise ReleaseError(f"Remote tag {tag} already exists; do not bump again to retry a failed release")
    name, email = author_identity(root)
    if not args.dry_run and (not name or not email):
        raise ReleaseError("Configure Git user.name and user.email (or JJ user.name/user.email) before releasing")

    with tempfile.TemporaryDirectory(prefix="hot-mic-release-") as temporary:
        checkout = Path(temporary) / "source"
        run(
            "git", "clone", "--single-branch", "--no-tags",
            "--branch", branch, "--", url, str(checkout), cwd=root,
        )
        run("git", "config", "remote.origin.pushurl", push_url, cwd=checkout)
        current, build = prepare_release(checkout, args.version)
        print(f"Release {repo}: {branch} → {tag} ({current} → {args.version}, build {build})", flush=True)
        print("Source: remote default branch; local checkout and uncommitted changes are excluded.", flush=True)
        print(run("git", "--no-pager", "diff", "--no-ext-diff", "--", "Resources/Info.plist", "CHANGELOG.md", cwd=checkout), flush=True)
        if args.dry_run:
            print("Dry run: no commit, tag, or remote refs were written.")
            return

        run("git", "config", "user.name", name, cwd=checkout)
        run("git", "config", "user.email", email, cwd=checkout)
        run("git", "add", "--", "Resources/Info.plist", "CHANGELOG.md", cwd=checkout)
        # Explicit identities override inherited author/committer environment variables.
        identity = {
            "GIT_AUTHOR_NAME": name, "GIT_AUTHOR_EMAIL": email,
            "GIT_COMMITTER_NAME": name, "GIT_COMMITTER_EMAIL": email,
        }
        run("git", "commit", "-m", f"Release {tag}", cwd=checkout, identity=identity)
        run("git", "tag", "-a", tag, "-m", f"Release {tag}", cwd=checkout, identity=identity)
        commit = run("git", "rev-parse", "HEAD", cwd=checkout)
        run(
            "git", "-c", "push.followTags=false", "push", "--atomic", "origin",
            f"HEAD:refs/heads/{branch}", f"refs/tags/{tag}:refs/tags/{tag}", cwd=checkout,
        )
        print(f"Pushed {branch} and {tag} atomically at {commit}. Waiting for publication…", flush=True)
        try:
            release_url = wait_for_release(repo, tag, commit, checkout)
        except (ReleaseError, subprocess.CalledProcessError, OSError, ValueError, KeyError, KeyboardInterrupt) as error:
            raise ReleaseError(
                f"Refs were pushed: {branch} and {tag} at {commit}, but publication could not be confirmed.\n"
                f"{error}\n"
                f"Re-run ALL jobs of the failed release workflow, or manually run release.yml with tag={tag} "
                "and publish=true. Use the SAME tag; do not bump the version again."
            ) from error
        print(release_url)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", metavar="VERSION", help="New app version: X.Y or X.Y.Z")
    parser.add_argument("--remote", default="origin", help="GitHub remote to release (default: origin)")
    parser.add_argument("--dry-run", action="store_true", help="Show the proposed remote-branch diff without writing refs")
    args = parser.parse_args()
    try:
        cut_release(args)
    except (ReleaseError, OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"Release failed: {error}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("Release interrupted.", file=sys.stderr)
        sys.exit(130)


if __name__ == "__main__":
    main()
