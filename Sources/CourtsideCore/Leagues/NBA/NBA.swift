// NBA: teams and schedule from ESPN's public site API (nba.com refuses scripted requests).
//   teams:    /apis/site/v2/sports/basketball/nba/teams
//   schedule: /apis/site/v2/sports/basketball/nba/teams/<id>/schedule?season=<end year>&seasontype=<n>
// Each team's schedule, deduplicated by event id, is the whole league's: 30 requests per season
// type. Season types: 1 preseason, 2 regular (NBA Cup games are regular season with a note),
// 3 postseason, 5 play-in. Postseason/play-in are only asked for from April on.

import Foundation

public struct NBA: League {
  public let id = "nba"
  public let name = "NBA"
  public let stages = [
    Stage("preseason", "Preseason"), Stage("regular", "Regular Season"), Stage("cup", "NBA Cup"),
    Stage("play-in", "Play-In"), Stage("first-round", "First Round"), Stage("semis", "Conference Semifinals"),
    Stage("conf-finals", "Conference Finals"), Stage("finals", "Finals"),
  ]

  static let api = "https://site.api.espn.com/apis/site/v2/sports/basketball/nba"
  static let eastern = TimeZone(identifier: "America/New_York")!

  public init() {}

  /// Seasons start in October; anything from July on belongs to the next one ("2026-27").
  public func season(on date: Date) -> String {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = Self.eastern
    let y = cal.component(.year, from: date), m = cal.component(.month, from: date)
    let start = m >= 7 ? y : y - 1
    return "\(start)-\(String(format: "%02d", (start + 1) % 100))"
  }

  public func teams() async throws -> [Team] {
    try Self.parseTeams(try await Web.data(URL(string: "\(Self.api)/teams")!) ?? Data())
  }

  public func schedule(season: String, teams: [Team], now: Date) async throws -> [ScheduledGame] {
    guard let startYear = Int(season.prefix(4)) else { return [] }
    let byID = Dictionary(teams.compactMap { t in t.espnID.map { ($0, t) } }, uniquingKeysWith: { a, _ in a })
    var types = [1, 2]
    if now >= Self.date("\(startYear + 1)-04-01") { types += [5, 3] }
    var games: [String: ScheduledGame] = [:]
    try await withThrowingTaskGroup(of: [ScheduledGame].self) { group in
      var pending = byID.keys.flatMap { tid in types.map { (tid, $0) } }.makeIterator()
      func next() -> Bool {
        guard let (tid, type) = pending.next() else { return false }
        group.addTask {
          let url = URL(string: "\(Self.api)/teams/\(tid)/schedule?season=\(startYear + 1)&seasontype=\(type)")!
          guard let data = try await Web.data(url) else { return [] }
          return try Self.parseSchedule(data, season: season, teams: byID)
        }
        return true
      }
      for _ in 0..<6 { _ = next() } // a few at a time, not 120 at once
      while let batch = try await group.next() {
        for g in batch { games[g.externalID] = g }
        _ = next()
      }
    }
    return games.values.sorted { ($0.date, $0.id) < ($1.date, $1.id) }
  }

  // MARK: parsing (pure, tested with saved ESPN responses)

  struct TeamsResponse: Decodable {
    struct Sport: Decodable { let leagues: [LeagueEntry] }
    struct LeagueEntry: Decodable { let teams: [Wrapper] }
    struct Wrapper: Decodable { let team: ESPNTeam }
    let sports: [Sport]
  }
  struct ESPNTeam: Decodable {
    struct Logo: Decodable { let href: String; let rel: [String]? }
    let id: String
    let abbreviation: String
    let displayName: String
    let shortDisplayName: String?
    let color: String?
    let alternateColor: String?
    let logos: [Logo]?
  }

  static func parseTeams(_ data: Data) throws -> [Team] {
    let r = try JSONDecoder().decode(TeamsResponse.self, from: data)
    return r.sports.flatMap(\.leagues).flatMap(\.teams).map(\.team).map { t in
      let logo = t.logos?.first { $0.rel?.contains("default") ?? false }?.href ?? t.logos?.first?.href
      return Team(league: "nba", abbr: t.abbreviation, name: t.displayName, shortName: t.shortDisplayName ?? t.displayName,
                  color: t.color, altColor: t.alternateColor, logoURL: logo, espnID: t.id)
    }
  }

  struct ScheduleResponse: Decodable {
    struct Event: Decodable {
      struct SeasonType: Decodable { let type: Int? }
      struct Competition: Decodable {
        struct Note: Decodable { let headline: String? }
        struct Competitor: Decodable {
          struct T: Decodable { let id: String; let abbreviation: String?; let displayName: String? }
          let homeAway: String
          let team: T
        }
        let notes: [Note]?
        let competitors: [Competitor]
      }
      let id: String
      let date: String
      let timeValid: Bool?
      let seasonType: SeasonType?
      let competitions: [Competition]
    }
    let events: [Event]?
  }

  /// One team's schedule -> games. `teams` (by ESPN id) supplies names, colors and logos.
  static func parseSchedule(_ data: Data, season: String, teams: [String: Team]) throws -> [ScheduledGame] {
    let r = try JSONDecoder().decode(ScheduleResponse.self, from: data)
    return (r.events ?? []).compactMap { e in
      guard let c = e.competitions.first,
            let h = c.competitors.first(where: { $0.homeAway == "home" }),
            let a = c.competitors.first(where: { $0.homeAway == "away" }),
            let home = teams[h.team.id], let away = teams[a.team.id],
            let start = parseDate(e.date) else { return nil } // TBD opponents are skipped
      let note = c.notes?.compactMap(\.headline).first
      let (stage, number) = stage(seasonType: e.seasonType?.type ?? 2, note: note)
      return ScheduledGame(league: "nba", season: season, stage: stage, gameNumber: number,
                           date: localDate(start), start: e.timeValid == false ? nil : start,
                           home: home, away: away, externalID: e.id)
    }
  }

  /// Stage from ESPN's season type and note ("East 1st Round - Game 1", "NBA Cup - Quarterfinal").
  static func stage(seasonType: Int, note: String?) -> (Stage, Int?) {
    let n = (note ?? "").lowercased()
    let number = n.range(of: #"game (\d+)"#, options: .regularExpression)
      .flatMap { Int(n[$0].split(separator: " ").last ?? "") }
    let s: Stage
    switch seasonType {
    case 1: s = Stage("preseason", "Preseason")
    case 5: s = Stage("play-in", "Play-In")
    case 3:
      if n.contains("play-in") { s = Stage("play-in", "Play-In") }
      else if n.contains("nba finals") { s = Stage("finals", "Finals") }
      else if n.contains("semifinal") || n.contains("2nd round") { s = Stage("semis", "Conference Semifinals") }
      else if n.contains("finals") { s = Stage("conf-finals", "Conference Finals") }
      else if n.contains("1st round") { s = Stage("first-round", "First Round") }
      else { s = Stage("playoffs", "Playoffs") }
    default:
      s = n.contains("nba cup") && !n.contains("group") ? Stage("cup", "NBA Cup") : Stage("regular", "Regular Season")
    }
    return (s, seasonType == 3 || seasonType == 5 ? number : nil)
  }

  // ESPN writes "2026-10-21T23:00Z" (no seconds) and sometimes with seconds.
  static func parseDate(_ s: String) -> Date? {
    for format in ["yyyy-MM-dd'T'HH:mmX", "yyyy-MM-dd'T'HH:mm:ssX"] {
      let f = DateFormatter()
      f.locale = Locale(identifier: "en_US_POSIX")
      f.dateFormat = format
      if let d = f.date(from: s) { return d }
    }
    return nil
  }

  /// The game's date in New York: a 7:30 pm ET tip-off is 23:30Z, a West Coast one is past midnight UTC.
  static func localDate(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = eastern
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: d)
  }

  static func date(_ ymd: String) -> Date {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = eastern
    f.dateFormat = "yyyy-MM-dd"
    return f.date(from: ymd) ?? .distantFuture
  }
}
