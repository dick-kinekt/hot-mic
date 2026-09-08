# Contributing to Hot Mic

Thanks for improving Hot Mic. Keep changes small, reviewable, and focused on an observable user or developer outcome.

## Development setup

1. Install full Xcode 26 or later with Swift 6.2 on a supported macOS version. The built app supports macOS 14 or later.
2. Clone the repository and open `Dictation.xcodeproj` in Xcode, or use the documented build command in [README.md](README.md).
3. Let Xcode resolve the pinned `KeyboardShortcuts` package dependency.
4. Use your own ElevenLabs account only when you intentionally need a live manual check. Do not add credentials to the repository or test setup.

The project and scheme are `Dictation`; the app product is **Hot Mic.app**. Keep the bundle identifier `local.Dictation` and the established Keychain identity unless a deliberate migration is part of the change.

## Change guidelines

- Describe the problem and proposed behavior before broadening scope. Use an issue or discussion for changes that alter the dictation workflow, provider-data boundary, privacy behavior, signing/distribution, or supported macOS versions.
- Prefer a single purpose per pull request. Include the relevant user-visible behavior, limitations, and documentation changes in the same pull request.
- Preserve the copy-only model unless the proposal explicitly changes it: Hot Mic does not paste, send Return, or maintain durable transcript history.
- Reuse native SwiftUI/AppKit and project conventions. Do not add a backend, analytics, plaintext credential storage, or machine-specific tooling for a local convenience.
- Keep public text free of local paths, private discussion, personal data, and claims of unperformed verification.

## Validate meaningfully

Run the narrowest check that exercises the behavior you changed. The commands in [README.md](README.md#focused-checks) cover the realtime transport, audio capture, recording workflow, and shortcut persistence with local or synthetic inputs.

When a focused check cannot cover a UI change, manually exercise the changed surface in the built app and state exactly what you observed. Do not add a test merely to increase coverage: tests should protect a realistic behavior, boundary, state transition, or error path.

Do not run live-provider tests in automated checks. Automated tests must not:

- Read or create real API keys, Keychain items, accounts, or notary credentials.
- Open the physical microphone or send real audio to ElevenLabs.
- Depend on a user clipboard, a global shortcut press, a live account, or a network service other than the local fixture.

Never commit API keys, access tokens, signing identities, Keychain profiles, audio, transcripts, `.env` files, private crash reports, or derived build output.

## Pull requests

Include:

- A concise description of the behavior changed and why.
- Focused validation performed, including manual steps when appropriate.
- Documentation or user-facing copy updates when the contract changes.
- Any limitations, platform assumptions, or follow-up discussion needed.

Keep commits and pull requests easy to review. Maintainers may ask for a smaller scope, an issue or discussion first, or a reproducible local test case before accepting a change.

## Cutting a release

Follow [RELEASING.md](RELEASING.md) for the Pixi release command, prerequisites,
workflow checks, and recovery after a failed release.

## Security issues

Do not report vulnerabilities in a public pull request or issue. Follow [SECURITY.md](SECURITY.md) instead.