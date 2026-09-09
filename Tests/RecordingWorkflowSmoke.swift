import AppKit
import Foundation

import Darwin

@MainActor
private final class FakeCapture: TranscriptionAudioCapturing {
    private(set) var isCapturing = false
    private let onStart: () -> Void

    init(onStart: @escaping () -> Void) { self.onStart = onStart }

    func start() throws { isCapturing = true; onStart() }
    func stop() { isCapturing = false }
    func drain() throws -> [Data] { [] }
}

@MainActor
private final class FakeRealtimeSession: TranscriptionRealtimeSession {
    private let onEvent: @MainActor (RealtimeEvent) -> Void
    private var finisher: CheckedContinuation<RealtimeResult, Error>?
    private(set) var finishRequests = 0
    private(set) var cancelled = false

    init(onEvent: @escaping @MainActor (RealtimeEvent) -> Void) {
        self.onEvent = onEvent
    }

    func connect(apiKey: String, configuration: RealtimeConfiguration) {}
    func enqueue(_ pcm: Data) throws {}

    func finish() async throws -> RealtimeResult {
        finishRequests += 1
        return try await withCheckedThrowingContinuation { finisher = $0 }
    }

    func cancel() { cancelled = true }
    func ready() { onEvent(.ready) }
    func partial(_ text: String) { onEvent(.partial(text)) }
    func committed(_ text: String) { onEvent(.committed(text)) }
    func fail(_ message: String) { onEvent(.failed(message)) }
    func succeed(_ text: String) {
        finisher?.resume(returning: RealtimeResult(text: text, language: "en"))
        finisher = nil
    }
}

@MainActor
private final class WorkflowWorld {
    private(set) var clients: [FakeRealtimeSession] = []
    private(set) var copied: [String] = []
    var pasteboardResults: [Bool]
    private(set) var microphoneStarts = 0
    var onCredentialLoad: (() -> Void)?
    var copyAction: ((String) -> Bool)?
    var clock = ContinuousClock.now

    init(pasteboardResults: [Bool] = []) {
        self.pasteboardResults = pasteboardResults
    }

    func dependencies() -> TranscriptionCoordinatorDependencies {
        TranscriptionCoordinatorDependencies(
            loadCredential: { [weak self] in self?.onCredentialLoad?(); return "test-key" },
            saveCredential: { _ in },
            deleteCredential: {},
            microphoneAuthorized: { true },
            requestMicrophone: { true },
            makeCapture: { [weak self] in FakeCapture { self?.microphoneStarts += 1 } },
            makeClient: { [weak self] onEvent in
                let client = FakeRealtimeSession(onEvent: onEvent)
                self?.clients.append(client)
                return client
            },
            copyToPasteboard: { [weak self] text in
                guard let self else { return false }
                self.copied.append(text)
                if let copyAction = self.copyAction { return copyAction(text) }
                return self.pasteboardResults.isEmpty ? true : self.pasteboardResults.removeFirst()
            },
            now: { [self] in clock }
        )
    }
}

@main
@MainActor
struct RecordingWorkflowSmoke {
    static func check(_ condition: Bool, _ message: String) {
        if !condition {
            print("FAIL \(message)")
            exit(1)
        }
    }

    static func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }

    private static func pumpTimer() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    }

    private static func makeModel(_ world: WorkflowWorld, archive: TranscriptArchive? = nil) -> TranscriptionCoordinator {
        let suite = "RecordingWorkflowSmoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removePersistentDomain(forName: suite)
        let settings = DictationSettings(defaults: defaults)
        settings.privacyReviewed = true
        return TranscriptionCoordinator(settings: settings, dependencies: world.dependencies(), archive: archive)
    }

    private static func finish(
        _ model: TranscriptionCoordinator,
        with text: String,
        in world: WorkflowWorld
    ) async {
        model.start()
        let client = world.clients.last!
        client.ready()
        model.pause()
        check(!model.capturing && model.isPresented, "pause must stop the microphone before finalization")
        await settle()
        client.succeed(text)
        await settle()
    }

    static func main() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let archiveDefaultsName = "ArchiveWorkflow.\(UUID().uuidString)"
        let archiveDefaults = UserDefaults(suiteName: archiveDefaultsName)!
        let archiveSettings = DictationSettings(defaults: archiveDefaults)
        let archive = TranscriptArchive(settings: archiveSettings, databaseURL: directory.appendingPathComponent("transcripts.sqlite3"))
        defer {
            archive.shutdown()
            try? FileManager.default.removeItem(at: directory)
            archiveDefaults.removePersistentDomain(forName: archiveDefaultsName)
        }
        let archiveWorld = WorkflowWorld()
        let archiveModel = makeModel(archiveWorld, archive: archive)
        archiveModel.start()
        archiveWorld.clients.last!.committed("Stable checkpoint.")
        archiveWorld.clients.last!.partial("Do not archive this guess.")
        check(archive.sessions.count == 1, "provider commit was not durably checkpointed")
        let archiveID = archive.sessions[0].id
        check(archive.text(for: archiveID) == "Stable checkpoint.", "archive included speculative words")
        archiveModel.pause()
        await settle()
        archiveWorld.clients.last!.succeed("Stable checkpoint.")
        await settle()
        await finish(archiveModel, with: "Continued session.", in: archiveWorld)
        check(archive.sessions.count == 1 && archive.sessions[0].id == archiveID,
              "Pause/Continue created duplicate sessions")
        check(archive.text(for: archiveID) == "Stable checkpoint. Continued session.", "archive lost resumed text")
        archiveModel.reset()
        await finish(archiveModel, with: "New session after reset.", in: archiveWorld)
        check(archive.sessions.count == 2, "Reset replaced historical session")
        archiveModel.togglePresentation()
        check(archive.sessions.count == 2, "shortcut cancellation erased history")

        let limitWorld = WorkflowWorld()
        let limitModel = makeModel(limitWorld)
        limitModel.start()
        limitWorld.clock = limitWorld.clock.advanced(by: .seconds(86_399))
        // Drive the real production timer; wall time does not advance by 24 hours.
        pumpTimer()
        check(limitModel.capturing, "recording stopped before the 24-hour ceiling")
        limitWorld.clock = limitWorld.clock.advanced(by: .seconds(1))
        pumpTimer()
        check(!limitModel.capturing && limitModel.state == .finalizing, "24-hour cap did not pause capture")
        await settle()
        limitWorld.clients.last!.succeed("At the limit.")
        await settle()
        check(limitWorld.copied == ["At the limit."], "limit did not finalize and copy")
        limitModel.start()
        pumpTimer()
        check(limitModel.capturing, "Continue did not reset continuous recording ceiling")
        limitModel.togglePresentation()

        let shortcutWorld = WorkflowWorld()
        let shortcutModel = makeModel(shortcutWorld)
        shortcutModel.togglePresentation()
        let canceledClient = shortcutWorld.clients.last!
        canceledClient.partial("Discard while connecting.")
        shortcutModel.togglePresentation()
        check(!shortcutModel.isPresented && !shortcutModel.capturing
                && shortcutModel.previewTranscript.isEmpty && shortcutWorld.copied.isEmpty,
              "shortcut did not cancel connecting capture without copying")
        shortcutModel.togglePresentation()
        let finishingClient = shortcutWorld.clients.last!
        finishingClient.ready()
        finishingClient.committed("Discard during finalization.")
        shortcutModel.close()
        await settle()
        shortcutModel.togglePresentation()
        shortcutModel.togglePresentation()
        finishingClient.succeed("Late canceled result.")
        canceledClient.partial("Late connecting words.")
        await settle()
        check(shortcutModel.isPresented && shortcutModel.capturing
                && shortcutModel.previewTranscript.isEmpty && shortcutWorld.copied.isEmpty,
              "canceled finalization changed a fresh dictation or copied text")
        shortcutModel.togglePresentation()
        check(!shortcutModel.isPresented && !shortcutModel.capturing,
              "shortcut did not cancel recording")
        await finish(shortcutModel, with: "Already copied.", in: shortcutWorld)
        shortcutModel.togglePresentation()
        check(!shortcutModel.isPresented && shortcutModel.transcript.isEmpty
                && shortcutWorld.copied == ["Already copied."],
              "shortcut failed to dismiss paused text without modifying the clipboard")

        let startupShortcutWorld = WorkflowWorld()
        let startupShortcutModel = makeModel(startupShortcutWorld)
        startupShortcutWorld.onCredentialLoad = { startupShortcutModel.togglePresentation() }
        startupShortcutModel.togglePresentation()
        check(!startupShortcutModel.isPresented && startupShortcutWorld.microphoneStarts == 0,
              "shortcut cancellation during credential access revived capture")

        let pausedWorld = WorkflowWorld()
        let pausedModel = makeModel(pausedWorld)
        await finish(pausedModel, with: "First segment.", in: pausedWorld)
        check(pausedModel.state == .paused, "pause did not leave the bar resumable")
        check(pausedModel.transcript == "First segment.", "pause did not retain the completed segment")
        check(pausedWorld.copied == ["First segment."], "pause did not automatically copy")

        check(pausedModel.previewTranscript == "First segment.", "pause did not retain the finalized preview")

        pausedModel.toggleRecording()
        let resumedClient = pausedWorld.clients.last!
        resumedClient.ready()
        pausedModel.pause()
        await settle()
        resumedClient.succeed("Second segment.")
        await settle()
        check(pausedModel.transcript == "First segment. Second segment.", "resume duplicated or replaced cumulative text")
        check(pausedWorld.copied == ["First segment.", "First segment. Second segment."], "resume did not copy cumulative text once")
        check(pausedModel.previewTranscript == "First segment. Second segment.",
              "resume did not preserve the cumulative preview")

        let previewWorld = WorkflowWorld()
        let previewModel = makeModel(previewWorld)
        previewModel.start()
        let previewClient = previewWorld.clients.last!
        previewClient.ready()
        previewClient.partial("Initial hypothesis.")
        check(previewModel.previewTranscript == "Initial hypothesis." && previewModel.transcript.isEmpty,
              "partial hypothesis did not appear without changing finalized text")
        previewClient.partial("Revised hypothesis.")
        check(previewModel.previewTranscript == "Revised hypothesis.",
              "revised partial hypothesis appended instead of replacing")
        previewClient.partial("")
        check(previewModel.previewTranscript.isEmpty, "empty partial hypothesis did not clear the preview")
        previewClient.committed("Committed words.")
        check(previewModel.previewTranscript == "Committed words." && previewModel.transcript.isEmpty,
              "committed words did not replace the provisional preview")
        previewClient.partial("Uncommitted tail.")
        check(previewModel.previewTranscript == "Committed words. Uncommitted tail.",
              "preview did not combine committed and provisional words")
        previewModel.pause()
        await settle()
        previewClient.succeed("Committed words.")
        await settle()
        check(previewModel.transcript == "Committed words." && previewModel.previewTranscript == "Committed words.",
              "finalization retained an uncommitted provisional hypothesis")
        check(previewWorld.copied == ["Committed words."], "finalization copied provisional words")

        let failedPreviewWorld = WorkflowWorld()
        let failedPreviewModel = makeModel(failedPreviewWorld)
        failedPreviewModel.start()
        let failedPreviewClient = failedPreviewWorld.clients.last!
        failedPreviewClient.ready()
        failedPreviewClient.partial("Failed hypothesis.")
        failedPreviewClient.fail("Synthetic failure.")
        check(failedPreviewModel.transcript.isEmpty && failedPreviewModel.previewTranscript.isEmpty,
              "failed stream retained a provisional hypothesis")
        failedPreviewModel.copyResult()
        check(failedPreviewWorld.copied.isEmpty, "failed stream copied a provisional hypothesis")

        let canceledPreviewWorld = WorkflowWorld()
        let canceledPreviewModel = makeModel(canceledPreviewWorld)
        canceledPreviewModel.start()
        let canceledPreviewClient = canceledPreviewWorld.clients.last!
        canceledPreviewClient.ready()
        canceledPreviewClient.partial("Canceled hypothesis.")
        canceledPreviewModel.cancel(reason: "Canceled.")
        check(canceledPreviewModel.transcript.isEmpty && canceledPreviewModel.previewTranscript.isEmpty,
              "canceled stream retained a provisional hypothesis")
        canceledPreviewModel.copyResult()
        check(canceledPreviewWorld.copied.isEmpty, "canceled stream copied a provisional hypothesis")

        let recordingResetWorld = WorkflowWorld()
        let recordingResetModel = makeModel(recordingResetWorld)
        recordingResetModel.start()
        let recordingResetClient = recordingResetWorld.clients.last!
        recordingResetClient.ready()
        recordingResetClient.partial("Discard this recording.")
        recordingResetModel.reset()
        check(recordingResetModel.isPresented && recordingResetModel.state == .paused && !recordingResetModel.capturing,
              "reset did not stop active microphone capture and leave the bar resumable")
        check(recordingResetClient.cancelled, "reset did not cancel the active realtime stream")
        check(recordingResetModel.transcript.isEmpty && recordingResetModel.previewTranscript.isEmpty
                && recordingResetModel.recordingSeconds == 0,
              "reset did not discard active recording text and timer")
        check(recordingResetWorld.copied.isEmpty, "reset copied active recording text")

        let finalizingResetWorld = WorkflowWorld()
        let finalizingResetModel = makeModel(finalizingResetWorld)
        finalizingResetModel.start()
        let finalizingResetClient = finalizingResetWorld.clients.last!
        finalizingResetClient.ready()
        finalizingResetClient.committed("Discard this finalization.")
        finalizingResetModel.pause()
        await settle()
        check(finalizingResetModel.state == .finalizing, "reset scenario did not enter finalization")
        finalizingResetModel.reset()
        check(finalizingResetModel.isPresented && finalizingResetModel.state == .paused
                && finalizingResetModel.transcript.isEmpty && finalizingResetModel.previewTranscript.isEmpty
                && finalizingResetModel.recordingSeconds == 0 && finalizingResetModel.microphoneStartMS == nil
                && finalizingResetModel.firstAudioMS == nil && finalizingResetModel.connectionMS == nil
                && finalizingResetModel.resultMS == nil && finalizingResetModel.detectedLanguage == nil,
              "reset did not discard finalization text, preview, and timing state")
        check(finalizingResetWorld.copied.isEmpty, "reset copied finalizing text")
        finalizingResetClient.succeed("Stale finalization.")
        finalizingResetClient.partial("Stale event.")
        finalizingResetClient.fail("Stale failure.")
        await settle()
        check(finalizingResetModel.transcript.isEmpty && finalizingResetModel.previewTranscript.isEmpty
                && finalizingResetWorld.copied.isEmpty,
              "stale finalization restored discarded text or copied it")
        finalizingResetModel.toggleRecording()
        let freshResetClient = finalizingResetWorld.clients.last!
        freshResetClient.ready()
        finalizingResetModel.pause()
        await settle()
        freshResetClient.succeed("Fresh after reset.")
        await settle()
        check(finalizingResetModel.transcript == "Fresh after reset."
                && finalizingResetWorld.copied == ["Fresh after reset."],
              "Continue after reset did not start a fresh dictation")

        let closingWorld = WorkflowWorld()
        let closingModel = makeModel(closingWorld)
        closingModel.start()
        let closingClient = closingWorld.clients.last!
        closingClient.ready()
        closingModel.close()
        await settle()
        closingModel.close()
        await settle()
        check(closingModel.state == .finalizing && closingModel.isClosing, "close did not wait for finalization")
        check(closingClient.finishRequests == 1, "close issued duplicate finalization")
        closingClient.succeed("Close segment.")
        await settle()
        check(closingModel.state == .idle && !closingModel.isPresented, "successful close did not dismiss")
        check(closingWorld.copied == ["Close segment."], "close did not copy before dismissal")

        let clipboardWorld = WorkflowWorld(pasteboardResults: [false, true])
        let clipboardModel = makeModel(clipboardWorld)
        await finish(clipboardModel, with: "Keep this text.", in: clipboardWorld)
        check(clipboardModel.isPresented && clipboardModel.isError && !clipboardModel.copySucceeded,
              "clipboard failure hid or discarded the result")
        clipboardModel.copyResult()
        check(clipboardModel.transcript == "Keep this text." && clipboardModel.copySucceeded && !clipboardModel.isError,
              "clipboard retry did not recover retained text")

        let staleWorld = WorkflowWorld()
        let staleModel = makeModel(staleWorld)
        staleModel.start()
        let staleClient = staleWorld.clients.last!
        staleClient.ready()
        staleModel.pause()
        await settle()
        staleModel.cancel(reason: "Interrupted.")
        staleModel.close()
        staleModel.start()
        let replacementClient = staleWorld.clients.last!
        staleClient.succeed("Stale segment.")
        staleClient.partial("Stale hypothesis.")
        await settle()
        check(staleModel.previewTranscript.isEmpty, "stale provisional event mutated a new dictation")
        replacementClient.ready()
        staleModel.pause()
        await settle()
        replacementClient.succeed("Fresh segment.")
        await settle()
        check(staleModel.transcript == "Fresh segment.", "stale finalization mutated a new dictation")

        let interruptedWorld = WorkflowWorld()
        let interruptedModel = makeModel(interruptedWorld)
        interruptedWorld.onCredentialLoad = { [weak interruptedModel] in interruptedModel?.pause() }
        interruptedModel.start()
        check(interruptedModel.isPresented && interruptedModel.state == .paused, "interrupted startup must remain resumable")
        check(interruptedWorld.microphoneStarts == 0, "microphone started after pause interrupted credential access")
        interruptedWorld.onCredentialLoad = { [weak interruptedModel] in interruptedModel?.close() }
        interruptedModel.toggleRecording()
        check(!interruptedModel.isPresented && !interruptedModel.capturing, "close during startup must dismiss without capture")
        check(interruptedWorld.microphoneStarts == 0, "microphone started after close interrupted credential access")

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let nativeClipboardWorld = WorkflowWorld()
        nativeClipboardWorld.copyAction = { text in
            pasteboard.clearContents()
            return pasteboard.setString(text, forType: .string)
        }
        let nativeClipboardModel = makeModel(nativeClipboardWorld)
        await finish(nativeClipboardModel, with: "Native first.", in: nativeClipboardWorld)
        check(pasteboard.string(forType: .string) == "Native first.", "pause did not reach native pasteboard")
        await finish(nativeClipboardModel, with: "Native second.", in: nativeClipboardWorld)
        check(pasteboard.string(forType: .string) == "Native first. Native second.", "native pasteboard lost resumed text")
        nativeClipboardModel.close()
        print("PASS pause/resume/close, live preview revisions, speculative-text recovery, stale events, interrupted startup and native private pasteboard")
    }
}
