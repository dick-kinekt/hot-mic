import AppKit
import Darwin
import Foundation

@MainActor
private final class ArchiveClock {
    var current: Date

    init(_ current: Date) {
        self.current = current
    }

    func now() -> Date { current }
}

@main
@MainActor
struct TranscriptArchiveSmoke {
    private static let day: TimeInterval = 24 * 60 * 60

    static func check(_ condition: Bool, _ message: String) {
        guard condition else {
            print("FAIL \(message)")
            exit(1)
        }
    }

    static func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }

    static func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptArchiveSmoke.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        return root
    }

    static func makeDefaults() -> (UserDefaults, String) {
        let suite = "TranscriptArchiveSmoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    static func main() async {
        do {
            try await exercisePersistenceAndUpsert()
            try await exerciseRetentionPolicies()
            try exerciseOpenFailure()
        } catch {
            check(false, "archive smoke setup failed")
        }
    }

    private static func exercisePersistenceAndUpsert() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let clock = ArchiveClock(Date(timeIntervalSince1970: 1_800_000_000))
        let databaseURL = root.appendingPathComponent("transcripts.sqlite3")
        let settings = DictationSettings(defaults: defaults)
        let archive = TranscriptArchive(settings: settings, databaseURL: databaseURL, now: clock.now)
        let id = UUID()

        check(!archive.save(
            id: UUID(),
            startedAt: clock.current,
            updatedAt: clock.current,
            text: " \n ",
            duration: 0,
            language: nil,
            isIncomplete: false
        ), "empty transcript created an archive record")
        check(archive.sessions.isEmpty, "empty transcript changed the archive")

        check(archive.save(
            id: id,
            startedAt: clock.current.addingTimeInterval(-90),
            updatedAt: clock.current.addingTimeInterval(-30),
            text: "Initial durable transcript.",
            duration: 3,
            language: "en",
            isIncomplete: true
        ), "initial transcript was not saved")
        check(archive.save(
            id: id,
            startedAt: clock.current.addingTimeInterval(-90),
            updatedAt: clock.current,
            text: "Corrected durable transcript.",
            duration: 6,
            language: "en",
            isIncomplete: false
        ), "upsert transcript was not saved")
        check(archive.sessions.count == 1 && archive.sessions[0].id == id,
              "upsert created duplicate transcript summaries")
        check(archive.sessions[0].preview == "Corrected durable transcript.",
              "summary preview did not reflect the newest text")

        let permissions = try FileManager.default.attributesOfItem(atPath: databaseURL.path)[.posixPermissions] as? NSNumber
        check(permissions.map { $0.intValue & 0o077 == 0 } == true,
              "database is readable by group or other users")

        archive.shutdown()
        let reopened = TranscriptArchive(settings: settings, databaseURL: databaseURL, now: clock.now)
        defer { reopened.shutdown() }
        check(reopened.sessions.count == 1 && reopened.sessions[0].id == id,
              "reopened archive lost the saved summary")
        check(reopened.text(for: id) == "Corrected durable transcript.",
              "reopened archive did not load selected transcript text")
    }

    private static func exerciseRetentionPolicies() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let clock = ArchiveClock(Date(timeIntervalSince1970: 1_810_000_000))
        let databaseURL = root.appendingPathComponent("transcripts.sqlite3")
        let settings = DictationSettings(defaults: defaults)
        let archive = TranscriptArchive(settings: settings, databaseURL: databaseURL, now: clock.now)
        defer { archive.shutdown() }

        let recentlyUpdatedID = UUID()
        check(archive.save(
            id: recentlyUpdatedID,
            startedAt: clock.current.addingTimeInterval(-30 * day),
            updatedAt: clock.current.addingTimeInterval(-day),
            text: "A long session with a recent update.",
            duration: 24,
            language: "nl",
            isIncomplete: false
        ), "recently updated transcript was not saved")
        check(archive.sessions.contains(where: { $0.id == recentlyUpdatedID }),
              "retention used startedAt instead of updatedAt")

        let boundaryID = UUID()
        check(archive.save(
            id: boundaryID,
            startedAt: clock.current.addingTimeInterval(-14 * day),
            updatedAt: clock.current.addingTimeInterval(-14 * day + 1),
            text: "Boundary retention transcript.",
            duration: 1,
            language: nil,
            isIncomplete: false
        ), "boundary transcript was not saved")
        check(archive.sessions.contains(where: { $0.id == boundaryID }),
              "transcript expired before fourteen elapsed days")

        clock.current = clock.current.addingTimeInterval(1)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await settle()
        check(!archive.sessions.contains(where: { $0.id == boundaryID }),
              "activation did not prune a transcript at the fourteen-day boundary")

        let settingsChangeID = UUID()
        check(archive.save(
            id: settingsChangeID,
            startedAt: clock.current.addingTimeInterval(-8 * day),
            updatedAt: clock.current.addingTimeInterval(-8 * day),
            text: "Policy-change transcript.",
            duration: 2,
            language: nil,
            isIncomplete: false
        ), "policy-change transcript was not saved")
        check(archive.sessions.contains(where: { $0.id == settingsChangeID }),
              "default fourteen-day policy pruned an eight-day transcript")

        settings.transcriptRetentionDays = 7
        await settle()
        check(!archive.sessions.contains(where: { $0.id == settingsChangeID }),
              "retention policy change did not prune immediately")

        settings.transcriptRetentionDays = 3_650
        await settle()
        check(archive.text(for: boundaryID) == nil && archive.text(for: settingsChangeID) == nil,
              "expired transcripts reappeared when retention increased")
        settings.transcriptRetentionDays = 7
        await settle()

        let reloadedSettings = DictationSettings(defaults: defaults)
        check(reloadedSettings.transcriptRetentionDays == 7,
              "retention policy was not persisted for restart")
        reloadedSettings.transcriptRetentionDays = 0
        check(reloadedSettings.transcriptRetentionDays == 1,
              "retention policy did not clamp to its minimum")
        reloadedSettings.transcriptRetentionDays = 9_999
        check(reloadedSettings.transcriptRetentionDays == 3_650,
              "retention policy did not clamp to its maximum")
    }

    private static func exerciseOpenFailure() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let databaseURL = root.appendingPathComponent("transcripts.sqlite3")
        let original = Data("not a sqlite database".utf8)
        try original.write(to: databaseURL, options: .atomic)

        let archive = TranscriptArchive(settings: DictationSettings(defaults: defaults), databaseURL: databaseURL)
        defer { archive.shutdown() }
        check(archive.errorMessage != nil, "corrupt archive was not surfaced to the user")
        check(try Data(contentsOf: databaseURL) == original,
              "open failure overwrote the existing archive")
    }
}
