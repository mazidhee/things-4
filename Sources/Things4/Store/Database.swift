import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum DatabaseError: LocalizedError {
    case open(String)
    case sql(String)

    var errorDescription: String? {
        switch self {
        case .open(let message): return "Could not open the database: \(message)"
        case .sql(let message): return "Database error: \(message)"
        }
    }
}

/// A tiny synchronous SQLite wrapper. Everything runs on the main thread, which
/// is fine at personal task-list scale and keeps the UI code simple.
final class Database {
    private var handle: OpaquePointer?
    let path: String

    init(path: String) throws {
        self.path = path
        if sqlite3_open_v2(path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(handle))
            throw DatabaseError.open(message)
        }
        try run("PRAGMA journal_mode=WAL;")
        try run("PRAGMA foreign_keys=ON;")
    }

    deinit {
        sqlite3_close(handle)
    }

    private func errorText() -> String {
        String(cString: sqlite3_errmsg(handle))
    }

    private func bind(_ statement: OpaquePointer?, _ params: [Any?]) {
        var index: Int32 = 1
        for value in params {
            switch value {
            case nil:
                sqlite3_bind_null(statement, index)
            case let value as String:
                sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
            case let value as Int:
                sqlite3_bind_int64(statement, index, Int64(value))
            case let value as Int64:
                sqlite3_bind_int64(statement, index, value)
            case let value as Double:
                sqlite3_bind_double(statement, index, value)
            case let value as Bool:
                sqlite3_bind_int(statement, index, value ? 1 : 0)
            case let value as Date:
                sqlite3_bind_double(statement, index, value.timeIntervalSince1970)
            default:
                sqlite3_bind_text(statement, index, String(describing: value!), -1, SQLITE_TRANSIENT)
            }
            index += 1
        }
    }

    func run(_ sql: String, _ params: [Any?] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.sql("\(errorText()) — \(sql)")
        }
        defer { sqlite3_finalize(statement) }
        bind(statement, params)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw DatabaseError.sql("\(errorText()) — \(sql)")
        }
    }

    func query(_ sql: String, _ params: [Any?] = []) throws -> [[String: Any]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.sql("\(errorText()) — \(sql)")
        }
        defer { sqlite3_finalize(statement) }
        bind(statement, params)

        var rows: [[String: Any]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: Any] = [:]
            let columns = sqlite3_column_count(statement)
            for column in 0..<columns {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER:
                    row[name] = Int(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT:
                    row[name] = sqlite3_column_double(statement, column)
                case SQLITE_TEXT:
                    row[name] = String(cString: sqlite3_column_text(statement, column))
                case SQLITE_NULL:
                    row[name] = nil
                default:
                    row[name] = nil
                }
            }
            rows.append(row)
        }
        return rows
    }

    func lastError() -> String { errorText() }
}
