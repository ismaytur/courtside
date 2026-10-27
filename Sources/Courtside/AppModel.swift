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

/// Games of one day (or, in a series view, one series; `title` is then empty or the matchup).
struct DayGroup: Identifiable {
  let id: String
  let title: String
  let games: [Game]
}

/// A top-level, pinned section: "Upcoming", a month ("October 2026"), or one playoff series.
struct Block: Identifiable {
  let id: String
  let title: String
  let days: [DayGroup]
  var laterCount = 0     // upcoming games past the next 7 days (hidden until asked for)
}

enum Dimension { case league, season, stage, team }

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
  var showLaterUpcoming = false

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

  /// Series stages are shown per matchup, ordered by game number, instead of per day.
  static let seriesStages: Set<String> = ["first-round", "semis", "conf-finals", "finals"]
  var isSeriesView: Bool { stage.map(Self.seriesStages.contains) ?? false }

  /// Games after the filters; `ignoring` leaves one filter out (for the sidebar's counts).
  func filtered(ignoring dim: Dimension? = nil) -> [Game] {
    games.filter { g in
      (dim == .league || league == nil || g.league == league) && (dim == .season || season == nil || g.season == season)
        && (dim == .stage || stage == nil || g.stage == stage) && (dim == .team || team == nil || g.home == team || g.away == team)
        && (scope != .favorites || g.favorite) && (scope != .downloaded || downloaded.contains(g.id))
    }
  }

  func counts(by key: (Game) -> String, ignoring dim: Dimension) -> [String: Int] {
    filtered(ignoring: dim).reduce(into: [:]) { $0[key($1), default: 0] += 1 }
  }

  /// The grid's content: "Upcoming" (next 7 days by day, the rest on request), then one block per
  /// month, newest first. A series stage instead gets one block per matchup.
  func blocks(now: Date = Date()) -> [Block] {
    let shown = filtered()
    if isSeriesView { return seriesBlocks(shown) }
    var out: [Block] = []
    let upcoming = shown.filter { isUpcoming($0, now: now) }
      .sorted { ($0.start ?? .distantFuture, $0.id) < ($1.start ?? .distantFuture, $1.id) }
    if !upcoming.isEmpty {
      let weekOut = Self.format(now.addingTimeInterval(7 * 86400), "yyyy-MM-dd")
      let near = upcoming.filter { $0.date <= weekOut }
      let later = upcoming.count - near.count
      out.append(Block(id: "upcoming", title: "Upcoming", days: dayGroups(showLaterUpcoming ? upcoming : near, now: now, newestFirst: false), laterCount: later))
    }
    let past = shown.filter { !isUpcoming($0, now: now) }
    let months = Dictionary(grouping: past, by: { String($0.date.prefix(7)) })
    for month in months.keys.sorted(by: >) {
      out.append(Block(id: "m-\(month)", title: Self.monthTitle(month), days: dayGroups(months[month]!, now: now, newestFirst: true)))
    }
    return out
  }

  private func dayGroups(_ games: [Game], now: Date, newestFirst: Bool) -> [DayGroup] {
    let byDay = Dictionary(grouping: games, by: \.date)
    let days = newestFirst ? byDay.keys.sorted(by: >) : byDay.keys.sorted()
    let today = Self.format(now, "yyyy-MM-dd")
    let yesterday = Self.format(now.addingTimeInterval(-86400), "yyyy-MM-dd")
    let tomorrow = Self.format(now.addingTimeInterval(86400), "yyyy-MM-dd")
    return days.map { day in
      let title = day == today ? "Today" : day == yesterday ? "Yesterday" : day == tomorrow ? "Tomorrow" : Self.shortDay(day)
      let sorted = byDay[day]!.sorted { newestFirst ? ($0.start ?? .distantPast) > ($1.start ?? .distantPast) : ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
      return DayGroup(id: day, title: title, games: sorted)
    }
  }

  private func seriesBlocks(_ shown: [Game]) -> [Block] {
    let series = Dictionary(grouping: shown) { "\($0.season)-\($0.stage)-" + [$0.home, $0.away].sorted().joined(separator: "-") }
    return series.map { key, games in
      let ordered = games.sorted { ($0.gameNumber ?? 0, $0.date) < ($1.gameNumber ?? 0, $1.date) }
      let first = ordered[0]
      let title = "\(team(first.league, first.home)?.shortName ?? first.homeName) vs \(team(first.league, first.away)?.shortName ?? first.awayName)"
      return Block(id: key, title: title, days: [DayGroup(id: key, title: "", games: ordered)])
    }
    .sorted { ($0.days[0].games[0].date, $0.id) > ($1.days[0].games[0].date, $1.id) }
  }

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
  static func shortDay(_ ymd: String) -> String { parseDay(ymd).map { format($0, "EEE d MMM") } ?? ymd }
  static func monthTitle(_ ym: String) -> String { parseDay(ym + "-01").map { format($0, "MMMM yyyy") } ?? ym }
}
