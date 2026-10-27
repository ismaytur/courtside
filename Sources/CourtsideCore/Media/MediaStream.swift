// One video served as HLS: its keyframe index -> playlist, and segments made on demand by
// remuxing (-c copy, no re-encode) just that stretch of the source, cached in `cacheDir`.
//
// Cutting exactly: ffmpeg's segment muxer splits at the first video keyframe at or after a time
// and puts every packet in exactly one piece, so consecutive segments made by separate ffmpeg runs
// join without gaps or overlaps. Each run starts one keyframe early (so the cut before our
// segment is made by the muxer, not by the seek) and keeps the middle piece. The muxer's times
// count from the first packet it gets, so the run must know where its seek landed: we seek just
// past the previous keyframe (ffmpeg backs off ~0.13 s with B-frames, then takes the keyframe at or
// before), and check the landing in the muxer's segment list, retrying once if it was elsewhere.
// -copyts keeps source timestamps (+10 s, so they're never negative), identical across runs.

import Foundation

public final class MediaStream: @unchecked Sendable {
  public let id: String
  public let source: MediaSource
  public let cacheDir: URL
  let tools: MediaTools
  /// How ffmpeg/ffprobe read the source: StreamServer's /raw URL (waits for torrent pieces).
  var input: String = ""
  public var readahead = 2
  public var log: @Sendable (String) -> Void = { _ in }

  private let lock = NSLock()
  private var playlistTask: Task<HLSPlaylist, Error>?
  private var segmentTasks: [Int: Task<URL, Error>] = [:]
  private var lastRequested = -1

  static let tsOffset = 10.0

  public init(id: String, source: MediaSource, cacheDir: URL, tools: MediaTools) {
    self.id = id
    self.source = source
    self.cacheDir = cacheDir
    self.tools = tools
  }

  // MARK: playlist

  public func playlist() async throws -> HLSPlaylist {
    let task = lock.withLock { () -> Task<HLSPlaylist, Error> in
      let t = playlistTask ?? Task { try await self.buildPlaylist() }
      playlistTask = t
      return t
    }
    do { return try await task.value } catch {
      lock.withLock { playlistTask = nil }  // let a later request try again
      throw error
    }
  }

  private func buildPlaylist() async throws -> HLSPlaylist {
    try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    let cached = cacheDir.appendingPathComponent("index.json")
    struct Saved: Codable { var size: Int64; var index: KeyframeIndex }
    if let d = try? Data(contentsOf: cached), let s = try? JSONDecoder().decode(Saved.self, from: d), s.size == source.size {
      return HLSPlaylist(index: s.index)
    }
    let t0 = Date()
    let index = try await KeyframeIndex.build(source: source, input: input, tools: tools)
    log("index: \(index.times.count) keyframes, \(Int(index.duration)) s, exact=\(index.exact), "
        + "\(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
    try? JSONEncoder().encode(Saved(size: source.size, index: index)).write(to: cached, options: .atomic)
    return HLSPlaylist(index: index)
  }

  // MARK: segments

  /// How soon a segment's bytes are needed: 0 = the player is waiting for it, n = n segments
  /// ahead of that. The /raw endpoint turns this into torrent deadlines, so read-ahead never
  /// slows down the segment on screen.
  func urgency(of segment: Int?) -> Int {
    guard let segment else { return 0 }
    // Behind the player (left over from before a seek): last in line.
    return lock.withLock { segment < lastRequested ? 100 : segment - lastRequested }
  }

  public func segmentURL(_ i: Int) -> URL { cacheDir.appendingPathComponent("seg-\(i).ts") }

  /// The segment's file, made now if needed; also starts making the next few.
  public func segment(_ i: Int) async throws -> URL {
    let pl = try await playlist()
    guard pl.segments.indices.contains(i) else { throw MediaStreamError.noSuchSegment(i) }

    return try await schedule(i, in: pl).value
  }

  private func schedule(_ i: Int, in pl: HLSPlaylist) -> Task<URL, Error> {
    lock.lock(); defer { lock.unlock() }
    // A jump (seek) rather than the next segment: stop work for the old position, so its pieces
    // stop competing with the new ones.
    let jumped = lastRequested >= 0 && (i < lastRequested || i > lastRequested + readahead + 1)
    if jumped {
      for (k, t) in segmentTasks where k < i || k > i + readahead { t.cancel(); segmentTasks[k] = nil }
      (source as? TorrentFileSource)?.torrent.clearDeadlines()
    }
    lastRequested = i
    for seg in pl.segments[i...min(i + readahead, pl.segments.count - 1)] where segmentTasks[seg.index] == nil {
      segmentTasks[seg.index] = Task {
        do { return try await self.make(seg, in: pl) } catch {
          self.lock.withLock { self.segmentTasks[seg.index] = nil }  // retry on the next request
          throw error
        }
      }
    }
    return segmentTasks[i]!
  }

  private func make(_ seg: HLSSegment, in pl: HLSPlaylist) async throws -> URL {
    let out = segmentURL(seg.index)
    if FileManager.default.fileExists(atPath: out.path) { return out }
    let k = pl.index.times
    let a = seg.keyframe
    let from = max(0, a - 1)

    // Torrent: ask for this stretch of the file before ffmpeg gets there.
    if let pos = pl.index.positions {
      let lo = pos[from]
      let hi = seg.endKeyframe.map { $0 + 1 < pos.count ? pos[$0 + 1] : source.size } ?? source.size
      if hi > lo { source.prefetch(lo..<hi, deadlineMs: 1500 + 3000 * urgency(of: seg.index)) }
    }

    let t0 = Date()
    let work = cacheDir.appendingPathComponent("work-\(seg.index)-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }

    // The seek should land on k[from]; if the cuts come out wrong it most likely landed one
    // keyframe earlier, so try that once.
    for landing in [k[from], k[max(0, from - 1)]] {
      try? FileManager.default.removeItem(at: work)
      try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
      let pieces = try await remux(seg, keyframes: k, exact: pl.index.exact, from: from, landing: landing, into: work)
      // Our piece is the middle one: it must start at our keyframe (the list reports the first
      // piece's start as 0, so that check only applies to later pieces), and a cut must have
      // happened after it unless it's the last segment.
      let want = a > 0 ? 1 : 0
      let tolerance = pl.index.exact ? 0.002 : Self.halfGap(k, a)
      let startOK = want == 0 || (pieces.count > want && abs(pieces[want].start - Self.tsOffset - seg.start) <= tolerance)
      let endOK = seg.endKeyframe == nil ? pieces.count == want + 1 : pieces.count >= want + 2
      if startOK && endOK {
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.moveItem(at: work.appendingPathComponent(pieces[want].file), to: out)
        log(String(format: "segment %d [%.2f–%.2f] %.1f s", seg.index, seg.start, seg.end, Date().timeIntervalSince(t0)))
        return out
      }
      log("segment \(seg.index): cuts at \(pieces.map { $0.start - Self.tsOffset }) with landing \(landing); "
          + (landing == k[max(0, from - 1)] ? "giving up" : "retrying"))
      if from == 0 { break }
    }
    throw MediaStreamError.cutFailed(seg.index)
  }

  static func halfGap(_ k: [Double], _ i: Int) -> Double {
    let prev = i > 0 ? k[i] - k[i - 1] : .infinity
    let next = i + 1 < k.count ? k[i + 1] - k[i] : .infinity
    let g = min(prev, next)
    return g.isFinite ? g / 2 : 1
  }

  struct Piece { var file: String; var start: Double; var end: Double }

  private func remux(_ seg: HLSSegment, keyframes k: [Double], exact: Bool, from: Int, landing: Double,
                     into dir: URL) async throws -> [Piece] {
    // Where the muxer should split: right at a keyframe when times are exact, else halfway
    // to the keyframe before (an estimate a little off still picks the right one).
    func cut(_ i: Int) -> Double { exact || i == 0 ? k[i] - 0.0005 : (k[i - 1] + k[i]) / 2 }
    func f(_ x: Double) -> String { String(format: "%.4f", x) }

    var args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-copyts"]
    if seg.keyframe > 0 {
      let gap = k[from + 1] - k[from]
      args += ["-ss", f(k[from] + min(0.2, gap / 2))]
    }
    // Tell /raw which segment this read is for (its urgency); a plain file path takes no query.
    let source = input.hasPrefix("http") ? "\(input)?seg=\(seg.index)" : input
    args += ["-i", source, "-map", "0:v:0", "-map", "0:a:0?", "-c", "copy", "-sn", "-dn"]
    if let e = seg.endKeyframe { args += ["-to", f(k[e] + 1.0)] }
    var times: [String] = []
    if seg.keyframe > 0 { times.append(f(cut(seg.keyframe) - landing)) }
    if let e = seg.endKeyframe { times.append(f(cut(e) - landing)) }
    args += ["-output_ts_offset", f(Self.tsOffset), "-muxdelay", "0", "-muxpreload", "0",
             "-f", "segment", "-segment_format", "mpegts",
             "-segment_list", dir.appendingPathComponent("list.csv").path, "-segment_list_type", "csv"]
    if !times.isEmpty { args += ["-segment_times", times.joined(separator: ",")] }
    args.append(dir.appendingPathComponent("p%d.ts").path)
    try await MediaTools.run(tools.ffmpeg, args)

    let csv = (try? String(contentsOf: dir.appendingPathComponent("list.csv"), encoding: .utf8)) ?? ""
    return csv.split(separator: "\n").compactMap { line in
      let p = line.split(separator: ",")
      guard p.count >= 3, let s = Double(p[1]), let e = Double(p[2]) else { return nil }
      return Piece(file: String(p[0]), start: s, end: e)
    }
  }
}

public enum MediaStreamError: Error { case noSuchSegment(Int), cutFailed(Int) }
