import XCTest
@testable import CourtsideCore

final class LibraryTests: XCTestCase {
  var home: URL!

  override func setUpWithError() throws {
    home = FileManager.default.temporaryDirectory.appendingPathComponent("courtside-test-\(UUID().uuidString)")
  }
  override func tearDown() { try? FileManager.default.removeItem(at: home) }

  func team(_ abbr: String) -> Team {
    Team(league: "nba", abbr: abbr, name: abbr, shortName: abbr, color: nil, altColor: nil, logoURL: nil)
  }
  func game(date: String, external: String = "401") -> ScheduledGame {
    ScheduledGame(league: "nba", season: "2026-27", stage: Stage("regular", "Regular Season"), gameNumber: nil,
                  date: date, start: nil, home: team("HOU"), away: team("ATL"), externalID: external)
  }

  func testMovedGameKeepsWatchPositionAndLinks() throws {
    let lib = try Library(paths: Paths(home: home))
    XCTAssertEqual(try lib.saveSchedule([game(date: "2026-10-26")], markNew: false), 1)
    lib.setFound("nba-2026-27-regular-2026-10-26-atl-hou", topicURL: "https://example.test/t", torrentURL: nil, resolution: nil, broadcast: nil)
    lib.setWatch("nba-2026-27-regular-2026-10-26-atl-hou", position: 1234, duration: 7000)

    // The league moves the game a day: same provider id, new date and so new game id.
    XCTAssertEqual(try lib.saveSchedule([game(date: "2026-10-27")], markNew: true), 0)
    let all = lib.games()
    XCTAssertEqual(all.count, 1)
    XCTAssertEqual(all[0].id, "nba-2026-27-regular-2026-10-27-atl-hou")
    XCTAssertEqual(all[0].watchPosition, 1234)
    XCTAssertEqual(all[0].topicURL, "https://example.test/t")
  }

  func testNewGamesAreFlaggedOnlyWhenAsked() throws {
    let lib = try Library(paths: Paths(home: home))
    try lib.saveSchedule([game(date: "2026-10-26", external: "1")], markNew: false)
    try lib.saveSchedule([game(date: "2026-10-28", external: "2")], markNew: true)
    XCTAssertEqual(lib.games(where: "is_new = 1").count, 1)
  }

  func testOldLayoutIsSetAside() throws {
    let paths = Paths(home: home)
    paths.ensure(home)
    let old = try Database(path: paths.database.path)
    try old.exec("CREATE TABLE games (id INTEGER PRIMARY KEY, title TEXT); INSERT INTO games(title) VALUES ('x');")
    _ = old

    let lib = try Library(paths: paths)
    XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("games.unsupported.db").path))
    XCTAssertEqual(lib.games().count, 0)
  }
}
