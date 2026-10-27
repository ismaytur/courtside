import XCTest
@testable import CourtsideCore

final class Pier720Tests: XCTestCase {
  static func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(name)"))
  }
  static func titles() throws -> [String] {
    String(decoding: try fixture("720pier-titles.txt"), as: UTF8.self).split(separator: "\n").map(String.init)
  }
  static func teams() throws -> [Team] { try NBA.parseTeams(fixture("nba-teams.json")) }

  // MARK: titles

  func testFixtureTitles() throws {
    let all = try Self.titles()
    XCTAssertEqual(all.count, 21)
    let parsed = all.compactMap { Pier720.parseTitle($0) }
    XCTAssertEqual(parsed.count, 18)
    XCTAssertEqual(all.suffix(3).compactMap { Pier720.parseTitle($0) }.count, 0)
  }

  func testRegularSeasonTitle() throws {
    let l = try XCTUnwrap(Pier720.parseTitle(Self.titles()[0], id: 7))
    XCTAssertEqual(l.id, 7)
    XCTAssertEqual(l.date, "2026-10-26")
    XCTAssertEqual(l.away, "Atlanta Hawks")
    XCTAssertEqual(l.home, "Houston Rockets")
    XCTAssertEqual(l.stage, "NBA 2026-2027 / RS")
    XCTAssertEqual(l.resolution, "1280x720")
    XCTAssertEqual(l.videoInfo, "WEB-DL HD/720p/60fps, MKV/H.264")
    XCTAssertEqual(l.broadcast, "EN/SCHN")
    XCTAssertEqual(l.topicURL, "https://720pier.ru/viewtopic.php?t=7")
  }

  func testPlayoffTitle() throws {
    let l = try XCTUnwrap(Pier720.parseTitle(Self.titles()[16]))
    XCTAssertEqual(l.date, "2026-04-30")
    XCTAssertEqual(l.stage, "NBA Playoffs 2026 / Round 1 / Game 6")
    XCTAssertEqual(l.resolution, "1920x1080")
    XCTAssertEqual(l.broadcast, "EN/ESPN")
  }

  func testListingPage() {
    let html = """
      <a href="./viewtopic.php?t=10&amp;sid=abc" class="topictitle">NBA 2026-2027 / RS / 25.10.2026 / Toronto Raptors @ Minnesota Timberwolves [Basketball, WEB-DL HD/720p/60fps, MKV/H.264, EN/DAZN-MIN]</a>
      <a href="./viewtopic.php?t=3" class="topictitle">Donate for Games</a>
      <a href="./viewtopic.php?t=12" class="topictitle">NBA 2026-2027 / RS / 26.10.2026 / Phoenix Suns @ Oklahoma City Thunder [Basketball, WEB-DL HD/720p/60fps, MKV/H.264, EN/OKC]</a>
      """
    XCTAssertEqual(Pier720.parseListing(html).map(\.id), [12, 10])
  }

  func testSubforums() {
    let html = """
      <a href="./viewforum.php?f=40&amp;sid=x" class="forumtitle">NBA Playoffs 2025</a>
      <a href="./viewforum.php?f=51" class="forumtitle">NBA Playoffs 2026</a>
      <a href="./viewforum.php?f=34" class="forumtitle">NBA</a>
      """
    let found = Pier720.parseSubforums(html, prefix: "NBA Playoffs")
    XCTAssertEqual(found.map(\.year), [2026, 2025])
    XCTAssertEqual(found.first?.forum, 51)
  }

  // MARK: matching

  /// ESPN teams, the forum's titles: one scheduled game per fixture title, plus a wrong-date one.
  func testMatchingAgainstSchedule() throws {
    let teams = try Self.teams()
    let names = TeamNames(teams: teams, aliases: NBA.pierAliases)
    func team(_ name: String) throws -> Team { try XCTUnwrap(teams.first { $0.name == name }, name) }
    func game(_ date: String, _ away: String, _ home: String) throws -> ScheduledGame {
      ScheduledGame(league: "nba", season: "2026-27", stage: Stage("regular", "Regular Season"), gameNumber: nil, date: date,
                    start: nil, home: try team(home), away: try team(away), externalID: "\(date)\(away)\(home)")
    }
    let clippers = try game("2026-10-25", "LA Clippers", "Oklahoma City Thunder")
    let hawks = try game("2026-10-26", "Atlanta Hawks", "Houston Rockets")
    let wrongDay = try game("2026-10-27", "Atlanta Hawks", "Houston Rockets")
    let knicks = try game("2026-04-30", "New York Knicks", "Atlanta Hawks")

    let listings = try Self.titles().enumerated().compactMap { Pier720.parseTitle($1, id: 100 + $0) }
    let hits = Pier720.match(listings, wanted: [clippers, hawks, wrongDay, knicks].map(Wanted.init), names: names)

    XCTAssertEqual(Set(hits.keys), [clippers.id, hawks.id, knicks.id])
    XCTAssertEqual(hits[clippers.id]?.home, "Oklahoma City Thunder")
    XCTAssertEqual(hits[clippers.id]?.away, "Los Angeles Clippers") // alias of ESPN's "LA Clippers"
    XCTAssertEqual(hits[hawks.id]?.broadcast, "EN/SCHN")
    XCTAssertEqual(hits[knicks.id]?.stage, "NBA Playoffs 2026 / Round 1 / Game 6")
  }

  func testSummerLeagueIgnored() throws {
    let names = TeamNames(teams: try Self.teams(), aliases: NBA.pierAliases)
    let summer = try XCTUnwrap(Pier720.parseTitle(Self.titles()[11]))
    XCTAssertNil(names.abbr(summer.home)) // "Golden State Warriors Gold"
    XCTAssertEqual(names.abbr(summer.away), "SA")
  }

  // MARK: finder

  func listing(_ id: Int, _ date: String) -> Listing {
    Listing(id: id, date: date, away: "Atlanta Hawks", home: "Houston Rockets", stage: "", resolution: nil, videoInfo: nil, broadcast: nil)
  }

  func finderFixture() throws -> (TeamNames, Wanted) {
    let names = TeamNames(teams: try Self.teams(), aliases: [:])
    return (names, Wanted(id: "g", date: "2026-10-20", away: "ATL", home: "HOU"))
  }

  func testFinderStopsWhenFound() async throws {
    let (names, want) = try finderFixture()
    var loaded: [Int] = []
    let found = try await Pier720.find(wanted: [want], names: names) { page in
      loaded.append(page)
      return page == 1 ? [self.listing(5, "2026-10-20")] : [self.listing(9, "2026-10-25")]
    }
    XCTAssertEqual(found["g"]?.id, 5)
    XCTAssertEqual(loaded, [0, 1])
  }

  func testFinderStopsAfterTwoOlderPages() async throws {
    let (names, want) = try finderFixture()
    var loaded: [Int] = []
    let found = try await Pier720.find(wanted: [want], names: names) { page in
      loaded.append(page)
      // page 1 is a bumped old topic (a fluke), page 2 is newer again, then two older pages in a row
      let date = ["2026-10-25", "2026-10-01", "2026-10-22", "2026-10-02", "2026-10-01", "2026-10-21"][page]
      return [self.listing(100 - page, date)]
    }
    XCTAssertTrue(found.isEmpty)
    XCTAssertEqual(loaded, [0, 1, 2, 3, 4])
  }

  func testFinderStopsAtEndAndCap() async throws {
    let (names, want) = try finderFixture()
    var count = 0
    _ = try await Pier720.find(wanted: [want], names: names) { page in count += 1; return page < 3 ? [self.listing(page, "2026-10-25")] : [] }
    XCTAssertEqual(count, 4)
    count = 0
    _ = try await Pier720.find(wanted: [want], names: names, maxPages: 80) { _ in count += 1; return [self.listing(1, "2026-10-25")] }
    XCTAssertEqual(count, 80)
  }

  // MARK: sign-in and attachment (hand-written phpBB samples)

  static let loginPage = """
    <html><body>
    <form action="./ucp.php?mode=login&amp;sid=0123abc" method="post" id="login" data-focus="username">
      <input type="text" tabindex="1" name="username" id="username" size="25" value="" class="inputbox autowidth" />
      <input type="password" tabindex="2" id="password" name="password" size="25" class="inputbox autowidth" autocomplete="off" />
      <input type="checkbox" name="autologin" id="autologin" tabindex="4" />
      <input type="hidden" name="redirect" value="./index.php?sid=0123abc&amp;x=1" />
      <input type="submit" name="login" tabindex="5" value="Вход" class="button1" />
      <input type="hidden" name="creation_time" value="1790000000" />
      <input type="hidden" name="form_token" value="deadbeef" />
      <input type="hidden" name="sid" value="0123abc" />
    </form>
    </body></html>
    """

  func testLoginForm() throws {
    let base = URL(string: "https://720pier.ru/ucp.php?mode=login")!
    let form = try XCTUnwrap(Pier720.parseLoginForm(Self.loginPage, base: base))
    XCTAssertEqual(form.action.absoluteString, "https://720pier.ru/ucp.php?mode=login&sid=0123abc")
    XCTAssertEqual(form.fields, [
      "redirect": "./index.php?sid=0123abc&x=1", "login": "Вход",
      "creation_time": "1790000000", "form_token": "deadbeef", "sid": "0123abc",
    ])
    XCTAssertFalse(Pier720.isSignedIn(Self.loginPage))
    XCTAssertTrue(Pier720.isSignedIn(#"<a href="./ucp.php?mode=logout&amp;sid=1">Выход [ me ]</a>"#))
    XCTAssertNil(Pier720.parseLoginForm("<html><form action='x'><input name='q'></form></html>", base: base))
  }

  func testAttachment() {
    let topic = URL(string: "https://720pier.ru/viewtopic.php?t=42")!
    let member = """
      <dl class="file"><dt><a class="postlink" href="./download/file.php?id=9876&amp;sid=ab">game.torrent</a></dt></dl>
      """
    XCTAssertEqual(Pier720.parseAttachment(member, base: topic)?.absoluteString, "https://720pier.ru/download/file.php?id=9876") // the session id is dropped; cookies carry it
    let guest = "<div class=\"error\">\(Pier720.guestNotice)</div>"
    XCTAssertNil(Pier720.parseAttachment(guest, base: topic))
  }
}
