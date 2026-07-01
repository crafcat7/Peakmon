//
//  HistoryStore.swift
//  PeakmonCore
//
//  Local history store for bounded history and bucketed aggregates.
//

import Foundation
import SQLite3

private let sqliteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private struct PersistedHistoryStore: Codable {
    let version: Int
    let savedAt: Date
    let ranges: [PersistedHistoryRange]
}

private struct PersistedHistoryRange: Codable {
    let range: HistoryRange
    let buckets: [MetricHistoryBucket]
}

private struct PersistedHistoryIncrement: Codable {
    let version: Int
    let savedAt: Date
    let records: [HistoryBucketRecord]
}

private struct LegacyHistoryLoadResult {
    var buckets: HistoryBucketMap
    var processedPayload: Bool
}

private enum SQLiteHistoryError: Error {
    case unavailable
    case operationFailed(String)
}

private final class SQLiteConnection: @unchecked Sendable {
    private(set) var pointer: OpaquePointer?

    init(_ pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        close()
    }

    func close() {
        if let pointer {
            sqlite3_close(pointer)
            self.pointer = nil
        }
    }
}

/// Storage policy for local diagnostic history.
///
/// The policy separates logical retention from physical SQLite maintenance:
/// history data is trimmed by time window, while the WAL and main database
/// files are compacted on a lower-frequency cadence to avoid extra writes on
/// every sample batch.
public struct HistoryStoragePolicy: Hashable, Sendable {
    public static let standard = HistoryStoragePolicy()

    public let saveInterval: TimeInterval
    public let maximumRetentionDuration: TimeInterval
    public let maintenanceInterval: TimeInterval
    public let inMemoryPruneInterval: TimeInterval
    public let walByteLimit: Int64
    public let databaseByteLimit: Int64
    public let vacuumInterval: TimeInterval

    public init(
        saveInterval: TimeInterval = 60,
        maximumRetentionDuration: TimeInterval = HistoryRange.maximumDuration,
        maintenanceInterval: TimeInterval = 15 * 60,
        inMemoryPruneInterval: TimeInterval = 10,
        walByteLimit: Int64 = 16 * 1024 * 1024,
        databaseByteLimit: Int64 = 64 * 1024 * 1024,
        vacuumInterval: TimeInterval = 6 * 60 * 60,
    ) {
        self.saveInterval = max(0, saveInterval)
        self.maximumRetentionDuration = max(HistoryRange.oneHour.bucketInterval, maximumRetentionDuration)
        self.maintenanceInterval = max(0, maintenanceInterval)
        self.inMemoryPruneInterval = max(0, inMemoryPruneInterval)
        self.walByteLimit = max(0, walByteLimit)
        self.databaseByteLimit = max(0, databaseByteLimit)
        self.vacuumInterval = max(0, vacuumInterval)
    }
}

/// Stores bounded local history for `1h / 6h / 24h` chart queries.
///
/// All ranges are held as aggregate buckets, including the 1-hour view.
/// That keeps the history layer time-based rather than sample-count-based:
/// a 0.5 s sampling interval still covers the last hour instead of only the
/// last 3600 raw samples.
public actor HistoryStore {
    private enum Persistence {
        static let snapshotVersion = 2
        static let legacySnapshotVersion = 1
        static let incrementVersion = 1
    }

    private enum Database {
        static let schemaVersion = 1
        static let timestampScale = 1_000_000.0
    }

    private var aggregation = HistoryBucketAggregation()
    private let databaseURL: URL?
    private let legacyPersistenceURL: URL?
    private let legacyLogURL: URL?
    private let storagePolicy: HistoryStoragePolicy
    private let retainedKinds: Set<MetricKind>?
    private var lastPersistedAt: Date?
    private var lastPrunedDatabaseAt: Date?
    private var lastCheckpointedDatabaseAt: Date?
    private var lastVacuumedDatabaseAt: Date?
    private var database: SQLiteConnection?
    private var didLoadPersistence = false

    public init(
        persistenceURL: URL? = nil,
        storagePolicy: HistoryStoragePolicy = .standard,
        retainedKinds: Set<MetricKind>? = nil,
    ) {
        self.databaseURL = persistenceURL.map(Self.databaseURL(for:))
        self.legacyPersistenceURL = persistenceURL.map(Self.legacySnapshotURL(for:))
        self.legacyLogURL = persistenceURL.map { Self.legacySnapshotURL(for: $0).appendingPathExtension("log") }
        self.storagePolicy = storagePolicy
        self.retainedKinds = retainedKinds
    }

    public init(
        persistenceURL: URL? = nil,
        persistenceSaveInterval: TimeInterval,
        persistenceCompactionInterval: TimeInterval = HistoryStoragePolicy.standard.maintenanceInterval,
        persistenceCompactionLogByteLimit: Int64 = HistoryStoragePolicy.standard.walByteLimit,
        persistenceDatabaseByteLimit: Int64 = HistoryStoragePolicy.standard.databaseByteLimit,
        persistenceVacuumInterval: TimeInterval = HistoryStoragePolicy.standard.vacuumInterval,
        retainedKinds: Set<MetricKind>? = nil,
    ) {
        self.init(
            persistenceURL: persistenceURL,
            storagePolicy: HistoryStoragePolicy(
                saveInterval: persistenceSaveInterval,
                maximumRetentionDuration: HistoryRange.maximumDuration,
                maintenanceInterval: persistenceCompactionInterval,
                walByteLimit: persistenceCompactionLogByteLimit,
                databaseByteLimit: persistenceDatabaseByteLimit,
                vacuumInterval: persistenceVacuumInterval,
            ),
            retainedKinds: retainedKinds,
        )
    }

    /// Append sample batch into local history.
    ///
    /// Values that are NaN or infinite are ignored.
    public func ingest(_ samples: [MetricSample]) {
        ingestPrepared(
            samples
                .filter { $0.value.isFinite }
                .sorted { $0.timestamp < $1.timestamp },
        )
    }

    /// Append samples that have already been filtered to finite values and
    /// sorted by timestamp.
    func ingestPrepared(_ orderedSamples: [MetricSample]) {
        ensurePersistenceLoaded()

        guard let now = aggregation.ingest(orderedSamples) else { return }
        pruneBucketsIfNeeded(at: now, force: false)
        schedulePersistence(at: now)
    }

    /// Return buckets for a given query range.
    ///
    /// - Parameters:
    ///   - kind: Optional kind filter.
    ///   - unit: Optional unit filter.
    ///   - range: 1h / 6h / 24h.
    ///   - now: Query horizon; injected for deterministic tests.
    public func buckets(
        for kind: MetricKind? = nil,
        unit: MetricUnit? = nil,
        range: HistoryRange,
        now: Date = .now,
    ) -> [MetricHistoryBucket] {
        ensurePersistenceLoaded()

        return aggregation.buckets(
            for: kind,
            unit: unit,
            range: range,
            now: now,
            maximumRetentionDuration: storagePolicy.maximumRetentionDuration,
        )
    }

    /// Clears all in-memory buckets for deterministic tests and
    /// controlled startup behavior.
    public func reset() {
        ensurePersistenceLoaded()

        aggregation.reset()
        lastPersistedAt = nil
        lastPrunedDatabaseAt = nil
        lastCheckpointedDatabaseAt = nil
        lastVacuumedDatabaseAt = nil
        removePersistedFile()
    }

    /// Persist any pending bucket changes immediately.
    public func flush() {
        ensurePersistenceLoaded()
        persistIfNeeded(at: .now, force: true)
    }

    private func ensurePersistenceLoaded() {
        guard !didLoadPersistence else { return }
        didLoadPersistence = true

        guard let databaseURL else { return }
        configureDatabase(at: databaseURL)
        if database != nil {
            let now = Date()
            aggregation.replaceBuckets(loadDatabaseBuckets(now: now))
            migrateLegacyIfNeeded(now: now)
        } else if let legacyPersistenceURL, let legacyLogURL {
            aggregation.replaceBuckets(Self.loadLegacyBuckets(
                from: legacyPersistenceURL,
                logURL: legacyLogURL,
                maximumRetentionDuration: storagePolicy.maximumRetentionDuration,
                retainedKinds: retainedKinds,
            ).buckets)
        }
    }

    private func pruneBucketsIfNeeded(at now: Date, force: Bool) {
        aggregation.pruneIfNeeded(
            at: now,
            maximumRetentionDuration: storagePolicy.maximumRetentionDuration,
            interval: storagePolicy.inMemoryPruneInterval,
            force: force,
        )
    }

    private func schedulePersistence(at _: Date) {
        guard database != nil else { return }
        persistIfNeeded(at: Date(), force: false)
    }

    private func persistIfNeeded(at now: Date, force: Bool) {
        guard database != nil else { return }
        if force {
            pruneBucketsIfNeeded(at: now, force: true)
            guard hasDirtyBuckets() else {
                maintainDatabaseAfterForcedFlush(at: now)
                return
            }
        } else {
            guard hasDirtyBuckets() else { return }
        }
        if !force, let lastPersistedAt, now.timeIntervalSince(lastPersistedAt) < storagePolicy.saveInterval {
            return
        }

        pruneBucketsIfNeeded(at: now, force: force)
        let records = dirtyBucketRecords()
        guard !records.isEmpty else { return }
        persistDirtyBuckets(records, at: now, forceMaintenance: force)
    }

    private func maintainDatabaseAfterForcedFlush(at now: Date) {
        do {
            try pruneDatabase(at: now)
            try maintainDatabaseStorage(at: now, force: true)
        } catch {
            // Persistence is best-effort; history remains queryable from memory.
        }
    }

    private func dirtyBucketRecords() -> [HistoryBucketRecord] {
        aggregation.dirtyRecords()
    }

    private func hasDirtyBuckets() -> Bool {
        aggregation.hasDirtyBuckets()
    }

    private func allBucketRecords() -> [HistoryBucketRecord] {
        aggregation.allRecords()
    }

    private func persistDirtyBuckets(
        _ records: [HistoryBucketRecord],
        at now: Date,
        forceMaintenance: Bool,
    ) {
        do {
            try persist(records, updatedAt: now, forceMaintenance: forceMaintenance)
            aggregation.clearDirtyBuckets()
            lastPersistedAt = now
        } catch {
            // Persistence is best-effort; in-memory history remains the source of truth.
        }
    }

    @discardableResult
    private func persistAllBucketsToDatabase(at now: Date) -> Bool {
        do {
            try persist(allBucketRecords(), updatedAt: now, forceMaintenance: true)
            aggregation.clearDirtyBuckets()
            lastPersistedAt = now
            return true
        } catch {
            return false
        }
    }

    private func persist(
        _ records: [HistoryBucketRecord],
        updatedAt: Date,
        forceMaintenance: Bool,
    ) throws {
        guard database != nil else { throw SQLiteHistoryError.unavailable }

        do {
            try execute("BEGIN IMMEDIATE TRANSACTION;")
            try upsert(records, updatedAt: updatedAt)
            if shouldPruneDatabase(at: updatedAt, force: forceMaintenance) {
                try pruneDatabase(at: updatedAt)
            }
            try execute("COMMIT TRANSACTION;")
        } catch {
            try? execute("ROLLBACK TRANSACTION;")
            throw error
        }

        try? maintainDatabaseStorage(at: updatedAt, force: forceMaintenance)
    }

    private func upsert(_ records: [HistoryBucketRecord], updatedAt: Date) throws {
        guard !records.isEmpty else { return }
        let sql = """
        INSERT INTO history_buckets (
            range, kind, unit, resolution, start_date, min, avg, max, last, last_sample_date, count, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(range, kind, unit, start_date) DO UPDATE SET
            resolution = excluded.resolution,
            min = excluded.min,
            avg = excluded.avg,
            max = excluded.max,
            last = excluded.last,
            last_sample_date = excluded.last_sample_date,
            count = excluded.count,
            updated_at = excluded.updated_at
        ;
        """
        let statement = try prepare(sql)
        defer {
            sqlite3_finalize(statement)
        }

        let updatedTimestamp = Self.databaseTimestamp(for: updatedAt)
        for record in records {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)

            try bind(record.range.rawValue, to: statement, at: 1)
            try bind(record.bucket.kind.rawValue, to: statement, at: 2)
            try bind(record.bucket.unit.rawValue, to: statement, at: 3)
            try bind(record.bucket.resolution, to: statement, at: 4)
            try bind(Self.databaseTimestamp(for: record.bucket.startDate), to: statement, at: 5)
            try bind(record.bucket.min, to: statement, at: 6)
            try bind(record.bucket.avg, to: statement, at: 7)
            try bind(record.bucket.max, to: statement, at: 8)
            try bind(record.bucket.last, to: statement, at: 9)
            try bind(Self.databaseTimestamp(for: record.bucket.lastSampleDate), to: statement, at: 10)
            try bind(Int64(record.bucket.count), to: statement, at: 11)
            try bind(updatedTimestamp, to: statement, at: 12)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw SQLiteHistoryError.operationFailed(lastSQLiteErrorMessage())
            }
        }
    }

    private func configureDatabase(at url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            var pointer: OpaquePointer?
            let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
            guard sqlite3_open_v2(url.path, &pointer, flags, nil) == SQLITE_OK, let opened = pointer else {
                let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open SQLite database"
                if let pointer {
                    sqlite3_close(pointer)
                }
                throw SQLiteHistoryError.operationFailed(message)
            }

            database = SQLiteConnection(opened)
            try execute("PRAGMA busy_timeout = 1000;")
            try execute("PRAGMA journal_mode = WAL;")
            try execute("PRAGMA synchronous = NORMAL;")
            try execute("PRAGMA temp_store = MEMORY;")
            try execute("PRAGMA wal_autocheckpoint = \(walAutoCheckpointPageCount());")
            try createSchema()
        } catch {
            database?.close()
            database = nil
        }
    }

    private func createSchema() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS history_buckets (
            range TEXT NOT NULL,
            kind TEXT NOT NULL,
            unit TEXT NOT NULL,
            resolution REAL NOT NULL,
            start_date INTEGER NOT NULL,
            min REAL NOT NULL,
            avg REAL NOT NULL,
            max REAL NOT NULL,
            last REAL NOT NULL,
            last_sample_date INTEGER,
            count INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            PRIMARY KEY (range, kind, unit, start_date)
        );
        """)
        try addColumnIfNeeded(name: "last_sample_date", definition: "INTEGER")
        try execute("""
        CREATE INDEX IF NOT EXISTS history_buckets_range_start_idx
        ON history_buckets(range, start_date);
        """)
        try execute("PRAGMA user_version = \(Database.schemaVersion);")
    }

    private func addColumnIfNeeded(name: String, definition: String) throws {
        let statement = try prepare("PRAGMA table_info(history_buckets);")
        defer {
            sqlite3_finalize(statement)
        }

        while sqlite3_step(statement) == SQLITE_ROW {
            if Self.columnText(statement, at: 1) == name {
                return
            }
        }

        try execute("ALTER TABLE history_buckets ADD COLUMN \(name) \(definition);")
    }

    private func loadDatabaseBuckets(now: Date) -> HistoryBucketMap {
        var result = HistoryBucketAggregation.emptyBuckets()
        guard database != nil else { return result }

        do {
            let statement = try prepare("""
            SELECT range, kind, unit, resolution, start_date, min, avg, max, last, last_sample_date, count
            FROM history_buckets
            ORDER BY range, kind, unit, start_date;
            """)
            defer {
                sqlite3_finalize(statement)
            }

            var shouldPrune = false
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let rangeRaw = Self.columnText(statement, at: 0),
                      let kindRaw = Self.columnText(statement, at: 1),
                      let unitRaw = Self.columnText(statement, at: 2),
                      let range = HistoryRange(rawValue: rangeRaw),
                      let kind = MetricKind(rawValue: kindRaw),
                      let unit = MetricUnit(rawValue: unitRaw)
                else {
                    shouldPrune = true
                    continue
                }

                let bucket = MetricHistoryBucket(
                    kind: kind,
                    unit: unit,
                    resolution: sqlite3_column_double(statement, 3),
                    startDate: Self.date(fromDatabaseTimestamp: sqlite3_column_int64(statement, 4)),
                    min: sqlite3_column_double(statement, 5),
                    avg: sqlite3_column_double(statement, 6),
                    max: sqlite3_column_double(statement, 7),
                    last: sqlite3_column_double(statement, 8),
                    lastSampleDate: Self.date(
                        fromDatabaseTimestamp: sqlite3_column_type(statement, 9) == SQLITE_NULL
                            ? sqlite3_column_int64(statement, 4)
                            : sqlite3_column_int64(statement, 9),
                    ),
                    count: Int(sqlite3_column_int64(statement, 10)),
                )
                if !Self.apply(
                    bucket: bucket,
                    range: range,
                    to: &result,
                    now: now,
                    maximumRetentionDuration: storagePolicy.maximumRetentionDuration,
                    retainedKinds: retainedKinds,
                ) {
                    shouldPrune = true
                }
            }

            if shouldPrune {
                try? pruneDatabase(at: now)
            }
        } catch {
            return HistoryBucketAggregation.emptyBuckets()
        }

        return result
    }

    private func migrateLegacyIfNeeded(now: Date) {
        guard database != nil,
              let legacyPersistenceURL,
              let legacyLogURL
        else { return }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: legacyPersistenceURL.path)
            || fileManager.fileExists(atPath: legacyLogURL.path)
        else { return }

        let loaded = Self.loadLegacyBuckets(
            from: legacyPersistenceURL,
            logURL: legacyLogURL,
            maximumRetentionDuration: storagePolicy.maximumRetentionDuration,
            retainedKinds: retainedKinds,
        )
        guard loaded.processedPayload else { return }

        aggregation.mergeBuckets(loaded.buckets)
        if persistAllBucketsToDatabase(at: now) {
            removeLegacyFiles()
        }
    }

    private func retentionCutoff(for range: HistoryRange, at now: Date) -> Date {
        HistoryRetention.cutoff(
            for: range,
            at: now,
            maximumRetentionDuration: storagePolicy.maximumRetentionDuration,
        )
    }

    private func shouldPruneDatabase(at now: Date, force: Bool) -> Bool {
        if force { return true }
        guard let lastPrunedDatabaseAt else { return true }
        return now.timeIntervalSince(lastPrunedDatabaseAt) >= storagePolicy.maintenanceInterval
    }

    private func pruneDatabase(at now: Date) throws {
        guard database != nil else { throw SQLiteHistoryError.unavailable }
        let statement = try prepare("""
        DELETE FROM history_buckets
        WHERE range = ? AND ((start_date + ?) <= ? OR start_date > ?);
        """)
        defer {
            sqlite3_finalize(statement)
        }

        for range in HistoryRange.allCases {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            let cutoff = retentionCutoff(for: range, at: now)
            try bind(range.rawValue, to: statement, at: 1)
            try bind(Self.databaseInterval(for: range.bucketInterval), to: statement, at: 2)
            try bind(Self.databaseTimestamp(for: cutoff), to: statement, at: 3)
            try bind(Self.databaseTimestamp(for: now), to: statement, at: 4)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw SQLiteHistoryError.operationFailed(lastSQLiteErrorMessage())
            }
        }

        guard let retainedKinds else {
            lastPrunedDatabaseAt = now
            return
        }
        let deleteKindStatement = try prepare("DELETE FROM history_buckets WHERE kind = ?;")
        defer {
            sqlite3_finalize(deleteKindStatement)
        }

        for kind in MetricKind.allCases where !retainedKinds.contains(kind) {
            sqlite3_reset(deleteKindStatement)
            sqlite3_clear_bindings(deleteKindStatement)
            try bind(kind.rawValue, to: deleteKindStatement, at: 1)
            guard sqlite3_step(deleteKindStatement) == SQLITE_DONE else {
                throw SQLiteHistoryError.operationFailed(lastSQLiteErrorMessage())
            }
        }

        lastPrunedDatabaseAt = now
    }

    private func maintainDatabaseStorage(at now: Date, force: Bool) throws {
        guard database != nil else { throw SQLiteHistoryError.unavailable }

        if shouldCheckpointDatabase(at: now, force: force) {
            let shouldTruncate = force
                || (storagePolicy.walByteLimit > 0 && sqliteFileSize(at: databaseWALURL) >= storagePolicy.walByteLimit)
            try checkpointDatabase(truncate: shouldTruncate, at: now)
        }

        if shouldVacuumDatabase(at: now) {
            try vacuumDatabase(at: now)
        }
    }

    private func shouldCheckpointDatabase(at now: Date, force: Bool) -> Bool {
        let walSize = sqliteFileSize(at: databaseWALURL)
        guard walSize > 0 else { return false }
        if force { return true }
        if storagePolicy.walByteLimit > 0, walSize >= storagePolicy.walByteLimit {
            return true
        }
        guard let lastCheckpointedDatabaseAt else { return true }
        return now.timeIntervalSince(lastCheckpointedDatabaseAt) >= storagePolicy.maintenanceInterval
    }

    private func checkpointDatabase(truncate: Bool, at now: Date) throws {
        try execute("PRAGMA wal_checkpoint(\(truncate ? "TRUNCATE" : "PASSIVE"));")
        lastCheckpointedDatabaseAt = now
    }

    private func shouldVacuumDatabase(at now: Date) -> Bool {
        guard storagePolicy.databaseByteLimit > 0 else { return false }
        guard sqliteFileSize(at: databaseURL) >= storagePolicy.databaseByteLimit else { return false }
        guard let lastVacuumedDatabaseAt else { return true }
        return now.timeIntervalSince(lastVacuumedDatabaseAt) >= storagePolicy.vacuumInterval
    }

    private func vacuumDatabase(at now: Date) throws {
        try execute("VACUUM;")
        lastVacuumedDatabaseAt = now
        if sqliteFileSize(at: databaseWALURL) > 0 {
            try checkpointDatabase(truncate: true, at: now)
        }
    }

    private func walAutoCheckpointPageCount() -> Int {
        guard storagePolicy.walByteLimit > 0 else { return 1_000 }
        return max(128, Int(storagePolicy.walByteLimit / 4_096))
    }

    private var databaseWALURL: URL? {
        guard let databaseURL else { return nil }
        return URL(fileURLWithPath: databaseURL.path + "-wal")
    }

    private func sqliteFileSize(at url: URL?) -> Int64 {
        guard let url else { return 0 }
        return Self.fileSize(at: url)
    }

    private func execute(_ sql: String) throws {
        guard let pointer = database?.pointer else { throw SQLiteHistoryError.unavailable }
        guard sqlite3_exec(pointer, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteHistoryError.operationFailed(lastSQLiteErrorMessage())
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        guard let pointer = database?.pointer else { throw SQLiteHistoryError.unavailable }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(pointer, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteHistoryError.operationFailed(lastSQLiteErrorMessage())
        }
        return statement
    }

    private func bind(_ value: String, to statement: OpaquePointer?, at index: Int32) throws {
        guard sqlite3_bind_text(statement, index, value, -1, sqliteTransientDestructor) == SQLITE_OK else {
            throw SQLiteHistoryError.operationFailed(lastSQLiteErrorMessage())
        }
    }

    private func bind(_ value: Double, to statement: OpaquePointer?, at index: Int32) throws {
        guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else {
            throw SQLiteHistoryError.operationFailed(lastSQLiteErrorMessage())
        }
    }

    private func bind(_ value: Int64, to statement: OpaquePointer?, at index: Int32) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else {
            throw SQLiteHistoryError.operationFailed(lastSQLiteErrorMessage())
        }
    }

    private func lastSQLiteErrorMessage() -> String {
        guard let pointer = database?.pointer else { return "SQLite database is unavailable" }
        return String(cString: sqlite3_errmsg(pointer))
    }

    private func removePersistedFile() {
        removeLegacyFiles()
        guard let databaseURL else { return }
        database?.close()
        database = nil
        Self.removeDatabaseFiles(at: databaseURL)
        configureDatabase(at: databaseURL)
    }

    private func removeLegacyFiles() {
        if let legacyPersistenceURL {
            try? FileManager.default.removeItem(at: legacyPersistenceURL)
        }
        if let legacyLogURL {
            try? FileManager.default.removeItem(at: legacyLogURL)
        }
    }

    private static func loadLegacyBuckets(
        from url: URL,
        logURL: URL,
        maximumRetentionDuration: TimeInterval,
        retainedKinds: Set<MetricKind>?,
    ) -> LegacyHistoryLoadResult {
        var result = HistoryBucketAggregation.emptyBuckets()
        var processedPayload = false
        var snapshotSavedAt: Date?
        let now = Date()
        let decoder = JSONDecoder()

        if let data = try? Data(contentsOf: url),
           let payload = try? decoder.decode(PersistedHistoryStore.self, from: data),
           payload.version == Persistence.snapshotVersion || payload.version == Persistence.legacySnapshotVersion {
            processedPayload = true
            snapshotSavedAt = payload.savedAt
            apply(
                snapshot: payload,
                to: &result,
                now: now,
                maximumRetentionDuration: maximumRetentionDuration,
                retainedKinds: retainedKinds,
            )
        }

        if let data = try? Data(contentsOf: logURL), !data.isEmpty {
            let text = String(decoding: data, as: UTF8.self)
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let lineData = String(line).data(using: .utf8),
                      let payload = try? decoder.decode(PersistedHistoryIncrement.self, from: lineData),
                      payload.version == Persistence.incrementVersion
                else {
                    continue
                }
                if let snapshotSavedAt, payload.savedAt <= snapshotSavedAt {
                    continue
                }
                processedPayload = true
                for record in payload.records {
                    apply(
                        bucket: record.bucket,
                        range: record.range,
                        to: &result,
                        now: now,
                        maximumRetentionDuration: maximumRetentionDuration,
                        retainedKinds: retainedKinds,
                    )
                }
            }
        }

        return LegacyHistoryLoadResult(buckets: result, processedPayload: processedPayload)
    }

    private static func apply(
        snapshot: PersistedHistoryStore,
        to result: inout HistoryBucketMap,
        now: Date,
        maximumRetentionDuration: TimeInterval,
        retainedKinds: Set<MetricKind>?,
    ) {
        for persistedRange in snapshot.ranges {
            for bucket in persistedRange.buckets {
                apply(
                    bucket: bucket,
                    range: persistedRange.range,
                    to: &result,
                    now: now,
                    maximumRetentionDuration: maximumRetentionDuration,
                    retainedKinds: retainedKinds,
                )
            }
        }
    }

    @discardableResult
    private static func apply(
        bucket: MetricHistoryBucket,
        range: HistoryRange,
        to result: inout HistoryBucketMap,
        now: Date,
        maximumRetentionDuration: TimeInterval,
        retainedKinds: Set<MetricKind>?,
    ) -> Bool {
        guard bucket.avg.isFinite, bucket.min.isFinite, bucket.max.isFinite, bucket.last.isFinite else { return false }
        guard bucket.resolution == range.bucketInterval else { return false }
        guard retainedKinds?.contains(bucket.kind) ?? true else { return false }
        guard HistoryRetention.bucketOverlapsRetention(
            startDate: bucket.startDate,
            range: range,
            at: now,
            maximumRetentionDuration: maximumRetentionDuration,
        ) else { return false }

        let key = HistoryBucketKey(kind: bucket.kind, unit: bucket.unit)
        var perRange = result[range, default: [:]]
        var perSeries = perRange[key, default: [:]]
        perSeries[bucket.startDate] = bucket
        perRange[key] = perSeries
        result[range] = perRange
        return true
    }

    private static func databaseURL(for url: URL) -> URL {
        if url.pathExtension.lowercased() == "sqlite" {
            return url
        }
        return url.deletingPathExtension().appendingPathExtension("sqlite")
    }

    private static func legacySnapshotURL(for url: URL) -> URL {
        if url.pathExtension.lowercased() == "sqlite" {
            return url.deletingPathExtension().appendingPathExtension("json")
        }
        return url
    }

    private static func databaseTimestamp(for date: Date) -> Int64 {
        Int64((date.timeIntervalSinceReferenceDate * Database.timestampScale).rounded())
    }

    private static func databaseInterval(for timeInterval: TimeInterval) -> Int64 {
        Int64((timeInterval * Database.timestampScale).rounded())
    }

    private static func date(fromDatabaseTimestamp timestamp: Int64) -> Date {
        Date(timeIntervalSinceReferenceDate: Double(timestamp) / Database.timestampScale)
    }

    private static func columnText(_ statement: OpaquePointer?, at index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: UnsafeRawPointer(text).assumingMemoryBound(to: CChar.self))
    }

    private static func fileSize(at url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else {
            return 0
        }
        return size.int64Value
    }

    private static func removeDatabaseFiles(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
    }
}
