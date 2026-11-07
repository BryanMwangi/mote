import Foundation
import SQLite3

/// Reads a SQLite database from a copy, since the browser that owns it is
/// usually running and holding locks on it. Its write-ahead log comes along,
/// so what the browser wrote last is read too.
public enum SQLiteCopy {
    public struct Unreadable: Error {}

    public struct Row {
        let statement: OpaquePointer

        public func text(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
        public func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        public func blob(_ column: Int32) -> Data {
            guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
        }
    }

    public struct Database {
        let handle: OpaquePointer

        /// The first row of a one-parameter query.
        public func first<Value>(_ sql: String, binding value: String, _ read: (Row) -> Value) -> Value? {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            return sqlite3_step(statement) == SQLITE_ROW ? read(Row(statement: statement)) : nil
        }

        public func all<Value>(_ sql: String, _ read: (Row) -> Value) throws -> [Value] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw Unreadable()
            }
            defer { sqlite3_finalize(statement) }
            var rows: [Value] = []
            while sqlite3_step(statement) == SQLITE_ROW { rows.append(read(Row(statement: statement))) }
            return rows
        }
    }

    public static func open<Result>(_ file: URL, _ work: (Database) throws -> Result) throws -> Result {
        let copy = FileManager.default.temporaryDirectory.appending(path: "mote-import-\(UUID().uuidString).db")
        try FileManager.default.copyItem(at: file, to: copy)
        let log = URL(fileURLWithPath: file.path + "-wal")
        if FileManager.default.fileExists(atPath: log.path) { try? FileManager.default.copyItem(at: log, to: URL(fileURLWithPath: copy.path + "-wal")) }
        defer {
            try? FileManager.default.removeItem(at: copy)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: copy.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: copy.path + "-shm"))
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw Unreadable()
        }
        defer { sqlite3_close(handle) }
        return try work(Database(handle: handle))
    }

    public static func rows<Value>(of file: URL, _ sql: String, _ read: (Row) -> Value) throws -> [Value] {
        try open(file) { try $0.all(sql, read) }
    }
}
