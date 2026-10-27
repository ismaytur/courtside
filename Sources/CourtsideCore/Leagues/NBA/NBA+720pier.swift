// NBA on 720pier.ru: the regular-season forum (f=34) plus the newest "NBA Playoffs YYYY" subforum
// (found on the f=32 page), matched to the library's games by date and teams.

import Foundation

extension NBA {
  /// How the forum spells teams that ESPN names differently.
  static let pierAliases = [
    "Los Angeles Clippers": "LAC", "LA Clippers": "LAC", "LA Lakers": "LAL",
    "Philadelphia Sixers": "PHI", "Portland Trailblazers": "POR",
  ]

  static func pierNames(_ library: Library) -> TeamNames {
    TeamNames(teams: library.teams(league: "nba"), aliases: pierAliases)
  }

  /// Played games without a topic yet: kick-off in the past, or (time unknown) an earlier date.
  static func pierMissing(_ library: Library, now: Date) -> [Wanted] {
    let today = ymd(now)
    return library.games(where: "league = 'nba' AND topic_url IS NULL AND ((start_time IS NOT NULL AND start_time < ?) OR (start_time IS NULL AND game_date < ?))",
                         [now.timeIntervalSince1970, today]).map(Wanted.init)
  }

  static func ymd(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = eastern; f.dateFormat = "yyyy-MM-dd"
    return f.string(from: d)
  }
}

/// What the NBA glue needs from 720pier; Pier720 in the app, a fake in tests.
public protocol PierForum: Sendable {
  func signIn() async throws
  func listing(forum: Int, page: Int) async throws -> [Listing]
  func newestSubforum(prefix: String) async throws -> Int?
  func torrent(topic: URL) async throws -> Data
}

extension Pier720: PierForum {}

extension NBA {
  /// Look for topics of these games and record them. Returns game id -> listing.
  static func pierFind(_ wanted: [Wanted], forum: some PierForum, library: Library, olderPages: Int = 2) async throws -> [String: Listing] {
    guard !wanted.isEmpty else { return [:] }
    var forums = [Pier720.nbaForum]
    if let playoffs = try await forum.newestSubforum(prefix: "NBA Playoffs") { forums.append(playoffs) }
    let found = try await Pier720.find(wanted: wanted, names: pierNames(library), olderPages: olderPages) { page in
      var all: [Listing] = []
      for f in forums { all += try await forum.listing(forum: f, page: page) }
      return all
    }
    for (gameID, l) in found {
      library.setFound(gameID, topicURL: l.topicURL, torrentURL: nil, resolution: l.resolution, broadcast: l.broadcast)
    }
    return found
  }

  /// The topic of one game, for Play: the stored one, else a deeper look than the availability
  /// check (it gives up only after four pages older than the game). Nil when it isn't posted.
  public static func pierTopic(for game: Game, forum: some PierForum, library: Library) async throws -> URL? {
    if let t = game.topicURL, let url = URL(string: t) { return url }
    let found = try await pierFind([Wanted(game)], forum: forum, library: library, olderPages: 4)
    return found[game.id].flatMap { URL(string: $0.topicURL) }
  }
}

extension Pier720 {
  /// Look for topics of the NBA games played so far and record them. Returns how many were found.
  /// The torrent link is resolved later (`torrent(topic:)`), when the game is actually downloaded.
  @discardableResult
  public func update(library: Library, league: NBA, now: Date = Date()) async throws -> Int {
    let missing = NBA.pierMissing(library, now: now)
    Log.info("720pier", "finder: \(missing.count) played games without a topic")
    let found = try await NBA.pierFind(missing, forum: self, library: library).count
    Log.info("720pier", "finder: found \(found)")
    return found
  }
}
