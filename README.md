# Hot Mic — by Kinekt

<img src="Dictation/Assets.xcassets/AppIcon.appiconset/HotMic_128@2x.png" width="96" alt="Hot Mic icon">

**For the record.**

Hot Mic is a native macOS dictation app that streams microphone audio to the ElevenLabs Scribe v2 Realtime API and copies finalized text to the clipboard. It is a regular Dock and Cmd-Tab app with a menu-bar control and a floating recording bar.

> Releases include source and a universal macOS DMG. The app is **ad-hoc signed, not Developer ID signed or notarized**; Gatekeeper may block downloaded copies. Ad-hoc signing does not establish a verified developer identity.

## Features

- Configurable global, single-press shortcut; the initial suggested shortcut is Control–Option–Space when available.
- Native SwiftUI/AppKit settings and a non-focus-stealing recording bar.
- Direct realtime transcription with live provisional text and finalized copied results.
- Compact Pause & copy, Resume, manual copy, Reset, and Copy & close controls.
- Optional OpenAI text cleanup with saved-session updates and one-level Undo.
- English, Dutch, or automatic language selection plus optional vocabulary hints.
- Provider API keys stored only in separate macOS Keychain items; no plaintext fallback.
- Local transcript archive with configurable automatic retention (14 days by default).
- No app-created audio files, backend, analytics, or automatic paste.

## Requirements

- macOS 14 or later.
- Full Xcode 26 or later (Swift 6.2) for building from source; the pinned `KeyboardShortcuts` dependency requires Swift 6.2.
- An ElevenLabs account, API key with speech-to-text access, and available credit for dictation.
- A microphone and macOS microphone permission.
- Optional: an OpenAI API key with Responses API / GPT-5.6 Terra access and credit for text cleanup. Recording does not require this key.

The Xcode target and scheme are named `Dictation`; the product is **Hot Mic.app**. Release packaging builds universal `arm64` and `x86_64` binaries.

## Build and run

Open `Dictation.xcodeproj` in Xcode, or build from the repository root:
```sh
git clone https://github.com/dick-kinekt/hot-mic.git
cd hot-mic
```


```sh
xcodebuild -project Dictation.xcodeproj -scheme Dictation \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build build
open '.build/Build/Products/Debug/Hot Mic.app'
```

Hot Mic opens its settings window at launch. Closing that window does not quit the app, disable the shortcut, stop an active recording, or clear the current result. Reopen it from the Dock, the menu-bar **Settings…** item, or Command–Comma. Quitting stops capture and discards uncopied in-memory text.

## Set up dictation

1. In ElevenLabs, create an API key with speech-to-text access and ensure the account has credit. See [ElevenLabs API authentication](https://elevenlabs.io/docs/api-reference/authentication).
2. In **General → Connection**, enter the key in the secure field and select **Save Key**. The key is stored in macOS Keychain under service `local.Dictation.elevenlabs` and account `api-key`; replacing or removing it updates that item. The draft field is cleared after saving or leaving settings.
3. Allow microphone access when prompted. If access was denied, enable **Hot Mic** in **System Settings → Privacy & Security → Microphone**.
4. In **Privacy**, read the provider guidance and acknowledge it. In **Speech**, choose Automatic, English, or Dutch, and optionally add vocabulary hints (one per line; at most 50, each 20 characters or fewer).
5. Set a recording shortcut in **General**. A cleared shortcut remains disabled across relaunches.

Never put an API key in source, a shell command, a `.env` file, an issue, or a chat message.

## Recording controls

The shortcut is **single press**, not hold-to-talk:

1. Press it once to start a new dictation and show the floating bar. Press it again to stop capture immediately, finish transcription, copy the final text, briefly show **Copied**, and close. Repeated presses while closing are ignored.
2. Select **Pause & copy** to turn the microphone off and finalize the current stream. On success, Hot Mic copies the complete accumulated dictation and keeps the bar open. The blue overlapping-documents button beside it copies the text again; the **Copied** status confirms success.
3. Select **Resume** to add another recording segment to the same dictation. The next Pause & copy copies all accumulated text, not only the new segment. An empty, zero-duration session offers **Start** instead.
4. Select **Reset** (the orange arrow button) to discard current text, stop pending work, clear the timer, and leave the bar ready for a new recording. **Cancel dictation** in the menu explicitly discards and dismisses. Neither action copies text; archived stable text is retained.
5. Select **×** or **Copy & close** to finish and copy before dismissing. Even an already-copied stopped session is copied again, in case another app replaced the clipboard. The roughly 600 ms confirmation starts only after a successful clipboard write. If finalization or copying fails, the bar and recoverable text stay available. Closing the separate Settings window does not stop recording.

The preview follows live provisional text and can be expanded to review the current dictation. Finalized text—not a provisional hypothesis—is copied. The recording bar does not activate Hot Mic or take focus from the destination app. Hot Mic does not paste text, send Return, or restore focus after copying.
Expanded review follows new text only while you are at the bottom. Scroll up to
read without being pulled back down; **Latest** resumes following. Collapse
returns to the latest two lines. Language, vocabulary and privacy choices persist
between launches; **Session** shows only the current dictation, not saved history.

### Optional text cleanup

In **General → OpenAI text cleanup**, enter an OpenAI API key and select **Save Key**.
It is stored separately in macOS Keychain under service `local.Dictation.openai`
and account `api-key`. The field never reveals the stored key and clears after
saving or closing settings. Removing this key does not affect recording or Undo.

After Pause & copy, select **Clean up text** beside Expand. Its purple icon and
high-contrast label indicate availability; it is muted while unavailable.
Each explicit click sends only the current stopped transcript to OpenAI's
Responses API using `gpt-5.6-terra`, with reasoning disabled and `store: false`.
It does not send audio, past sessions, or a conversation history. Internet access
and OpenAI usage credit are required; there is no local fallback or automatic retry.

The model is instructed to remove clear fillers, stutters, and false starts and
repair grammar and punctuation without summarizing, translating, inventing facts,
or changing meaning. English, Dutch, mixed language, names, numbers, negations,
uncertainty, code, URLs, and literal quotations should be preserved. These are
instructions, not a guarantee: review the result and use Undo when necessary.

A changed result updates the **same saved session** in Transcripts and is copied
to the clipboard. **Undo cleanup** restores and copies the original text without
a network request; it is available only in memory until Resume, Reset, Clear, or
Close. Resume retains an applied cleaned prefix and appends new raw dictation
without automatically cleaning it. Closing or manually copying during cleanup
cancels the pending request and uses the currently visible authoritative text.
Late successes or errors cannot overwrite a newer session.

An identical result is recopied without updating the archive's retention timestamp.
An empty, refused, incomplete, malformed, or failed response leaves the original,
archive, and clipboard unchanged. Authentication, quota, network, and timeout
errors allow a manual retry. Clipboard failure after a successful cleanup retains
the cleaned text and Undo; archive-save failures are reported.

Cleanup accepts at most **96,000 UTF-8 bytes** per request, with a **32,768-token**
output cap, a 45-second request timeout and a 60-second resource timeout. Oversized
input is rejected without sending it; text is never silently truncated or split.
This cleanup limit is separate from the 24-hour recording limit.

## Transcript archive and recording duration

**Transcripts** lists saved sessions with their text, date, recording duration and
language. Pause & copy/Resume updates one session; Reset, explicit cancellation and
Clear result clear the live text but keep already archived stable text. Provider
commits are checkpointed during recording; finalization updates the saved result.
Interrupted sessions are marked incomplete. Provisional live guesses are not saved.
Earlier dictations from versions without the archive cannot be recovered.

The app permits **24 hours of continuous recording** before automatically stopping,
finalizing and copying. Resume starts another stretch in the same session.
Provider restrictions, connection failures and sleep can still interrupt capture;
this is not a guarantee of an uninterrupted 24-hour provider connection.

Set **Keep transcripts for … days** in Transcripts and press **Apply**. The default
is 14 days, configurable from 1 to 3,650 days, measured from the session's last
update. Reducing retention requires confirmation and deletes newly expired entries.
Expiry runs every minute while Hot Mic is open, on launch, and on wake/activation.
If the app is closed, expired records are removed when it next starts.
Increasing retention does not recover deleted transcripts.

Archive data lives in `~/Library/Application Support/Hot Mic/transcripts.sqlite3`.
It uses private filesystem permissions, not application-level encryption; protect
the Mac/account accordingly. Deletion does not remove external backups or clipboard
copies. Provider zero retention is separate from this local retention policy.


## Privacy, provider data, and charges

Microphone capture runs only while recording. Audio is sent directly to ElevenLabs;
already-buffered audio can finish sending after capture stops, during finalization.
Hot Mic has no backend and does not create audio files. Stable transcript text and
session metadata are stored locally for the configured retention period. Diagnostic
logs do not contain API keys, authorization headers, raw audio, payloads or transcripts.

Dictation uses the account holder's ElevenLabs API access and can incur ElevenLabs charges, including additional cost for keyterm prompting. Review the provider's terms, pricing, and data practices before use.

Before real use, turn off **Terms and privacy → Data use → Improve the models for everyone** in your ElevenLabs account. That training opt-out applies to future submissions; it is **not** zero retention, and Hot Mic cannot verify or change the account setting.

The **Request zero retention** setting sends `enable_logging=false`. It is intended for eligible enterprise accounts. If ElevenLabs rejects the request, dictation fails rather than silently falling back to ordinary retention. When the setting is off, ordinary provider retention applies. Provider eligibility and account configuration are outside Hot Mic's control.

Optional **Clean up text** sends the current stopped transcript directly to OpenAI
and incurs separate OpenAI API charges. No automatic cleanup occurs during recording
or on Pause & copy. Requests use `store: false`, no tools, no conversation state,
and no disk HTTP cache. Redirects are rejected instead of forwarding text or keys.
OpenAI does not use API data for training by default, but abuse-monitoring logs may
normally be retained for up to 30 days (with exceptions in its policy).
`store: false` and the ElevenLabs retention setting do **not** guarantee OpenAI
zero retention. Account eligibility and data controls remain provider-managed.

Copied text is placed on the system clipboard. Clipboard managers, sync services, and other apps may retain it.

Useful provider references:

- [Realtime speech-to-text API](https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime)
- [Realtime transcripts and commit strategies](https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/realtime/transcripts-and-commit-strategies.md)
- [Model-training opt-out](https://elevenlabs.io/docs/help-center/legal/is-my-data-used-to-improve-eleven-labs-ai-models.md)
- [Zero retention mode](https://elevenlabs.io/docs/eleven-api/resources/zero-retention-mode.md)
- [OpenAI Responses API](https://developers.openai.com/api/reference/resources/responses/methods/create)
- [GPT-5.6 Terra model and pricing](https://developers.openai.com/api/docs/models/gpt-5.6-terra)
- [OpenAI API data controls](https://developers.openai.com/api/docs/guides/your-data)

## Troubleshooting
### Xcode command-line tools are selected instead of Xcode

For build/check commands, set
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` in that command's
environment (adjust if Xcode is installed elsewhere). This selects full Xcode
without changing your global developer-tool settings.

### macOS asks for Keychain access again

Local builds use ad-hoc signing. Rebuilding or changing the installation location
can require renewed Keychain or microphone authorization. Approve prompts only
in macOS; never share your key or login password in an issue.


### Microphone access is unavailable

Use **General → Microphone → Allow Microphone**. If macOS previously denied the request, enable Hot Mic in **System Settings → Privacy & Security → Microphone**, then return to the app and try again.

### A shortcut does not work

Choose a different shortcut in **General**. Hot Mic checks known system and application-menu conflicts for the default suggestion, but macOS or another app may still reserve a shortcut. A cleared shortcut disables global recording until you choose one again.

### The app cannot begin dictation

Confirm all of the following: privacy guidance is acknowledged, vocabulary hints meet their limits, a Keychain API key is saved, microphone access is allowed, and the ElevenLabs account can use speech-to-text. Authentication, quota, rate-limit, policy, network, and provider errors are shown in the app.

### Copying failed

Keep the recording bar open and use its **Copy** action, or open **Session** in settings to select and copy the current text manually. Do not assume the clipboard changed after a failed copy.

## Known limitations

Hot Mic is deliberately a copy-only dictation workflow. It currently has no:

- Automatic paste, Return-key synthesis, or focus restoration.
- Raycast integration or Raycast history.
- Launch-at-login support.

Physical global-shortcut presses and every sleep, input-device, and provider-account condition depend on the local macOS and ElevenLabs environment.

## Releases

[GitHub Releases](https://github.com/dick-kinekt/hot-mic/releases) contain
versioned source archives, universal macOS DMGs, and SHA-256 checksums.
The app is ad-hoc signed and not notarized; Gatekeeper may block downloaded copies.

See [RELEASING.md](RELEASING.md) for release commands, download verification,
workflow recovery, and local DMG packaging.

## Focused checks

The retained checks use synthetic audio, a local loopback fixture, an intercepted URLSession, fakes, or a private test pasteboard. They do not call ElevenLabs or OpenAI, use real API keys, or open the microphone. Run the smallest relevant check for a change.

The realtime transport regression requires Xcode and Bun:

```sh
python3 scripts/verify_realtime.py
```

The audio-capture smoke check:

```sh
mkdir -p .build/verification
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  Dictation/AudioCapture.swift Tests/AudioCaptureSmoke.swift \
  -o .build/verification/audio-capture-smoke
.build/verification/audio-capture-smoke
```

The recording-workflow smoke check:

```sh
mkdir -p .build/verification
ARCH="$(uname -m)"
xcrun swiftc -target "$ARCH-apple-macosx14.0" -swift-version 6 \
  -warnings-as-errors -strict-concurrency=complete -parse-as-library \
  -framework AppKit -framework AVFoundation -framework Security \
  Dictation/AudioCapture.swift Dictation/CredentialStore.swift \
  Dictation/DictationSettings.swift Dictation/RealtimeClient.swift \
  Dictation/OpenAITextCleaner.swift \
  Dictation/TranscriptArchive.swift Dictation/TranscriptionCoordinator.swift Tests/RecordingWorkflowSmoke.swift \
  -o .build/verification/recording-workflow-smoke
.build/verification/recording-workflow-smoke
```

OpenAI cleanup request, failure, refusal, partial-output, redirect and cancellation boundaries:

```sh
xcrun swiftc -swift-version 6 -warnings-as-errors -strict-concurrency=complete \
  -parse-as-library Dictation/OpenAITextCleaner.swift Tests/OpenAITextCleanerSmoke.swift \
  -o .build/verification/openai-cleaner-smoke
.build/verification/openai-cleaner-smoke
```

Archive persistence, retention boundaries, policy updates and corruption checks:

```sh
mkdir -p .build/verification
xcrun swiftc -swift-version 6 -warnings-as-errors -strict-concurrency=complete \
  -parse-as-library Dictation/RealtimeClient.swift Dictation/DictationSettings.swift \
  Dictation/TranscriptArchive.swift Tests/TranscriptArchiveSmoke.swift \
  -o .build/verification/transcript-archive-smoke
.build/verification/transcript-archive-smoke
```

The shortcut smoke check requires a Debug build first so the pinned KeyboardShortcuts product is available:

```sh
mkdir -p .build/verification
ARCH="$(uname -m)"
xcrun swiftc -target "$ARCH-apple-macosx14.0" -swift-version 6 \
  -warnings-as-errors -strict-concurrency=complete -parse-as-library \
  -I .build/Build/Products/Debug \
  Dictation/RecordingShortcutController.swift Tests/RecordingShortcutSmoke.swift \
  .build/Build/Products/Debug/KeyboardShortcuts.o \
  -o .build/verification/recording-shortcut-smoke
PACKAGE_RESOURCE_BUNDLE_PATH="$PWD/.build/Build/Products/Debug" \
  .build/verification/recording-shortcut-smoke
```

## Repository map

- `Dictation/` — application source and app icon catalog: capture, realtime client, Keychain storage, shortcut, settings, and recording UI.
- `Dictation.xcodeproj/` — Xcode project and Swift Package resolution.
- `Resources/` — app metadata, entitlements, and DMG artwork.
- `Tests/` — focused smoke programs and the local realtime fixture.
- `scripts/` — source-release and DMG packaging plus focused verification helpers.
- `.github/workflows/release.yml` — source and DMG validation, tagged releases, and manual publication.
- `pixi.toml` / `pixi.lock` — locked release tooling and the one-command release task.
- [`RELEASING.md`](RELEASING.md) — release procedures, artifact verification, and DMG packaging.
- [`CHANGELOG.md`](CHANGELOG.md) — public version history.
- [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) — third-party software notices.

## Contributing and license

See [CONTRIBUTING.md](CONTRIBUTING.md) for development and contribution guidance and [SECURITY.md](SECURITY.md) for vulnerability reporting.

Hot Mic is licensed under the [MIT License](LICENSE). Third-party software is identified in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).