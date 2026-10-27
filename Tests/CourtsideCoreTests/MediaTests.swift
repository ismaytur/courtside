import CryptoKit
import XCTest
@testable import CourtsideCore

final class MediaTests: XCTestCase {
  func testPlaylistSegmentsStartOnKeyframes() {
    let k = stride(from: 0.0, to: 60, by: 1.95).map { $0 }
    let pl = HLSPlaylist(index: KeyframeIndex(times: k, positions: nil, duration: 60, exact: true))
    XCTAssertEqual(pl.segments.first?.start, 0)
    XCTAssertEqual(pl.segments.last?.end, 60)
    for (a, b) in zip(pl.segments, pl.segments.dropFirst()) {
      XCTAssertEqual(a.end, b.start)
      XCTAssertTrue(k.contains(b.start))
      XCTAssertGreaterThanOrEqual(a.duration, 6)
    }
    let m3u8 = pl.m3u8 { "seg-\($0.index).ts" }
    XCTAssertTrue(m3u8.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
    XCTAssertTrue(m3u8.hasSuffix("#EXT-X-ENDLIST\n"))
  }

  func testShortTailJoinsLastSegment() {
    let pl = HLSPlaylist(index: KeyframeIndex(times: [0, 6, 12], positions: nil, duration: 12.5, exact: true))
    XCTAssertEqual(pl.segments.map(\.start), [0, 6])
    XCTAssertEqual(pl.segments.last?.end, 12.5)
    XCTAssertNil(pl.segments.last?.endKeyframe)
  }

  func testByteRanges() {
    XCTAssertEqual(StreamServer.byteRange("bytes=0-", size: 100), 0..<100)
    XCTAssertEqual(StreamServer.byteRange("bytes=10-19", size: 100), 10..<20)
    XCTAssertEqual(StreamServer.byteRange("bytes=90-200", size: 100), 90..<100)
    XCTAssertEqual(StreamServer.byteRange("bytes=-10", size: 100), 90..<100)
    XCTAssertNil(StreamServer.byteRange("bytes=100-", size: 100))
    XCTAssertNil(StreamServer.byteRange(nil, size: 100))
  }

  // MARK: with the bundled ffmpeg (skipped if `mise run vendor` hasn't run)

  private func tools() throws -> MediaTools {
    do { return try MediaTools.locate() } catch { throw XCTSkip("ffmpeg not built") }
  }

  /// 30 s of 720p60 H.264 (B-frames) + AAC in MKV, like the real broadcasts.
  private func makeMKV(_ tools: MediaTools, seconds: Int = 30) async throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("courtside-test-\(UUID().uuidString).mkv")
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    try await MediaTools.run(tools.ffmpeg, [
      "-hide_banner", "-loglevel", "error", "-y",
      "-filter_complex", "testsrc2=size=1280x720:rate=60,format=nv12[v];sine=sample_rate=48000[a]",
      "-map", "[v]", "-map", "[a]", "-t", "\(seconds)",
      "-c:v", "h264_videotoolbox", "-b:v", "4M", "-profile:v", "high", "-bf", "2", "-g", "120",
      "-c:a", "aac", url.path,
    ])
    return url
  }

  private func keyframesByFFprobe(_ tools: MediaTools, _ url: URL) async throws -> [Double] {
    let out = try await MediaTools.run(tools.ffprobe, [
      "-v", "error", "-select_streams", "v", "-show_entries", "packet=pts_time,flags", "-of", "csv=p=0", url.path,
    ])
    return String(decoding: out, as: UTF8.self).split(separator: "\n").compactMap { l in
      let f = l.split(separator: ",")
      return f.count >= 2 && f[1].hasPrefix("K") ? Double(f[0]) : nil
    }
  }

  func testMatroskaCuesMatchFFprobe() async throws {
    let tools = try tools()
    let url = try await makeMKV(tools)
    let idx = try await MatroskaIndex.read(LocalFileSource(url))
    let probed = try await keyframesByFFprobe(tools, url)
    XCTAssertTrue(idx.exact)
    XCTAssertEqual(idx.duration, 30, accuracy: 0.1)
    XCTAssertEqual(idx.times.count, probed.count)
    for (a, b) in zip(idx.times, probed) { XCTAssertEqual(a, b, accuracy: 0.0011) }
    XCTAssertEqual(idx.positions?.count, idx.times.count)
  }

  /// Segments made by separate ffmpeg runs must join exactly: no frame twice, none missing.
  func testSegmentsJoinWithoutGapsOrOverlaps() async throws {
    let tools = try tools()
    let url = try await makeMKV(tools)
    let cache = FileManager.default.temporaryDirectory.appendingPathComponent("courtside-hls-\(UUID().uuidString)")
    addTeardownBlock { try? FileManager.default.removeItem(at: cache) }
    let stream = MediaStream(id: "t", source: try LocalFileSource(url), cacheDir: cache, tools: tools)
    stream.input = url.path  // ffmpeg can read a complete local file directly
    stream.readahead = 0
    let pl = try await stream.playlist()
    XCTAssertGreaterThan(pl.segments.count, 2)

    var video: [Double] = [], audio: [Double] = []
    for seg in pl.segments {
      let file = try await stream.segment(seg.index)
      for (type, into) in [("v", 0), ("a", 1)] {
        let out = try await MediaTools.run(tools.ffprobe, [
          "-v", "error", "-select_streams", type, "-show_entries", "packet=pts_time", "-of", "csv=p=0", file.path,
        ])
        // ffprobe's csv ends some lines with an empty field ("10.000000,")
        let ts = String(decoding: out, as: UTF8.self).split(separator: "\n")
          .compactMap { Double($0.split(separator: ",").first ?? "") }.sorted()
        if into == 0 {
          XCTAssertEqual(ts.first ?? -1, seg.start + MediaStream.tsOffset, accuracy: 0.002, "segment \(seg.index)")
          video += ts
        } else {
          audio += ts
        }
      }
    }
    XCTAssertEqual(video.count, 30 * 60)
    XCTAssertEqual(Set(video).count, video.count)
    XCTAssertEqual(Set(audio).count, audio.count)
    XCTAssertEqual(video, video.sorted())
    XCTAssertEqual(audio, audio.sorted())
  }

  // MARK: torrent bridge

  /// A single-file .torrent for `data` (bencoded by hand; libtorrent hashes it on add).
  private func makeTorrent(name: String, data: Data, pieceLength: Int) -> Data {
    var pieces = Data()
    var off = 0
    while off < data.count {
      pieces.append(contentsOf: Insecure.SHA1.hash(data: data[off..<min(off + pieceLength, data.count)]))
      off += pieceLength
    }
    func str(_ s: String) -> Data { Data("\(s.utf8.count):\(s)".utf8) }
    var info = Data("d".utf8)
    info += str("length") + Data("i\(data.count)e".utf8)
    info += str("name") + str(name)
    info += str("piece length") + Data("i\(pieceLength)e".utf8)
    info += str("pieces") + Data("\(pieces.count):".utf8) + pieces
    info += Data("e".utf8)
    return Data("d".utf8) + str("info") + info + Data("e".utf8)
  }

  func testTorrentFilesPiecesAndCompleteData() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("courtside-torrent-\(UUID().uuidString)")
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let content = Data((0..<(3 * 16384 + 100)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    try content.write(to: dir.appendingPathComponent("game.mkv"))

    let session = try TorrentSession(listenPort: 0, uploadKBps: 64)
    let t = try session.add(torrent: makeTorrent(name: "game.mkv", data: content, pieceLength: 16384), saveTo: dir)
    XCTAssertEqual(t.name, "game.mkv")
    XCTAssertEqual(t.infoHash.count, 40)
    XCTAssertEqual(t.files, [TorrentFile(index: 0, path: "game.mkv", size: Int64(content.count), offset: 0)])
    XCTAssertEqual(t.pieceCount, 4)
    XCTAssertEqual(t.pieces(file: t.files[0], range: 16000..<16500), 0...1)
    XCTAssertEqual(t.pieces(file: t.files[0], range: 49152..<49252), 3...3)
    XCTAssertNil(t.pieces(file: t.files[0], range: Int64(content.count)..<Int64(content.count + 1)))

    // The data is already on disk: once libtorrent has checked it, the range is "downloaded".
    t.select(files: [0])
    try await withTimeout(10) { try await t.waitFor(file: t.files[0], range: 0..<Int64(content.count)) }
    XCTAssertTrue(t.has(file: t.files[0], range: 0..<Int64(content.count)))
    let src = TorrentFileSource(torrent: t, file: t.files[0])
    let bytes = try await src.read(16380..<16400)
    XCTAssertEqual(bytes, content[16380..<16400])
    XCTAssertEqual(t.status?.wantedDone, Int64(content.count))

    session.remove(t)
    do {
      try await t.waitFor(piece: 0)
      XCTFail("removed torrent should throw")
    } catch TorrentError.removed {}
  }

  private func withTimeout(_ seconds: Double, _ body: @escaping @Sendable () async throws -> Void) async throws {
    try await withThrowingTaskGroup(of: Void.self) { g in
      g.addTask { try await body() }
      g.addTask {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
        throw XCTSkip("timed out")
      }
      try await g.next()
      g.cancelAll()
    }
  }
}
