// A small HTTP server (Network.framework) for AVPlayer and for our own ffmpeg/ffprobe runs:
//   GET /s/<id>/index.m3u8   the VOD playlist
//   GET /s/<id>/seg-<n>.ts   a segment, remuxed on demand
//   GET /s/<id>/raw          the source file's bytes (Range), each chunk only once it's downloaded
// Bound to 127.0.0.1, or to all interfaces for AirPlay: an Apple TV fetches the playlist and
// segments itself, so it needs the Mac's LAN address, not loopback.

import Foundation
import Network

public final class StreamServer: @unchecked Sendable {
  public let lan: Bool
  public private(set) var port: UInt16 = 0
  public var log: @Sendable (String) -> Void = { _ in }

  private let listener: NWListener
  private let queue = DispatchQueue(label: "courtside.stream-server", attributes: .concurrent)
  private let lock = NSLock()
  private var streams: [String: MediaStream] = [:]

  /// - Parameters:
  ///   - port: 0 = any free port.
  ///   - lan: listen on every interface (AirPlay); otherwise loopback only.
  public init(port: UInt16 = 0, lan: Bool = false) throws {
    self.lan = lan
    let params = NWParameters.tcp
    params.allowLocalEndpointReuse = true
    if !lan {
      params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
      listener = try NWListener(using: params)
    } else {
      listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port) ?? .any)
    }
  }

  /// Start listening; returns once the port is known.
  public func start() async throws {
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
      let once = Once()
      listener.stateUpdateHandler = { [weak self] state in
        switch state {
        case .ready:
          self?.port = self?.listener.port?.rawValue ?? 0
          once.run { c.resume() }
        case .failed(let e):
          once.run { c.resume(throwing: e) }
        default: break
        }
      }
      listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
      listener.start(queue: queue)
    }
  }

  public func stop() { listener.cancel() }

  /// Serve a stream; its playlist URL is `playlistURL(for:)`.
  public func add(_ stream: MediaStream) {
    stream.input = "http://127.0.0.1:\(port)/s/\(stream.id)/raw"
    lock.withLock { streams[stream.id] = stream }
  }

  public func remove(_ id: String) { lock.withLock { streams[id] = nil } }

  /// The address players use: loopback, or the Mac's LAN address when serving the LAN.
  public func playlistURL(for stream: MediaStream) -> URL {
    let host = lan ? (Self.lanAddress() ?? "127.0.0.1") : "127.0.0.1"
    return URL(string: "http://\(host):\(port)/s/\(stream.id)/index.m3u8")!
  }

  /// First private IPv4 address of an active interface (en0 = Wi-Fi/Ethernet first).
  public static func lanAddress() -> String? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }
    var found: [(String, String)] = []
    for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
      let ifa = p.pointee
      guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
            ifa.ifa_flags & UInt32(IFF_UP) != 0, ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
      else { continue }
      let ip = String(cString: host)
      if ip.hasPrefix("169.254.") { continue }
      found.append((String(cString: ifa.ifa_name), ip))
    }
    return (found.first { $0.0 == "en0" } ?? found.first { $0.0.hasPrefix("en") } ?? found.first)?.1
  }

  // MARK: connections

  private func accept(_ conn: NWConnection) {
    conn.start(queue: queue)
    receiveRequest(conn, buffer: Data())
  }

  private func receiveRequest(_ conn: NWConnection, buffer: Data) {
    conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
      guard let self else { conn.cancel(); return }
      var buf = buffer
      if let data { buf.append(data) }
      if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
        let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
        Task { await self.respond(conn, head: head) }
      } else if error != nil || done || buf.count > 64 * 1024 {
        conn.cancel()
      } else {
        self.receiveRequest(conn, buffer: buf)
      }
    }
  }

  private struct Request {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
  }

  private func parse(_ head: String) -> Request? {
    let lines = head.components(separatedBy: "\r\n")
    let first = lines.first?.split(separator: " ") ?? []
    guard first.count >= 2 else { return nil }
    var headers: [String: String] = [:]
    for l in lines.dropFirst() {
      guard let c = l.firstIndex(of: ":") else { continue }
      headers[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
    }
    let target = String(first[1]).split(separator: "?", maxSplits: 1).map(String.init)
    var query: [String: String] = [:]
    for kv in (target.count > 1 ? target[1] : "").split(separator: "&") {
      let p = kv.split(separator: "=", maxSplits: 1).map(String.init)
      query[p[0]] = p.count > 1 ? p[1] : ""
    }
    return Request(method: String(first[0]), path: target.first ?? "/", query: query, headers: headers)
  }

  private func respond(_ conn: NWConnection, head: String) async {
    defer { conn.cancel() }
    guard let req = parse(head), req.method == "GET" || req.method == "HEAD" else {
      await send(conn, status: 400, headers: [:], body: Data()); return
    }
    let parts = req.path.split(separator: "/").map(String.init)
    let stream = lock.withLock { parts.count == 3 && parts[0] == "s" ? streams[parts[1]] : nil }
    guard let stream else { await send(conn, status: 404, headers: [:], body: Data()); return }
    let name = parts[2]
    do {
      if name == "index.m3u8" {
        let pl = try await stream.playlist()
        let body = Data(pl.m3u8 { "seg-\($0.index).ts" }.utf8)
        await send(conn, status: 200, headers: ["Content-Type": "application/vnd.apple.mpegurl"],
                   body: req.method == "HEAD" ? nil : body, length: body.count)
      } else if name.hasPrefix("seg-"), name.hasSuffix(".ts"), let i = Int(name.dropFirst(4).dropLast(3)) {
        let t0 = Date()
        let url = try await stream.segment(i)
        let body = try Data(contentsOf: url)
        log(String(format: "GET %@ %@ (%.0f KB, %.2f s)", stream.id, name, Double(body.count) / 1024, Date().timeIntervalSince(t0)))
        await sendFile(conn, req: req, body: body, type: "video/mp2t")
      } else if name == "raw" {
        await sendRaw(conn, req: req, stream: stream)
      } else {
        await send(conn, status: 404, headers: [:], body: Data())
      }
    } catch {
      log("error \(req.path): \(error)")
      await send(conn, status: 500, headers: [:], body: Data("\(error)".utf8))
    }
  }

  // MARK: responses

  /// Parses "bytes=a-b" / "bytes=a-" / "bytes=-n" against a size.
  static func byteRange(_ header: String?, size: Int64) -> Range<Int64>? {
    guard let h = header, h.hasPrefix("bytes="), !h.contains(",") else { return nil }
    let spec = h.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
    guard spec.count == 2 else { return nil }
    if spec[0].isEmpty, let n = Int64(spec[1]) { return max(0, size - n)..<size }
    guard let a = Int64(spec[0]), a < size else { return nil }
    let b = Int64(spec[1]).map { min($0, size - 1) } ?? (size - 1)
    return b >= a ? a..<(b + 1) : nil
  }

  private func sendFile(_ conn: NWConnection, req: Request, body: Data, type: String) async {
    if let r = Self.byteRange(req.headers["range"], size: Int64(body.count)) {
      let slice = body[Int(r.lowerBound)..<Int(r.upperBound)]
      await send(conn, status: 206, headers: [
        "Content-Type": type, "Content-Range": "bytes \(r.lowerBound)-\(r.upperBound - 1)/\(body.count)",
      ], body: req.method == "HEAD" ? nil : Data(slice), length: slice.count)
    } else {
      await send(conn, status: 200, headers: ["Content-Type": type],
                 body: req.method == "HEAD" ? nil : body, length: body.count)
    }
  }

  /// Source bytes, streamed chunk by chunk as the torrent delivers them. Keeps the next few MB
  /// prioritized so the download stays ahead of the reader. `?seg=N` says which segment the
  /// reader is making: read-ahead segments get later deadlines than the one being watched.
  private func sendRaw(_ conn: NWConnection, req: Request, stream: MediaStream) async {
    let source = stream.source
    let segment = req.query["seg"].flatMap { Int($0) }
    let size = source.size
    let range = Self.byteRange(req.headers["range"], size: size) ?? 0..<size
    let partial = req.headers["range"] != nil
    var headers = ["Content-Type": "application/octet-stream"]
    if partial { headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(size)" }
    guard await send(conn, status: partial ? 206 : 200, headers: headers, body: nil, length: range.count) else { return }
    if req.method == "HEAD" { return }

    let chunk: Int64 = 512 * 1024
    guard let h = try? FileHandle(forReadingFrom: source.file) else { return }
    defer { try? h.close() }
    var pos = range.lowerBound
    while pos < range.upperBound {
      let end = min(pos + chunk, range.upperBound)
      let rank = stream.urgency(of: segment)  // re-read per chunk: read-ahead becomes urgent once it's watched
      if rank == 0 { source.focus(at: pos) }
      if rank <= 3 {
        let ahead: Int64 = rank == 0 ? 8 << 20 : 2 << 20
        source.prefetch(end..<min(end + ahead, range.upperBound), deadlineMs: 1000 + 3000 * rank)
      }
      do {
        let waited = Date()
        try await source.ensure(pos..<end, deadlineMs: 3000 * rank)
        if Date().timeIntervalSince(waited) > 1 {
          log(String(format: "raw seg=%@ rank %d waited %.1f s for @%.1f MB", segment.map(String.init) ?? "-", rank,
                     Date().timeIntervalSince(waited), Double(pos) / 1e6))
        }
        try h.seek(toOffset: UInt64(pos))
        guard let data = try h.read(upToCount: Int(end - pos)), !data.isEmpty else { return }
        guard await sendBody(conn, data) else { return }  // reader hung up (ffmpeg seeks by reconnecting)
        pos += Int64(data.count)
      } catch {
        log("raw read at \(pos): \(error)")
        return
      }
    }
  }

  @discardableResult
  private func send(_ conn: NWConnection, status: Int, headers: [String: String], body: Data?, length: Int? = nil) async -> Bool {
    let reason = [200: "OK", 206: "Partial Content", 400: "Bad Request", 404: "Not Found", 500: "Internal Server Error"][status] ?? "OK"
    var head = "HTTP/1.1 \(status) \(reason)\r\n"
    var h = headers
    h["Content-Length"] = String(length ?? body?.count ?? 0)
    h["Accept-Ranges"] = "bytes"
    h["Connection"] = "close"
    h["Cache-Control"] = "no-cache"
    for (k, v) in h { head += "\(k): \(v)\r\n" }
    head += "\r\n"
    var data = Data(head.utf8)
    if let body { data.append(body) }
    return await sendBody(conn, data)
  }

  private func sendBody(_ conn: NWConnection, _ data: Data) async -> Bool {
    await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
      conn.send(content: data, completion: .contentProcessed { c.resume(returning: $0 == nil) })
    }
  }
}

/// Runs its closure at most once (continuations must resume exactly once).
final class Once: @unchecked Sendable {
  private let lock = NSLock()
  private var done = false
  func run(_ body: () -> Void) {
    let first = lock.withLock { () -> Bool in defer { done = true }; return !done }
    if first { body() }
  }
}
