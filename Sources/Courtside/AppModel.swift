// What the window shows: the library's games, the filters the sidebar sets, and the actions
// (refresh, check 720pier, play, favorite, clear download). Everything it reads or writes lives in
// COURTSIDE_HOME.

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
  case upcoming = "Upcoming", notPosted = "Not posted yet", available = "Available", downloading = "Downloading",
       downloaded = "Downloaded"
}

/// What the player overlay shows, from "looking for the torrent" to the video itself.
enum PlayStage {
  case loading(String)
  case choose(OpenGame, resume: WatchRules.Start?)   // resume / start over / part picker
  case playing(GamePlayer)
  case failed(String)
}

struct Playing {
  let game: Game
  var stage: PlayStage
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
  private(set) var downloaded: Set<String> = []        // complete downloads
  private(set) var hasFiles: Set<String> = []          // anything on disk (complete or not)
  private(set) var downloadProgress: [String: Double] = [:]   // games downloading now, 0…1
  private(set) var refreshing = false
  private(set) var checkingPier = false
  private(set) var now = Date()                        // ticks every minute: games start, Upcoming ends
  var message: String?                                 // shown in an alert
  var pierNote: String?                                // why the automatic 720pier check didn't work
  private(set) var playing: Playing?

  @ObservationIgnored let engine: PlaybackEngine
  @ObservationIgnored private var pierClient: (CourtsideCore.Settings.Account, Pier720)?
  @ObservationIgnored private var playTask: Task<Void, Never>?

  var scope = Scope.all
  var league: String?
  var season: String?
  var stage: String?
  var team: String?
  // The timeline shows a window of game days, oldest first: [windowFirst, windowLast]. It opens at
  // the first day with games still to come and grows by `step` days at either end as you scroll.
  private(set) var windowFirst: String?
  private(set) var windowLast: String?
  static let step = 5

  init() {
    let loaded = Settings.load(paths)
    settings = loaded
    engine = PlaybackEngine(uploadKBps: loaded.storage.uploadKBps, lan: loaded.playback.airplayLAN)
    do { library = try Library(paths: paths) }
    catch { message = "Couldn't open the library: \(error.localizedDescription)" }
    reload()
    if season == nil { season = seasons.first }
    engine.onComplete = { [weak self] _ in
      Task { @MainActor in self?.reload(); self?.enforceCap() }
    }
    NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.closePlayer() }
    }
  }

  /// On launch: show what's stored, refresh the schedule if it's due (which also checks 720pier),
  /// else just check 720pier for newly posted games.
  func start() async {
    guard let library else { return }
    Task { await self.ticker() }
    enforceCap()
    // Tests (with a scratch COURTSIDE_HOME): press Play on this game at launch.
    if let id = ProcessInfo.processInfo.environment["COURTSIDE_TEST_PLAY"], let g = library.game(id) { play(g) }
    let due = Leagues.all.contains { settings.isOn(league: $0.id) && ScheduleRefresh(library: library, settings: settings).isDue($0) }
    if due { await refresh(force: false) } else { await checkPier(manual: false) }
  }

  /// Keeps `now` and the download percentages current.
  private func ticker() async {
    var n = 0
    while !Task.isCancelled {
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      n += 1
      if n % 30 == 0 { now = Date() }
      var progress: [String: Double] = [:]
      for id in engine.openIDs {
        if let g = engine.game(id), g.torrent != nil, g.progress < 1 { progress[id] = g.progress }
      }
      if progress != downloadProgress { downloadProgress = progress }
    }
  }

  // MARK: reading

  func reload() {
    guard let library else { return }
    games = library.games().filter { settings.isOn(league: $0.league) }
    teams = Dictionary(uniqueKeysWithValues: Leagues.all.flatMap { library.teams(league: $0.id) }.map { ("\($0.league)/\($0.abbr)", $0) })
    let folders = games.map { ($0.id, folder($0)) }.filter { $0.1.exists }
    hasFiles = Set(folders.map(\.0))
    downloaded = Set(folders.filter { $0.1.isComplete }.map(\.0))
    if windowFirst == nil { resetTimeline() }   // first load; later reloads keep where you are
    loadLogos()
  }

  /// What the filters are set to; the timeline re-opens when it changes.
  var filterKey: String { "\(scope.rawValue)|\(league ?? "")|\(season ?? "")|\(stage ?? "")|\(team ?? "")" }

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

  func folder(_ g: Game) -> GameFolder { GameFolder(paths: paths, league: g.league, game: g.id) }

  func status(_ g: Game) -> Status {
    if downloaded.contains(g.id) { return .downloaded }
    if downloadProgress[g.id] != nil { return .downloading }
    if isUpcoming(g, now: now) { return .upcoming }
    return g.topicURL == nil ? .notPosted : .available
  }

  func isUpcoming(_ g: Game, now: Date) -> Bool {
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

  /// Series stages: one block per matchup (the timeline doesn't apply).
  func seriesView() -> [Block] { seriesBlocks(filtered()) }

  /// Every game day after the filters, oldest first.
  func gameDays() -> [String] { Array(Set(filtered().map(\.date))).sorted() }

  /// The first day with a game still to come (by start time), else the last day there is.
  func anchorDay(_ days: [String]) -> String? {
    let upcoming = Set(filtered().filter { isUpcoming($0, now: now) }.map(\.date))
    return days.first(where: upcoming.contains) ?? days.last
  }

  /// Back to the opening position: the anchor day and the `step - 1` game days after it.
  func resetTimeline(to day: String? = nil) {
    let days = gameDays()
    guard let start = day.flatMap({ d in days.first { $0 >= d } }) ?? anchorDay(days), let i = days.firstIndex(of: start) else {
      windowFirst = nil; windowLast = nil; return
    }
    windowFirst = days[i]
    windowLast = days[min(days.count - 1, i + Self.step - 1)]
  }

  /// Indices of the window in `days`, opening it if it isn't set or no longer fits the filters.
  private func window(_ days: [String]) -> ClosedRange<Int>? {
    guard let f = windowFirst, let l = windowLast,
          let lo = days.firstIndex(where: { $0 >= f }), let hi = days.lastIndex(where: { $0 <= l }), lo <= hi else { return nil }
    return lo...hi
  }

  var canLoadEarlier: Bool { let d = gameDays(); return window(d).map { $0.lowerBound > 0 } ?? false }
  var canLoadLater: Bool { let d = gameDays(); return window(d).map { $0.upperBound < d.count - 1 } ?? false }

  func loadEarlier() {
    let days = gameDays()
    guard let w = window(days), w.lowerBound > 0 else { return }
    windowFirst = days[max(0, w.lowerBound - Self.step)]
  }

  func loadLater() {
    let days = gameDays()
    guard let w = window(days), w.upperBound < days.count - 1 else { return }
    windowLast = days[min(days.count - 1, w.upperBound + Self.step)]
  }

  /// The loaded days, oldest first.
  func timeline() -> [DayGroup] {
    let days = gameDays()
    guard let w = window(days) else { return [] }
    let shown = Set(days[w])
    return dayGroups(filtered().filter { shown.contains($0.date) }, now: now, newestFirst: false)
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
    await checkPier(manual: false)
  }

  // MARK: 720pier

  var hasPierAccount: Bool {
    let a = settings.sources["720pier"] ?? CourtsideCore.Settings.Account()
    return !a.username.isEmpty && !a.password.isEmpty
  }

  /// One client per account, so its sign-in is reused.
  private func pier() -> Pier720 {
    let account = settings.sources["720pier"] ?? CourtsideCore.Settings.Account()
    if let (a, p) = pierClient, a == account { return p }
    let p = Pier720(account: account)
    pierClient = (account, p)
    return p
  }

  /// Sign in and look for topics of the games played so far. The automatic run (after a refresh,
  /// on launch) is quiet without an account and reports problems in a banner; the toolbar's
  /// "Check 720pier" says what happened in an alert.
  func checkPier(manual: Bool) async {
    guard let library, !checkingPier, settings.isOn(league: "nba") else { return }
    guard hasPierAccount else {
      if manual { message = Self.explain(Pier720Error.noAccount) }
      return
    }
    checkingPier = true
    defer { checkingPier = false }
    do {
      let p = pier()
      // Give up after 60 s so the check can't spin forever if a step hangs (the network, the forum,
      // the browser warm-up): the spinner stops and the user gets a message instead.
      let found = try await Self.withTimeout(seconds: 60) {
        try await p.signIn()
        return try await p.update(library: library, league: NBA())
      }
      pierNote = nil
      reload()
      if manual { message = found == 0 ? "No newly posted games on 720pier." : "Found \(found) newly posted game\(found == 1 ? "" : "s") on 720pier." }
    } catch is TimeoutError {
      Log.warn("720pier", "check gave up after 60 s")
      let note = "720pier didn't answer within 60 seconds. Check Help ▸ Show Logs for where it stopped."
      if manual { message = note } else { pierNote = note }
    } catch {
      if manual { message = Self.explain(error) } else { pierNote = Self.explain(error) }
    }
  }

  struct TimeoutError: Error {}

  /// Run `work`, but throw `TimeoutError` if it isn't done within `seconds`.
  static func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask { try await work() }
      group.addTask { try await Task.sleep(for: .seconds(seconds)); throw TimeoutError() }
      defer { group.cancelAll() }
      return try await group.next()!
    }
  }

  /// Plain-language reasons for what goes wrong with 720pier and playback.
  static func explain(_ error: Error) -> String {
    switch error {
    case Pier720Error.noAccount:
      return "Add your 720pier username and password in Settings (Courtside > Settings) to find and play games."
    case Pier720Error.signInFailed(let said?):
      return "720pier didn't sign you in: \(said)"
    case Pier720Error.signInFailed(nil):
      return "720pier didn't sign you in. Check the username and password in Settings."
    case let e as WebError where e.status == 403:
      return "720pier refused the connection (403: it blocks programs). Courtside can't reach it right now."
    case let e as WebError:
      return "720pier answered with an error (HTTP \(e.status)). Try again later."
    case let e as TorrentError:
      return "The download couldn't start: \(e.description)."
    case let e as LocalizedError where e.errorDescription != nil:
      return e.errorDescription!
    default:
      return "Something went wrong: \(error.localizedDescription)"
    }
  }

  // MARK: playing

  func play(_ g: Game) {
    guard playing == nil else { return }
    playing = Playing(game: g, stage: .loading("Opening the game…"))
    playTask = Task { await open(g) }
  }

  private func setStage(_ stage: PlayStage, for g: Game) {
    guard playing?.game.id == g.id else { return }
    playing?.stage = stage
  }

  private func open(_ g: Game) async {
    guard let library else { return }
    let folder = folder(g)
    do {
      var torrent: Data?
      if !folder.isComplete, !FileManager.default.fileExists(atPath: folder.torrentFile.path) {
        guard g.league == "nba" else { throw PlaybackError.notPosted }
        guard hasPierAccount else { throw Pier720Error.noAccount }
        if g.topicURL == nil { setStage(.loading("Looking for the game on 720pier…"), for: g) }
        guard let topic = try await NBA.pierTopic(for: g, forum: pier(), library: library) else { throw PlaybackError.notPosted }
        setStage(.loading("Getting the torrent from 720pier…"), for: g)
        let data = try await pier().torrent(topic: topic)
        // A signed-out answer is a web page, not a bencoded dictionary.
        guard data.first == UInt8(ascii: "d") else {
          Log.warn("720pier", "the torrent download returned a web page, not a .torrent — page says: \(Log.snippet(String(decoding: data, as: UTF8.self)))")
          throw Pier720Error.signInFailed(nil)
        }
        torrent = data
      }
      try Task.checkCancellation()
      let open = try engine.open(id: g.id, folder: folder, torrentData: torrent)
      reload()
      enforceCap()
      let fresh = library.game(g.id) ?? g
      let resume = WatchRules.resume(position: fresh.watchPosition, duration: fresh.duration,
                                     part: folder.state?.part ?? 0, parts: open.parts.count)
      if resume != nil || open.parts.count > 1 {
        setStage(.choose(open, resume: resume), for: g)
      } else {
        startPlayer(open, at: .beginning)
      }
    } catch is CancellationError {
    } catch {
      setStage(.failed(Self.explain(error)), for: g)
    }
  }

  func startPlayer(_ open: OpenGame, at start: WatchRules.Start) {
    guard let library, let p = playing else { return }
    let player = GamePlayer(game: library.game(p.game.id) ?? p.game, open: open, engine: engine, library: library)
    player.start(part: start.part, at: start.position)
    playing?.stage = .playing(player)
  }

  /// Close the overlay; the position is saved and the download carries on.
  func closePlayer() {
    playTask?.cancel()
    if case .playing(let player)? = playing?.stage { player.close() }
    playing = nil
    reload()
  }

  var playingID: String? { playing?.game.id }

  // MARK: downloads

  /// Delete what's on disk beyond the cap, least recently watched first; never the game playing.
  func enforceCap() {
    guard let library else { return }
    let entries = library.games().compactMap { g -> DownloadCap.Entry? in
      let f = folder(g)
      guard f.exists else { return nil }
      return DownloadCap.Entry(id: g.id, bytes: f.bytes, lastUsed: g.watchedAt ?? f.created)
    }
    let cap = Int64(settings.storage.cacheGB * 1_000_000_000)
    let remove = DownloadCap.evictions(entries, capBytes: cap, keep: Set([playingID].compactMap { $0 }))
    guard !remove.isEmpty else { return }
    for id in remove {
      engine.close(id)
      if let g = library.game(id) { folder(g).delete() }
    }
    reload()
  }

  func toggleFavorite(_ g: Game) {
    library?.setFavorite(g.id, !g.favorite)
    reload()
  }

  /// Stop the game's torrent and delete its folder (closing the player first if it's this game).
  func clearDownload(_ g: Game) {
    if playingID == g.id { closePlayer() }
    engine.close(g.id)
    folder(g).delete()
    reload()
  }

  func clearAllDownloads() {
    closePlayer()
    engine.closeAll()
    for l in Leagues.all { try? FileManager.default.removeItem(at: paths.downloads(l.id)) }
    reload()
  }

  func update(_ change: (inout CourtsideCore.Settings) -> Void) {
    let before = settings
    change(&settings)
    do { try settings.save(paths) } catch { message = "Couldn't save settings: \(error.localizedDescription)" }
    if settings.storage.uploadKBps != before.storage.uploadKBps { engine.setUploadLimit(kbps: settings.storage.uploadKBps) }
    if settings.playback.airplayLAN != before.playback.airplayLAN { engine.setLAN(settings.playback.airplayLAN) }
    reload()
    if settings.storage.cacheGB < before.storage.cacheGB { enforceCap() }
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
