// A small wrapper over the system SQLite: open, run statements with bound values, read rows as
// dictionaries. Rollback-journal mode (no WAL) so games.db is always one complete file.

import Foundation
import SQLite3

public typealias Row = [String: Any]

public struct DatabaseError: LocalizedError {
  public let message: String
  public var errorDescription: String? { message }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class Database: @unchecked Sendable {
  private var handle: OpaquePointer?
  private let lock = NSRecursiveLock() // one statement at a time, from any thread

  public init(path: String) throws {
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
      let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "can't open \(path)"
      sqlite3_close(handle)
      throw DatabaseError(message: msg)
    }
    try exec("PRAGMA journal_mode = DELETE; PRAGMA foreign_keys = ON;")
  }

  deinit { sqlite3_close(handle) }

  /// Run one or more statements without parameters (schema, pragmas).
  public func exec(_ sql: String) throws {
    lock.lock(); defer { lock.unlock() }
    var err: UnsafeMutablePointer<CChar>?
    if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
      let msg = err.map { String(cString: $0) } ?? "exec failed"
      sqlite3_free(err)
      throw DatabaseError(message: msg)
    }
  }

  /// Run a statement with `?` parameters; returns the number of changed rows.
  @discardableResult
  public func run(_ sql: String, _ args: [Any?] = []) throws -> Int {
    lock.lock(); defer { lock.unlock() }
    let stmt = try prepare(sql, args)
    defer { sqlite3_finalize(stmt) }
    let rc = sqlite3_step(stmt)
    guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw lastError() }
    return Int(sqlite3_changes(handle))
  }

  /// Rows of a query as [column: value] (Int64, Double, String or NSNull).
  public func query(_ sql: String, _ args: [Any?] = []) throws -> [Row] {
    lock.lock(); defer { lock.unlock() }
    let stmt = try prepare(sql, args)
    defer { sqlite3_finalize(stmt) }
    var rows: [Row] = []
    while true {
      let rc = sqlite3_step(stmt)
      if rc == SQLITE_DONE { break }
      guard rc == SQLITE_ROW else { throw lastError() }
      var row: Row = [:]
      for i in 0..<sqlite3_column_count(stmt) {
        let name = String(cString: sqlite3_column_name(stmt, i))
        switch sqlite3_column_type(stmt, i) {
        case SQLITE_INTEGER: row[name] = sqlite3_column_int64(stmt, i)
        case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, i)
        case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(stmt, i))
        default: row[name] = NSNull()
        }
      }
      rows.append(row)
    }
    return rows
  }

  /// Run `body` in one transaction (much faster for many writes; all or nothing).
  public func transaction<T>(_ body: () throws -> T) throws -> T {
    lock.lock(); defer { lock.unlock() }
    try exec("BEGIN")
    do { let out = try body(); try exec("COMMIT"); return out }
    catch { try? exec("ROLLBACK"); throw error }
  }

  private func prepare(_ sql: String, _ args: [Any?]) throws -> OpaquePointer? {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { throw lastError() }
    for (i, arg) in args.enumerated() {
      let idx = Int32(i + 1)
      switch arg {
      case nil, is NSNull: sqlite3_bind_null(stmt, idx)
      case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
      case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
      case let v as Bool: sqlite3_bind_int64(stmt, idx, v ? 1 : 0)
      case let v as Double: sqlite3_bind_double(stmt, idx, v)
      case let v as String: sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
      default: sqlite3_bind_text(stmt, idx, String(describing: arg!), -1, SQLITE_TRANSIENT)
      }
    }
    return stmt
  }

  private func lastError() -> DatabaseError { DatabaseError(message: String(cString: sqlite3_errmsg(handle))) }
}

extension Row {
  public func string(_ k: String) -> String? { self[k] as? String }
  public func int(_ k: String) -> Int? { (self[k] as? Int64).map(Int.init) }
  public func double(_ k: String) -> Double? { (self[k] as? Double) ?? (self[k] as? Int64).map(Double.init) }
}
