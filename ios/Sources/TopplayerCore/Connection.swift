import Foundation
import SQLite3

public typealias Row = [String: Any]

public struct DbError: Error, LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One SQLite connection. Access is serialised with a lock, so it can be shared between threads.
public final class Connection {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()

    public init(path: String) throws {
        if sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            throw DbError(message: "Cannot open database")
        }
        sqlite3_busy_timeout(handle, 8000)
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=NORMAL")
    }

    deinit { sqlite3_close(handle) }

    private func message() -> String { String(cString: sqlite3_errmsg(handle)) }

    public func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        if sqlite3_exec(handle, sql, nil, nil, nil) != SQLITE_OK { throw DbError(message: message() + " in " + sql.prefix(80)) }
    }

    private func bind(_ st: OpaquePointer?, _ args: [Any?]) {
        for (i, a) in args.enumerated() {
            let n = Int32(i + 1)
            switch a {
            case nil: sqlite3_bind_null(st, n)
            case let v as Bool: sqlite3_bind_int64(st, n, v ? 1 : 0)
            case let v as Int: sqlite3_bind_int64(st, n, Int64(v))
            case let v as Int64: sqlite3_bind_int64(st, n, v)
            case let v as Int32: sqlite3_bind_int64(st, n, Int64(v))
            case let v as Double: sqlite3_bind_double(st, n, v)
            case let v as String: sqlite3_bind_text(st, n, v, -1, transient)
            default: sqlite3_bind_text(st, n, String(describing: a!), -1, transient)
            }
        }
    }

    /// Runs a statement without results; returns the number of changed rows.
    @discardableResult
    public func run(_ sql: String, _ args: [Any?] = []) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &st, nil) == SQLITE_OK else { throw DbError(message: message() + " in " + sql.prefix(80)) }
        defer { sqlite3_finalize(st) }
        bind(st, args)
        let rc = sqlite3_step(st)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw DbError(message: message()) }
        return Int(sqlite3_changes(handle))
    }

    public var lastInsertId: Int64 { sqlite3_last_insert_rowid(handle) }

    public func query(_ sql: String, _ args: [Any?] = []) throws -> [Row] {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &st, nil) == SQLITE_OK else { throw DbError(message: message() + " in " + sql.prefix(80)) }
        defer { sqlite3_finalize(st) }
        bind(st, args)
        var out: [Row] = []
        let cols = sqlite3_column_count(st)
        let names = (0..<cols).map { String(cString: sqlite3_column_name(st, $0)) }
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw DbError(message: message()) }
            var row = Row()
            for i in 0..<cols {
                switch sqlite3_column_type(st, i) {
                case SQLITE_INTEGER: row[names[Int(i)]] = sqlite3_column_int64(st, i)
                case SQLITE_FLOAT: row[names[Int(i)]] = sqlite3_column_double(st, i)
                case SQLITE_NULL: break
                default: row[names[Int(i)]] = String(cString: sqlite3_column_text(st, i))
                }
            }
            out.append(row)
        }
        return out
    }

    public func one(_ sql: String, _ args: [Any?] = []) throws -> Row? { try query(sql, args).first }

    public func scalar(_ sql: String, _ args: [Any?] = []) -> Int64 {
        guard let r = try? query(sql, args).first, let v = r.values.first else { return 0 }
        if let i = v as? Int64 { return i }
        if let d = v as? Double { return Int64(d) }
        return 0
    }

    /// Prepared insert for the importer: bind values, step, reset.
    public final class Statement {
        fileprivate var st: OpaquePointer?
        fileprivate let conn: Connection

        fileprivate init(_ conn: Connection, _ sql: String) throws {
            self.conn = conn
            guard sqlite3_prepare_v2(conn.handle, sql, -1, &st, nil) == SQLITE_OK else { throw DbError(message: conn.message()) }
        }

        deinit { sqlite3_finalize(st) }

        /// Executes with the given values and returns the new row id.
        @discardableResult
        public func insert(_ args: [Any?]) throws -> Int64 {
            sqlite3_reset(st)
            sqlite3_clear_bindings(st)
            conn.bind(st, args)
            guard sqlite3_step(st) == SQLITE_DONE else { throw DbError(message: conn.message()) }
            return sqlite3_last_insert_rowid(conn.handle)
        }
    }

    public func prepare(_ sql: String) throws -> Statement { try Statement(self, sql) }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE")
        do {
            let r = try body()
            try exec("COMMIT")
            return r
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}
