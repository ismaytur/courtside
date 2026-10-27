import XCTest
@testable import CourtsideCore

final class NBATests: XCTestCase {
  func fixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
  }

  func teamsByID() throws -> [String: Team] {
    let teams = try NBA.parseTeams(fixture("nba-teams"))
    return Dictionary(uniqueKeysWithValues: teams.compactMap { t in t.espnID.map { ($0, t) } })
  }

  func testThirtyTeamsWithColorsAndLogos() throws {
    let teams = try NBA.parseTeams(fixture("nba-teams"))
    XCTAssertEqual(teams.count, 30)
    XCTAssertEqual(Set(teams.map(\.abbr)).count, 30)
    let hawks = try XCTUnwrap(teams.first { $0.abbr == "ATL" })
    XCTAssertEqual(hawks.shortName, "Hawks")
    XCTAssertNotNil(hawks.color)
    XCTAssertNotNil(hawks.logoURL)
  }

  func testHawksRegularSeason() throws {
    let games = try NBA.parseSchedule(fixture("nba-atl-regular"), season: "2026-27", teams: teamsByID())
    XCTAssertEqual(games.count, 80)
    XCTAssertTrue(games.allSatisfy { $0.stage.key == "regular" || $0.stage.key == "cup" })
    XCTAssertTrue(games.allSatisfy { $0.home.abbr == "ATL" || $0.away.abbr == "ATL" })
    XCTAssertEqual(Set(games.map(\.id)).count, games.count)
  }

  func testUTCBecomesEasternDate() throws {
    // A West Coast tip-off is past midnight UTC but still the previous evening in New York.
    XCTAssertEqual(NBA.localDate(NBA.parseDate("2026-04-21T00:00Z")!), "2026-04-20")
    XCTAssertEqual(NBA.localDate(NBA.parseDate("2026-10-21T23:00Z")!), "2026-10-21")
    XCTAssertEqual(NBA.localDate(NBA.parseDate("2026-06-04T00:30Z")!), "2026-06-03")
  }

  func testKnicksPlayoffStagesAndGameNumbers() throws {
    let games = try NBA.parseSchedule(fixture("nba-nyk-playoffs-2026"), season: "2025-26", teams: teamsByID())
    func stage(_ key: String) -> [ScheduledGame] { games.filter { $0.stage.key == key } }
    XCTAssertEqual(stage("first-round").count, 6)
    XCTAssertEqual(stage("semis").count, 4)
    XCTAssertEqual(stage("conf-finals").count, 4)
    XCTAssertEqual(stage("finals").count, 5)
    XCTAssertEqual(stage("first-round").compactMap(\.gameNumber).sorted(), [1, 2, 3, 4, 5, 6])
    XCTAssertEqual(stage("finals").compactMap(\.gameNumber).sorted(), [1, 2, 3, 4, 5])
    let game2 = try XCTUnwrap(stage("first-round").first { $0.gameNumber == 2 })
    XCTAssertEqual(game2.date, "2026-04-20")
  }

  func testPreseason() throws {
    let games = try NBA.parseSchedule(fixture("nba-atl-preseason"), season: "2026-27", teams: teamsByID())
    XCTAssertEqual(games.count, 5)
    XCTAssertTrue(games.allSatisfy { $0.stage.key == "preseason" && $0.gameNumber == nil })
  }

  func testStageFromNotes() {
    XCTAssertEqual(NBA.stage(seasonType: 2, note: "NBA Cup - Quarterfinal").0.key, "cup")
    XCTAssertEqual(NBA.stage(seasonType: 2, note: "NBA Cup - Group Play").0.key, "regular")
    XCTAssertEqual(NBA.stage(seasonType: 5, note: nil).0.key, "play-in")
  }
}
