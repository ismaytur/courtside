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

extension Pier720 {
  /// Look for topics of the NBA games played so far and record them. Returns how many were found.
  /// The torrent link is resolved later (`torrent(topic:)`), when the game is actually downloaded.
  @discardableResult
  public func update(library: Library, league: NBA, now: Date = Date()) async throws -> Int {
    let wanted = NBA.pierMissing(library, now: now)
    guard !wanted.isEmpty else { return 0 }
    var forums = [Pier720.nbaForum]
    if let playoffs = try await newestSubforum(prefix: "NBA Playoffs") { forums.append(playoffs) }
    let found = try await Pier720.find(wanted: wanted, names: NBA.pierNames(library)) { page in
      var all: [Listing] = []
      for forum in forums { all += try await self.listing(forum: forum, page: page) }
      return all
    }
    for (gameID, l) in found {
      library.setFound(gameID, topicURL: l.topicURL, torrentURL: nil, resolution: l.resolution, broadcast: l.broadcast)
    }
    return found.count
  }
}
