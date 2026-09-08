#!/usr/bin/env python3
"""Exercise release cuts against disposable Git remotes without GitHub access."""

import datetime
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


RELEASE_SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "cut_release.py"
REMOTE_URL = "https://github.com/release-tests/hot-mic.git"
NOTES = "- Preserve remote release notes.\n- Ship the new recorder."
CHANGELOG = f"# Changelog\n\n## Unreleased\n\n{NOTES}\n\n## 1.2 — Previous release\n\n- Older notes.\n"
FAKE_GH = r'''#!/usr/bin/env python3
import json
import os
import subprocess
import sys

args = sys.argv[1:]
if args[:2] == ["repo", "view"]:
    result = {
        "nameWithOwner": "release-tests/hot-mic",
        "defaultBranchRef": {"name": "trunk"},
        "viewerPermission": "WRITE",
    }
elif args[:1] == ["api"]:
    result = {"id": 101, "name": "Release", "path": ".github/workflows/release.yml", "state": "active"}
elif args[:2] == ["run", "list"]:
    tag = args[args.index("--branch") + 1]
    sha = subprocess.check_output(
        ["git", "--git-dir", os.environ["TEST_REMOTE"], "rev-parse", f"refs/tags/{tag}^{{commit}}"],
        text=True,
    ).strip()
    result = [{"databaseId": 202, "status": "completed", "headSha": sha}]
elif args[:2] == ["run", "watch"]:
    if os.environ.get("TEST_WATCH_FAIL"):
        print("The release workflow failed.", file=sys.stderr)
        sys.exit(1)
    sys.exit(0)
elif args[:2] == ["release", "view"]:
    result = {"url": f"https://github.com/release-tests/hot-mic/releases/tag/{args[2]}"}
else:
    sys.exit(f"Unsupported fake GitHub service request: {args!r}")
print(json.dumps(result))
'''


class ReleaseCutSmoke(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="hot-mic-release-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.remote = self.root / "remote.git"
        self.seed = self.root / "seed"
        self.checkout = self.root / "checkout"
        tools = self.root / "bin"
        tools.mkdir()
        (tools / "python3").symlink_to(sys.executable)
        fake_gh = tools / "gh"
        fake_gh.write_text(FAKE_GH)
        fake_gh.chmod(0o755)
        git = shutil.which("git")
        if git is None:
            self.fail("These smoke tests require git")
        home = self.root / "home"
        home.mkdir()
        temporary_files = self.root / "tmp"
        temporary_files.mkdir()
        self.env = {
            "PATH": os.pathsep.join([str(tools), str(Path(git).parent), os.defpath]),
            "HOME": str(home),
            "XDG_CONFIG_HOME": str(home / "config"),
            "TMPDIR": str(temporary_files),
            "GIT_CONFIG_GLOBAL": str(self.root / "gitconfig"),
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_ALLOW_PROTOCOL": "file",
            "GH_CONFIG_DIR": str(home / "gh"),
            "GH_PROMPT_DISABLED": "1",
            "TEST_REMOTE": str(self.remote),
            "LC_ALL": "C",
        }
        self.git(self.root, "config", "--global", "user.name", "Release Test Author")
        self.git(self.root, "config", "--global", "user.email", "release-test@example.invalid")
        self.git(self.root, "config", "--global", f"url.{self.remote}.insteadOf", REMOTE_URL)
        self.git(self.root, "init", "--bare", "--initial-branch=trunk", str(self.remote))
        self.git(self.root, "init", "--initial-branch=trunk", str(self.seed))
        (self.seed / "Resources").mkdir()
        (self.seed / "Resources" / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleShortVersionString": "1.2",
            "CFBundleVersion": "7",
            "CFBundleName": "Hot Mic",
        }))
        (self.seed / "CHANGELOG.md").write_text(CHANGELOG)
        (self.seed / ".github" / "workflows").mkdir(parents=True)
        (self.seed / ".github" / "workflows" / "release.yml").write_text(
            "name: Release\non:\n  push:\n    tags: ['v*']\njobs: {}\n"
        )
        (self.seed / "scripts").mkdir()
        shutil.copyfile(RELEASE_SCRIPT, self.seed / "scripts" / "cut_release.py")
        self.git(self.seed, "add", ".")
        self.git(self.seed, "commit", "-m", "Seed remote release source")
        self.git(self.seed, "remote", "add", "origin", REMOTE_URL)
        self.git(self.seed, "push", "origin", "trunk")
        self.git(self.root, "clone", REMOTE_URL, str(self.checkout))
        (self.checkout / "local-only.txt").write_text("Never release this local commit.\n")
        self.git(self.checkout, "add", "local-only.txt")
        self.git(self.checkout, "commit", "-m", "Local work must not ship")
        (self.checkout / "CHANGELOG.md").write_text("Uncommitted local notes must stay here.\n")
        self.git(self.checkout, "add", "CHANGELOG.md")
        (self.checkout / "Resources" / "Info.plist").write_text("Unstaged local edit\n")
        (self.checkout / "untracked.txt").write_text("Untracked work must survive.\n")

    def git(self, cwd, *args):
        return subprocess.run(
            ["git", *args], cwd=cwd, env=self.env, check=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        ).stdout

    def remote_refs(self):
        return self.git(self.root, "--git-dir", str(self.remote), "show-ref")

    def remote_head(self):
        return self.git(self.root, "--git-dir", str(self.remote), "rev-parse", "trunk").decode().strip()

    def remote_file(self, path):
        return self.git(self.root, "--git-dir", str(self.remote), "show", f"trunk:{path}")

    def checkout_snapshot(self):
        files = {
            str(path.relative_to(self.checkout)): path.read_bytes()
            for path in self.checkout.rglob("*")
            if ".git" not in path.relative_to(self.checkout).parts and path.is_file()
        }
        return (
            files,
            self.git(self.checkout, "show-ref"),
            self.git(self.checkout, "status", "--porcelain=v1", "--untracked-files=all"),
            (self.checkout / ".git" / "index").read_bytes(),
        )

    def release(self, version="1.3", *options, watch_fail=False):
        snapshot = self.checkout_snapshot()
        result = subprocess.run(
            [sys.executable, str(self.checkout / "scripts" / "cut_release.py"), version, *options],
            cwd=self.checkout,
            env={**self.env, **({"TEST_WATCH_FAIL": "1"} if watch_fail else {})},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=30,
        )
        self.assertEqual(self.checkout_snapshot(), snapshot, "Release modified the invoking checkout")
        return result

    def assert_failed_without_push(self, version="1.3", *options):
        before = self.remote_refs()
        result = self.release(version, *options)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.remote_refs(), before, result.stdout + result.stderr)
        return result

    def test_release_uses_remote_default_branch_and_preserves_local_work(self):
        (self.seed / "remote-only.txt").write_text("The remote advanced after the invoking clone.\n")
        self.git(self.seed, "add", "remote-only.txt")
        self.git(self.seed, "commit", "-m", "Advance remote independently")
        self.git(self.seed, "push", "origin", "trunk")
        previous = self.remote_head()
        before_date = datetime.date.today().isoformat()
        result = self.release()
        after_date = datetime.date.today().isoformat()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        head = self.remote_head()
        self.assertNotEqual(head, previous)
        self.assertEqual(
            self.git(self.root, "--git-dir", str(self.remote), "rev-parse", "trunk^").decode().strip(),
            previous,
        )
        self.assertEqual(
            self.git(self.root, "--git-dir", str(self.remote), "cat-file", "-t", "v1.3"), b"tag\n",
        )
        self.assertEqual(
            self.git(self.root, "--git-dir", str(self.remote), "rev-parse", "v1.3^{commit}").decode().strip(),
            head,
        )
        changed = self.git(
            self.root, "--git-dir", str(self.remote), "diff-tree", "--no-commit-id", "--name-only", "-r", head,
        ).decode().splitlines()
        self.assertEqual(set(changed), {"Resources/Info.plist", "CHANGELOG.md"})
        info = plistlib.loads(self.remote_file("Resources/Info.plist"))
        self.assertEqual(info, {
            "CFBundleShortVersionString": "1.3", "CFBundleVersion": "8", "CFBundleName": "Hot Mic",
        })
        changelog = self.remote_file("CHANGELOG.md").decode()
        headings = changelog.split("\n## ")
        self.assertEqual(len(headings), 4)
        self.assertEqual(headings[1].strip(), "Unreleased")
        release_heading, release_notes = headings[2].split("\n", 1)
        self.assertRegex(release_heading, r"^1\.3\b")
        self.assertTrue(any(date in release_heading for date in {before_date, after_date}), release_heading)
        self.assertEqual(release_notes.strip(), NOTES)
        self.assertEqual(headings[3], CHANGELOG.split("\n## ")[2])
        self.assertEqual(
            self.git(self.root, "--git-dir", str(self.remote), "show", "-s", "--format=%an <%ae>", head),
            b"Release Test Author <release-test@example.invalid>\n",
        )
        tree = self.git(self.root, "--git-dir", str(self.remote), "ls-tree", "-r", "--name-only", head).decode().splitlines()
        self.assertIn("remote-only.txt", tree)
        self.assertNotIn("local-only.txt", tree)
        self.assertIn("https://github.com/release-tests/hot-mic/releases/tag/v1.3", result.stdout)

    def test_dry_run_shows_plan_without_writing_remote(self):
        before = self.remote_refs()
        result = self.release("1.3", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.remote_refs(), before)
        self.assertIn("Resources/Info.plist", result.stdout)
        self.assertIn("CHANGELOG.md", result.stdout)
        self.assertIn("trunk", result.stdout)
        self.assertIn("v1.3", result.stdout)

    def test_invalid_or_non_increasing_versions_do_not_push(self):
        for version in ("01.3", "1.3.0.0", "v1.3", "1.2.0", "1.1.9"):
            with self.subTest(version=version):
                self.assert_failed_without_push(version)

    def test_empty_unreleased_notes_do_not_push(self):
        (self.seed / "CHANGELOG.md").write_text(
            "# Changelog\n\n## Unreleased\n\n## 1.2 — Previous release\n\n- Older notes.\n"
        )
        self.git(self.seed, "add", "CHANGELOG.md")
        self.git(self.seed, "commit", "-m", "Clear unreleased notes")
        self.git(self.seed, "push", "origin", "trunk")
        self.assert_failed_without_push()

    def test_configured_git_hook_can_reject_the_release_commit(self):
        hooks = self.root / "local-hooks"
        hooks.mkdir()
        hook = hooks / "pre-commit"
        hook.write_text('#!/bin/sh\necho "Release commit rejected by policy" >&2\nexit 1\n')
        hook.chmod(0o755)
        self.git(self.root, "config", "--global", "core.hooksPath", str(hooks))
        self.assert_failed_without_push()

    def test_atomic_rejection_leaves_branch_and_tag_unchanged(self):
        hook = self.remote / "hooks" / "update"
        hook.write_text('#!/bin/sh\nif [ "$1" = refs/heads/trunk ]; then\n  echo "Branch is protected" >&2\n  exit 1\nfi\n')
        hook.chmod(0o755)
        self.assert_failed_without_push()

    def test_workflow_failure_reports_pushed_refs_without_claiming_release(self):
        previous = self.remote_head()
        result = self.release(watch_fail=True)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotEqual(self.remote_head(), previous)
        self.assertEqual(
            self.git(self.root, "--git-dir", str(self.remote), "rev-parse", "v1.3^{commit}").decode().strip(),
            self.remote_head(),
        )
        output = result.stdout + result.stderr
        self.assertIn("pushed", output.lower())
        self.assertIn("v1.3", output)
        self.assertRegex(output.lower(), r"all jobs|workflow_dispatch|manual")
        self.assertNotIn("https://github.com/release-tests/hot-mic/releases/tag/v1.3", output)


if __name__ == "__main__":
    unittest.main()
