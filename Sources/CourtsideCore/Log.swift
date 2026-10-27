// Rotating file log, mirrored to the system log (Console.app, subsystem com.ismaytur.courtside).
//   ~/Library/Logs/Courtside/courtside.log      ($COURTSIDE_HOME/logs/ when COURTSIDE_HOME is set)
//   rotated at 5 MB into courtside.1.log … courtside.5.log
// Lines are "2026-10-28 14:03:12.345 INFO  [720pier] message". Anything that could be a secret goes
// through `redact` first: passwords, cookies, form tokens, phpBB session ids in URLs.

import Foundation
import os

public enum Log {
  public enum Level: String { case debug = "DEBUG", info = "INFO", warn = "WARN", error = "ERROR" }

  static let maxBytes = 5_000_000
  static let keep = 5
  private static let queue = DispatchQueue(label: "com.ismaytur.courtside.log")
  private static let system = Logger(subsystem: "com.ismaytur.courtside", category: "app")
  nonisolated(unsafe) static var dir: URL = defaultDir()

  static func defaultDir() -> URL {
    if let home = ProcessInfo.processInfo.environment["COURTSIDE_HOME"], !home.isEmpty {
      return URL(fileURLWithPath: (home as NSString).expandingTildeInPath).appendingPathComponent("logs")
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Courtside")
  }

  public static var folder: URL { dir }
  public static var file: URL { dir.appendingPathComponent("courtside.log") }

  public static func debug(_ area: String, _ message: String) { write(.debug, area, message) }
  public static func info(_ area: String, _ message: String) { write(.info, area, message) }
  public static func warn(_ area: String, _ message: String) { write(.warn, area, message) }
  public static func error(_ area: String, _ message: String) { write(.error, area, message) }

  public static func write(_ level: Level, _ area: String, _ message: String) {
    let text = redact(message)
    let line = "\(stamp()) \(level.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0)) [\(area)] \(text)\n"
    switch level {
    case .debug: system.debug("[\(area, privacy: .public)] \(text, privacy: .public)")
    case .info: system.info("[\(area, privacy: .public)] \(text, privacy: .public)")
    case .warn, .error: system.error("[\(area, privacy: .public)] \(text, privacy: .public)")
    }
    queue.async { append(line) }
  }

  /// Wait until everything written so far is on disk (tests, before copying the log).
  public static func flush() { queue.sync {} }

  private static func append(_ line: String) {
    let fm = FileManager.default
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    if let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int, size + line.utf8.count > maxBytes { rotate() }
    if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil) }
    guard let h = try? FileHandle(forWritingTo: file) else { return }
    defer { try? h.close() }
    _ = try? h.seekToEnd()
    try? h.write(contentsOf: Data(line.utf8))
  }

  /// courtside.log -> .1 -> .2 … ; the oldest beyond `keep` is dropped.
  static func rotate() {
    let fm = FileManager.default
    let numbered = { (n: Int) in dir.appendingPathComponent("courtside.\(n).log") }
    try? fm.removeItem(at: numbered(keep))
    for n in stride(from: keep - 1, through: 1, by: -1) where fm.fileExists(atPath: numbered(n).path) {
      try? fm.moveItem(at: numbered(n), to: numbered(n + 1))
    }
    try? fm.moveItem(at: file, to: numbered(1))
  }

  private static func stamp() -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f.string(from: Date())
  }

  // MARK: secrets

  /// Blank out values that must never reach a log: password/token/cookie-like keys in query strings
  /// and forms (key=value), and Cookie/Set-Cookie headers.
  public static func redact(_ s: String) -> String {
    var out = s
    let keys = "password|passwd|pass|sid|form_token|creation_time|token|auth|session|cookie|key"
    out = out.replacingOccurrences(of: #"(?i)\b("# + keys + #")=([^&\s"';,]+)"#, with: "$1=…", options: .regularExpression)
    out = out.replacingOccurrences(of: #"(?i)\b(set-cookie|cookie)\s*:\s*[^\n]*"#, with: "$1: …", options: .regularExpression)
    out = out.replacingOccurrences(of: #"\b[0-9a-f]{32,}\b"#, with: "…", options: .regularExpression) // session-id-like hex
    return out
  }

  /// The visible text of an HTML page, shortened and redacted: enough to read what a page said
  /// (an error, a block page, "wrong password") without logging the page.
  public static func snippet(_ html: String, limit: Int = 300) -> String {
    var t = html.replacingOccurrences(of: #"(?is)<(script|style)\b.*?</\1>"#, with: " ", options: .regularExpression)
    t = t.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
    t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    return redact(String(t.prefix(limit)))
  }

  // MARK: reading back

  /// The lines of the most recent run of `area` that starts with a line containing `marker`
  /// (e.g. the last sign-in), from the current log file.
  public static func lastRun(area: String, marker: String) -> String {
    flush()
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { return "" }
    let lines = text.split(separator: "\n").map(String.init).filter { $0.contains("[\(area)]") }
    guard let start = lines.lastIndex(where: { $0.contains(marker) }) else { return lines.suffix(40).joined(separator: "\n") }
    return lines[start...].joined(separator: "\n")
  }
}
