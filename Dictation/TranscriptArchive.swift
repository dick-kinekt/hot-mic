import AppKit
import Combine
import Foundation
import SQLite3

struct TranscriptSummary: Identifiable, Equatable {
    let id: UUID
    let startedAt: Date
    let updatedAt: Date
    let preview: String
    let duration: Double
    let language: String?
    let isIncomplete: Bool
}

@MainActor
final class TranscriptArchive: ObservableObject {
    @Published private(set) var sessions: [TranscriptSummary] = []
    @Published private(set) var errorMessage: String?

    private enum Failure {
        case opening
        case reading
        case writing
    }

    private static let previewCharacterLimit = 240
    private static let pruningInterval: TimeInterval = 60

    private let settings: DictationSettings
    private let databaseURL: URL?
    private let now: () -> Date
    private let fileManager: FileManager

    private var database: OpaquePointer?
    private var retentionObserver: AnyCancellable?
    private var lifecycleObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var pruningTimer: Timer?
    private var isShutdown = false
    private var summariesLoaded = false

    init(
        settings: DictationSettings,
        databaseURL: URL? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.settings = settings
        self.databaseURL = databaseURL ?? Self.defaultDatabaseURL()
        self.now = now
        self.fileManager = .default

        retentionObserver = settings.$transcriptRetentionDays
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.pruneExpired()
                }
            }

        installLifecycleObservers()
        startPruningTimer()

        guard openDatabaseIfNeeded() else { return }
        pruneExpired()
    }

    func save(
        id: UUID,
        startedAt: Date,
        updatedAt: Date,
        text: String,
        duration: Double,
        language: String?,
        isIncomplete: Bool
    ) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard openDatabaseIfNeeded() else { return false }

        let saved = performWrite {
            self.upsert(
                id: id,
                startedAt: startedAt,
                updatedAt: updatedAt,
                text: text,
                duration: duration,
                language: language,
                isIncomplete: isIncomplete
            ) && self.deleteExpiredRecords()
        }
        if !saved { invalidateSummaries() }
        return saved
    }

    func text(for id: UUID) -> String? {
        guard pruneExpiredRecords() else { return nil }
        guard openDatabaseIfNeeded(), let statement = prepare("""
            SELECT text
            FROM transcript_sessions
            WHERE id = ?
            LIMIT 1;
            """) else {
            report(.reading)
            return nil
        }
        defer { sqlite3_finalize(statement) }

        guard bind(id.uuidString.lowercased(), to: statement, at: 1) else {
            report(.reading)
            return nil
        }

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            guard let text = columnText(statement, at: 0) else {
                report(.reading)
                return nil
            }
            clearError()
            return text
        case SQLITE_DONE:
            clearError()
            return nil
        default:
            report(.reading)
            return nil
        }
    }

    func pruneExpired() {
        _ = pruneExpiredRecords()
    }

    private func pruneExpiredRecords() -> Bool {
        guard openDatabaseIfNeeded() else { return false }
        guard let hasExpiredRecords = hasExpiredRecords() else {
            report(.reading)
            return false
        }
        guard hasExpiredRecords else {
            guard !summariesLoaded else {
                clearError()
                return true
            }
            return reloadSummaries()
        }
        let pruned = performWrite { self.deleteExpiredRecords() }
        if !pruned { invalidateSummaries() }
        return pruned
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true

        retentionObserver?.cancel()
        retentionObserver = nil
        pruningTimer?.invalidate()
        pruningTimer = nil
        for (center, observer) in lifecycleObservers {
            center.removeObserver(observer)
        }
        lifecycleObservers.removeAll()
        closeDatabase()
    }

    private static func defaultDatabaseURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Hot Mic", isDirectory: true)
            .appendingPathComponent("transcripts.sqlite3", isDirectory: false)
    }

    private func installLifecycleObservers() {
        let activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pruneExpired()
            }
        }
        lifecycleObservers.append((.default, activationObserver))

        let wakeCenter = NSWorkspace.shared.notificationCenter
        let wakeObserver = wakeCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pruneExpired()
            }
        }
        lifecycleObservers.append((wakeCenter, wakeObserver))
    }

    private func startPruningTimer() {
        let timer = Timer(timeInterval: Self.pruningInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pruneExpired()
            }
        }
        pruningTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func openDatabaseIfNeeded() -> Bool {
        guard !isShutdown else { return false }
        if database != nil { return true }
        guard let databaseURL else {
            report(.opening)
            return false
        }

        do {
            try createPrivateDirectory(containing: databaseURL)
        } catch {
            report(.opening)
            return false
        }

        var openedDatabase: OpaquePointer?
        let status = sqlite3_open_v2(
            databaseURL.path,
            &openedDatabase,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard status == SQLITE_OK, let openedDatabase else {
            if let openedDatabase {
                sqlite3_close_v2(openedDatabase)
            }
            report(.opening)
            return false
        }

        database = openedDatabase
        guard configureDatabase() else {
            closeDatabase()
            report(.opening)
            return false
        }

        do {
            try secureDatabaseFiles()
        } catch {
            closeDatabase()
            report(.opening)
            return false
        }

        clearError()
        return true
    }

    private func configureDatabase() -> Bool {
        guard execute("PRAGMA foreign_keys = ON;"),
              let journalMode = singleText("PRAGMA journal_mode = WAL;"),
              journalMode.caseInsensitiveCompare("wal") == .orderedSame,
              execute("PRAGMA synchronous = FULL;"),
              singleText("PRAGMA quick_check;") == "ok",
              execute("""
                CREATE TABLE IF NOT EXISTS transcript_sessions (
                    id TEXT PRIMARY KEY NOT NULL,
                    started_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    text TEXT NOT NULL,
                    duration REAL NOT NULL,
                    language TEXT,
                    is_incomplete INTEGER NOT NULL CHECK (is_incomplete IN (0, 1))
                );
                """),
              execute("""
                CREATE INDEX IF NOT EXISTS transcript_sessions_updated_at
                ON transcript_sessions(updated_at DESC);
                """) else {
            return false
        }
        return true
    }

    private func createPrivateDirectory(containing databaseURL: URL) throws {
        let directory = databaseURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw CocoaError(.fileWriteFileExists)
            }
        } else {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        }
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: directory.path)
    }

    private func secureDatabaseFiles() throws {
        guard let databaseURL else { return }
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let path = databaseURL.path + suffix
            guard fileManager.fileExists(atPath: path) else { continue }
            try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: path)
        }
    }

    private func closeDatabase() {
        guard let database else { return }
        self.database = nil
        sqlite3_close_v2(database)
    }

    private func performWrite(_ operation: () -> Bool) -> Bool {
        guard execute("BEGIN IMMEDIATE TRANSACTION;") else {
            report(.writing)
            return false
        }
        guard operation() else {
            _ = execute("ROLLBACK;")
            report(.writing)
            return false
        }
        guard execute("COMMIT;") else {
            _ = execute("ROLLBACK;")
            report(.writing)
            return false
        }

        do {
            try secureDatabaseFiles()
        } catch {
            invalidateSummaries()
            report(.writing)
            return false
        }
        return reloadSummaries()
    }

    private func upsert(
        id: UUID,
        startedAt: Date,
        updatedAt: Date,
        text: String,
        duration: Double,
        language: String?,
        isIncomplete: Bool
    ) -> Bool {
        guard let statement = prepare("""
            INSERT INTO transcript_sessions (
                id, started_at, updated_at, text, duration, language, is_incomplete
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                updated_at = excluded.updated_at,
                text = excluded.text,
                duration = excluded.duration,
                language = excluded.language,
                is_incomplete = excluded.is_incomplete;
            """) else {
            return false
        }
        defer { sqlite3_finalize(statement) }

        guard bind(id.uuidString.lowercased(), to: statement, at: 1),
              bind(startedAt.timeIntervalSince1970, to: statement, at: 2),
              bind(updatedAt.timeIntervalSince1970, to: statement, at: 3),
              bind(text, to: statement, at: 4),
              bind(duration, to: statement, at: 5),
              bind(language, to: statement, at: 6),
              bind(Int32(isIncomplete ? 1 : 0), to: statement, at: 7) else {
            return false
        }
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func hasExpiredRecords() -> Bool? {
        guard let statement = prepare("""
            SELECT EXISTS(
                SELECT 1
                FROM transcript_sessions
                WHERE updated_at <= ?
            );
            """) else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        let retention = TimeInterval(settings.transcriptRetentionDays) * 24 * 60 * 60
        guard bind(now().addingTimeInterval(-retention).timeIntervalSince1970, to: statement, at: 1),
              sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        return sqlite3_column_int(statement, 0) != 0
    }

    private func deleteExpiredRecords() -> Bool {
        guard let statement = prepare("DELETE FROM transcript_sessions WHERE updated_at <= ?;") else {
            return false
        }
        defer { sqlite3_finalize(statement) }

        let retention = TimeInterval(settings.transcriptRetentionDays) * 24 * 60 * 60
        guard bind(now().addingTimeInterval(-retention).timeIntervalSince1970, to: statement, at: 1) else {
            return false
        }
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func reloadSummaries() -> Bool {
        summariesLoaded = false
        guard let statement = prepare("""
            SELECT
                id,
                started_at,
                updated_at,
                substr(text, 1, 241),
                duration,
                language,
                is_incomplete
            FROM transcript_sessions
            ORDER BY updated_at DESC, id DESC;
            """) else {
            return reportReadFailure()
        }
        defer { sqlite3_finalize(statement) }

        var loaded: [TranscriptSummary] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let storedID = columnText(statement, at: 0),
                      let id = UUID(uuidString: storedID),
                      let previewPrefix = columnText(statement, at: 3) else {
                    return reportReadFailure()
                }
                let language = columnText(statement, at: 5)
                loaded.append(
                    TranscriptSummary(
                        id: id,
                        startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                        updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                        preview: Self.preview(from: previewPrefix),
                        duration: sqlite3_column_double(statement, 4),
                        language: language,
                        isIncomplete: sqlite3_column_int(statement, 6) != 0
                    )
                )
            case SQLITE_DONE:
                replaceSessions(with: loaded)
                summariesLoaded = true
                clearError()
                return true
            default:
                return reportReadFailure()
            }
        }
    }

    private func reportReadFailure() -> Bool {
        invalidateSummaries()
        report(.reading)
        return false
    }

    private func replaceSessions(with replacement: [TranscriptSummary]) {
        guard sessions != replacement else { return }
        sessions = replacement
    }

    private func invalidateSummaries() {
        summariesLoaded = false
        replaceSessions(with: [])
    }

    private func clearError() {
        guard errorMessage != nil else { return }
        errorMessage = nil
    }

    private static func preview(from prefix: String) -> String {
        let truncated = prefix.count > previewCharacterLimit
        let visiblePrefix = truncated ? String(prefix.dropLast()) : prefix
        let normalized = visiblePrefix
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        return truncated ? normalized + "…" : normalized
    }

    private func execute(_ statement: String) -> Bool {
        guard let database else { return false }
        return sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK
    }

    private func singleText(_ query: String) -> String? {
        guard let statement = prepare(query) else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return columnText(statement, at: 0)
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        guard let database else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        return statement
    }

    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) -> Bool {
        value.withCString {
            sqlite3_bind_text(statement, index, $0, -1, sqliteTransientDestructor()) == SQLITE_OK
        }
    }

    private func bind(_ value: String?, to statement: OpaquePointer, at index: Int32) -> Bool {
        guard let value else {
            return sqlite3_bind_null(statement, index) == SQLITE_OK
        }
        return bind(value, to: statement, at: index)
    }

    private func bind(_ value: Double, to statement: OpaquePointer, at index: Int32) -> Bool {
        sqlite3_bind_double(statement, index, value) == SQLITE_OK
    }

    private func bind(_ value: Int32, to statement: OpaquePointer, at index: Int32) -> Bool {
        sqlite3_bind_int(statement, index, value) == SQLITE_OK
    }

    private func columnText(_ statement: OpaquePointer, at index: Int32) -> String? {
        guard let bytes = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: bytes)
    }

    private func report(_ failure: Failure) {
        let message: String
        switch failure {
        case .opening:
            message = "Transcript archive could not be opened."
        case .reading:
            message = "Transcript archive could not be read."
        case .writing:
            message = "Transcript archive could not be saved."
        }
        guard errorMessage != message else { return }
        errorMessage = message
    }
}

private func sqliteTransientDestructor() -> sqlite3_destructor_type {
    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
