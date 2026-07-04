import Foundation
import SQLite3

/// Local learning-event store (§7.2). Uses the generic `learning_events`
/// schema from FUTURE_PLAN.md so v2–v4 modules (Track/Practice/Learn) need
/// zero migration. v1 writes mistake/success rows only.
actor MistakeStore {
    enum EventType: String {
        case mistake, success, newWord = "new_word", drillResult = "drill_result"
    }

    struct RecurringMistake {
        let grammarPoint: String
        let count: Int
    }

    private var db: OpaquePointer?
    private var sessionID: Int64 = 0

    func open() throws {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NihongoBuddy", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("memory.sqlite").path

        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw StoreError.cannotOpen(String(cString: sqlite3_errmsg(db)))
        }
        try exec("""
            CREATE TABLE IF NOT EXISTS learning_events (
              id INTEGER PRIMARY KEY,
              ts DATETIME NOT NULL,
              session_id INTEGER NOT NULL,
              type TEXT NOT NULL,
              item TEXT NOT NULL,
              wrong TEXT,
              correct TEXT,
              grammar_point TEXT,
              jlpt_level TEXT
            );
            CREATE TABLE IF NOT EXISTS sessions (
              id INTEGER PRIMARY KEY,
              start DATETIME NOT NULL,
              end DATETIME,
              turn_count INTEGER DEFAULT 0,
              mistake_count INTEGER DEFAULT 0,
              new_item_count INTEGER DEFAULT 0
            );
            """)
        try exec("INSERT INTO sessions (start) VALUES (datetime('now'));")
        sessionID = sqlite3_last_insert_rowid(db)
    }

    func record(_ type: EventType, item: String, wrong: String? = nil,
                correct: String? = nil, grammarPoint: String? = nil, jlptLevel: String? = nil) {
        guard db != nil else { return }
        var stmt: OpaquePointer?
        let sql = """
            INSERT INTO learning_events (ts, session_id, type, item, wrong, correct, grammar_point, jlpt_level)
            VALUES (datetime('now'), ?, ?, ?, ?, ?, ?, ?);
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_int64(stmt, 1, sessionID)
        sqlite3_bind_text(stmt, 2, type.rawValue, -1, transient)
        sqlite3_bind_text(stmt, 3, item, -1, transient)
        bindOptional(stmt, 4, wrong, transient)
        bindOptional(stmt, 5, correct, transient)
        bindOptional(stmt, 6, grammarPoint, transient)
        bindOptional(stmt, 7, jlptLevel, transient)
        sqlite3_step(stmt)
    }

    /// Top recurring grammar-point mistakes across all sessions — injected into
    /// the system prompt at session start ("clingy, remembers you").
    func topRecurring(limit: Int) -> [RecurringMistake] {
        guard db != nil else { return [] }
        var stmt: OpaquePointer?
        let sql = """
            SELECT grammar_point, COUNT(*) AS n FROM learning_events
            WHERE type = 'mistake' AND grammar_point IS NOT NULL
            GROUP BY grammar_point ORDER BY n DESC LIMIT ?;
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var out: [RecurringMistake] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let point = sqlite3_column_text(stmt, 0) {
                out.append(RecurringMistake(grammarPoint: String(cString: point),
                                            count: Int(sqlite3_column_int(stmt, 1))))
            }
        }
        return out
    }

    func closeSession() {
        try? exec("UPDATE sessions SET end = datetime('now') WHERE id = \(sessionID);")
    }

    private func bindOptional(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?, _ destructor: sqlite3_destructor_type) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, destructor)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func exec(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorMessage)
            throw StoreError.execFailed(message)
        }
    }

    enum StoreError: Error {
        case cannotOpen(String)
        case execFailed(String)
    }
}
