import Foundation
import GRDB
import OpenIslandCore

public struct BackupPreview: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let sourceName: String
    public let tasks: Int
    public let sessions: Int
    public let notes: Int
    public let criteria: Int
    public let pomodoros: Int
    public let preparedURL: URL
}

public enum FocusBackupError: LocalizedError {
    case unavailable, incompatible, invalid, protectedDestination

    public var errorDescription: String? {
        switch self {
        case .unavailable: L10n.tr("backup.unavailable")
        case .incompatible: L10n.tr("backup.incompatible")
        case .invalid: L10n.tr("backup.invalid")
        case .protectedDestination: L10n.tr("backup.protected_destination")
        }
    }
}

public struct FocusBackups: Sendable {
    public let store: FocusStore
    public let databaseURL: URL
    public var directory: URL { databaseURL.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true) }
    private var pendingURL: URL { Self.pendingURL(for: databaseURL) }

    public init(store: FocusStore) throws {
        guard store.dbQueue.path != ":memory:" else { throw FocusBackupError.unavailable }
        self.store = store
        databaseURL = URL(fileURLWithPath: store.dbQueue.path)
    }

    public func latestBackupDate() throws -> Date? {
        try backupFiles().compactMap { try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
    }

    @discardableResult
    public func create(now: Date = .now) throws -> URL {
        try ensureDirectory()
        let url = directory.appendingPathComponent("manual-\(Int(now.timeIntervalSince1970))-\(UUID().uuidString).sqlite")
        try Self.copy(store.dbQueue, to: url)
        return url
    }

    public func daily(now: Date = .now) throws {
        try ensureDirectory()
        let day = Int(now.timeIntervalSince1970 / 86_400)
        let url = directory.appendingPathComponent("daily-\(day).sqlite")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        // Publish only a complete snapshot; an interrupted copy must not suppress tomorrow's backup.
        let temporary = directory.appendingPathComponent(".daily-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Self.copy(store.dbQueue, to: temporary)
        try FileManager.default.moveItem(at: temporary, to: url)
        let daily = try backupFiles().filter { $0.lastPathComponent.hasPrefix("daily-") }.sorted {
            $0.lastPathComponent > $1.lastPathComponent
        }
        for expired in daily.dropFirst(7) { try FileManager.default.removeItem(at: expired) }
    }

    public func export(to destination: URL) throws {
        let target = destination.resolvingSymlinksInPath().standardizedFileURL.path
        let protected = [databaseURL, databaseURL.appendingPathExtension("pending-restore.sqlite"),
            URL(fileURLWithPath: databaseURL.path + "-wal"), URL(fileURLWithPath: databaseURL.path + "-shm")]
        guard !protected.contains(where: { $0.resolvingSymlinksInPath().standardizedFileURL.path == target }) else {
            throw FocusBackupError.protectedDestination
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".focus-export-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Self.copy(store.dbQueue, to: temporary)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }

    public func preview(_ source: URL) throws -> BackupPreview {
        try ensureDirectory()
        let id = UUID()
        let prepared = directory.appendingPathComponent(".preview-\(id.uuidString).sqlite")
        do {
            let input = try Self.readOnly(source)
            defer { try? input.close() }
            try Self.validate(input)
            try Self.copy(input, to: prepared)
            let candidate = try DatabaseQueue(path: prepared.path)
            defer { try? candidate.close() }
            try FocusStore.migrator(upTo: nil).migrate(candidate)
            try Self.validate(candidate)
            return try candidate.read { db in
                BackupPreview(id: id, sourceName: source.lastPathComponent,
                    tasks: try Int.fetchOne(db, sql: "SELECT count(*) FROM tasks") ?? 0,
                    sessions: try Int.fetchOne(db, sql: "SELECT count(*) FROM sessions") ?? 0,
                    notes: try Int.fetchOne(db, sql: "SELECT count(*) FROM tasks WHERE note IS NOT NULL AND trim(note) != ''") ?? 0,
                    criteria: try Int.fetchOne(db, sql: "SELECT count(*) FROM task_criteria") ?? 0,
                    pomodoros: try Int.fetchOne(db, sql: "SELECT count(*) FROM pomodoros") ?? 0, preparedURL: prepared)
            }
        } catch {
            try? FileManager.default.removeItem(at: prepared)
            throw error
        }
    }

    public func discard(_ preview: BackupPreview) {
        guard preview.preparedURL.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
              preview.preparedURL.lastPathComponent == ".preview-\(preview.id.uuidString).sqlite" else { return }
        try? FileManager.default.removeItem(at: preview.preparedURL)
    }

    public func stage(_ preview: BackupPreview) throws {
        guard preview.preparedURL.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
              preview.preparedURL.lastPathComponent == ".preview-\(preview.id.uuidString).sqlite" else { throw FocusBackupError.invalid }
        let candidate = try Self.readOnly(preview.preparedURL)
        try Self.validate(candidate)
        try candidate.close()
        guard !FileManager.default.fileExists(atPath: pendingURL.path) else { throw FocusBackupError.protectedDestination }
        try FileManager.default.moveItem(at: preview.preparedURL, to: pendingURL)
    }

    // Run before services open the database. SQLite's backup transaction replaces all tables together.
    static func applyPending(to queue: DatabaseQueue, databaseURL: URL) -> String? {
        let pending = pendingURL(for: databaseURL)
        guard FileManager.default.fileExists(atPath: pending.path) else { return nil }
        let directory = databaseURL.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
        let consumed = directory.appendingPathComponent("restore-input-\(UUID().uuidString).sqlite")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Consume first so a crash or cleanup failure cannot replay an old restore over new work.
            try FileManager.default.moveItem(at: pending, to: consumed)
            let input = try readOnly(consumed)
            defer { try? input.close() }
            try validate(input)
            let safety = directory.appendingPathComponent("before-restore-\(Int(Date.now.timeIntervalSince1970))-\(UUID().uuidString).sqlite")
            try copy(queue, to: safety)
            try input.backup(to: queue)
        } catch {
            return L10n.tr("backup.restore_failed", error.localizedDescription)
        }
        return nil
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    private func backupFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "sqlite" && !$0.lastPathComponent.hasPrefix("restore-input-") }
    }

    private static func pendingURL(for database: URL) -> URL { database.appendingPathExtension("pending-restore.sqlite") }

    private static func readOnly(_ url: URL) throws -> DatabaseQueue {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw FocusBackupError.invalid }
        var config = Configuration()
        config.readonly = true
        return try DatabaseQueue(path: url.path, configuration: config)
    }

    private static func copy(_ source: DatabaseQueue, to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw FocusBackupError.protectedDestination }
        let destination = try DatabaseQueue(path: url.path)
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try source.backup(to: destination)
            // A portable snapshot must not depend on WAL/SHM sidecars from an open source.
            try destination.writeWithoutTransaction { try $0.execute(sql: "PRAGMA journal_mode = DELETE") }
            try destination.close()
        } catch {
            try? destination.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private static func validate(_ queue: DatabaseQueue) throws {
        let versions = FocusStore.migrator(upTo: nil).migrations
        let applied = try queue.read { db -> [String] in
            guard try db.tableExists("grdb_migrations"),
                  try String.fetchAll(db, sql: "PRAGMA quick_check") == ["ok"],
                  try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty else { throw FocusBackupError.invalid }
            return try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
        guard !applied.isEmpty, Set(applied) == Set(versions.prefix(applied.count)) else { throw FocusBackupError.incompatible }
        let expected = try DatabaseQueue()
        defer { try? expected.close() }
        try FocusStore.migrator(upTo: versions[applied.count - 1]).migrate(expected)
        // A migration ledger alone does not prove the file is a Focus Island database.
        // Check every table/index and reject injected triggers/views before executing migrations.
        let sql = "SELECT type || '|' || name || '|' || coalesce(sql, '') FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name"
        let actualSchema = try queue.read { try String.fetchAll($0, sql: sql) }
        let expectedSchema = try expected.read { try String.fetchAll($0, sql: sql) }
        guard actualSchema == expectedSchema else { throw FocusBackupError.incompatible }
    }
}
