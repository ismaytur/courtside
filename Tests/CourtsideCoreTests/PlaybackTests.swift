import XCTest
@testable import CourtsideCore

final class PlaybackTests: XCTestCase {
  // MARK: resume and watched

  func testResumeRules() {
    // Never played, or barely: start from the beginning.
    XCTAssertNil(WatchRules.resume(position: nil, duration: nil, part: 0, parts: 1))
    XCTAssertNil(WatchRules.resume(position: 12, duration: 9000, part: 0, parts: 1))
    // Midway: resume there.
    XCTAssertEqual(WatchRules.resume(position: 4000, duration: 9000, part: 0, parts: 1), .init(part: 0, position: 4000))
    // In the post-game show (last 3%, at least a minute): watched, so start over.
    XCTAssertNil(WatchRules.resume(position: 8800, duration: 9000, part: 0, parts: 1))
    XCTAssertTrue(WatchRules.isWatched(position: 8800, duration: 9000, part: 0, parts: 1))
    XCTAssertFalse(WatchRules.isWatched(position: 8000, duration: 9000, part: 0, parts: 1))
    // A short video still needs the last minute.
    XCTAssertFalse(WatchRules.isAtEnd(position: 530, duration: 600))
    XCTAssertTrue(WatchRules.isAtEnd(position: 545, duration: 600))
  }

  func testResumeAcrossParts() {
    // The end of the first half goes on with the second.
    XCTAssertEqual(WatchRules.resume(position: 4450, duration: 4500, part: 0, parts: 2), .init(part: 1, position: 0))
    XCTAssertFalse(WatchRules.isWatched(position: 4450, duration: 4500, part: 0, parts: 2))
    XCTAssertEqual(WatchRules.resume(position: 1000, duration: 4500, part: 1, parts: 2), .init(part: 1, position: 1000))
    XCTAssertTrue(WatchRules.isWatched(position: 4450, duration: 4500, part: 1, parts: 2))
    // A saved part that no longer exists is clamped.
    XCTAssertEqual(WatchRules.resume(position: 1000, duration: 4500, part: 5, parts: 2)?.part, 1)
  }

  // MARK: downloads cap

  func testCapRemovesLeastRecentlyWatchedFirstButNeverThePlayingGame() {
    let day: TimeInterval = 86400
    let gb: Int64 = 1_000_000_000
    let e = [
      DownloadCap.Entry(id: "new", bytes: 4 * gb, lastUsed: Date(timeIntervalSince1970: 10 * day)),
      DownloadCap.Entry(id: "oldest", bytes: 4 * gb, lastUsed: Date(timeIntervalSince1970: 1 * day)),
      DownloadCap.Entry(id: "playing", bytes: 4 * gb, lastUsed: Date(timeIntervalSince1970: 0)),
      DownloadCap.Entry(id: "middle", bytes: 4 * gb, lastUsed: Date(timeIntervalSince1970: 5 * day)),
    ]
    XCTAssertEqual(DownloadCap.evictions(e, capBytes: 16 * gb, keep: ["playing"]), [])
    XCTAssertEqual(DownloadCap.evictions(e, capBytes: 12 * gb, keep: ["playing"]), ["oldest"])
    XCTAssertEqual(DownloadCap.evictions(e, capBytes: 7 * gb, keep: ["playing"]), ["oldest", "middle", "new"])
    // Even alone over the cap, the playing game stays.
    XCTAssertEqual(DownloadCap.evictions(e, capBytes: 1, keep: ["playing"]), ["oldest", "middle", "new"])
  }

  // MARK: parts

  func testPartsAreVideosInNaturalOrderWithoutSamples() {
    func f(_ i: Int, _ path: String, _ mb: Int64) -> TorrentFile { TorrentFile(index: i, path: path, size: mb << 20, offset: 0) }
    let files = [
      f(0, "Game/Part 10.mkv", 1500), f(1, "Game/Part 2.mkv", 1500), f(2, "Game/sample.mkv", 1400),
      f(3, "Game/poster.jpg", 1), f(4, "Game/Part 1.mkv", 1500), f(5, "Game/intro.mkv", 20),
    ]
    XCTAssertEqual(GameFolder.parts(of: files).map(\.index), [4, 1, 0])
    XCTAssertEqual(GameFolder.parts(of: [f(0, "a.nfo", 1), f(1, "b.bin", 5)]).map(\.index), [1])
  }

  func testFolderState() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("courtside-folder-\(UUID().uuidString)")
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    let folder = GameFolder(url: dir)
    XCTAssertFalse(folder.exists)
    XCTAssertNil(folder.state)
    folder.update { $0.parts = ["a.mkv"]; $0.part = 0 }
    XCTAssertFalse(folder.isComplete)
    folder.update { $0.complete = true }
    XCTAssertTrue(folder.isComplete)
    XCTAssertEqual(folder.state?.parts, ["a.mkv"])
  }

  // MARK: topic lookup on Play

  func testTopicLookupUsesStoredTopicElseSearchesAndRecordsIt() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("courtside-topic-\(UUID().uuidString)")
    addTeardownBlock { try? FileManager.default.removeItem(at: home) }
    let lib = try Library(paths: Paths(home: home))
    func team(_ abbr: String, _ name: String) -> Team {
      Team(league: "nba", abbr: abbr, name: name, shortName: name, color: nil, altColor: nil, logoURL: nil)
    }
    let atl = team("ATL", "Atlanta Hawks"), hou = team("HOU", "Houston Rockets"), bos = team("BOS", "Boston Celtics")
    try lib.saveTeams([atl, hou, bos])
    func game(_ date: String, _ away: Team, _ home: Team, _ ext: String) -> ScheduledGame {
      ScheduledGame(league: "nba", season: "2026-27", stage: Stage("regular", "Regular Season"), gameNumber: nil,
                    date: date, start: nil, home: home, away: away, externalID: ext)
    }
    try lib.saveSchedule([game("2026-10-20", atl, hou, "1"), game("2026-10-21", bos, atl, "2"), game("2026-10-22", hou, bos, "3")],
                         markNew: false)
    let forum = FakeForum(pages: [
      [Listing(id: 900, date: "2026-10-25", away: "Boston Celtics", home: "Houston Rockets", stage: "NBA 2026-2027 / RS",
               resolution: nil, videoInfo: nil, broadcast: nil)],
      [Listing(id: 850, date: "2026-10-21", away: "Boston Celtics", home: "Atlanta Hawks", stage: "NBA 2026-2027 / RS",
               resolution: "1280x720", videoInfo: nil, broadcast: "EN/FDSN")],
    ])

    // Already known: no page is read.
    let known = lib.games(where: "external_id = '1'")[0]
    lib.setFound(known.id, topicURL: "https://720pier.ru/viewtopic.php?t=1", torrentURL: nil, resolution: nil, broadcast: nil)
    let stored = try await NBA.pierTopic(for: lib.game(known.id)!, forum: forum, library: lib)
    XCTAssertEqual(stored?.absoluteString, "https://720pier.ru/viewtopic.php?t=1")
    let readBefore = await forum.pagesRead
    XCTAssertEqual(readBefore, [])

    // Not known yet: found on the second page, and remembered.
    let missing = lib.games(where: "external_id = '2'")[0]
    let found = try await NBA.pierTopic(for: missing, forum: forum, library: lib)
    XCTAssertEqual(found?.absoluteString, Pier720.topicURL(850).absoluteString)
    XCTAssertEqual(lib.game(missing.id)?.topicURL, Pier720.topicURL(850).absoluteString)
    XCTAssertEqual(lib.game(missing.id)?.broadcast, "EN/FDSN")

    // Not posted at all: nil after the pages run out (not an endless walk).
    let notPosted = lib.games(where: "external_id = '3'")[0]
    let none = try await NBA.pierTopic(for: notPosted, forum: forum, library: lib)
    XCTAssertNil(none)
  }
}

/// 720pier without the network: fixed listing pages (the same for every forum), no subforum.
actor FakeForum: PierForum {
  let pages: [[Listing]]
  var pagesRead: [Int] = []

  init(pages: [[Listing]]) { self.pages = pages }

  func signIn() async throws {}
  func listing(forum: Int, page: Int) async throws -> [Listing] {
    pagesRead.append(page)
    return page < pages.count ? pages[page] : []
  }
  func newestSubforum(prefix: String) async throws -> Int? { nil }
  func torrent(topic: URL) async throws -> Data { Data() }
}
