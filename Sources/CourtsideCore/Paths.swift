// Everything local lives in ~/.courtside (override with COURTSIDE_HOME, e.g. for testing):
//   games.db                              the library (all leagues)
//   config.json                           settings
//   leagues/<league>/logos/               team logos, fetched once
//   leagues/<league>/downloads/<game-id>/ a game's torrent content (a file or a folder) + hls/

import Foundation

public struct Paths: Sendable {
  public let home: URL

  public init(home: URL? = nil) {
    if let home { self.home = home }
    else if let env = ProcessInfo.processInfo.environment["COURTSIDE_HOME"], !env.isEmpty {
      self.home = URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
    } else {
      self.home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".courtside")
    }
  }

  public var database: URL { home.appendingPathComponent("games.db") }
  public var config: URL { home.appendingPathComponent("config.json") }
  public func league(_ id: String) -> URL { home.appendingPathComponent("leagues/\(id)") }
  public func logos(_ league: String) -> URL { self.league(league).appendingPathComponent("logos") }
  public func downloads(_ league: String) -> URL { self.league(league).appendingPathComponent("downloads") }
  public func download(league: String, game: String) -> URL { downloads(league).appendingPathComponent(game) }

  /// Create a folder (and its parents) if it's missing, and return it.
  @discardableResult
  public func ensure(_ dir: URL) -> URL {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }
}
