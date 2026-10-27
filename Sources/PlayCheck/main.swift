// End-to-end check of Play, without 720pier: a test game seeded by a torrent session on this Mac,
// played through the app's own PlaybackEngine, GamePlayer and Library.
//
//   COURTSIDE_HOME=<scratch> swift run PlayCheck            the check (exits 0 when it passes)
//   COURTSIDE_HOME=<scratch> swift run PlayCheck --seed     only seed (prints the peer address) and
//                                                           write game.torrent into a library game
//                                                           (--game <id>), for trying the real app
//
// The check: Play → playing → seek far (bytes not downloaded yet, download capped) → close (saves the
// position) → open again → resumes there → download finishes → folder marked complete.

import AVFoundation
import AppKit
import CourtsideCore
import CryptoKit

setvbuf(stdout, nil, _IOLBF, 0)
let started = Date()
func say(_ s: String) { print(String(format: "[%6.1f] ", Date().timeIntervalSince(started)) + s) }
func fail(_ s: String) -> Never { say("CHECK FAILED: \(s)"); exit(1) }

guard let homeEnv = ProcessInfo.processInfo.environment["COURTSIDE_HOME"], !homeEnv.isEmpty else {
  fail("set COURTSIDE_HOME to a scratch folder (never the real ~/.courtside)")
}
let args = CommandLine.arguments
let seedOnly = args.contains("--seed")
let gameArg = args.firstIndex(of: "--game").map { args[$0 + 1] }
let paths = Paths()
let work = paths.home.appendingPathComponent("playcheck")

/// 10 minutes of 720p60 H.264 (High, B-frames, 2 s GOPs) + AAC in MKV, like a 720pier broadcast.
func makeVideo(_ tools: MediaTools) async throws -> URL {
  let dir = work.appendingPathComponent("seed")
  let url = dir.appendingPathComponent("Hawks at Rockets 26.10.2026.mkv")
  if FileManager.default.fileExists(atPath: url.path) { return url }
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  say("making the test video (10 min)…")
  try await MediaTools.run(tools.ffmpeg, [
    "-hide_banner", "-loglevel", "error", "-y",
    "-filter_complex", "testsrc2=size=1280x720:rate=60,format=nv12[v];sine=frequency=440:sample_rate=48000[a]",
    "-map", "[v]", "-map", "[a]", "-t", "600",
    "-c:v", "h264_videotoolbox", "-b:v", "6M", "-profile:v", "high", "-bf", "2", "-g", "120",
    "-c:a", "aac", "-b:a", "160k", url.path,
  ])
  return url
}

/// A single-file .torrent (bencoded by hand, no tracker: peers are connected directly).
func makeTorrent(_ file: URL, pieceLength: Int = 256 * 1024) throws -> Data {
  let h = try FileHandle(forReadingFrom: file)
  defer { try? h.close() }
  var pieces = Data(), length = 0
  while let chunk = try h.read(upToCount: pieceLength), !chunk.isEmpty {
    pieces.append(contentsOf: Insecure.SHA1.hash(data: chunk))
    length += chunk.count
  }
  func str(_ s: String) -> Data { Data("\(s.utf8.count):".utf8) + Data(s.utf8) }
  var info = Data("d".utf8)
  info += str("length") + Data("i\(length)e".utf8)
  info += str("name") + str(file.lastPathComponent)
  info += str("piece length") + Data("i\(pieceLength)e".utf8)
  info += str("pieces") + Data("\(pieces.count):".utf8) + pieces
  info += Data("e".utf8)
  return Data("d".utf8) + str("info") + info + Data("e".utf8)
}

@MainActor
func waitFor(_ what: String, timeout: Double, _ ok: () -> Bool) async {
  let t0 = Date()
  while !ok() {
    if Date().timeIntervalSince(t0) > timeout { fail("timed out waiting for \(what)") }
    try? await Task.sleep(nanoseconds: 200_000_000)
  }
}

@MainActor
func playingPast(_ p: GamePlayer, _ t: Double, timeout: Double) async {
  await waitFor("playback past \(Int(t)) s", timeout: timeout) {
    if case .failed(let m) = p.phase { fail("player: \(m)") }
    return p.phase == .playing && p.player.rate > 0 && p.position >= t
  }
}

@MainActor
func run() async throws {
  let tools = try MediaTools.locate()
  let video = try await makeVideo(tools)
  let torrent = try makeTorrent(video)

  // The seeder: another session in this process, with the complete file.
  let seeder = try TorrentSession(listenPort: 0, uploadKBps: 0)
  let seeded = try seeder.add(torrent: torrent, saveTo: video.deletingLastPathComponent(), selectAll: true)
  await waitFor("the seeder to check its file", timeout: 60) { seeded.isComplete(seeded.files) }
  let peer = "127.0.0.1:\(seeder.listenPort)"
  say("seeding \(seeded.name) (\(seeded.files[0].size / 1_000_000) MB) at \(peer)")

  let library = try Library(paths: paths)
  if seedOnly {
    // For the real app: put the torrent where Play looks first, so it skips 720pier.
    if let id = gameArg, let g = library.game(id) {
      let folder = GameFolder(paths: paths, league: g.league, game: g.id)
      try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
      try torrent.write(to: folder.torrentFile)
      say("wrote \(folder.torrentFile.path)")
    }
    say("SEEDING: start the app with COURTSIDE_TEST_PEERS=\(peer)")
    while true { try await Task.sleep(nanoseconds: 60_000_000_000) }
  }

  // A played game in the library (no topic: Play must not need 720pier when game.torrent is there).
  func team(_ a: String, _ n: String) -> Team { Team(league: "nba", abbr: a, name: n, shortName: n, color: nil, altColor: nil, logoURL: nil) }
  let sg = ScheduledGame(league: "nba", season: "2026-27", stage: Stage("regular", "Regular Season"), gameNumber: nil,
                         date: "2026-10-26", start: Date(timeIntervalSince1970: 1_793_059_200),
                         home: team("HOU", "Houston Rockets"), away: team("ATL", "Atlanta Hawks"), externalID: "playcheck-1")
  try library.saveSchedule([sg], markNew: false)
  let folder = GameFolder(paths: paths, league: "nba", game: sg.id)
  folder.delete()
  library.setWatch(sg.id, position: nil, duration: nil)

  setenv("COURTSIDE_TEST_PEERS", peer, 1)
  let engine = PlaybackEngine(uploadKBps: 256, lan: false)
  engine.log = { say($0) }
  try engine.setDownloadLimit(kbps: 2000)   // below the video's own speed ×3: a far seek must fetch on demand
  final class Flag: @unchecked Sendable { var done = false }
  let completed = Flag()
  engine.onComplete = { _ in completed.done = true }

  // 1. Play from the start.
  var t0 = Date()
  let open = try engine.open(id: sg.id, folder: folder, torrentData: torrent)
  say("opened: \(open.parts.count) part(s): \(open.parts)")
  let p1 = GamePlayer(game: library.game(sg.id)!, open: open, engine: engine, library: library)
  p1.player.isMuted = true
  p1.start(part: 0, at: 0)
  await playingPast(p1, 2, timeout: 120)
  say(String(format: "PLAYING after %.1f s (duration %.0f s, downloaded %.0f%%)", Date().timeIntervalSince(t0), p1.duration, open.progress * 100))

  // 2. Seek far: 80 %, whose bytes aren't downloaded yet.
  let target = (p1.duration * 0.8).rounded()
  say(String(format: "seeking to %.0f s with %.0f%% downloaded", target, open.progress * 100))
  t0 = Date()
  await p1.player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
  await playingPast(p1, target + 3, timeout: 120)
  say(String(format: "SEEK OK: playing at %.1f s, %.1f s after the seek", p1.position, Date().timeIntervalSince(t0)))

  // 3. Close: the position is saved.
  let closedAt = p1.position
  p1.close()
  guard let saved = library.game(sg.id), let pos = saved.watchPosition, abs(pos - closedAt) < 2,
        abs((saved.duration ?? 0) - p1.duration) < 1 else {
    fail("position not saved: \(String(describing: library.game(sg.id)?.watchPosition)) vs \(closedAt)")
  }
  say(String(format: "closed at %.1f s; library has position %.1f of %.0f s", closedAt, pos, saved.duration ?? 0))

  // 4. Open again: resumes where it was closed.
  let again = try engine.open(id: sg.id, folder: folder, torrentData: nil)
  guard let resume = WatchRules.resume(position: saved.watchPosition, duration: saved.duration,
                                       part: folder.state?.part ?? 0, parts: again.parts.count) else { fail("nothing to resume") }
  let p2 = GamePlayer(game: saved, open: again, engine: engine, library: library)
  p2.player.isMuted = true
  t0 = Date()
  p2.start(part: resume.part, at: resume.position)
  await playingPast(p2, resume.position + 2, timeout: 60)
  guard p2.position < resume.position + 15 else { fail("resumed at \(p2.position), wanted \(resume.position)") }
  say(String(format: "RESUME OK: playing at %.1f s (saved %.1f), %.1f s after Play", p2.position, resume.position, Date().timeIntervalSince(t0)))
  p2.close()

  // 5. The rest downloads; the folder is marked complete (the card's "Downloaded").
  try engine.setDownloadLimit(kbps: 0)
  await waitFor("the download to finish", timeout: 300) { completed.done }
  guard folder.isComplete else { fail("folder not marked complete") }
  say("DOWNLOADED: \(folder.url.lastPathComponent) complete, \(folder.bytes / 1_000_000) MB on disk")

  // 6. A complete download plays from its files, without the torrent.
  engine.close(sg.id)
  let local = try engine.open(id: sg.id, folder: folder, torrentData: nil)
  guard local.torrent == nil else { fail("complete game still opened its torrent") }
  let p3 = GamePlayer(game: library.game(sg.id)!, open: local, engine: engine, library: library)
  p3.player.isMuted = true
  p3.start(part: 0, at: 60)
  await playingPast(p3, 62, timeout: 60)
  say(String(format: "LOCAL OK: playing the downloaded file at %.1f s", p3.position))
  p3.close()
  say("CHECK PASSED")
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
  do { try await run(); exit(0) } catch { fail("\(error)") }
}
app.run()
