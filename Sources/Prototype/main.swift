// Step-0 prototype: prove the native engine. A torrent (or a local file) is streamed through the
// bundled ffmpeg as HLS into Apple's player.
//
//   swift run Prototype --torrent <file.torrent|https://…>   stream a torrent's biggest file
//   swift run Prototype --file <video.mkv>                   same HLS path for a local file
//   swift run Prototype --make-test-mkv <out.mkv>            H.264 + AAC test MKV (bundled ffmpeg)
// Options:
//   --lan          serve on the Mac's LAN address (for AirPlay to an Apple TV), not 127.0.0.1
//   --port N       server port (default: any free one)
//   --check        no window: play, seek to --seek-to (fraction, default 0.8), verify, exit 0/1
//   --seek-to F
//   --download-kbps N   cap the download (shows that a far seek fetches its pieces on demand)
// Downloads and segments go under $COURTSIDE_HOME/prototype (default: a temp folder).

import AVFoundation
import AVKit
import AppKit
import CourtsideCore
import CoreImage

setvbuf(stdout, nil, _IOLBF, 0)

struct Options {
  var torrent: String?
  var file: String?
  var makeTestMKV: String?
  var lan = false
  var port: UInt16 = 0
  var check = false
  var seekTo = 0.8
  var downloadKBps = 0.0

  init(_ args: [String]) {
    var it = args.makeIterator()
    while let a = it.next() {
      switch a {
      case "--torrent": torrent = it.next()
      case "--file": file = it.next()
      case "--make-test-mkv": makeTestMKV = it.next()
      case "--lan": lan = true
      case "--port": port = UInt16(it.next() ?? "") ?? 0
      case "--check": check = true
      case "--seek-to": seekTo = Double(it.next() ?? "") ?? 0.8
      case "--download-kbps": downloadKBps = Double(it.next() ?? "") ?? 0
      default: fail("unknown option \(a)")
      }
    }
  }
}

func say(_ s: String) {
  let t = String(format: "%7.1f", Date().timeIntervalSince(started))
  print("[\(t)] \(s)")
}

func fail(_ s: String) -> Never {
  FileHandle.standardError.write(Data("error: \(s)\n".utf8))
  exit(1)
}

let started = Date()
let opts = Options(Array(CommandLine.arguments.dropFirst()))
let home: URL = {
  if let h = ProcessInfo.processInfo.environment["COURTSIDE_HOME"], !h.isEmpty {
    return URL(fileURLWithPath: (h as NSString).expandingTildeInPath)
  }
  return FileManager.default.temporaryDirectory.appendingPathComponent("courtside-prototype")
}()
let work = home.appendingPathComponent("prototype")

// Keep the session/server alive for the whole run.
var keep: [AnyObject] = []

@MainActor
func setUp() async throws -> (URL, MediaStream, Torrent?) {
  let tools = try MediaTools.locate()
  say("ffmpeg: \(tools.ffmpeg.path)")

  if let out = opts.makeTestMKV {
    // Like a 720pier broadcast: 720p60 H.264 (High, B-frames, ~2 s GOPs) + AAC, in MKV.
    try await MediaTools.run(tools.ffmpeg, [
      "-hide_banner", "-loglevel", "error", "-y",
      "-filter_complex", "testsrc2=size=1280x720:rate=60,format=nv12[v];sine=frequency=440:sample_rate=48000[a]",
      "-map", "[v]", "-map", "[a]", "-t", "600",
      "-c:v", "h264_videotoolbox", "-b:v", "6M", "-profile:v", "high", "-bf", "2", "-g", "120",
      "-c:a", "aac", "-b:a", "160k", out,
    ])
    say("wrote \(out)")
    exit(0)
  }

  let server = try StreamServer(port: opts.port, lan: opts.lan)
  server.log = { say("http: \($0)") }
  try await server.start()
  keep.append(server)

  let stream: MediaStream
  var torrent: Torrent?
  if let path = opts.file {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    let src = try LocalFileSource(url)
    let cache = work.appendingPathComponent("hls-local/\(url.deletingPathExtension().lastPathComponent)")
    stream = MediaStream(id: "local", source: src, cacheDir: cache, tools: tools)
  } else if let t = opts.torrent {
    let data: Data
    if t.hasPrefix("http://") || t.hasPrefix("https://") {
      guard let d = try await Web.data(URL(string: t)!) else { fail("couldn't download \(t)") }
      data = d
    } else {
      data = try Data(contentsOf: URL(fileURLWithPath: (t as NSString).expandingTildeInPath))
    }
    let session = try TorrentSession(listenPort: 0, uploadKBps: Settings.load(Paths(home: home)).storage.uploadKBps)
    session.setDownloadLimit(kbps: opts.downloadKBps)
    keep.append(session)
    let tor = try session.add(torrent: data, saveTo: work.appendingPathComponent("downloads"))
    say("torrent \(tor.name): \(tor.files.count) files, \(tor.pieceCount) pieces × \(tor.pieceLength / 1024) KB")
    for f in tor.files { say("  [\(f.index)] \(f.path) \(f.size / 1_000_000) MB") }
    guard let main = tor.files.filter({ [".mkv", ".mp4", ".m4v", ".mov", ".ts"].contains(where: $0.path.lowercased().hasSuffix) })
      .max(by: { $0.size < $1.size }) ?? tor.mainFile else { fail("torrent has no files") }
    tor.select(files: [main.index])
    say("streaming [\(main.index)] \(main.path)")
    stream = MediaStream(id: String(tor.infoHash.prefix(12)), source: TorrentFileSource(torrent: tor, file: main),
                         cacheDir: work.appendingPathComponent("downloads/hls-\(tor.infoHash.prefix(12))"), tools: tools)
    torrent = tor
  } else {
    fail("pass --torrent, --file or --make-test-mkv")
  }
  stream.log = { say("stream: \($0)") }
  server.add(stream)
  keep.append(stream)

  say("preparing (keyframe index)…")
  let pl = try await stream.playlist()
  say("playlist: \(pl.segments.count) segments, \(Int(pl.index.duration)) s")
  let url = server.playlistURL(for: stream)
  say("PLAYLIST URL: \(url.absoluteString)")
  return (url, stream, torrent)
}

func progressLine(_ t: Torrent?) -> String {
  guard let s = t?.status else { return "" }
  return String(format: "torrent %.1f%% ↓%.1f MB/s ↑%.0f KB/s peers %d (seeds %d)", s.progress * 100,
                Double(s.downloadBps) / 1e6, Double(s.uploadBps) / 1e3, s.peers, s.seeds)
}

// MARK: --check: headless play + seek, verified with decoded frames

@MainActor
final class Checker {
  let player: AVPlayer
  let item: AVPlayerItem
  let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
  let torrent: Torrent?
  let snapshots: URL

  var source: MediaSource?
  var playlist: HLSPlaylist?

  init(url: URL, torrent: Torrent?, snapshots: URL) {
    item = AVPlayerItem(url: url)
    item.add(output)
    player = AVPlayer(playerItem: item)
    player.isMuted = true
    self.torrent = torrent
    self.snapshots = snapshots
  }

  /// Wait until playback has moved `seconds` past `from`; returns how long that took.
  func playUntil(_ target: Double, timeout: Double) async throws -> Double {
    let t0 = Date()
    while Date().timeIntervalSince(t0) < timeout {
      if item.status == .failed { throw item.error ?? NSError(domain: "player", code: 1) }
      let now = player.currentTime().seconds
      if now.isFinite, now >= target { return Date().timeIntervalSince(t0) }
      try await Task.sleep(nanoseconds: 250_000_000)
    }
    throw NSError(domain: "player", code: 2, userInfo: [NSLocalizedDescriptionKey:
      "timed out at \(player.currentTime().seconds) waiting for \(target); \(item.errorLog()?.events.last?.errorComment ?? "")"])
  }

  /// Save the frame on screen now; returns its mean brightness (0 = black: nothing decoded).
  func snapshot(_ name: String) -> Double? {
    let t = item.currentTime()
    guard let pb = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) else { return nil }
    let ci = CIImage(cvPixelBuffer: pb)
    let ctx = CIContext()
    let url = snapshots.appendingPathComponent("\(name).png")
    try? ctx.writePNGRepresentation(of: ci, to: url, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    var px = [UInt8](repeating: 0, count: 4)
    let avg = ci.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: ci.extent)])
    ctx.render(avg, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
    say("snapshot \(url.path) \(CVPixelBufferGetWidth(pb))×\(CVPixelBufferGetHeight(pb))")
    return (Double(px[0]) + Double(px[1]) + Double(px[2])) / 3
  }

  func run(duration: Double, seekTo: Double) async -> Bool {
    try? FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
    do {
      let t0 = Date()
      player.play()
      let startup = try await playUntil(2, timeout: 180)
      say(String(format: "PLAYING: 2 s in after %.1f s (startup); %@", startup, progressLine(torrent)))
      _ = try await playUntil(8, timeout: 120)
      let b1 = snapshot("start") ?? 0
      let target = (duration * seekTo).rounded()
      if let src = source as? TorrentFileSource, let pl = playlist,
         let seg = pl.segments.first(where: { $0.end > target }), let pos = pl.index.positions {
        let at = pos[seg.keyframe]
        let have = src.torrent.has(file: src.torrentFile, range: at..<min(src.size, at + 1_000_000))
        say("seeking to \(Int(target)) s: its bytes (@\(at / 1_000_000) MB) downloaded already? \(have ? "yes" : "no")")
      } else {
        say("seeking to \(Int(target)) s")
      }
      let s0 = Date()
      await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
      _ = try await playUntil(target + 3, timeout: 180)
      say(String(format: "SEEK OK: playing at %.1f s, %.1f s after the seek; %@", player.currentTime().seconds,
                 Date().timeIntervalSince(s0), progressLine(torrent)))
      let b2 = snapshot("after-seek") ?? 0
      let video = item.tracks.contains { $0.assetTrack?.mediaType == .video }
      let size = item.presentationSize
      say(String(format: "video track: %@, size %.0f×%.0f, frame brightness %.0f / %.0f", video ? "yes" : "no",
                 size.width, size.height, b1, b2))
      for e in item.errorLog()?.events ?? [] { say("player error log: \(e.errorStatusCode) \(e.errorComment ?? "")") }
      if let a = item.accessLog()?.events.last {
        say(String(format: "access log: %d segments, %.1f Mbps indicated, stalls %d", a.numberOfMediaRequests,
                   a.indicatedBitrate / 1e6, a.numberOfStalls))
      }
      say(String(format: "total %.1f s", Date().timeIntervalSince(t0)))
      return video && size.width > 0 && b1 > 5 && b2 > 5
    } catch {
      say("CHECK FAILED: \(error)")
      return false
    }
  }
}

// MARK: window

@MainActor
final class PlayerWindow: NSObject, NSWindowDelegate {
  let window: NSWindow
  let player: AVPlayer

  init(url: URL, title: String) {
    player = AVPlayer(url: url)
    player.allowsExternalPlayback = true  // AirPlay: the Apple TV fetches the URL itself
    let view = AVPlayerView()
    view.player = player
    view.controlsStyle = .floating
    view.allowsPictureInPicturePlayback = true
    let picker = AVRoutePickerView()
    picker.player = player
    picker.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(picker)
    NSLayoutConstraint.activate([
      picker.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
      picker.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
      picker.widthAnchor.constraint(equalToConstant: 32), picker.heightAnchor.constraint(equalToConstant: 32),
    ])
    window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
                      styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    window.title = title
    window.contentView = view
    window.center()
    super.init()
    window.delegate = self
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    player.play()
  }

  func windowWillClose(_ notification: Notification) { exit(0) }
}

let app = NSApplication.shared
app.setActivationPolicy(opts.check ? .prohibited : .regular)
Task { @MainActor in
  do {
    let (url, stream, torrent) = try await setUp()
    if torrent != nil {
      Task { @MainActor in
        while true {
          try? await Task.sleep(nanoseconds: 5_000_000_000)
          say(progressLine(torrent))
        }
      }
    }
    if opts.check {
      let pl = try await stream.playlist()
      let checker = Checker(url: url, torrent: torrent, snapshots: work.appendingPathComponent("snapshots"))
      checker.source = stream.source
      checker.playlist = pl
      let ok = await checker.run(duration: pl.index.duration, seekTo: opts.seekTo)
      say(ok ? "CHECK PASSED" : "CHECK FAILED")
      exit(ok ? 0 : 1)
    } else {
      keep.append(PlayerWindow(url: url, title: "Courtside prototype — \(url.absoluteString)"))
    }
  } catch {
    fail("\(error)")
  }
}
app.run()
