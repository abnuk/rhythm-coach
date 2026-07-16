import Foundation
import RhythmAudio
import RhythmCore
import SQLite3

/// One practice session's stored summary.
struct SessionRecord: Identifiable, Sendable, Hashable {
    var id: String
    var startedAt: Date
    var durationSec: Double
    var bpm: Double
    var subdivision: String
    var clickDensity: String = ClickDensity.everySlot.rawValue
    var gapPattern: String?
    var targetOffsetMs: Double
    var sampleRate: Double
    var bufferFrames: Int
    var inputDeviceName: String
    var latencyCompMs: Double
    var latencySource: String
    var toleranceMs: Double
    var audioPath: String?
    var hitCount: Int
    var missedCount: Int
    var extraCount: Int
    var meanMs: Double
    var sdMs: Double
    var minMs: Double
    var maxMs: Double
    var pctInTolerance: Double
    var driftMsPerMin: Double
    var lag1: Double
}

struct HitRow: Sendable {
    var slotIndex: Int
    var deviationMs: Double
    var onsetSample: Double
    var kind: String  // hit | missed | extra
}

/// Minimal SQLite persistence (system libsqlite3, no dependencies).
/// All calls must come from the main actor.
@MainActor
final class Database {
    private var db: OpaquePointer?

    static let shared = Database()

    private init() {
        let dir = Self.applicationSupportDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("rhythmcoach.db").path
        if sqlite3_open(path, &db) != SQLITE_OK {
            assertionFailure("cannot open database at \(path)")
        }
        migrate()
    }

    static func applicationSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("RhythmCoach", isDirectory: true)
    }

    static func sessionsDirectory() -> URL {
        applicationSupportDirectory().appendingPathComponent("Sessions", isDirectory: true)
    }

    private func exec(_ sql: String) {
        var errorMessage: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errorMessage) != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "?"
            sqlite3_free(errorMessage)
            assertionFailure("sqlite exec failed: \(message)")
        }
    }

    private func migrate() {
        exec("PRAGMA journal_mode=WAL")
        exec("""
        CREATE TABLE IF NOT EXISTS session (
          id TEXT PRIMARY KEY, startedAt REAL NOT NULL, durationSec REAL,
          bpm REAL, subdivision TEXT, gapPattern TEXT, targetOffsetMs REAL,
          sampleRate REAL, bufferFrames INTEGER, inputDeviceName TEXT,
          latencyCompMs REAL, latencySource TEXT, toleranceMs REAL,
          audioPath TEXT,
          hitCount INTEGER, missedCount INTEGER, extraCount INTEGER,
          meanMs REAL, sdMs REAL, minMs REAL, maxMs REAL,
          pctInTolerance REAL, driftMsPerMin REAL, lag1 REAL
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS hit (
          sessionId TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE,
          slotIndex INTEGER, deviationMs REAL, onsetSample REAL, kind TEXT
        )
        """)
        exec("CREATE INDEX IF NOT EXISTS hit_session ON hit(sessionId)")
        addColumnIfMissing(table: "session", column: "clickDensity", ddl: "TEXT DEFAULT 'everySlot'")
        exec("""
        CREATE TABLE IF NOT EXISTS calibration (
          inputUID TEXT, outputUID TEXT, sampleRate REAL, bufferFrames INTEGER,
          roundtripSamples REAL, sdSamples REAL, runs INTEGER, createdAt REAL,
          PRIMARY KEY (inputUID, outputUID, sampleRate, bufferFrames)
        )
        """)
    }

    /// Adds a column to an existing table when older databases predate it.
    private func addColumnIfMissing(table: String, column: String, ddl: String) {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if text(stmt, 1) == column { return }
        }
        exec("ALTER TABLE \(table) ADD COLUMN \(column) \(ddl)")
    }

    // MARK: - Sessions

    func save(session: SessionRecord, hits: [HitRow]) {
        exec("BEGIN")
        defer { exec("COMMIT") }

        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, """
        INSERT OR REPLACE INTO session (
          id, startedAt, durationSec, bpm, subdivision, gapPattern,
          targetOffsetMs, sampleRate, bufferFrames, inputDeviceName,
          latencyCompMs, latencySource, toleranceMs, audioPath,
          hitCount, missedCount, extraCount, meanMs, sdMs, minMs, maxMs,
          pctInTolerance, driftMsPerMin, lag1, clickDensity
        ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, session.id)
        sqlite3_bind_double(stmt, 2, session.startedAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 3, session.durationSec)
        sqlite3_bind_double(stmt, 4, session.bpm)
        bindText(stmt, 5, session.subdivision)
        bindText(stmt, 6, session.gapPattern)
        sqlite3_bind_double(stmt, 7, session.targetOffsetMs)
        sqlite3_bind_double(stmt, 8, session.sampleRate)
        sqlite3_bind_int(stmt, 9, Int32(session.bufferFrames))
        bindText(stmt, 10, session.inputDeviceName)
        sqlite3_bind_double(stmt, 11, session.latencyCompMs)
        bindText(stmt, 12, session.latencySource)
        sqlite3_bind_double(stmt, 13, session.toleranceMs)
        bindText(stmt, 14, session.audioPath)
        sqlite3_bind_int(stmt, 15, Int32(session.hitCount))
        sqlite3_bind_int(stmt, 16, Int32(session.missedCount))
        sqlite3_bind_int(stmt, 17, Int32(session.extraCount))
        sqlite3_bind_double(stmt, 18, session.meanMs)
        sqlite3_bind_double(stmt, 19, session.sdMs)
        sqlite3_bind_double(stmt, 20, session.minMs)
        sqlite3_bind_double(stmt, 21, session.maxMs)
        sqlite3_bind_double(stmt, 22, session.pctInTolerance)
        sqlite3_bind_double(stmt, 23, session.driftMsPerMin)
        sqlite3_bind_double(stmt, 24, session.lag1)
        bindText(stmt, 25, session.clickDensity)
        sqlite3_step(stmt)

        var hitStmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO hit VALUES (?,?,?,?,?)", -1, &hitStmt, nil)
        defer { sqlite3_finalize(hitStmt) }
        for hit in hits {
            sqlite3_reset(hitStmt)
            bindText(hitStmt, 1, session.id)
            sqlite3_bind_int(hitStmt, 2, Int32(hit.slotIndex))
            sqlite3_bind_double(hitStmt, 3, hit.deviationMs)
            sqlite3_bind_double(hitStmt, 4, hit.onsetSample)
            bindText(hitStmt, 5, hit.kind)
            sqlite3_step(hitStmt)
        }
    }

    func sessions() -> [SessionRecord] {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT * FROM session ORDER BY startedAt DESC", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        var result: [SessionRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(SessionRecord(
                id: text(stmt, 0) ?? UUID().uuidString,
                startedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                durationSec: sqlite3_column_double(stmt, 2),
                bpm: sqlite3_column_double(stmt, 3),
                subdivision: text(stmt, 4) ?? "quarter",
                clickDensity: text(stmt, 24) ?? ClickDensity.everySlot.rawValue,
                gapPattern: text(stmt, 5),
                targetOffsetMs: sqlite3_column_double(stmt, 6),
                sampleRate: sqlite3_column_double(stmt, 7),
                bufferFrames: Int(sqlite3_column_int(stmt, 8)),
                inputDeviceName: text(stmt, 9) ?? "",
                latencyCompMs: sqlite3_column_double(stmt, 10),
                latencySource: text(stmt, 11) ?? "reported",
                toleranceMs: sqlite3_column_double(stmt, 12),
                audioPath: text(stmt, 13),
                hitCount: Int(sqlite3_column_int(stmt, 14)),
                missedCount: Int(sqlite3_column_int(stmt, 15)),
                extraCount: Int(sqlite3_column_int(stmt, 16)),
                meanMs: sqlite3_column_double(stmt, 17),
                sdMs: sqlite3_column_double(stmt, 18),
                minMs: sqlite3_column_double(stmt, 19),
                maxMs: sqlite3_column_double(stmt, 20),
                pctInTolerance: sqlite3_column_double(stmt, 21),
                driftMsPerMin: sqlite3_column_double(stmt, 22),
                lag1: sqlite3_column_double(stmt, 23)
            ))
        }
        return result
    }

    func hits(sessionID: String) -> [HitRow] {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT slotIndex, deviationMs, onsetSample, kind FROM hit WHERE sessionId = ? ORDER BY slotIndex", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, sessionID)
        var result: [HitRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(HitRow(
                slotIndex: Int(sqlite3_column_int(stmt, 0)),
                deviationMs: sqlite3_column_double(stmt, 1),
                onsetSample: sqlite3_column_double(stmt, 2),
                kind: text(stmt, 3) ?? "hit"
            ))
        }
        return result
    }

    func deleteSession(id: String) {
        if let path = sessions().first(where: { $0.id == id })?.audioPath {
            try? FileManager.default.removeItem(atPath: path)
        }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "DELETE FROM hit WHERE sessionId = ?", -1, &stmt, nil)
        bindText(stmt, 1, id)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        sqlite3_prepare_v2(db, "DELETE FROM session WHERE id = ?", -1, &stmt, nil)
        bindText(stmt, 1, id)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    // MARK: - Calibration

    func saveCalibration(inputUID: String, outputUID: String, bufferFrames: Int, result: CalibrationResult) {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO calibration VALUES (?,?,?,?,?,?,?,?)", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, inputUID)
        bindText(stmt, 2, outputUID)
        sqlite3_bind_double(stmt, 3, result.sampleRate)
        sqlite3_bind_int(stmt, 4, Int32(bufferFrames))
        sqlite3_bind_double(stmt, 5, result.roundtripSamples)
        sqlite3_bind_double(stmt, 6, result.sdSamples)
        sqlite3_bind_int(stmt, 7, Int32(result.runs))
        sqlite3_bind_double(stmt, 8, Date().timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    func calibration(inputUID: String, outputUID: String, sampleRate: Double, bufferFrames: Int) -> CalibrationResult? {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, """
        SELECT roundtripSamples, sdSamples, runs FROM calibration
        WHERE inputUID = ? AND outputUID = ? AND sampleRate = ? AND bufferFrames = ?
        """, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, inputUID)
        bindText(stmt, 2, outputUID)
        sqlite3_bind_double(stmt, 3, sampleRate)
        sqlite3_bind_int(stmt, 4, Int32(bufferFrames))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return CalibrationResult(
            roundtripSamples: sqlite3_column_double(stmt, 0),
            sdSamples: sqlite3_column_double(stmt, 1),
            runs: Int(sqlite3_column_int(stmt, 2)),
            sampleRate: sampleRate
        )
    }

    // MARK: - helpers

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, transient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func text(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }
}
