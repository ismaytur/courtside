// The library in games.db: one row per scheduled game (all leagues) plus each league's teams.
// A game's id is ScheduledGame.id ("nba-2026-27-regular-2026-10-26-atl-hou"); schedule refreshes
// match rows by the provider's id, so a moved game keeps its watch position and links.
// A file with another layout (e.g. the Node version's games/releases) is set aside as
// games.unsupported.db and a fresh library starts; no migrations.

import Foundation

public struct Game: Identifiable, Sendable, Hashable {
  public let id: String
  public let league: String
  public let season: String
  public let stage: String
  public let stageLabel: String
  public let gameNumber: Int?
  public let date: String            // league-local "yyyy-MM-dd"
  public let start: Date?
  public let home: String, homeName: String
  public let away: String, awayName: String
  public var topicURL: String?       // where the source posted it (e.g. a 720pier topic)
  public var torrentURL: String?
  public var resolution: String?
  public var broadcast: String?
  public var favorite: Bool
  public var watchPosition: Double?
  public var duration: Double?
  public var watchedAt: Date?        // last time it was played (cache cap: least recently watched go first)
  public var isNew: Bool
}

public final class Library: @unchecked Sendable {
  public let db: Database
  public let paths: Paths

  static let schema = """
    CREATE TABLE IF NOT EXISTS games (
      id             TEXT PRIMARY KEY,
      league         TEXT NOT NULL,
      season         TEXT NOT NULL,
      stage          TEXT NOT NULL,
      stage_label    TEXT NOT NULL,
      game_number    INTEGER,
      game_date      TEXT NOT NULL,
      start_time     REAL,
      home_abbr      TEXT NOT NULL,
      home_name      TEXT NOT NULL,
      away_abbr      TEXT NOT NULL,
      away_name      TEXT NOT NULL,
      external_id    TEXT,
      topic_url      TEXT,
      torrent_url    TEXT,
      resolution     TEXT,
      broadcast      TEXT,
      found_at       TEXT,
      favorite       INTEGER NOT NULL DEFAULT 0,
      watch_position REAL,
      duration       REAL,
      watched_at     TEXT,
      is_new         INTEGER NOT NULL DEFAULT 0,
      added_at       TEXT NOT NULL DEFAULT (datetime('now'))
    );
    CREATE UNIQUE INDEX IF NOT EXISTS games_external ON games(league, external_id);
    CREATE INDEX IF NOT EXISTS games_date   ON games(game_date);
    CREATE INDEX IF NOT EXISTS games_season ON games(league, season);
    CREATE INDEX IF NOT EXISTS games_home   ON games(home_abbr);
    CREATE INDEX IF NOT EXISTS games_away   ON games(away_abbr);
    CREATE TABLE IF NOT EXISTS teams (
      league     TEXT NOT NULL,
      abbr       TEXT NOT NULL,
      name       TEXT NOT NULL,
      short_name TEXT NOT NULL,
      color      TEXT,
      alt_color  TEXT,
      logo_url   TEXT,
      espn_id    TEXT,
      PRIMARY KEY (league, abbr)
    );
    CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
    """

  public init(paths: Paths = Paths()) throws {
    self.paths = paths
    paths.ensure(paths.home)
    var db = try Database(path: paths.database.path)
    if try !Self.compatible(db) {
      let aside = paths.home.appendingPathComponent("games.unsupported.db")
      try? FileManager.default.removeItem(at: aside)
      try FileManager.default.moveItem(at: paths.database, to: aside)
      db = try Database(path: paths.database.path)
    }
    try db.exec(Self.schema)
    self.db = db
  }

  /// Empty, or already this layout.
  static func compatible(_ db: Database) throws -> Bool {
    let cols = try db.query("PRAGMA table_info(games)").compactMap { $0.string("name") }
    return cols.isEmpty || cols.contains("home_abbr")
  }

  // MARK: meta

  public func meta(_ key: String) -> String? {
    (try? db.query("SELECT value FROM meta WHERE key = ?", [key]))?.first?.string("value")
  }
  public func setMeta(_ key: String, _ value: String) {
    _ = try? db.run("INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [key, value])
  }

  // MARK: schedule

  public func saveTeams(_ teams: [Team]) throws {
    try db.transaction {
      for t in teams {
        try db.run("""
          INSERT INTO teams(league, abbr, name, short_name, color, alt_color, logo_url, espn_id) VALUES (?,?,?,?,?,?,?,?)
          ON CONFLICT(league, abbr) DO UPDATE SET name=excluded.name, short_name=excluded.short_name, color=excluded.color,
            alt_color=excluded.alt_color, logo_url=excluded.logo_url, espn_id=excluded.espn_id
          """, [t.league, t.abbr, t.name, t.shortName, t.color, t.altColor, t.logoURL, t.espnID])
      }
    }
  }

  public func teams(league: String) -> [Team] {
    ((try? db.query("SELECT * FROM teams WHERE league = ? ORDER BY name", [league])) ?? []).map {
      Team(league: league, abbr: $0.string("abbr") ?? "", name: $0.string("name") ?? "", shortName: $0.string("short_name") ?? "",
           color: $0.string("color"), altColor: $0.string("alt_color"), logoURL: $0.string("logo_url"), espnID: $0.string("espn_id"))
    }
  }

  /// Insert new games and update moved ones (matched by the provider's id). Returns how many were new.
  /// `markNew`: flag new games as NEW (not on the first import of a season).
  @discardableResult
  public func saveSchedule(_ games: [ScheduledGame], markNew: Bool) throws -> Int {
    try db.transaction {
      var added = 0
      for g in games {
        let fields: [Any?] = [g.id, g.season, g.stage.key, g.stage.label, g.gameNumber, g.date, g.start?.timeIntervalSince1970,
                              g.home.abbr, g.home.name, g.away.abbr, g.away.name]
        let changed = try db.run("""
          UPDATE games SET id=?, season=?, stage=?, stage_label=?, game_number=?, game_date=?, start_time=?,
            home_abbr=?, home_name=?, away_abbr=?, away_name=? WHERE league = ? AND external_id = ?
          """, fields + [g.league, g.externalID])
        if changed == 0 {
          try db.run("""
            INSERT OR IGNORE INTO games(id, season, stage, stage_label, game_number, game_date, start_time,
              home_abbr, home_name, away_abbr, away_name, league, external_id, is_new) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, fields + [g.league, g.externalID, markNew])
          added += 1
        }
      }
      return added
    }
  }

  // MARK: reading

  public func games(where clause: String = "1", _ args: [Any?] = [], order: String = "game_date DESC, start_time DESC") -> [Game] {
    ((try? db.query("SELECT * FROM games WHERE \(clause) ORDER BY \(order)", args)) ?? []).map(Self.game)
  }

  public func game(_ id: String) -> Game? { games(where: "id = ?", [id]).first }

  static func game(_ r: Row) -> Game {
    Game(id: r.string("id") ?? "", league: r.string("league") ?? "", season: r.string("season") ?? "",
         stage: r.string("stage") ?? "", stageLabel: r.string("stage_label") ?? "", gameNumber: r.int("game_number"),
         date: r.string("game_date") ?? "", start: r.double("start_time").map { Date(timeIntervalSince1970: $0) },
         home: r.string("home_abbr") ?? "", homeName: r.string("home_name") ?? "",
         away: r.string("away_abbr") ?? "", awayName: r.string("away_name") ?? "",
         topicURL: r.string("topic_url"), torrentURL: r.string("torrent_url"), resolution: r.string("resolution"),
         broadcast: r.string("broadcast"), favorite: r.int("favorite") == 1, watchPosition: r.double("watch_position"),
         duration: r.double("duration"), watchedAt: r.string("watched_at").flatMap(sqliteDate), isNew: r.int("is_new") == 1)
  }

  /// SQLite's datetime('now'): "yyyy-MM-dd HH:mm:ss", UTC.
  static func sqliteDate(_ s: String) -> Date? {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f.date(from: s)
  }

  // MARK: writing per game

  /// Record where a source has the game (720pier topic, torrent link, quality).
  public func setFound(_ id: String, topicURL: String?, torrentURL: String?, resolution: String?, broadcast: String?) {
    _ = try? db.run("""
      UPDATE games SET topic_url = coalesce(?, topic_url), torrent_url = coalesce(?, torrent_url),
        resolution = coalesce(?, resolution), broadcast = coalesce(?, broadcast), found_at = coalesce(found_at, datetime('now'))
      WHERE id = ?
      """, [topicURL, torrentURL, resolution, broadcast, id])
  }

  public func setWatch(_ id: String, position: Double?, duration: Double?) {
    _ = try? db.run("UPDATE games SET watch_position = ?, duration = coalesce(?, duration), watched_at = datetime('now'), is_new = 0 WHERE id = ?",
                    [position, duration, id])
  }

  public func setFavorite(_ id: String, _ on: Bool) {
    _ = try? db.run("UPDATE games SET favorite = ? WHERE id = ?", [on, id])
  }
}
