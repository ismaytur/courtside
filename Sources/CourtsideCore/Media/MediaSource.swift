// A video file that may still be downloading. Everything that reads it (our MKV index reader,
// ffprobe/ffmpeg through StreamServer's /raw endpoint) first waits for the bytes it needs, so
// nobody ever reads the zeros of a not-yet-downloaded piece.

import Foundation

public protocol MediaSource: AnyObject, Sendable {
  /// The file on disk (complete or sparse).
  var file: URL { get }
  var size: Int64 { get }
  /// Return once these bytes are on disk; for a torrent, wanted within `deadlineMs`.
  func ensure(_ range: Range<Int64>, deadlineMs: Int) async throws
  /// Hint: these bytes will be read soon (e.g. the rest of a segment).
  func prefetch(_ range: Range<Int64>, deadlineMs: Int)
  /// The player is waiting at `offset`: put the bytes from there first.
  func focus(at offset: Int64)
}

extension MediaSource {
  public func ensure(_ range: Range<Int64>) async throws { try await ensure(range, deadlineMs: 0) }
  public func prefetch(_ range: Range<Int64>) { prefetch(range, deadlineMs: 1500) }
}

extension MediaSource {
  /// Read bytes, waiting for them first. Clamped to the file.
  public func read(_ range: Range<Int64>) async throws -> Data {
    let r = max(0, range.lowerBound)..<min(size, range.upperBound)
    guard !r.isEmpty else { return Data() }
    try await ensure(r)
    let h = try FileHandle(forReadingFrom: file)
    defer { try? h.close() }
    try h.seek(toOffset: UInt64(r.lowerBound))
    return try h.read(upToCount: r.count) ?? Data()
  }
}

/// A file that's already complete.
public final class LocalFileSource: MediaSource {
  public let file: URL
  public let size: Int64

  public init(_ file: URL) throws {
    self.file = file
    let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
    size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
  }

  public func ensure(_ range: Range<Int64>, deadlineMs: Int) async throws {}
  public func prefetch(_ range: Range<Int64>, deadlineMs: Int) {}
  public func focus(at offset: Int64) {}
}

/// One file of a torrent, readable as it downloads.
public final class TorrentFileSource: MediaSource, @unchecked Sendable {
  public let torrent: Torrent
  public let torrentFile: TorrentFile
  public var file: URL { torrent.url(of: torrentFile) }
  public var size: Int64 { torrentFile.size }

  private let lock = NSLock()
  private var focused: Range<Int64>?
  static let window: Int64 = 32 << 20

  public init(torrent: Torrent, file: TorrentFile) {
    self.torrent = torrent
    torrentFile = file
  }

  public func focus(at offset: Int64) {
    // Re-prioritizing touches every piece of the file, so only when the reader has left the
    // middle of the current window.
    let moved = lock.withLock { () -> Bool in
      if let f = focused, f.contains(offset), offset < f.upperBound - Self.window / 2 { return false }
      focused = offset..<min(size, offset + Self.window)
      return true
    }
    if moved { torrent.focus(file: torrentFile, window: offset..<min(size, offset + Self.window)) }
  }

  public func ensure(_ range: Range<Int64>, deadlineMs: Int) async throws {
    try await torrent.waitFor(file: torrentFile, range: range, deadlineMs: deadlineMs)
  }

  public func prefetch(_ range: Range<Int64>, deadlineMs: Int) {
    // Later than anything being waited on right now, but ahead of the normal rarest-first order.
    torrent.prioritize(file: torrentFile, range: range, deadlineMs: deadlineMs, stepMs: 150)
  }
}
