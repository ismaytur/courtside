// The bundled ffmpeg/ffprobe (built by `mise run vendor`, copied into the app's Resources).
// Never Homebrew's: a PATH lookup is deliberately not part of the search.

import Foundation

public struct MediaTools: Sendable {
  public let ffmpeg: URL
  public let ffprobe: URL

  public enum Failure: Error, CustomStringConvertible {
    case notFound
    case failed(tool: String, status: Int32, stderr: String)
    public var description: String {
      switch self {
      case .notFound: return "ffmpeg/ffprobe not found (run `mise run vendor`)"
      case .failed(let tool, let status, let stderr): return "\(tool) exited \(status): \(stderr.suffix(800))"
      }
    }
  }

  public init(ffmpeg: URL, ffprobe: URL) {
    self.ffmpeg = ffmpeg
    self.ffprobe = ffprobe
  }

  /// $COURTSIDE_FFMPEG_DIR, next to the executable / in the app's Resources, else the repo's
  /// vendor/build/ffmpeg/bin (development builds).
  public static func locate() throws -> MediaTools {
    var dirs: [URL] = []
    if let env = ProcessInfo.processInfo.environment["COURTSIDE_FFMPEG_DIR"], !env.isEmpty {
      dirs.append(URL(fileURLWithPath: env))
    }
    if let res = Bundle.main.resourceURL { dirs.append(res) }
    dirs.append(Bundle.main.bundleURL)
    if let exe = Bundle.main.executableURL { dirs.append(exe.deletingLastPathComponent()) }
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()  // …/Sources/CourtsideCore/Media
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    dirs.append(repo.appendingPathComponent("vendor/build/ffmpeg/bin"))
    for d in dirs {
      let f = d.appendingPathComponent("ffmpeg"), p = d.appendingPathComponent("ffprobe")
      if FileManager.default.isExecutableFile(atPath: f.path), FileManager.default.isExecutableFile(atPath: p.path) {
        return MediaTools(ffmpeg: f, ffprobe: p)
      }
    }
    throw Failure.notFound
  }

  /// Run a tool to completion; returns stdout (stderr goes into the error on failure).
  /// Cancelling the calling task terminates the process.
  @discardableResult
  public static func run(_ tool: URL, _ args: [String], stderrToStdout: Bool = false) async throws -> Data {
    let p = Process()
    p.executableURL = tool
    p.arguments = args
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = stderrToStdout ? out : err
    p.standardInput = FileHandle.nullDevice

    // Drain both pipes while it runs (a full pipe would block the tool).
    final class Box: @unchecked Sendable { var out = Data(); var err = Data(); let lock = NSLock() }
    let box = Box()
    out.fileHandleForReading.readabilityHandler = { h in
      let d = h.availableData; box.lock.withLock { box.out.append(d) }
    }
    if !stderrToStdout {
      err.fileHandleForReading.readabilityHandler = { h in
        let d = h.availableData; box.lock.withLock { box.err.append(d) }
      }
    }
    let status: Int32 = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int32, Error>) in
        p.terminationHandler = { c.resume(returning: $0.terminationStatus) }
        do { try p.run() } catch { p.terminationHandler = nil; c.resume(throwing: error) }
      }
    } onCancel: {
      if p.isRunning { p.terminate() }
    }
    out.fileHandleForReading.readabilityHandler = nil
    err.fileHandleForReading.readabilityHandler = nil
    // Whatever arrived after the last handler call.
    let restOut = (try? out.fileHandleForReading.readToEnd()) ?? nil
    let restErr = stderrToStdout ? nil : ((try? err.fileHandleForReading.readToEnd()) ?? nil)
    let (stdout, stderr) = box.lock.withLock { () -> (Data, Data) in
      if let restOut { box.out.append(restOut) }
      if let restErr { box.err.append(restErr) }
      return (box.out, box.err)
    }
    try Task.checkCancellation()
    guard status == 0 else {
      throw Failure.failed(tool: tool.lastPathComponent, status: status,
                           stderr: String(decoding: stderrToStdout ? stdout : stderr, as: UTF8.self))
    }
    return stdout
  }
}
