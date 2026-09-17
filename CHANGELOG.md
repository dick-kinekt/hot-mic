# Changelog

## Unreleased

- Make the global recording shortcut finish, copy, briefly confirm success, and close; retain a separate explicit Cancel action.
- Recopy stopped sessions on Close, keep failed copies visible, and prevent duplicate or stale close operations.
- Add optional OpenAI text cleanup using GPT-5.6 Terra, a separate Keychain credential, and explicit cloud/privacy disclosure; replace the local filler filter while preserving same-session archive updates, clipboard, transient Undo and cancellation-safe completion.
- Use smaller Pause & copy / Resume controls and show cleanup beside Expand without changing the panel dimensions.
- Make available cleanup more legible with a purple icon; add a blue manual copy control with a persistent overlapping-documents icon, orange Reset and red Close hover.
- Bound compact-preview layout to the latest text so very long sessions do not stall the controls; expanded review and copied/saved text remain complete.

## 0.2.0 — 2026-09-09

- Raise the continuous recording ceiling from five minutes to 24 hours, retaining pause/finalize/copy behavior.
- Add a local Transcripts archive with one entry per session, durable stable-text checkpoints, and full-text review/copy.
- Add configurable automatic transcript deletion, defaulting to 14 days from the last session update, checked on launch, wake/activation and every minute while running.
- Preserve archived stable text across Reset/cancellation; mark interrupted checkpoints incomplete and keep provisional guesses out of history.
- Document local archive privacy separately from ElevenLabs retention and add archive/duration regressions.

## 0.1.0 — 2026-09-09

- Tagged and manually triggered releases with version-checked source archives, universal ad-hoc-signed DMGs, and SHA-256 checksums for both assets.
- GitHub Actions builds the app from the source archive and verifies the DMG before publication; pull requests and manual dry runs retain downloadable build artifacts without publishing.
- Clarified the Swift 6.2 / Xcode 26 build requirement imposed by the pinned `KeyboardShortcuts` dependency.
- Locked Pixi release tooling and a one-command release cut that bumps metadata and changelog, atomically pushes the release commit and tag, and waits for publication.
- Pinned workflow checkouts to the triggering commit and rechecked the remote tag before publishing its artifacts.

## 0.0.0 — Initial public source version

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
