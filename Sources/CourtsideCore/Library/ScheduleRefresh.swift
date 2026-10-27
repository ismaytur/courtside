// Keeps the library's schedule current: for every league that's on, teams first (the schedule
// needs their ids), then the current season's games. Runs when it never ran, is a week old, or is forced.

import Foundation

public struct ScheduleRefresh: Sendable {
  public static let maxAge: TimeInterval = 7 * 24 * 3600

  public let library: Library
  public let settings: Settings

  public init(library: Library, settings: Settings) {
    self.library = library
    self.settings = settings
  }

  static func key(_ league: String) -> String { "schedule.refreshed.\(league)" }

  public func isDue(_ league: any League, now: Date = Date()) -> Bool {
    guard let text = library.meta(Self.key(league.id)), let t = Double(text) else { return true }
    return now.timeIntervalSince1970 - t > Self.maxAge
  }

  /// Refresh the leagues that are on and due (all of them when `force`). Returns how many games were new.
  /// A league that fails (offline, ESPN down) is skipped and its error reported; the rest still run.
  @discardableResult
  public func run(force: Bool = false, now: Date = Date()) async -> Result {
    var result = Result()
    for league in Leagues.all where settings.isOn(league: league.id) && (force || isDue(league, now: now)) {
      do { result.added += try await refresh(league, now: now) }
      catch { result.errors.append("\(league.name): \(error.localizedDescription)") }
    }
    return result
  }

  public struct Result: Sendable {
    public var added = 0
    public var errors: [String] = []
  }

  func refresh(_ league: any League, now: Date) async throws -> Int {
    let teams = try await league.teams()
    try library.saveTeams(teams)
    let season = league.season(on: now)
    let games = try await league.schedule(season: season, teams: teams, now: now)
    // The first import of a season isn't "new": hundreds of games would all carry the badge.
    let seen = "schedule.imported.\(league.id).\(season)"
    let added = try library.saveSchedule(games, markNew: library.meta(seen) != nil)
    library.setMeta(seen, "1")
    library.setMeta(Self.key(league.id), String(now.timeIntervalSince1970))
    return added
  }
}
