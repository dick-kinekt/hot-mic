# Changelog

## Unreleased

- Tagged and manually triggered releases with version-checked source archives, universal ad-hoc-signed DMGs, and SHA-256 checksums for both assets.
- GitHub Actions builds the app from the source archive and verifies the DMG before publication; pull requests and manual dry runs retain downloadable build artifacts without publishing.
- Clarified the Swift 6.2 / Xcode 26 build requirement imposed by the pinned `KeyboardShortcuts` dependency.
- Locked Pixi release tooling and a one-command release cut that bumps metadata and changelog, atomically pushes the release commit and tag, and waits for publication.
- Pinned workflow checkouts to the triggering commit and rechecked the remote tag before publishing its artifacts.

## 1.0 — Initial public source version

- Native Hot Mic app with Dock, menu-bar and reusable settings-window access.
- General, Speech, Privacy and Session settings; original icon and installer artwork.
- Single-press dictation with Pause/Continue, Reset, finish-and-copy Close and live transcript review.
- Direct ElevenLabs Scribe v2 Realtime streaming, Keychain credential storage, language selection and vocabulary hints.
- MIT license for original work and bundled third-party license notices.
- Public setup, contribution and security documentation; portable universal DMG packaging with pinned build-tool dependencies.

This version is copy-only and has no durable transcript history or automatic paste.
Source publication is not a notarized binary release. Default packages use
ad-hoc signing, which does not establish a verified developer identity.
Developer ID signing and Apple notarization remain a separate distribution option.
