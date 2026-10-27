// A league plug-in says which games exist: its seasons, stages, teams and schedule. Where to get a
// game's video is a source's job (Sources/), wired to the league in its own file
// (e.g. NBA+720pier.swift). To add a league: a folder under Leagues/ with a type conforming to
// `League`, then add it to `Leagues.all`.

import Foundation

public struct Team: Sendable, Hashable, Codable {
  public let league: String
  public let abbr: String        // short code used in game IDs, e.g. "ATL"
  public let name: String        // "Atlanta Hawks"
  public let shortName: String   // "Hawks"
  public let color: String?      // hex without '#', for posters
  public let altColor: String?
  public let logoURL: String?
  public let espnID: String?     // schedule provider's team id, when it has one

  public init(league: String, abbr: String, name: String, shortName: String, color: String?, altColor: String?,
              logoURL: String?, espnID: String? = nil) {
    self.league = league; self.abbr = abbr; self.name = name; self.shortName = shortName
    self.color = color; self.altColor = altColor; self.logoURL = logoURL; self.espnID = espnID
  }
}

public struct Stage: Sendable, Hashable {
  public let key: String         // part of the game ID, e.g. "regular", "first-round"
  public let label: String       // "Regular Season", "First Round"
  public init(_ key: String, _ label: String) { self.key = key; self.label = label }
}

/// One game from a league's schedule, before it's in the library.
public struct ScheduledGame: Sendable, Hashable {
  public let league: String
  public let season: String       // "2026-27"
  public let stage: Stage
  public let gameNumber: Int?     // playoff series game
  public let date: String         // local date of the league ("yyyy-MM-dd", US Eastern for the NBA)
  public let start: Date?         // nil when the time isn't set yet
  public let home: Team
  public let away: Team
  public let externalID: String   // the schedule provider's id (stays the same if the game moves)

  /// Stable, readable game ID: league-season-stage-date-away-home.
  public var id: String {
    "\(league)-\(season)-\(stage.key)-\(date)-\(away.abbr)-\(home.abbr)".lowercased()
  }

  public init(league: String, season: String, stage: Stage, gameNumber: Int?, date: String, start: Date?, home: Team, away: Team, externalID: String) {
    self.league = league; self.season = season; self.stage = stage; self.gameNumber = gameNumber
    self.date = date; self.start = start; self.home = home; self.away = away; self.externalID = externalID
  }
}

public protocol League: Sendable {
  var id: String { get }          // "nba": folder names, game IDs, settings
  var name: String { get }        // "NBA"
  var stages: [Stage] { get }     // in season order, for filters
  /// Season label for a date, e.g. "2026-27".
  func season(on date: Date) -> String
  func teams() async throws -> [Team]
  func schedule(season: String, teams: [Team], now: Date) async throws -> [ScheduledGame]
}

public enum Leagues {
  public static let all: [any League] = [NBA()]
  public static func find(_ id: String) -> (any League)? { all.first { $0.id == id } }
}
