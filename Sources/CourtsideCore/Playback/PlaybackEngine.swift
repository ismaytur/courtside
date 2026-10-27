// Everything between "this game's .torrent" and "a URL AVPlayer can play": one torrent session
// and one stream server for the app, and the games opened so far. A game keeps downloading (and
// then seeding, within the upload cap) after the player closes, until it's cleared or the app quits.
//
// A complete download plays straight from its files; otherwise each part is a TorrentFileSource
// whose bytes wait for their pieces. Either way the part is served as HLS (MediaStream).

import Foundation

public final class OpenGame: @unchecked Sendable {
  public let id: String
  public let folder: GameFolder
  public let parts: [String]                  // relative paths, playing order
  public let torrent: Torrent?
  let files: [TorrentFile]                    // the parts in the torrent (empty when playing local files)
  var streams: [Int: MediaStream] = [:]

  init(id: String, folder: GameFolder, parts: [String], torrent: Torrent?, files: [TorrentFile]) {
    self.id = id; self.folder = folder; self.parts = parts; self.torrent = torrent; self.files = files
  }

  public var labels: [String] { parts.enumerated().map { GameFolder.label($1, index: $0) } }

  /// 0…1 of the parts downloaded; 1 for local files.
  public var progress: Double { torrent?.status?.progress ?? 1 }
}

public struct PlayableURL: Sendable {
  public let url: URL
  public let duration: Double
}

public final class PlaybackEngine: @unchecked Sendable {
  private let lock = NSLock()
  private var session: TorrentSession?
  private var server: StreamServer?
  private var games: [String: OpenGame] = [:]
  private var uploadKBps: Double
  private var lan: Bool
  public var log: @Sendable (String) -> Void = { Log.info("playback", $0) }
  /// A game finished downloading (called on the torrent event thread).
  public var onComplete: (@Sendable (String) -> Void)?

  /// Peers to connect every torrent to directly, "host:port,…" (COURTSIDE_TEST_PEERS): lets the
  /// end-to-end test seed a torrent on this Mac without a tracker.
  let testPeers: [(String, Int)]

  public init(uploadKBps: Double, lan: Bool) {
    self.uploadKBps = uploadKBps
    self.lan = lan
    testPeers = (ProcessInfo.processInfo.environment["COURTSIDE_TEST_PEERS"] ?? "").split(separator: ",").compactMap { p in
      let hp = p.split(separator: ":")
      guard hp.count == 2, let port = Int(hp[1]) else { return nil }
      return (String(hp[0]), port)
    }
  }

  public func setUploadLimit(kbps: Double) {
    lock.withLock { uploadKBps = kbps; session?.setUploadLimit(kbps: kbps) }
  }

  /// Download cap, 0 = unlimited (tests: makes a far seek fetch its pieces on demand).
  public func setDownloadLimit(kbps: Double) throws { try torrentSession().setDownloadLimit(kbps: kbps) }

  /// Serve on the home network (AirPlay) from the next part played on.
  public func setLAN(_ on: Bool) { lock.withLock { lan = on } }

  public func game(_ id: String) -> OpenGame? { lock.withLock { games[id] } }
  public var openIDs: [String] { lock.withLock { Array(games.keys) } }

  private func torrentSession() throws -> TorrentSession {
    try lock.withLock {
      if let session { return session }
      let s = try TorrentSession(listenPort: 0, uploadKBps: uploadKBps)
      session = s
      return s
    }
  }

  /// The running server, (re)started when the home-network setting changed.
  private func streamServer() async throws -> StreamServer {
    let (current, wantLAN) = lock.withLock { (server, lan) }
    if let current, current.lan == wantLAN { return current }
    let s = try StreamServer(lan: wantLAN)
    try await s.start()
    let old = lock.withLock { () -> StreamServer? in
      let old = server
      server = s
      for g in games.values { for st in g.streams.values { s.add(st) } }
      return old
    }
    old?.stop()
    return s
  }

  // MARK: opening

  /// Open a game: from its complete files, or by adding its torrent (`torrentData`, else the saved
  /// game.torrent) to the session. Already open: the same object.
  public func open(id: String, folder: GameFolder, torrentData: Data?) throws -> OpenGame {
    if let g = game(id) { return g }
    Log.info("playback", "open \(id) (\(torrentData != nil ? "new torrent" : "from its folder"))")
    if let state = folder.state, state.complete, !state.parts.isEmpty,
       state.parts.allSatisfy({ FileManager.default.fileExists(atPath: folder.file($0).path) }) {
      let g = OpenGame(id: id, folder: folder, parts: state.parts, torrent: nil, files: [])
      lock.withLock { games[id] = g }
      return g
    }
    guard let data = torrentData ?? (try? Data(contentsOf: folder.torrentFile)) else { throw PlaybackError.noTorrent }
    if torrentData != nil {
      try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
      try data.write(to: folder.torrentFile, options: .atomic)
    }
    let t = try torrentSession().add(torrent: data, saveTo: folder.url)
    let files = GameFolder.parts(of: t.files)
    guard !files.isEmpty else { try? torrentSession().remove(t); throw PlaybackError.noVideo }
    t.select(files: Set(files.map(\.index)))
    for (host, port) in testPeers { t.connect(peer: host, port: port) }
    let parts = files.map(\.path)
    folder.update { $0.parts = parts; $0.part = min($0.part, parts.count - 1) }
    let g = OpenGame(id: id, folder: folder, parts: parts, torrent: t, files: files)
    t.onFinished = { [weak self, weak g] in
      guard let g, t.isComplete(files) else { return }
      g.folder.update { $0.complete = true }
      self?.log("\(id): download complete")
      self?.onComplete?(id)
    }
    lock.withLock { games[id] = g }
    // Already complete (all checked on disk) before the handler was set.
    if t.isComplete(files) { t.onFinished?() }
    return g
  }

  /// The HLS URL of one part; builds its keyframe index first (waits for the bytes that needs).
  public func play(_ g: OpenGame, part: Int) async throws -> PlayableURL {
    Log.info("playback", "play \(g.id) part \(part + 1) of \(g.parts.count)")
    let server = try await streamServer()
    let stream = try lock.withLock { () -> MediaStream in
      if let s = g.streams[part] { return s }
      let source: MediaSource
      if let t = g.torrent { source = TorrentFileSource(torrent: t, file: g.files[part]) }
      else { source = try LocalFileSource(g.folder.file(g.parts[part])) }
      let s = MediaStream(id: "\(g.id)-p\(part)", source: source, cacheDir: g.folder.hls(part: part), tools: try MediaTools.locate())
      s.log = { [log] in log("\(g.id) part \(part): \($0)") }
      g.streams[part] = s
      return s
    }
    server.add(stream)
    if let t = g.torrent { t.focus(file: g.files[part], window: 0..<min(g.files[part].size, 32 << 20)) }
    let pl = try await stream.playlist()
    return PlayableURL(url: server.playlistURL(for: stream), duration: pl.index.duration)
  }

  // MARK: closing

  /// Stop a game's torrent and forget it (its files stay unless `deleteFolder`).
  public func close(_ id: String, deleteFolder: Bool = false) {
    let (g, server, session) = lock.withLock { (games.removeValue(forKey: id), server, session) }
    if let g {
      for s in g.streams.values { server?.remove(s.id) }
      if let t = g.torrent { session?.remove(t) }
    }
    if deleteFolder, let g { g.folder.delete() }
  }

  public func closeAll() {
    for id in openIDs { close(id) }
  }
}

public enum PlaybackError: LocalizedError {
  case noTorrent, noVideo, notPosted

  public var errorDescription: String? {
    switch self {
    case .noTorrent: "There's no torrent for this game yet."
    case .noVideo: "This torrent has no video file."
    case .notPosted: "This game isn't on 720pier yet."
    }
  }
}
