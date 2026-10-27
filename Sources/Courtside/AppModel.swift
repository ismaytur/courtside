// What the window shows: the library's games, the filters the sidebar sets, and the actions
// (refresh, favorite, clear download). Everything it reads or writes lives in COURTSIDE_HOME.

import SwiftUI
import AppKit
import Observation
import CourtsideCore

enum Scope: String, CaseIterable, Identifiable {
  case all = "All games", favorites = "Favorites", downloaded = "Downloaded"
  var id: String { rawValue }
  var icon: String {
    switch self {
    case .all: "sportscourt"
    case .favorites: "heart"
    case .downloaded: "arrow.down.circle"
    }
  }
}

enum Status: String {
  case upcoming = "Upcoming", notPosted = "Not posted yet", available = "Available", downloaded = "Downloaded"
}

struct DaySection: Identifiable {
  let id: String        // "upcoming" or the date
  let title: String
  let games: [Game]
}

@MainActor @Observable
final class AppModel {
  let paths = Paths()
  private(set) var library: Library?
  private(set) var settings: CourtsideCore.Settings
  private(set) var games: [Game] = []
  private(set) var teams: [String: Team] = [:]       // "nba/ATL"
  private(set) var logoImages: [String: NSImage] = [:]
  private(set) var downloaded: Set<String> = []
  private(set) var refreshing = false
  var message: String?                                 // shown in an alert

  var scope = Scope.all
  var league: String?
  var season: String?
  var stage: String?
  var team: String?

  init() {
    settings = Settings.load(paths)
    do { library = try Library(paths: paths) }
    catch { message = "Couldn't open the library: \(error.localizedDescription)" }
    reload()
    if season == nil { season = seasons.first }
  }

  /// On launch: show what's stored, then refresh the schedule if it's due.
  func start() async {
    guard let library else { return }
    let due = Leagues.all.contains { settings.isOn(league: $0.id) && ScheduleRefresh(library: library, settings: settings).isDue($0) }
    if due { await refresh(force: false) }
  }

  // MARK: reading

  func reload() {
    guard let library else { return }
    games = library.games().filter { settings.isOn(league: $0.league) }
    teams = Dictionary(uniqueKeysWithValues: Leagues.all.flatMap { library.teams(league: $0.id) }.map { ("\($0.league)/\($0.abbr)", $0) })
    downloaded = Set(games.filter { FileManager.default.fileExists(atPath: paths.download(league: $0.league, game: $0.id).path) }.map(\.id))
    loadLogos()
  }

  private func loadLogos() {
    for (key, team) in teams where logoImages[key] == nil {
      if let img = NSImage(contentsOf: Logos(paths: paths).file(for: team)) { logoImages[key] = img }
    }
  }

  func team(_ league: String, _ abbr: String) -> Team? { teams["\(league)/\(abbr)"] }
  func logo(_ league: String, _ abbr: String) -> NSImage? { logoImages["\(league)/\(abbr)"] }

  var leagues: [any League] { Leagues.all.filter { settings.isOn(league: $0.id) } }

  var seasons: [String] { Array(Set(games.map(\.season))).sorted(by: >) }

  var stages: [Stage] {
    let present = Set(games.filter { league == nil || $0.league == league }.map(\.stage))
    return (leagues.first { $0.id == league } ?? leagues.first)?.stages.filter { present.contains($0.key) } ?? []
  }

  var teamChoices: [Team] {
    teams.values.filter { league == nil || $0.league == league }.sorted { $0.name < $1.name }
  }

  func status(_ g: Game, now: Date = Date()) -> Status {
    if downloaded.contains(g.id) { return .downloaded }
    if isUpcoming(g, now: now) { return .upcoming }
    return g.topicURL == nil ? .notPosted : .available
  }

  func isUpcoming(_ g: Game, now: Date = Date()) -> Bool {
    if let start = g.start { return start > now }
    return g.date > Self.format(now, "yyyy-MM-dd")
  }

  /// Games after the filters, as "Upcoming" (soonest first) then one section per date, newest first.
  var sections: [DaySection] {
    let now = Date()
    let shown = games.filter { g in
      (league == nil || g.league == league) && (season == nil || g.season == season)
        && (stage == nil || g.stage == stage) && (team == nil || g.home == team || g.away == team)
        && (scope != .favorites || g.favorite) && (scope != .downloaded || downloaded.contains(g.id))
    }
    let upcoming = shown.filter { isUpcoming($0, now: now) }
      .sorted { ($0.start ?? .distantFuture, $0.id) < ($1.start ?? .distantFuture, $1.id) }
    let past = Dictionary(grouping: shown.filter { !isUpcoming($0, now: now) }, by: \.date)
    var out: [DaySection] = []
    if !upcoming.isEmpty { out.append(DaySection(id: "upcoming", title: "Upcoming", games: upcoming)) }
    for date in past.keys.sorted(by: >) {
      out.append(DaySection(id: date, title: Self.dayTitle(date), games: past[date]!.sorted { ($0.start ?? .distantPast) > ($1.start ?? .distantPast) }))
    }
    return out
  }

  var shownCount: Int { sections.reduce(0) { $0 + $1.games.count } }

  // MARK: actions

  func refresh(force: Bool) async {
    guard let library, !refreshing else { return }
    refreshing = true
    defer { refreshing = false }
    let result = await ScheduleRefresh(library: library, settings: settings).run(force: force)
    reload()
    if season == nil || !seasons.contains(season!) { season = seasons.first }
    if !result.errors.isEmpty { message = "Couldn't refresh everything:\n" + result.errors.joined(separator: "\n") }
    await Logos(paths: paths).fetchAll(Array(teams.values))
    loadLogos()
  }

  func toggleFavorite(_ g: Game) {
    library?.setFavorite(g.id, !g.favorite)
    reload()
  }

  func clearDownload(_ g: Game) {
    try? FileManager.default.removeItem(at: paths.download(league: g.league, game: g.id))
    reload()
  }

  func clearAllDownloads() {
    for l in Leagues.all { try? FileManager.default.removeItem(at: paths.downloads(l.id)) }
    reload()
  }

  /// The player comes in a later step.
  func onPlay(_ g: Game) {
    message = "Player coming soon"
  }

  func update(_ change: (inout CourtsideCore.Settings) -> Void) {
    change(&settings)
    do { try settings.save(paths) } catch { message = "Couldn't save settings: \(error.localizedDescription)" }
    reload()
  }

  // MARK: dates (game dates are US Eastern days)

  static let eastern = TimeZone(identifier: "America/New_York")!

  static func format(_ d: Date, _ pattern: String) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = eastern
    f.dateFormat = pattern
    return f.string(from: d)
  }

  static func parseDay(_ ymd: String) -> Date? {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = eastern
    f.dateFormat = "yyyy-MM-dd"
    return f.date(from: ymd)
  }

  static func dayTitle(_ ymd: String) -> String { parseDay(ymd).map { format($0, "EEEE, MMMM d, yyyy") } ?? ymd }
  static func shortDay(_ ymd: String) -> String { parseDay(ymd).map { format($0, "EEE, MMM d") } ?? ymd }
}
