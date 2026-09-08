# Releasing Hot Mic

Hot Mic releases contain a versioned source archive, a universal macOS DMG, and
SHA-256 checksums. The app is **ad-hoc signed, not Developer ID signed or notarized**.
Gatekeeper may block downloaded copies, and an ad-hoc signature does not establish
a verified developer identity. Keep that limitation in the DMG filename and
release notes.

## Cutting a release

Install [Pixi](https://pixi.sh) and authenticate Git and the GitHub CLI for the
release repository. `pixi.toml` and `pixi.lock` supply Python, Git, `gh`, and
`actionlint` on Apple Silicon and Intel macOS. The lockfile gives maintainers a
shared toolchain, and named tasks provide a common entry point for release work.
You do not need local Xcode to cut a release; the GitHub runner builds the app.

Merge the intended changes and nonempty `CHANGELOG.md` **Unreleased** notes to
the remote's default branch first. The release workflow and scripts must also be
merged and Actions enabled. Choose a version greater than the current app
version, in `X.Y` or `X.Y.Z` form without leading zeroes:

```sh
# Preview the release metadata diff without committing, tagging, or pushing.
pixi run release 1.0.1 --dry-run

# Commit the metadata, push the release, and wait for its GitHub Release.
pixi run release 1.0.1
```

The command uses `origin` by default; pass `--remote fork` only if you intend to
release that fork. It clones the remote default branch into temporary storage,
sets `CFBundleShortVersionString`, increments `CFBundleVersion`, and moves the
Unreleased notes into a dated version section while leaving an empty Unreleased
section for future changes. It then commits, creates an annotated tag, and
pushes both refs atomically without force. A rejected branch update cannot leave
an orphan release tag.

Your current branch/bookmarks, working files, and local changes are untouched,
including in a Jujutsu workspace. Git author settings come from the invoking
checkout (with Jujutsu settings as a fallback). Actual publication requires push
permission and obeys branch protection; this command does not bypass review rules.
It waits for the tag's exact commit to finish the release workflow and prints
the release URL on success.

Release tooling checks are local and use disposable Git repositories:

```sh
pixi run check-release
pixi run lint-release
```

## Release workflow

The [Release workflow](.github/workflows/release.yml) builds source and a universal
DMG for pull requests, pushes to `main`, and manual runs. These runs do not publish
unless explicitly requested. Pushing a `vX.Y` or `vX.Y.Z` tag automatically
publishes a [GitHub Release](https://github.com/dick-kinekt/hot-mic/releases).
The tag must exactly match the committed `CFBundleShortVersionString` in
`Resources/Info.plist`; prerelease suffixes are not supported.

CI extracts the source archive and builds a universal Release app using Xcode
26.3, requires the pinned Swift package resolution, checks both architectures,
the ad-hoc signature, and bundled licenses, then packages and verifies the DMG.
All checks must pass before publication. Dry runs retain the same files in the
`release-assets` workflow artifact for 14 days.

Non-manual runs build the triggering commit rather than a moving branch ref.
Before publication, CI checks that the remote tag still points to the built
commit.

The local release command uses your authenticated Git and `gh` access to push
and watch the release. CI publication uses the built-in `GITHUB_TOKEN` with
`contents: write` only in the publish job; no extra personal access token,
Developer ID certificate, or notary credentials are required in repository
secrets. Workflow actions are pinned to commit SHAs.

### Manual workflow runs

Open **Actions → Release → Run workflow**. Leave `tag` empty and `publish`
unchecked to validate the selected branch or tag. To build a specific existing
release tag, enter it in `tag`; check `publish` to create its GitHub Release.
The workflow checks out that exact tag, not the branch selected in the UI.
Manual publication requires `tag` and never creates or moves tags. The tag must
include the release scripts and point to the intended version. The workflow must
be present on the default branch for the manual button to appear.

Equivalent CLI commands:

```sh
# Build and package without publishing.
gh workflow run release.yml --ref main

# Publish an existing tag that does not already have a release.
gh workflow run release.yml --ref main -f tag=v1.0 -F publish=true
```

A tag push already triggers publication, so manual publication is useful when
a tag was created without triggering Actions or an earlier attempt failed. It
does not replace an existing release.

## Recovering a failed release

Treat published tags and assets as immutable: do not move tags or replace a
tarball that downstream recipes may already checksum. The workflow does not
overwrite existing releases. If a workflow fails after the refs were pushed,
do not cut the same version again or move its tag. Use **Re-run all jobs** on
that run, or manually dispatch the workflow for the same existing tag. If
publication left a draft, inspect and remove only that unpublished draft before
retrying. Ship corrections to a published release under a new version.

Use repository tag rules to prevent updates and deletion of `v*` tags. The
workflow rechecks the tag's commit before publication, but that cannot prevent a
concurrent tag mutation after the check.

## Release artifacts

Each release contains:

- `hot-mic-<version>.tar.gz`: committed source with one `hot-mic-<version>/`
  root directory, including licenses, artwork, build scripts, and `Package.resolved`.
- `Hot-Mic-<version>-macos-universal-adhoc.dmg`: an ad-hoc-signed app for
  Apple Silicon and Intel Macs running macOS 14 or later; **not notarized**.
- `SHA256SUMS`: SHA-256 digests for both the source archive and DMG.

Download all three assets into one directory and verify them:

```sh
shasum -a 256 -c SHA256SUMS
```

The checksum detects changed bytes; it is not a developer identity or notarization
ticket. If Gatekeeper blocks the app, [building from reviewed source](README.md#build-and-run)
is an alternative. Do not disable macOS security protections to run an untrusted
copy. See [SECURITY.md](SECURITY.md) for download safety guidance.

To install a trusted DMG, open it, drag **Hot Mic** onto **Applications**, eject
the image, and open the app from Applications. Quit any development copy before
opening the installed one. Each user supplies their own ElevenLabs key.

## Building a source archive locally

To prepare only the source assets, use Python 3.10 or later and Git from the
repository root:

```sh
python3 scripts/build_source_release.py
(cd dist && shasum -a 256 -c SHA256SUMS)
```

This archives Git `HEAD`, not uncommitted or untracked files. Passing
`--tag v1.0` additionally requires that tag to match the committed version and
point to `HEAD`. Repeated runs for the same commit with the same tools produce
the same archive bytes.

## Packaging a DMG locally

Packaging requires macOS, full Xcode 26 or later, Python 3.10 or later, and the
system tools used by `scripts/build_dmg.py`. From the repository root, create an
isolated virtual environment and install the package-only dependencies:

```sh
python3 -m venv --copies .build/dmg-tools
.build/dmg-tools/bin/python -m pip install -r scripts/dmg-requirements.txt
.build/dmg-tools/bin/python scripts/build_dmg.py
```

With no `--app` argument, the script builds a universal Release app and writes
`dist/Hot-Mic-<version>.dmg`. It uses standard operating-system temporary storage
by default. To choose the parent directory for temporary staging, pass `--work-dir`;
a relative path resolves from the repository root and a missing directory is
created:

```sh
.build/dmg-tools/bin/python scripts/build_dmg.py --work-dir /path/to/writable-temporary-parent
```

To package an existing app instead of building one, pass `--app`:

```sh
.build/dmg-tools/bin/python scripts/build_dmg.py --app '/path/to/Hot Mic.app'
```

The default package and automated release DMGs are ad-hoc signed and **not
notarized**. Do not represent them as notarized or frictionless public downloads.
For Developer ID distribution, provide your own signing identity and existing
notarytool Keychain profile:

```sh
.build/dmg-tools/bin/python scripts/build_dmg.py \
  --signing-identity 'Developer ID Application: Your Name (TEAMID)' \
  --notary-profile YOUR_NOTARY_PROFILE
```

`--notary-profile` requires `--signing-identity`. No signing identity, account
credential, or notary profile is included in this repository.

The original app icon and installer artwork can be regenerated with:

```sh
xcrun swift scripts/generate_brand_assets.swift
```

## Downstream packaging

A future conda-forge feedstock can use this source URL, substituting its version:

```text
https://github.com/dick-kinekt/hot-mic/releases/download/v<version>/hot-mic-<version>.tar.gz
```

Use the digest from that release's `SHA256SUMS` in the recipe's `sha256` field,
and include `LICENSE` and the applicable third-party licenses.
[conda-forge requires checksummed source archives](https://conda-forge.org/docs/maintainer/adding_pkgs/#build-from-tarballs-not-repos).
There is no conda-forge package or recipe in this repository yet. A future recipe
still needs to handle the Xcode/Swift 6.2 toolchain, macOS 14 deployment target,
pinned `KeyboardShortcuts` source (currently fetched by SwiftPM), and app-bundle
installation. This source release does not establish an offline conda build.
