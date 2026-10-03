import Foundation
import SQLite3

enum AppPaths {
    static let directory = URL.applicationSupportDirectory
        .appendingPathComponent("BUSY", isDirectory: true)
    static let database = directory.appendingPathComponent("busy.db")
    static let rules = directory.appendingPathComponent("rules.json")
}

final class Database: @unchecked Sendable {
    private let queue = DispatchQueue(label: "BUSY.database", qos: .utility)
    // Accesso esclusivo dalla queue, inclusi apertura, schema e chiusura.
    private var handle: OpaquePointer?
    private var acceptsSamples = true
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let lastSampleSQL = "SELECT * FROM samples ORDER BY timestamp DESC, id DESC LIMIT 1"

    init() async throws {
        try await perform {
            let location = AppPaths.database
            try FileManager.default.createDirectory(at: location.deletingLastPathComponent(),
                                                   withIntermediateDirectories: true)
            try self.check(sqlite3_open_v2(location.path, &self.handle,
                SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil))
            try self.check(sqlite3_busy_timeout(self.handle, 3000))
            try self.execute("""
                CREATE TABLE IF NOT EXISTS samples (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    timestamp INTEGER NOT NULL,
                    bundle_id TEXT NOT NULL,
                    domain TEXT,
                    category TEXT NOT NULL,
                    matched_rule TEXT
                );
                CREATE INDEX IF NOT EXISTS idx_samples_timestamp ON samples(timestamp);
                """)
        }
    }

    // L'accodamento avviene sul main actor per rispettare l'ordine delle
    // transizioni del Sampler; tutto il lavoro SQLite rimane sulla queue.
    @MainActor func insertSample(_ session: Session) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                continuation.resume(with: Result {
                    guard self.acceptsSamples else { return }
                    try self.insertOnQueue(session)
                })
            }
        }
    }

    // Percorso bloccante riservato alla terminazione. Le scritture asincrone
    // tardive non possono riaprire una sessione dopo il marker finale.
    func insertSampleSync(_ session: Session) throws {
        try queue.sync {
            try insertOnQueue(session)
            acceptsSamples = false
        }
    }

    private func insertOnQueue(_ session: Session) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let last = try query(Self.lastSampleSQL).first
            if last.map({ !session.hasSameActivity(as: $0) }) ?? true {
                let statement = try prepare("""
                    INSERT INTO samples(timestamp, bundle_id, domain, category, matched_rule)
                    VALUES (?, ?, ?, ?, ?)
                    """)
                defer { sqlite3_finalize(statement) }
                // Mantiene l'ordine anche dopo una correzione all'indietro dell'orologio.
                let timestamp = max(session.timestamp.timeIntervalSince1970,
                                    last?.timestamp.timeIntervalSince1970 ?? -.infinity)
                try check(sqlite3_bind_int64(statement, 1, Int64(timestamp)))
                try bind(session.bundleID, to: statement, at: 2)
                try bind(session.domain, to: statement, at: 3)
                try bind(session.category.rawValue, to: statement, at: 4)
                try bind(session.matchedRule, to: statement, at: 5)
                try check(sqlite3_step(statement), expected: SQLITE_DONE)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func lastSample() async throws -> Session? {
        try await perform {
            try self.query(Self.lastSampleSQL).first
        }
    }

    func samplesInRange(from: Date, to: Date) async throws -> [Session] {
        guard from < to else { return [] }
        return try await perform {
            // Include il predecessore: senza di lui si perderebbe il tempo a cavallo di from.
            try self.query("""
                SELECT * FROM samples WHERE id = (
                    SELECT id FROM samples WHERE timestamp < ?
                    ORDER BY timestamp DESC, id DESC LIMIT 1
                )
                UNION ALL
                SELECT * FROM samples WHERE timestamp >= ? AND timestamp < ?
                ORDER BY timestamp, id
                """, dates: [from, from, to])
        }
    }

    private func perform<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try operation() }) }
        }
    }

    private func check(_ code: Int32, expected: Int32 = SQLITE_OK) throws {
        guard code == expected else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Connessione SQLite non disponibile"
            throw NSError(domain: "BUSY.SQLite", code: Int(code),
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func execute(_ sql: String) throws {
        try check(sqlite3_exec(handle, sql, nil, nil, nil))
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        if code != SQLITE_OK {
            if let statement { sqlite3_finalize(statement) }
            try check(code)
        }
        guard let statement else {
            throw NSError(domain: "BUSY.SQLite", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "Statement SQLite vuoto"])
        }
        return statement
    }

    private func bind(_ value: String?, to statement: OpaquePointer, at index: Int32) throws {
        if let value {
            try check(sqlite3_bind_text(statement, index, value, -1, transient))
        } else { try check(sqlite3_bind_null(statement, index)) }
    }

    private func query(_ sql: String, dates: [Date] = []) throws -> [Session] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (index, date) in dates.enumerated() {
            try check(sqlite3_bind_double(statement, Int32(index + 1), date.timeIntervalSince1970))
        }
        func string(_ index: Int32) -> String? {
            sqlite3_column_text(statement, index).map { String(cString: $0) }
        }
        var sessions: [Session] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            try check(code, expected: SQLITE_ROW)
            guard let bundle = string(2), let rawCategory = string(4),
                  let category = Category(rawValue: rawCategory) else {
                throw NSError(domain: "BUSY.SQLite", code: 0,
                              userInfo: [NSLocalizedDescriptionKey: "Record SQLite non valido"])
            }
            sessions.append(Session(id: sqlite3_column_int64(statement, 0),
                timestamp: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 1))),
                bundleID: bundle, domain: string(3), category: category, matchedRule: string(5)))
        }
        return sessions
    }
}
