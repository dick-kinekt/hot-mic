# Security Policy

## Supported version

The supported version is **1.0**, represented by the current repository source. There are no older supported releases. Security fixes are expected to land in current source and subsequent releases. Automated release apps use ad-hoc signatures; they are not Developer ID signed or notarized.

## Reporting a vulnerability

Use GitHub's **Private vulnerability reporting** for this repository when that option is enabled. Provide a minimal, reproducible report with the affected source version, impact, prerequisites, and safe reproduction steps.

If private vulnerability reporting is unavailable, open a minimal public issue requesting a private reporting channel. Do **not** disclose exploit details, credentials, audio, transcripts, personally identifiable information, API responses, or proof-of-concept payloads in that issue.

Please allow maintainers time to acknowledge, investigate, and coordinate a fix before public disclosure. Reports that demonstrate a credible impact and avoid unnecessary exposure are the most useful.

## Keep credentials and user data out of reports

Never include any of the following in an issue, discussion, pull request, commit, log, screenshot, or crash attachment:

- ElevenLabs API keys, account data, payment information, or API responses containing sensitive data.
- Apple signing certificates, notarization credentials, Keychain profiles, or passwords.
- Recorded audio, dictated text, clipboard contents, or another person's personal data.
- Local machine paths, environment files, or complete diagnostic bundles that may contain private data.

Use redacted placeholders and synthetic fixtures. If a report needs a request or transcript fragment to reproduce a problem, reduce it to non-sensitive synthetic data first.

## Provider-data boundary

Hot Mic captures microphone audio only while recording and sends it directly to
ElevenLabs. Buffered audio can continue sending during finalization after capture
stops. The app has no Hot Mic backend, does not create audio files or transcript
logs, and stores the API key in the macOS Keychain. ElevenLabs account terms,
charges, retention, training opt-out, and zero-retention eligibility are
provider-controlled boundaries; see the privacy section of
[README.md](README.md#privacy-provider-data-and-charges).

The app can request zero retention with `enable_logging=false`, but that request is only for eligible accounts and fails if rejected. It must not be interpreted as a general guarantee that provider retention, account behavior, or downstream clipboard handling is eliminated.

## Binary and download safety

The release workflow publishes source archives, universal macOS DMGs, and SHA-256 checksums. The app in each automated release DMG is **ad-hoc signed, not Developer ID signed or notarized**. This signature does not establish a verified developer identity, and Gatekeeper may block downloaded copies.

Obtain downloads only from this repository's GitHub Releases and verify both assets against the release's `SHA256SUMS`. A checksum detects changed bytes but is not a code-signing identity or notarization ticket. If a release is blocked or you cannot establish trust in a download, inspect and build the source instead. Treat unverifiable copies from third parties as untrusted. Do not disable macOS security protections to run an untrusted copy.

## Scope

Examples of in-scope reports include credential exposure, unintended microphone capture or transmission, unsafe handling of copied text, privilege escalation, malicious package execution, and security-relevant signing or distribution flaws. Provider outages, transcription quality, account billing disputes, and ordinary feature requests are generally not security vulnerabilities unless they demonstrate a security impact.