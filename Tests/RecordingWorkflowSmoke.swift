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
    var confirmationWaiters: [CheckedContinuation<Void, Never>] = []
    var holdCleanup = false
    var cleanupWaiters: [CheckedContinuation<String, Error>] = []
    var cleanupResponse: String?
    var cleanupError: Error?
    var cleanupKey: String? = "cleanup-test-key"
    var onCleanupCredentialLoad: (() -> Void)?
    private(set) var cleanupRequests = 0

    func releaseConfirmation() {
        let waiters = confirmationWaiters
        confirmationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    init(pasteboardResults: [Bool] = []) {
        self.pasteboardResults = pasteboardResults
    }

    func dependencies() -> TranscriptionCoordinatorDependencies {
        TranscriptionCoordinatorDependencies(
            loadCredential: { [weak self] in self?.onCredentialLoad?(); return "test-key" },
            saveCredential: { _ in },
            deleteCredential: {},
            loadCleanupCredential: { [self] in onCleanupCredentialLoad?(); return cleanupKey },
            saveCleanupCredential: { [self] in cleanupKey = $0 },
            deleteCleanupCredential: { [self] in cleanupKey = nil },
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
            now: { [self] in clock },
            waitForCloseConfirmation: { [self] in
                await withCheckedContinuation { confirmationWaiters.append($0) }
            },
            cleanTranscript: { [self] text, _ in
                cleanupRequests += 1
                if holdCleanup {
                    return try await withCheckedThrowingContinuation { cleanupWaiters.append($0) }
                }
                if let cleanupError { throw cleanupError }
                return cleanupResponse ?? text
            }
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

    private static func verifyCleanup(settings: DictationSettings, directory: URL) async {
        let url = directory.appendingPathComponent("cleanup.sqlite3")
        let archive = TranscriptArchive(settings: settings, databaseURL: url)
        let board = NSPasteboard.withUniqueName()
        defer { archive.shutdown(); board.releaseGlobally() }
        let world = WorkflowWorld()
        world.copyAction = { text in
            board.clearContents()
            return board.setString(text, forType: .string)
        }
        let model = makeModel(world, archive: archive)
        check(!model.canCleanText, "hidden session allowed cleanup")
        model.start()
        check(!model.canCleanText, "live session allowed cleanup")
        world.clock = world.clock.advanced(by: .seconds(7))
        model.pause()
        check(!model.canCleanText, "finalizing session allowed cleanup")
        await settle()
        world.clients.last!.succeed("um, First segment.")
        await settle()
        await finish(model, with: "Ik wil ehm morgen testen.", in: world)
        let original = "um, First segment. Ik wil ehm morgen testen."
        let cleaned = "First segment. Ik wil morgen testen."
        world.cleanupResponse = cleaned
        let before = archive.sessions[0]
        check(before.duration == 7, "duration fixture failed")
        model.cleanUpText()
        check(model.isCleaningText && !model.canCleanText, "cleanup did not publish progress")
        await settle()
        check(model.transcript == cleaned && model.previewTranscript == cleaned
                && board.string(forType: .string) == cleaned && model.canUndoCleanup,
              "cleanup preview, result, clipboard or Undo diverged")
        let after = archive.sessions[0]
        check(archive.sessions.count == 1 && after.id == before.id
                && after.startedAt == before.startedAt && after.duration == before.duration
                && after.language == before.language && after.isIncomplete == before.isIncomplete,
              "cleanup changed session identity or metadata")
        let reopened = TranscriptArchive(settings: settings, databaseURL: url)
        check(reopened.text(for: before.id) == cleaned, "cleanup was not persisted to the existing row")
        reopened.shutdown()
        let updateTime = after.updatedAt
        model.cleanUpText()
        await settle()
        check(archive.sessions[0].updatedAt == updateTime && model.canUndoCleanup,
              "no-op cleanup changed retention or discarded Undo")
        model.copyResult()
        check(model.canUndoCleanup, "manual copy discarded available Undo")
        model.undoCleanup()
        check(model.transcript == original && model.previewTranscript == original
                && archive.text(for: before.id) == original && board.string(forType: .string) == original
                && !model.canUndoCleanup, "Undo did not restore every text surface")
        model.cleanUpText()
        await settle()
        model.start()
        check(!model.canUndoCleanup && model.cleanupNotice == nil, "Resume retained stale Undo or notice")
        world.clients.last!.ready()
        model.pause()
        await settle()
        world.clients.last!.succeed("uh, Raw resumed segment.")
        await settle()
        check(model.transcript == cleaned + " uh, Raw resumed segment.",
              "Resume lost cleaned prefix or cleaned/duplicated raw new segment")
        world.cleanupResponse = cleaned + " Raw resumed segment."
        model.cleanUpText()
        await settle()
        let cumulative = cleaned + " Raw resumed segment."
        check(model.transcript == cumulative && archive.text(for: before.id) == cumulative,
              "subsequent cleanup did not clean cumulative text")
        model.reset()
        await finish(model, with: "A fresh session.", in: world)
        check(archive.sessions.count == 2 && archive.text(for: before.id) == cumulative,
              "Reset altered older cleaned session")
        model.discardAndDismiss()

        let recoveredWorld = WorkflowWorld()
        let recovered = makeModel(recoveredWorld, archive: archive)
        recovered.start()
        recoveredWorld.clients.last!.committed("um, Stable recovered words.")
        recoveredWorld.clients.last!.partial("Provisional words.")
        recovered.cancel()
        let recoveredID = archive.sessions[0].id
        recoveredWorld.cleanupResponse = "Stable recovered words."
        recovered.cleanUpText()
        await settle()
        check(recovered.transcript == "Stable recovered words."
                && archive.sessions.first(where: { $0.id == recoveredID })?.isIncomplete == true,
              "cleanup lost incomplete status or included provisional words")
        recovered.undoCleanup()
        check(recovered.transcript == "um, Stable recovered words."
                && archive.sessions.first(where: { $0.id == recoveredID })?.isIncomplete == true,
              "Undo lost recovered stable text or incomplete status")
        recovered.discardAndDismiss()

        let emptyWorld = WorkflowWorld()
        let empty = makeModel(emptyWorld, archive: archive)
        await finish(empty, with: "uh, um, ehm...", in: emptyWorld)
        let emptySummary = archive.sessions[0]
        let copies = emptyWorld.copied
        emptyWorld.cleanupResponse = ""
        empty.cleanUpText()
        await settle()
        check(empty.transcript == "uh, um, ehm..." && emptyWorld.copied == copies
                && archive.sessions[0] == emptySummary && !empty.canUndoCleanup,
              "filler-only cleanup destroyed original text, archive or clipboard")
        empty.discardAndDismiss()

        let failedCopyWorld = WorkflowWorld(pasteboardResults: [true, false])
        let failedCopy = makeModel(failedCopyWorld, archive: archive)
        await finish(failedCopy, with: "um, Keep the cleaned text.", in: failedCopyWorld)
        failedCopyWorld.cleanupResponse = "Keep the cleaned text."
        failedCopy.cleanUpText()
        await settle()
        check(failedCopy.transcript == "Keep the cleaned text." && failedCopy.canUndoCleanup
                && failedCopy.isError && !failedCopy.copySucceeded && failedCopy.cleanupNotice == nil,
              "clipboard failure lost cleaned text/Undo or claimed success")
        failedCopy.undoCleanup()
        check(failedCopy.transcript == "um, Keep the cleaned text." && failedCopy.copySucceeded,
              "Undo could not recover from clipboard failure")
        failedCopy.discardAndDismiss()

        let failureArchive = TranscriptArchive(settings: settings, databaseURL: directory.appendingPathComponent("failure.sqlite3"))
        let failureWorld = WorkflowWorld()
        let failure = makeModel(failureWorld, archive: failureArchive)
        await finish(failure, with: "um, Archive failure sample.", in: failureWorld)
        failureArchive.shutdown()
        failureWorld.cleanupResponse = "Archive failure sample."
        failure.cleanUpText()
        await settle()
        check(failure.transcript == "Archive failure sample." && failure.canUndoCleanup
                && failure.copySucceeded && failureWorld.copied.last == failure.transcript,
              "archive failure lost text/Undo or prevented clipboard recovery")
        failure.cleanUpText()
        await settle()
        check(failure.canUndoCleanup && failureWorld.copied.last == failure.transcript,
              "no-op after archive failure discarded Undo or failed to recopy")
        failure.undoCleanup()
        check(failure.transcript == "um, Archive failure sample."
                && failureWorld.copied.last == failure.transcript && !failure.canUndoCleanup,
              "Undo after archive failure did not restore and copy the original")
        failure.discardAndDismiss()

        for action in ["resume", "reset", "close", "clear", "cancel", "discard", "copy"] {
            let staleArchive = TranscriptArchive(settings: settings, databaseURL: directory.appendingPathComponent("\(action).sqlite3"))
            let staleWorld = WorkflowWorld()
            let stale = makeModel(staleWorld, archive: staleArchive)
            await finish(stale, with: "um, Original authoritative text.", in: staleWorld)
            staleWorld.holdCleanup = true
            stale.cleanUpText()
            await settle()
            check(staleWorld.cleanupWaiters.count == 1, "cleanup gate did not start")
            switch action {
            case "resume": stale.start()
            case "reset": stale.reset()
            case "close": stale.close()
            case "clear": stale.clearResult()
            case "cancel": stale.cancel()
            case "discard": stale.discardAndDismiss()
            default: stale.copyResult()
            }
            let transcript = stale.transcript
            let copied = staleWorld.copied
            let rows = staleArchive.sessions
            staleWorld.cleanupWaiters.removeFirst().resume(returning: "Stale cleanup must not publish.")
            await settle()
            check(stale.transcript == transcript && staleWorld.copied == copied
                    && staleArchive.sessions == rows && !stale.isCleaningText && !stale.canUndoCleanup,
                  "\(action) allowed stale cleanup to mutate preview/clipboard/archive")
            stale.discardAndDismiss()
            staleWorld.releaseConfirmation()
            await settle()
            staleArchive.shutdown()
        }

        let generationWorld = WorkflowWorld()
        let generationModel = makeModel(generationWorld)
        await finish(generationModel, with: "um, Old request.", in: generationWorld)
        generationWorld.holdCleanup = true
        generationModel.cleanUpText()
        await settle()
        generationModel.reset()
        await finish(generationModel, with: "um, New request.", in: generationWorld)
        generationModel.cleanUpText()
        await settle()
        generationWorld.cleanupWaiters.removeLast().resume(returning: "New request.")
        await settle()
        generationWorld.cleanupWaiters.removeFirst().resume(returning: "Old request.")
        await settle()
        check(generationModel.transcript == "New request."
                && generationWorld.copied.last == "New request." && generationModel.canUndoCleanup,
              "older completion overwrote a newer session/request")
        generationModel.discardAndDismiss()
    }

    private static func verifyCleanupAPIFailures(settings: DictationSettings, directory: URL) async {
        let archive = TranscriptArchive(settings: settings, databaseURL: directory.appendingPathComponent("api-errors.sqlite3"))
        defer { archive.shutdown() }
        let world = WorkflowWorld()
        world.cleanupKey = nil
        let model = makeModel(world, archive: archive)
        await finish(model, with: "Ik heb 't idee dat, uuuh, hij niet op 17 mei komt.", in: world)
        let original = model.transcript
        let before = archive.sessions[0]
        let copies = world.copied
        model.cleanUpText()
        await settle()
        check(model.copySucceeded && !model.canCleanText && world.cleanupRequests == 0,
              "missing optional cleanup key prevented recording/copy or sent a request")
        check(model.saveCleanupKey("synthetic-key") && model.canCleanText,
              "saving cleanup key did not enable stopped cleanup")
        world.cleanupError = URLError(.timedOut)
        model.cleanUpText()
        await settle()
        check(model.isError && !model.isCleaningText && model.canCleanText
                && model.transcript == original && world.copied == copies
                && archive.sessions[0] == before && !model.canUndoCleanup,
              "API failure changed original/archive/clipboard or blocked retry")
        world.cleanupError = nil
        world.cleanupResponse = "Ik heb het idee dat hij niet op 17 mei komt."
        model.cleanUpText()
        await settle()
        let cleaned = model.transcript
        let cleanedSummary = archive.sessions[0]
        let cleanedCopies = world.copied
        check(cleaned != original && model.canUndoCleanup && !model.isError,
              "retry failed to apply cleanup")
        world.cleanupError = URLError(.notConnectedToInternet)
        model.cleanUpText()
        await settle()
        check(model.isError && model.canUndoCleanup && model.transcript == cleaned
                && archive.sessions[0] == cleanedSummary && world.copied == cleanedCopies,
              "failed repeat cleanup discarded Undo or mutated saved/copied text")
        model.deleteCleanupKey()
        check(!model.hasCleanupKey && !model.canCleanText && model.canUndoCleanup,
              "key removal discarded offline Undo")
        model.undoCleanup()
        check(model.transcript == original && archive.text(for: before.id) == original
                && world.copied.last == original && !model.canUndoCleanup,
              "Undo required an OpenAI key or network")
        model.discardAndDismiss()

        let missingWorld = WorkflowWorld()
        let missing = makeModel(missingWorld)
        await finish(missing, with: "Keep this original.", in: missingWorld)
        missingWorld.cleanupKey = nil
        missing.cleanUpText()
        await settle()
        check(!missing.hasCleanupKey && missing.isError && !missing.isCleaningText
                && missingWorld.cleanupRequests == 0 && missing.transcript == "Keep this original.",
              "externally removed key allowed cleanup or left progress stuck")
        missing.discardAndDismiss()

        let reentrantWorld = WorkflowWorld()
        let reentrant = makeModel(reentrantWorld)
        await finish(reentrant, with: "Do not send after Reset.", in: reentrantWorld)
        reentrantWorld.onCleanupCredentialLoad = { reentrant.reset() }
        reentrant.cleanUpText()
        await settle()
        check(reentrantWorld.cleanupRequests == 0 && reentrant.transcript.isEmpty
                && !reentrant.isCleaningText && !reentrant.isError,
              "Keychain reentrancy sent obsolete text or published stale state")
        reentrantWorld.onCleanupCredentialLoad = nil
        reentrant.discardAndDismiss()

        let lateWorld = WorkflowWorld()
        let late = makeModel(lateWorld)
        await finish(late, with: "Old session.", in: lateWorld)
        lateWorld.holdCleanup = true
        late.cleanUpText()
        await settle()
        late.reset()
        await finish(late, with: "New authoritative session.", in: lateWorld)
        let newCopies = lateWorld.copied
        lateWorld.cleanupWaiters.removeFirst().resume(throwing: URLError(.timedOut))
        await settle()
        check(!late.isError && !late.isCleaningText && late.transcript == "New authoritative session."
                && lateWorld.copied == newCopies,
              "late network error corrupted the newer session")
        late.discardAndDismiss()
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
        archiveModel.discardAndDismiss()
        check(archive.sessions.count == 2, "explicit discard erased history")

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
        limitModel.discardAndDismiss()

        let shortcutWorld = WorkflowWorld()
        let shortcutModel = makeModel(shortcutWorld)
        shortcutModel.togglePresentation()
        let connectingClient = shortcutWorld.clients.last!
        connectingClient.partial("Connecting hypothesis.")
        shortcutModel.togglePresentation()
        check(!shortcutModel.capturing && shortcutModel.isPresented, "shortcut did not stop connecting capture")
        await settle()
        shortcutModel.togglePresentation()
        shortcutModel.close()
        shortcutModel.start()
        check(connectingClient.finishRequests == 1 && shortcutWorld.clients.count == 1,
              "duplicate close/start duplicated finalization or started a session")
        connectingClient.succeed("Final connecting text.")
        await settle()
        check(shortcutModel.isPresented && shortcutModel.state == .paused
                && shortcutModel.isShowingCopyConfirmation
                && shortcutWorld.copied == ["Final connecting text."],
              "shortcut did not acknowledge actual final copy before dismissal")
        shortcutModel.togglePresentation()
        shortcutModel.close()
        shortcutModel.copyResult()
        check(shortcutWorld.copied.count == 1 && shortcutWorld.confirmationWaiters.count == 1,
              "duplicate requests copied again or extended confirmation")
        shortcutWorld.releaseConfirmation()
        await settle()
        check(!shortcutModel.isPresented, "confirmation completion did not dismiss")
        shortcutModel.togglePresentation()
        let canceledClient = shortcutWorld.clients.last!
        check(canceledClient !== connectingClient, "new shortcut reused old session")
        canceledClient.partial("Discard while connecting.")
        shortcutModel.discardAndDismiss()
        shortcutModel.start()
        let finishingClient = shortcutWorld.clients.last!
        finishingClient.ready()
        finishingClient.committed("Discard during finalization.")
        shortcutModel.close()
        await settle()
        shortcutModel.discardAndDismiss()
        shortcutModel.start()
        finishingClient.succeed("Late canceled result.")
        canceledClient.partial("Late connecting words.")
        await settle()
        check(shortcutModel.isPresented && shortcutModel.capturing
                && shortcutModel.previewTranscript.isEmpty && shortcutWorld.copied.count == 1,
              "explicitly discarded result changed fresh dictation or copied text")
        shortcutModel.discardAndDismiss()

        for invalidation in ["reset", "discard", "clear", "cancel"] {
            let world = WorkflowWorld()
            let model = makeModel(world)
            await finish(model, with: "Old confirmation.", in: world)
            model.close()
            await settle()
            check(model.isShowingCopyConfirmation, "missing confirmation before invalidation")
            switch invalidation {
            case "reset": model.reset()
            case "discard": model.discardAndDismiss()
            case "clear": model.clearResult()
            default: model.cancel()
            }
            model.start()
            let before = world.copied
            world.releaseConfirmation()
            await settle()
            check(model.isPresented && model.capturing && world.copied == before,
                  "stale confirmation \(invalidation) dismissed or copied new recording")
            model.discardAndDismiss()
        }

        let startupShortcutWorld = WorkflowWorld()
        let startupShortcutModel = makeModel(startupShortcutWorld)
        startupShortcutWorld.onCredentialLoad = { startupShortcutModel.togglePresentation() }
        startupShortcutModel.togglePresentation()
        check(!startupShortcutModel.isPresented && startupShortcutWorld.microphoneStarts == 0,
              "shortcut close during credential access revived capture")

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
        check(closingModel.isPresented && closingModel.isShowingCopyConfirmation,
              "close skipped visible success acknowledgement")
        closingWorld.releaseConfirmation()
        await settle()
        check(closingModel.state == .idle && !closingModel.isPresented, "successful close did not dismiss")
        check(closingWorld.copied == ["Close segment."], "close did not copy before dismissal")

        let failingCloseWorld = WorkflowWorld(pasteboardResults: [false, true])
        let failingCloseModel = makeModel(failingCloseWorld)
        failingCloseModel.start()
        let failingCloseClient = failingCloseWorld.clients.last!
        failingCloseClient.committed("Recover stable text.")
        failingCloseModel.close()
        await settle()
        failingCloseClient.fail("Provider unavailable.")
        check(failingCloseModel.isPresented && failingCloseModel.isError
                && !failingCloseModel.isClosing && !failingCloseModel.isShowingCopyConfirmation,
              "failed finalization entered successful close")
        failingCloseClient.succeed("Late failed result.")
        await settle()
        failingCloseModel.close()
        check(failingCloseModel.isPresented && failingCloseModel.isError
                && !failingCloseModel.isShowingCopyConfirmation,
              "failed clipboard write entered successful close")
        failingCloseModel.copyResult()
        check(failingCloseModel.copySucceeded && !failingCloseModel.isClosing,
              "retry Copy failed to recover close error")
        failingCloseModel.close()
        await settle()
        check(failingCloseModel.isShowingCopyConfirmation, "explicit retry Close skipped acknowledgement")
        failingCloseWorld.releaseConfirmation()
        await settle()
        check(!failingCloseModel.isPresented, "recovered Close did not dismiss")

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
        pasteboard.clearContents()
        check(pasteboard.setString("Unrelated clipboard.", forType: .string), "private clipboard setup failed")
        nativeClipboardModel.close()
        check(pasteboard.string(forType: .string) == "Native first. Native second."
                && nativeClipboardModel.isShowingCopyConfirmation,
              "closing already-copied text failed to restore overwritten clipboard")
        await settle()
        nativeClipboardWorld.releaseConfirmation()
        await settle()
        nativeClipboardModel.start()
        nativeClipboardModel.discardAndDismiss()
        await verifyCleanup(settings: archiveSettings, directory: directory)
        await verifyCleanupAPIFailures(settings: archiveSettings, directory: directory)
        print("PASS close confirmation, recovery, private clipboard, cleanup/Undo persistence, lifecycle invalidation and stale results")
    }
}
