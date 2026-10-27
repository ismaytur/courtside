// A torrent in the session: its files, which of them to download, progress, and streaming. For
// streaming, `waitFor(file:range:)` gives the range's pieces deadlines (so libtorrent fetches them
// first, in order) and returns once they're all verified on disk.

import Foundation
import TorrentBridge

public struct TorrentFile: Sendable, Equatable {
  public let index: Int
  public let path: String   // relative to the torrent's folder
  public let size: Int64
  public let offset: Int64  // where it starts in the torrent's byte stream
}

public struct TorrentStatus: Sendable {
  public let progress: Double        // 0…1 of the selected files
  public let wanted: Int64
  public let wantedDone: Int64
  public let downloadBps: Int
  public let uploadBps: Int
  public let peers: Int
  public let seeds: Int
  public let uploaded: Int64
  public let state: Int              // libtorrent's torrent_status::state_t
}

public final class Torrent: @unchecked Sendable {
  public let id: UInt32
  public let name: String
  public let infoHash: String
  public let folder: URL
  public let files: [TorrentFile]
  public let pieceLength: Int
  public let pieceCount: Int

  private weak var session: TorrentSession?
  private let lock = NSLock()
  private var ptr: OpaquePointer?
  private var waiters: [Int: [CheckedContinuation<Void, Error>]] = [:]  // piece -> waiting tasks
  private var error: String?

  /// Called (on the event thread) when every selected file is downloaded.
  public var onFinished: (@Sendable () -> Void)? {
    get { lock.withLock { finishedHandler } }
    set { lock.withLock { finishedHandler = newValue } }
  }
  private var finishedHandler: (@Sendable () -> Void)?

  init(session: TorrentSession, handle: OpaquePointer, folder: URL) {
    self.session = session
    ptr = handle
    self.folder = folder
    id = tb_id(handle)
    name = Self.string { tb_name(handle, $0, $1) }
    infoHash = Self.string { tb_info_hash(handle, $0, $1) }
    pieceLength = Int(tb_piece_length(handle))
    pieceCount = Int(tb_num_pieces(handle))
    files = (0..<Int(tb_num_files(handle))).map { i in
      TorrentFile(index: i, path: Self.string { tb_file_path(handle, Int32(i), $0, $1) },
                  size: tb_file_size(handle, Int32(i)), offset: tb_file_offset(handle, Int32(i)))
    }
  }

  public func url(of file: TorrentFile) -> URL { folder.appendingPathComponent(file.path) }

  /// The biggest file: for a game that's the video (the rest are samples, .nfo, posters).
  public var mainFile: TorrentFile? { files.max { $0.size < $1.size } }

  // MARK: selection and status

  /// Download only these files (others are skipped, apart from pieces they share with them).
  public func select(files indexes: Set<Int>) {
    with { p in for f in files { tb_file_priority(p, Int32(f.index), indexes.contains(f.index) ? 4 : 0) } }
  }

  public var status: TorrentStatus? {
    with { p in
      var s = tb_status()
      tb_get_status(p, &s)
      return TorrentStatus(progress: s.progress, wanted: s.wanted, wantedDone: s.wanted_done,
                           downloadBps: Int(s.download_bps), uploadBps: Int(s.upload_bps), peers: Int(s.peers),
                           seeds: Int(s.seeds), uploaded: s.uploaded, state: Int(s.state))
    }
  }

  /// Verified bytes per file.
  public func fileProgress() -> [Int64] {
    with { p in
      var out = [Int64](repeating: 0, count: files.count)
      tb_file_progress(p, &out, Int32(out.count))
      return out
    } ?? []
  }

  // MARK: streaming

  /// Pieces covering a byte range of a file.
  public func pieces(file: TorrentFile, range: Range<Int64>) -> ClosedRange<Int>? {
    guard !range.isEmpty, range.lowerBound >= 0, range.lowerBound < file.size else { return nil }
    let start = file.offset + range.lowerBound
    let end = file.offset + min(range.upperBound, file.size) - 1
    return Int(start / Int64(pieceLength))...Int(end / Int64(pieceLength))
  }

  public func has(file: TorrentFile, range: Range<Int64>) -> Bool {
    guard let ps = pieces(file: file, range: range) else { return false }
    return with { p in ps.allSatisfy { tb_have_piece(p, Int32($0)) != 0 } } ?? false
  }

  /// Fetch these bytes before anything else: piece deadlines from `deadlineMs`, `stepMs` apart.
  public func prioritize(file: TorrentFile, range: Range<Int64>, deadlineMs: Int = 0, stepMs: Int = 100) {
    guard let ps = pieces(file: file, range: range) else { return }
    with { p in tb_set_deadlines(p, Int32(ps.lowerBound), Int32(ps.upperBound), Int32(deadlineMs), Int32(stepMs)) }
  }

  /// Streaming focus: the window's pieces at top priority, the rest of the file low (still
  /// downloading, but only with bandwidth the window doesn't need).
  public func focus(file: TorrentFile, window: Range<Int64>) {
    guard let all = pieces(file: file, range: 0..<file.size), let win = pieces(file: file, range: window) else { return }
    with { p in
      tb_set_piece_priorities(p, Int32(all.lowerBound), Int32(all.upperBound), 1)
      tb_set_piece_priorities(p, Int32(win.lowerBound), Int32(win.upperBound), 7)
    }
  }

  /// Drop all deadlines (e.g. after a seek, so the old position stops competing).
  public func clearDeadlines() { with { tb_clear_deadlines($0) } }

  /// Return once [range) of the file is downloaded and verified, prioritizing it meanwhile.
  public func waitFor(file: TorrentFile, range: Range<Int64>, deadlineMs: Int = 0) async throws {
    guard let ps = pieces(file: file, range: range) else { throw TorrentError.badRange }
    prioritize(file: file, range: range, deadlineMs: deadlineMs)
    for piece in ps { try await waitFor(piece: piece) }
  }

  public func waitFor(piece: Int) async throws {
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
      lock.lock()
      if let error { lock.unlock(); c.resume(throwing: TorrentError.failed(error)); return }
      guard let p = ptr else { lock.unlock(); c.resume(throwing: TorrentError.removed); return }
      // Checked under the lock that pieceFinished takes, so a piece finishing right now can't
      // slip between the check and the registration.
      if tb_have_piece(p, Int32(piece)) != 0 { lock.unlock(); c.resume(); return }
      waiters[piece, default: []].append(c)
      lock.unlock()
    }
  }

  func pieceFinished(_ piece: Int) {
    let ws = lock.withLock { waiters.removeValue(forKey: piece) ?? [] }
    for w in ws { w.resume() }
  }

  /// libtorrent checked the data already on disk. Pieces found there don't get piece events, so
  /// wake whoever waits for one of them.
  func checked() {
    let ready = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
      guard let p = ptr else { return [] }
      let have = waiters.keys.filter { tb_have_piece(p, Int32($0)) != 0 }
      return have.flatMap { waiters.removeValue(forKey: $0) ?? [] }
    }
    for w in ready { w.resume() }
  }

  /// Connect to a peer directly (a seeder on this Mac in tests: no tracker needed).
  public func connect(peer host: String, port: Int) {
    with { p in _ = tb_connect_peer(p, host, Int32(port)) }
  }

  /// Whether every byte of these files is downloaded and verified.
  public func isComplete(_ files: [TorrentFile]) -> Bool {
    let done = fileProgress()
    return !files.isEmpty && files.allSatisfy { $0.index < done.count && done[$0.index] >= $0.size }
  }

  func failed(_ message: String) {
    lock.lock()
    error = message
    let ws = waiters.values.flatMap { $0 }
    waiters = [:]
    lock.unlock()
    for w in ws { w.resume(throwing: TorrentError.failed(message)) }
  }

  func detach(_ body: (OpaquePointer) -> Void) {
    lock.lock()
    let p = ptr
    ptr = nil
    let ws = waiters.values.flatMap { $0 }
    waiters = [:]
    if let p { body(p) }
    lock.unlock()
    for w in ws { w.resume(throwing: TorrentError.removed) }
  }

  @discardableResult
  private func with<T>(_ body: (OpaquePointer) -> T) -> T? {
    lock.lock(); defer { lock.unlock() }
    guard let p = ptr else { return nil }
    return body(p)
  }

  private static func string(_ fill: (UnsafeMutablePointer<CChar>, Int) -> Int) -> String {
    var buf = [CChar](repeating: 0, count: 4096)
    _ = fill(&buf, buf.count)
    return String(cString: buf)
  }
}
