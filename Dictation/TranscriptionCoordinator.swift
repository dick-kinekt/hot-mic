import AppKit
import AVFoundation
import Combine

@MainActor
protocol TranscriptionAudioCapturing: AnyObject {
    var isCapturing: Bool { get }
    func start() throws
    func stop()
    func drain() throws -> [Data]
}

extension AudioCapture: TranscriptionAudioCapturing {}

@MainActor
protocol TranscriptionRealtimeSession: AnyObject {
    func connect(apiKey: String, configuration: RealtimeConfiguration)
    func enqueue(_ pcm: Data) throws
    func finish() async throws -> RealtimeResult
    func cancel()
}

extension RealtimeClient: TranscriptionRealtimeSession {}

/// Native boundaries used by the coordinator. Production supplies the concrete Keychain,
/// microphone, realtime, and pasteboard implementations; executable smoke tests inject fakes.
@MainActor
struct TranscriptionCoordinatorDependencies {
    let loadCredential: () throws -> String?
    let saveCredential: (String) throws -> Void
    let deleteCredential: () throws -> Void
    let microphoneAuthorized: () -> Bool
    let requestMicrophone: () async -> Bool
    let makeCapture: () -> any TranscriptionAudioCapturing
    let makeClient: (@escaping @MainActor (RealtimeEvent) -> Void) -> any TranscriptionRealtimeSession
    let copyToPasteboard: (String) -> Bool
    var now: () -> ContinuousClock.Instant = { .now }

    static func live() -> Self {
        let credentials = CredentialStore()
        return Self(
            loadCredential: { try credentials.load() },
            saveCredential: { try credentials.save($0) },
            deleteCredential: { try credentials.delete() },
            microphoneAuthorized: {
                AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            },
            requestMicrophone: {
                await AVCaptureDevice.requestAccess(for: .audio)
            },
            makeCapture: { AudioCapture() },
            makeClient: { onEvent in RealtimeClient(onEvent: onEvent) },
            copyToPasteboard: { text in
                NSPasteboard.general.clearContents()
                return NSPasteboard.general.setString(text, forType: .string)
            }
        )
    }
}

@MainActor
final class TranscriptionCoordinator: ObservableObject {
    enum State: String {
        case idle = "Idle"
        case starting = "Recording · connecting"
        case recording = "Recording"
        case finalizing = "Processing · microphone off"
        case paused = "Paused"
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var notice = "Set up your key and microphone, then use the shortcut to begin dictation."
    @Published private(set) var transcript = ""
    @Published private(set) var previewTranscript = ""
    @Published private(set) var hasKey = false
    @Published private(set) var microphoneAllowed = false
    @Published private(set) var recordingSeconds: Double = 0
    @Published private(set) var microphoneStartMS: Double?
    @Published private(set) var firstAudioMS: Double?
    @Published private(set) var connectionMS: Double?
    @Published private(set) var resultMS: Double?
    @Published private(set) var isError = false
    @Published private(set) var detectedLanguage: String?
    @Published private(set) var isPresented = false
    @Published private(set) var isClosing = false
    @Published private(set) var copySucceeded = false

    private let settings: DictationSettings
    private let dependencies: TranscriptionCoordinatorDependencies
    private let archive: TranscriptArchive?
    private var archiveID = UUID()
    private var archiveStartedAt = Date()
    private var archiveSaveFailed = false
    private var capture: (any TranscriptionAudioCapturing)?
    private var client: (any TranscriptionRealtimeSession)?
    private var streamID: UUID?
    private var poller: Timer?
    private var finishTask: Task<Void, Never>?
    private var segmentRequestedAt = ContinuousClock.now
    private var activeRecordingBeganAt: ContinuousClock.Instant?
    private var finalizationBeganAt: ContinuousClock.Instant?
    private var accumulatedRecordingSeconds: Double = 0
    private var committedCurrentSegment = ""
    private var provisionalCurrentSegment = ""
    private var completedSegments: [String] = []
    private var hasIncompleteText = false
    private var observers: [NSObjectProtocol] = []

    var active: Bool {
        switch state {
        case .starting, .recording, .finalizing: true
        case .idle, .paused: false
        }
    }

    var capturing: Bool { capture?.isCapturing == true }

    convenience init(settings: DictationSettings, archive: TranscriptArchive) {
        self.init(settings: settings, dependencies: .live(), archive: archive)
    }

    init(
        settings: DictationSettings,
        dependencies: TranscriptionCoordinatorDependencies,
        archive: TranscriptArchive? = nil
    ) {
        self.settings = settings
        self.dependencies = dependencies
        self.archive = archive
        refreshPermissions()
        do { hasKey = try dependencies.loadCredential() != nil }
        catch { notice = error.localizedDescription; isError = true }

        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.cancel(reason: "Recording paused because the Mac is sleeping or the session is inactive.")
                }
            })
        }
    }

    func refreshPermissions() {
        microphoneAllowed = dependencies.microphoneAuthorized()
    }

    func requestMicrophone() async {
        guard !active else { return }
        _ = await dependencies.requestMicrophone()
        refreshPermissions()
        notice = microphoneAllowed
            ? "Microphone allowed. Use the shortcut when you are ready to dictate."
            : "Allow Hot Mic in System Settings → Privacy & Security → Microphone, then try again."
        isError = !microphoneAllowed
    }

    func saveKey(_ key: String) -> Bool {
        guard !active else { return false }
        do {
            try dependencies.saveCredential(key)
            hasKey = true
            notice = "API key saved in Keychain. Use the shortcut to begin dictation."
            isError = false
            return true
        } catch {
            notice = error.localizedDescription
            isError = true
            return false
        }
    }

    func deleteKey() {
        guard !active else { return }
        do {
            try dependencies.deleteCredential()
            hasKey = false
            notice = "API key removed from Keychain."
            isError = false
        } catch {
            notice = error.localizedDescription
            isError = true
        }
    }

    /// Starts a new visible dictation, or a new stream within the visible paused dictation.
    func start() {
        guard !active else { return }

        if !isPresented {
            beginNewDictation()
        } else {
            guard state == .paused else { return }
        }

        beginStream()
    }

    /// The global shortcut starts when hidden, or discards and dismisses when visible.
    func togglePresentation() {
        if isPresented {
            reset()
            dismissDictation()
            notice = "Dictation canceled. Microphone and connection are off."
        } else {
            start()
        }
    }

    /// Pauses an active stream, or continues the visible paused dictation.
    func toggleRecording() {
        switch state {
        case .starting, .recording:
            pause()
        case .idle, .paused:
            start()
        case .finalizing:
            break
        }
    }

    /// Stops microphone capture immediately, then finalizes and copies the current stream.
    func pause() {
        guard state == .starting || state == .recording else { return }
        finishCurrentStream()
    }

    /// Finalizes and copies before dismissal when there is an active stream.
    func close() {
        switch state {
        case .starting, .recording:
            isClosing = true
            pause()
            if state == .paused, isClosing { closePausedDictation() }
        case .finalizing:
            isClosing = true
            notice = "Finishing transcription and copying before closing; microphone is off."
        case .paused:
            isClosing = true
            closePausedDictation()
        case .idle:
            dismissDictation()
        }
    }

    func cancel(reason: String = "Dictation canceled. Microphone and connection are off.") {
        guard active else { return }

        let recovered = commitCurrentPartialText()
        releaseCurrentStream(cancelClient: true, cancelFinishTask: true)
        checkpointArchive(incomplete: hasIncompleteText)
        state = isPresented ? .paused : .idle
        isClosing = false
        isError = false
        notice = recovered
            ? reason + " Committed text recovered below; it may be incomplete."
            : reason
    }

    /// Discards the visible dictation without copying and leaves the bar ready for a fresh stream.
    func reset() {
        guard isPresented else { return }

        checkpointArchive(incomplete: active || hasIncompleteText)
        releaseCurrentStream(cancelClient: true, cancelFinishTask: true)
        beginNewDictation()
        notice = "Ready to continue dictation."
    }

    func clearResult() {
        guard !active else { return }
        checkpointArchive(incomplete: hasIncompleteText)
        archiveID = UUID()
        archiveStartedAt = Date()
        accumulatedRecordingSeconds = 0
        recordingSeconds = 0
        completedSegments.removeAll(keepingCapacity: true)
        committedCurrentSegment.removeAll(keepingCapacity: true)
        provisionalCurrentSegment.removeAll(keepingCapacity: true)
        refreshTranscript()
        hasIncompleteText = false
        copySucceeded = false
        detectedLanguage = nil
    }

    func copyResult() {
        guard !transcript.isEmpty else { return }

        if dependencies.copyToPasteboard(transcript) {
            copySucceeded = true
            isError = false
            notice = hasIncompleteText
                ? "Copied recovered text. It may be incomplete; clipboard-history tools may retain it."
                : "Copied. Clipboard-history tools may retain this text."
            if archiveSaveFailed {
                notice += " Saving to Transcripts failed; keep this copy and check Settings."
            }
            if isClosing, state == .paused { dismissDictation() }
        } else {
            copySucceeded = false
            isClosing = false
            isError = true
            notice = "Clipboard write failed. Retry Copy, or open Setup to select and copy the text manually."
        }
    }

    private func beginNewDictation() {
        archiveID = UUID()
        archiveStartedAt = Date()
        archiveSaveFailed = false
        // Set this first so a non-activating bar can surface before any Keychain interaction.
        isPresented = true
        isClosing = false
        state = .paused
        completedSegments.removeAll(keepingCapacity: true)
        committedCurrentSegment.removeAll(keepingCapacity: true)
        provisionalCurrentSegment.removeAll(keepingCapacity: true)
        refreshTranscript()
        hasIncompleteText = false
        copySucceeded = false
        accumulatedRecordingSeconds = 0
        recordingSeconds = 0
        microphoneStartMS = nil
        firstAudioMS = nil
        connectionMS = nil
        resultMS = nil
        detectedLanguage = nil
        isError = false
        notice = "Preparing dictation."
    }

    private func beginStream() {
        guard isPresented, state == .paused else { return }
        guard settings.privacyReviewed else {
            startupFailure("Review the privacy and training opt-out guidance in setup before recording.")
            return
        }
        guard settings.vocabularyValid else {
            startupFailure("Use at most 50 vocabulary hints, each no longer than 20 characters.")
            return
        }

        refreshPermissions()
        guard microphoneAllowed else {
            startupFailure("Allow microphone access before recording.")
            return
        }

        let configuration = settings.configuration
        let id = UUID()
        streamID = id
        committedCurrentSegment.removeAll(keepingCapacity: true)
        provisionalCurrentSegment.removeAll(keepingCapacity: true)
        refreshPreviewTranscript()
        copySucceeded = false
        isClosing = false
        isError = false
        state = .starting
        segmentRequestedAt = dependencies.now()
        activeRecordingBeganAt = nil
        finalizationBeganAt = nil
        microphoneStartMS = nil
        firstAudioMS = nil
        connectionMS = nil
        resultMS = nil
        detectedLanguage = nil

        do {
            guard let key = try dependencies.loadCredential(), !key.isEmpty else {
                hasKey = false
                startupFailure("Save your ElevenLabs API key in Keychain first.", streamID: id)
                return
            }
            hasKey = true

            // Keychain access can re-enter the main run loop. A pause, close, or cancellation
            // during that prompt invalidates this stream before capture can start.
            guard ownsStream(id), state == .starting else { return }

            let newCapture = dependencies.makeCapture()
            guard ownsStream(id), state == .starting else {
                newCapture.stop()
                return
            }
            capture = newCapture
            try newCapture.start()
            guard ownsStream(id), state == .starting else {
                newCapture.stop()
                return
            }

            activeRecordingBeganAt = dependencies.now()
            microphoneStartMS = milliseconds(since: segmentRequestedAt)
            notice = "Microphone active. Audio is buffered in memory while ElevenLabs connects."

            let newClient = dependencies.makeClient { [weak self] event in
                self?.handle(event, for: id)
            }
            guard ownsStream(id), state == .starting else {
                newClient.cancel()
                return
            }

            client = newClient
            newClient.connect(apiKey: key, configuration: configuration)
            guard ownsStream(id), state == .starting || state == .recording else { return }
            installPoller()
        } catch {
            guard ownsStream(id) else { return }
            finalizationFailed(error.localizedDescription, streamID: id)
        }
    }

    private func handle(_ event: RealtimeEvent, for id: UUID) {
        guard ownsStream(id) else { return }

        switch event {
        case .ready:
            connectionMS = milliseconds(since: segmentRequestedAt)
            if state == .starting { state = .recording }
            if state == .recording {
                notice = "Recording to ElevenLabs. Pause when you want to review this segment."
            }
        case .partial(let text):
            let provisional = normalized(text)
            guard provisional != provisionalCurrentSegment else { return }
            provisionalCurrentSegment = provisional
            refreshPreviewTranscript()
        case .committed(let text):
            provisionalCurrentSegment.removeAll(keepingCapacity: true)
            let stable = normalized(text)
            if !stable.isEmpty {
                append(stable, to: &committedCurrentSegment)
            }
            refreshPreviewTranscript()
            checkpointArchive(incomplete: true)
        case .failed(let message):
            finalizationFailed(message, streamID: id)
        }
    }

    private func installPoller() {
        guard poller == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollAudio() }
        }
        poller = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func pollAudio() {
        guard state == .starting || state == .recording else { return }
        updateRecordingDuration()
        do {
            try drainAudio()
            if let activeRecordingBeganAt, seconds(since: activeRecordingBeganAt) >= 24 * 60 * 60 {
                pause()
                if state == .finalizing {
                    notice = "24-hour recording limit reached; finishing with the microphone off."
                }
            }
        } catch {
            guard let id = streamID else { return }
            finalizationFailed(error.localizedDescription, streamID: id)
        }
    }

    private func drainAudio() throws {
        guard let capture, let client else { return }
        for bytes in try capture.drain() {
            if firstAudioMS == nil { firstAudioMS = milliseconds(since: segmentRequestedAt) }
            try client.enqueue(bytes)
        }
    }

    private func finishCurrentStream() {
        guard let id = streamID else {
            pauseInterruptedStartup()
            return
        }

        // A Keychain prompt or another synchronous dependency can be interrupted before a
        // realtime client exists. Invalidate first so that startup cannot revive capture later.
        guard let client else {
            pauseInterruptedStartup()
            return
        }

        stopCapture()
        finalizationBeganAt = dependencies.now()
        state = .finalizing
        notice = isClosing
            ? "Finishing transcription and copying before closing; microphone is off."
            : "Finishing transcription; microphone is off."

        do {
            try drainAudio()
        } catch {
            finalizationFailed(error.localizedDescription, streamID: id)
            return
        }

        finishTask = Task { [weak self, client] in
            do {
                let result = try await client.finish()
                guard let self, self.ownsStream(id), self.state == .finalizing else { return }
                self.completeCurrentSegment(result, streamID: id)
            } catch {
                guard let self, self.ownsStream(id) else { return }
                self.finalizationFailed(error.localizedDescription, streamID: id)
            }
        }
    }

    private func completeCurrentSegment(_ result: RealtimeResult, streamID id: UUID) {
        guard ownsStream(id) else { return }

        let completed = normalized(result.text)
        guard !completed.isEmpty else {
            finalizationFailed("No speech was recognized. Keep the bar open and try again.", streamID: id)
            return
        }

        completedSegments.append(completed)
        committedCurrentSegment.removeAll(keepingCapacity: true)
        provisionalCurrentSegment.removeAll(keepingCapacity: true)
        refreshTranscript()
        detectedLanguage = result.language
        if let finalizationBeganAt { resultMS = milliseconds(since: finalizationBeganAt) }

        releaseCurrentStream(cancelClient: false, cancelFinishTask: false)
        state = .paused
        isError = false
        checkpointArchive(incomplete: hasIncompleteText)
        notice = "Dictation complete. Copying the cumulative result."
        copyResult()
    }

    private func pauseInterruptedStartup() {
        releaseCurrentStream(cancelClient: true, cancelFinishTask: true)
        state = isPresented ? .paused : .idle
        isError = false
        notice = "Paused before recording started. Continue when you are ready."
    }

    private func startupFailure(_ message: String, streamID id: UUID? = nil) {
        if let id, !ownsStream(id) { return }
        if id != nil { releaseCurrentStream(cancelClient: true, cancelFinishTask: true) }
        state = isPresented ? .paused : .idle
        isClosing = false
        isError = true
        notice = message
    }

    private func finalizationFailed(_ message: String, streamID id: UUID) {
        guard ownsStream(id) else { return }
        let recovered = commitCurrentPartialText()
        releaseCurrentStream(cancelClient: true, cancelFinishTask: true)
        state = isPresented ? .paused : .idle
        checkpointArchive(incomplete: hasIncompleteText)
        isClosing = false
        isError = true
        notice = message + (recovered ? " Committed text recovered below; it may be incomplete." : "")
    }

    @discardableResult
    private func commitCurrentPartialText() -> Bool {
        let partial = committedCurrentSegment
        committedCurrentSegment.removeAll(keepingCapacity: true)
        provisionalCurrentSegment.removeAll(keepingCapacity: true)
        guard !partial.isEmpty else {
            refreshPreviewTranscript()
            return false
        }
        completedSegments.append(partial)
        refreshTranscript()
        hasIncompleteText = true
        copySucceeded = false
        return true
    }

    private func closePausedDictation() {
        guard state == .paused else { return }
        if transcript.isEmpty || copySucceeded {
            dismissDictation()
        } else {
            copyResult()
        }
    }

    private func dismissDictation() {
        guard !active else { return }
        isPresented = false
        isClosing = false
        state = .idle
    }

    private func releaseCurrentStream(cancelClient: Bool, cancelFinishTask: Bool) {
        // Callbacks from cancellation may synchronously re-enter the coordinator. Invalidate
        // first so no finalization or realtime event can restore discarded stream state.
        streamID = nil
        stopCapture()
        capture = nil
        let currentClient = client
        client = nil
        if cancelClient { currentClient?.cancel() }
        if cancelFinishTask { finishTask?.cancel() }
        finishTask = nil
        finalizationBeganAt = nil
        committedCurrentSegment.removeAll(keepingCapacity: true)
        provisionalCurrentSegment.removeAll(keepingCapacity: true)
        refreshPreviewTranscript()
    }

    private func invalidatePoller() {
        poller?.invalidate()
        poller = nil
    }

    private func ownsStream(_ id: UUID) -> Bool {
        streamID == id && isPresented
    }

    private func updateRecordingDuration() {
        guard let activeRecordingBeganAt else { return }
        let duration = accumulatedRecordingSeconds + seconds(since: activeRecordingBeganAt)
        // Avoid redrawing the interface at the audio polling rate.
        if Int(duration) != Int(recordingSeconds) { recordingSeconds = duration }
    }

    private func stopCapture() {
        if let activeRecordingBeganAt {
            accumulatedRecordingSeconds += seconds(since: activeRecordingBeganAt)
            self.activeRecordingBeganAt = nil
        }
        if recordingSeconds != accumulatedRecordingSeconds {
            recordingSeconds = accumulatedRecordingSeconds
        }
        invalidatePoller()
        capture?.stop()
    }

    /// Save stable provider commits, never speculative live hypotheses. One row survives
    /// Pause/Continue; Reset and Clear start a new identity without erasing the archive.
    private func checkpointArchive(incomplete: Bool) {
        guard let archive else { return }
        var text = transcript
        append(committedCurrentSegment, to: &text)
        guard !text.isEmpty else { return }
        let duration = accumulatedRecordingSeconds
            + (activeRecordingBeganAt.map { seconds(since: $0) } ?? 0)
        archiveSaveFailed = !archive.save(
            id: archiveID, startedAt: archiveStartedAt, updatedAt: Date(),
            text: text, duration: duration, language: detectedLanguage,
            isIncomplete: incomplete
        )
    }

    private func refreshTranscript() {
        transcript = assembledText(completedSegments)
        refreshPreviewTranscript()
    }

    private func refreshPreviewTranscript() {
        var preview = transcript
        append(committedCurrentSegment, to: &preview)
        append(provisionalCurrentSegment, to: &preview)
        if preview != previewTranscript { previewTranscript = preview }
    }

    private func append(_ text: String, to base: inout String) {
        guard !text.isEmpty else { return }
        if !base.isEmpty { base.append(" ") }
        base.append(text)
    }

    private func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func assembledText(_ segments: [String]) -> String {
        segments.joined(separator: " ")
    }

    private func milliseconds(since instant: ContinuousClock.Instant) -> Double {
        seconds(since: instant) * 1_000
    }

    private func seconds(since instant: ContinuousClock.Instant) -> Double {
        let components = instant.duration(to: dependencies.now()).components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
