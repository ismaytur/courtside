// One libtorrent session for the whole app (TorrentBridge's C API underneath). A background
// thread pumps libtorrent's events: finished pieces wake whoever is waiting for a byte range.
// Tracker/peer traffic is libtorrent's own; it doesn't go through Web/fetch.

import Foundation
import TorrentBridge

public enum TorrentError: Error, CustomStringConvertible {
  case session(String)
  case add(String)
  case badRange
  case removed
  case failed(String)

  public var description: String {
    switch self {
    case .session(let m): return "torrent session: \(m)"
    case .add(let m): return "couldn't add torrent: \(m)"
    case .badRange: return "byte range outside the file"
    case .removed: return "torrent was removed"
    case .failed(let m): return "torrent error: \(m)"
    }
  }
}

public final class TorrentSession: @unchecked Sendable {
  let handle: OpaquePointer
  private let lock = NSLock()
  private var torrents: [UInt32: Torrent] = [:]

  /// - Parameters:
  ///   - listenPort: incoming peer connections; 0 lets the OS pick.
  ///   - uploadKBps: upload cap (Settings.storage.uploadKBps); 0 = unlimited.
  public init(listenPort: Int = 6881, uploadKBps: Double = 0) throws {
    var err = [CChar](repeating: 0, count: 512)
    let listen = "0.0.0.0:\(listenPort),[::]:\(listenPort)"
    guard let s = tb_session_new(listen, Self.bps(uploadKBps), &err, err.count) else {
      throw TorrentError.session(String(cString: err))
    }
    handle = s
    // The pump holds the session only for one poll at a time, so dropping the last reference
    // elsewhere ends it (and deinit then runs on whichever thread let go last).
    let thread = Thread { [weak self] in
      while let session = self { session.pollOnce() }
    }
    thread.name = "courtside.torrent-events"
    thread.qualityOfService = .userInitiated
    thread.start()
  }

  deinit { tb_session_free(handle) }

  public func setUploadLimit(kbps: Double) {
    tb_session_set_upload_limit(handle, Self.bps(kbps))
  }

  /// Download cap, 0 = unlimited (for tests: makes "is it fetched on demand?" visible).
  public func setDownloadLimit(kbps: Double) {
    tb_session_set_download_limit(handle, Self.bps(kbps))
  }

  /// Add a torrent from its .torrent file. Nothing downloads until files are selected
  /// (`Torrent.select`), unless `selectAll`.
  public func add(torrent data: Data, saveTo folder: URL, selectAll: Bool = false) throws -> Torrent {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var err = [CChar](repeating: 0, count: 512)
    let ptr = data.withUnsafeBytes { raw in
      tb_add(handle, raw.baseAddress, raw.count, folder.path, selectAll ? 0 : 1, &err, err.count)
    }
    guard let ptr else { throw TorrentError.add(String(cString: err)) }
    let t = Torrent(session: self, handle: ptr, folder: folder)
    lock.withLock { torrents[t.id] = t }
    return t
  }

  /// Stop and forget a torrent; `deleteFiles` also removes what it downloaded.
  public func remove(_ torrent: Torrent, deleteFiles: Bool = false) {
    lock.withLock { torrents[torrent.id] = nil }
    torrent.detach { ptr in tb_remove(handle, ptr, deleteFiles ? 1 : 0) }
  }

  private static func bps(_ kbps: Double) -> Int32 { Int32(max(0, min(kbps * 1024, Double(Int32.max)))) }

  // MARK: events

  private func pollOnce() {
    let ctx = Unmanaged.passUnretained(self).toOpaque()
    tb_session_poll(handle, 250, { ctx, kind, id, piece, message in
      let session = Unmanaged<TorrentSession>.fromOpaque(ctx!).takeUnretainedValue()
      session.deliver(kind: kind, id: id, piece: piece, message: message.map { String(cString: $0) } ?? "")
    }, ctx)
  }

  private func deliver(kind: Int32, id: UInt32, piece: Int32, message: String) {
    let t = lock.withLock { torrents[id] }
    guard let t else { return }
    switch Int(kind) {
    case Int(TB_EVENT_PIECE_FINISHED): t.pieceFinished(Int(piece))
    case Int(TB_EVENT_ERROR): t.failed(message)
    default: break
    }
  }
}
