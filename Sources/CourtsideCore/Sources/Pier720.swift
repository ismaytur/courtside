// Source: 720pier.ru, a phpBB forum. Each game is a topic titled like
//   NBA 2026-2027 / RS / 26.10.2026 / Atlanta Hawks @ Houston Rockets [Basketball, WEB-DL HD/720p/60fps, MKV/H.264, EN/SCHN]
//   NBA Playoffs 2026 / Round 1 / Game 6 / 30.04.2026 / New York Knicks @ Atlanta Hawks [… EN/ESPN]
// Listing pages are viewforum.php?f=<forum>&start=25n, sorted by latest reply (an old game jumps
// back to page 1 when someone comments). The .torrent is a post attachment that only signed-in
// members see; guests get a notice instead.
//
// Parsing is pure and tested offline. All HTTP goes through `Web`; cookies live in `fetch`.

import Foundation

public struct Listing: Sendable, Hashable {
  public let id: Int              // topic id (follows creation order)
  public let date: String         // "yyyy-MM-dd", as written in the title (US Eastern, like ESPN)
  public let away: String         // full team name as the forum writes it
  public let home: String
  public let stage: String        // "NBA 2026-2027 / RS", "NBA Playoffs 2026 / Round 1 / Game 6"
  public let resolution: String?  // "1280x720"
  public let videoInfo: String?   // "WEB-DL HD/720p/60fps, MKV/H.264"
  public let broadcast: String?   // "EN/SCHN"
  public var topicURL: String { Pier720.topicURL(id).absoluteString }
}

public struct LoginForm: Sendable, Equatable {
  public let action: URL
  public var fields: [String: String]   // hidden inputs (form_token, creation_time, sid, redirect…) + the login button
}

public enum Pier720Error: LocalizedError {
  case noAccount, signInFailed(String?), pageMissing(URL), noAttachment

  public var errorDescription: String? {
    switch self {
    case .noAccount: "Enter your 720pier username and password in Settings."
    case .signInFailed(let said?): "720pier didn't sign you in: \(said)"
    case .signInFailed(nil): "720pier didn't accept the username and password."
    case .pageMissing(let url): "720pier page not found: \(url.path)"
    case .noAttachment: "This 720pier topic has no torrent attachment."
    }
  }
}

public actor Pier720: Source {
  public nonisolated let id = "720pier"
  public nonisolated let name = "720pier.ru"
  public nonisolated var homepage: URL { Self.url("viewforum.php?f=\(Self.nbaForum)") }

  static let base = URL(string: "https://720pier.ru/")!
  static let nbaForum = 34
  static let archiveForum = 32      // lists the yearly "NBA Playoffs YYYY" subforums
  static let perPage = 25
  static let guestNotice = "У вас нет необходимых прав для просмотра вложений"

  private let account: Settings.Account
  private var signedIn = false

  public init(account: Settings.Account) { self.account = account }

  nonisolated static func url(_ path: String) -> URL { URL(string: path, relativeTo: base)!.absoluteURL }
  nonisolated static func topicURL(_ id: Int) -> URL { url("viewtopic.php?t=\(id)") }

  // MARK: pages

  /// One page of a forum's topic list (0-based), game topics only. Empty past the last page.
  public func listing(forum: Int, page: Int) async throws -> [Listing] {
    let url = Self.url("viewforum.php?f=\(forum)&start=\(page * Self.perPage)")
    guard let html = try await Web.text(url) else { return [] }
    return Self.parseListing(html)
  }

  /// The forum id of the newest "<prefix> YYYY" subforum on the archive page (e.g. "NBA Playoffs 2026").
  public func newestSubforum(prefix: String) async throws -> Int? {
    let url = Self.url("viewforum.php?f=\(Self.archiveForum)")
    guard let html = try await Web.text(url) else { throw Pier720Error.pageMissing(url) }
    return Self.parseSubforums(html, prefix: prefix).first?.forum
  }

  // MARK: sign in

  public func signIn() async throws {
    guard !account.username.isEmpty, !account.password.isEmpty else { throw Pier720Error.noAccount }
    Log.info("720pier", "sign-in: start (username set, password set)")
    let loginURL = Self.url("ucp.php?mode=login")
    guard let page = try await Web.text(loginURL) else { throw Pier720Error.pageMissing(loginURL) }
    if Self.isSignedIn(page) {
      Log.info("720pier", "sign-in: already signed in (logout link on the login page)")
      signedIn = true; return
    }
    guard var form = Self.parseLoginForm(page, base: loginURL) else {
      Log.warn("720pier", "sign-in: no login form on the login page — page says: \(Log.snippet(page))")
      throw Pier720Error.pageMissing(loginURL)
    }
    Log.info("720pier", "sign-in: form found, posts to \(Web.describe(form.action)), fields: \(form.fields.keys.sorted().joined(separator: ", "))")
    form.fields["username"] = account.username
    form.fields["password"] = account.password
    form.fields["autologin"] = "on"
    let res = try await Web.postForm(form.action, form.fields, headers: ["Referer": loginURL.absoluteString])
    let answer = String(decoding: res.body, as: UTF8.self)
    let said = Self.parseError(answer)
    Log.info("720pier", "sign-in: posted → \(res.status), ended at \(Web.describe(res.url)), logout link: \(Self.isSignedIn(answer) ? "yes" : "no")"
      + (said.map { ", forum says: \($0)" } ?? ""))
    if let said, !Self.isSignedIn(answer) {
      Log.warn("720pier", "sign-in: rejected — \(said)")
      throw Pier720Error.signInFailed(said)
    }
    // The answer is a redirect or a "you have been logged in" page; the home page tells for sure.
    let home = try await Web.text(Self.url("index.php")) ?? answer
    guard Self.isSignedIn(home) else {
      Log.warn("720pier", "sign-in: home page still shows a guest — post answer says: \(Log.snippet(answer))")
      throw Pier720Error.signInFailed(nil)
    }
    Log.info("720pier", "sign-in: done")
    signedIn = true
  }

  /// phpBB's message for a failed form (wrong password, too many attempts, form expired), shown in
  /// an element with class "error" on the login page it sends back.
  public nonisolated static func parseError(_ html: String) -> String? {
    guard let m = html.firstMatch(of: #/class="[^"]*\berror\b[^"]*"[^>]*>([\s\S]*?)</(?:div|p|span|dd)>/#) else { return nil }
    let text = Log.snippet(String(m.1), limit: 200)
    return text.isEmpty ? nil : text
  }

  // MARK: torrent

  /// Absolute .torrent URL of a topic. Signs in first time, and once more if the page still shows
  /// the guest notice (an expired session).
  public func attachmentURL(topic: URL) async throws -> URL {
    if !signedIn { try await signIn() }
    var html = try await topicHTML(topic)
    if html.contains(Self.guestNotice) {
      Log.info("720pier", "topic shows the guest notice; signing in again")
      signedIn = false
      try await signIn()
      html = try await topicHTML(topic)
    }
    guard let url = Self.parseAttachment(html, base: topic) else {
      Log.warn("720pier", "no torrent attachment on \(Web.describe(topic)) — page says: \(Log.snippet(html))")
      throw Pier720Error.noAttachment
    }
    return url
  }

  public func torrent(topic: URL) async throws -> Data {
    let url = try await attachmentURL(topic: topic)
    guard let data = try await Web.data(url, headers: ["Referer": topic.absoluteString]) else {
      throw Pier720Error.pageMissing(url)
    }
    return data
  }

  private func topicHTML(_ url: URL) async throws -> String {
    guard let html = try await Web.text(url) else { throw Pier720Error.pageMissing(url) }
    return html
  }

  // MARK: parsing (pure)

  static let resolutions = ["1080p": "1920x1080", "720p": "1280x720", "540p": "960x540"]

  /// One topic title -> what it says about the game, or nil if it isn't a game (announcements, discussion).
  public nonisolated static func parseTitle(_ title: String, id: Int = 0) -> Listing? {
    var head = title, tags: [String] = []
    if let m = title.wholeMatch(of: #/(.*?)\s*\[(.*)\]\s*/#) {
      head = String(m.1)
      tags = m.2.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && $0.lowercased() != "basketball" }
    }
    let parts = head.components(separatedBy: " / ").map { $0.trimmingCharacters(in: .whitespaces) }
    guard let di = parts.firstIndex(where: { $0.wholeMatch(of: #/\d{1,2}\.\d{1,2}\.\d{4}/#) != nil }),
          di >= 1, di + 1 < parts.count else { return nil }
    let teams = parts[di + 1].components(separatedBy: " @ ").map { $0.trimmingCharacters(in: .whitespaces) }
    guard teams.count == 2, !teams[0].isEmpty, !teams[1].isEmpty, let date = isoDate(parts[di]) else { return nil }
    let isBroadcast = { (t: String) in t.wholeMatch(of: #/[A-Z]{2}\/.*/#) != nil }
    let res = tags.joined(separator: " ").firstMatch(of: #/\b(\d{3,4}p)\b/#).map { String($0.1) }
    return Listing(
      id: id, date: date, away: teams[0], home: teams[1], stage: parts[..<di].joined(separator: " / "),
      resolution: res.map { resolutions[$0] ?? $0 },
      videoInfo: tags.filter { !isBroadcast($0) }.joined(separator: ", ").nilIfEmpty,
      broadcast: tags.first(where: isBroadcast))
  }

  /// Game topics of one forum page, newest topic first. Announcements and stickies are dropped
  /// because they don't parse as games.
  public nonisolated static func parseListing(_ html: String) -> [Listing] {
    html.matches(of: #/<a href="\./viewtopic\.php\?t=(\d+)[^"]*"[^>]*class="topictitle"[^>]*>([\s\S]*?)</a>/#)
      .compactMap { m in
        let title = decodeEntities(String(m.2)).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
          .trimmingCharacters(in: .whitespaces)
        return parseTitle(title, id: Int(m.1) ?? 0)
      }
      .sorted { $0.id > $1.id }
  }

  /// Subforum links titled "<prefix> YYYY", newest year first.
  public nonisolated static func parseSubforums(_ html: String, prefix: String) -> [(year: Int, forum: Int)] {
    let found = html.matches(of: #/<a href="\./viewforum\.php\?f=(\d+)[^"]*"[^>]*>\s*([^<]*?)\s*</a>/#).compactMap { m -> (Int, Int)? in
      let text = decodeEntities(String(m.2))
      guard text.hasPrefix(prefix + " "), let year = Int(text.dropFirst(prefix.count + 1)), let forum = Int(m.1) else { return nil }
      return (year, forum)
    }
    return Dictionary(found, uniquingKeysWith: { a, _ in a }).map { (year: $0.key, forum: $0.value) }.sorted { $0.year > $1.year }
  }

  /// The sign-in form of ucp.php?mode=login: its action and hidden inputs. Nil when the page has no
  /// login form (already signed in, or not the login page).
  public nonisolated static func parseLoginForm(_ html: String, base: URL) -> LoginForm? {
    for m in html.matches(of: #/<form\b([^>]*)>([\s\S]*?)</form>/#) {
      let body = String(m.2)
      guard body.contains(#"name="username""#), body.contains(#"name="password""#) else { continue }
      var fields: [String: String] = [:]
      for input in body.matches(of: #/<input\b([^>]*)>/#) {
        let a = attributes(String(input.1))
        guard let name = a["name"], !name.isEmpty else { continue }
        let type = a["type"]?.lowercased()
        if type == "hidden" || (type == "submit" && name == "login") { fields[name] = decodeEntities(a["value"] ?? "") }
      }
      let action = attributes(String(m.1))["action"].map(decodeEntities) ?? ""
      guard let url = URL(string: action, relativeTo: base)?.absoluteURL else { continue }
      return LoginForm(action: url, fields: fields)
    }
    return nil
  }

  /// Signed-in pages carry a logout link; guests see the login form instead.
  public nonisolated static func isSignedIn(_ html: String) -> Bool { html.contains("mode=logout") }

  /// The .torrent attachment link of a topic page, absolute. Nil for guests and for topics without one.
  public nonisolated static func parseAttachment(_ html: String, base: URL) -> URL? {
    guard let m = html.firstMatch(of: #/href="(\.?\/?download\/file\.php\?id=\d+)[^"]*"/#) else { return nil }
    return URL(string: decodeEntities(String(m.1)), relativeTo: base)?.absoluteURL
  }

  // MARK: helpers

  nonisolated static func isoDate(_ dmy: String) -> String? {
    let p = dmy.split(separator: ".")
    guard p.count == 3 else { return nil }
    return "\(p[2])-\(p[1].count == 1 ? "0" : "")\(p[1])-\(p[0].count == 1 ? "0" : "")\(p[0])"
  }

  nonisolated static func attributes(_ tag: String) -> [String: String] {
    var out: [String: String] = [:]
    for m in tag.matches(of: #/([\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/#) {
      out[String(m.1).lowercased()] = String(m.2 ?? m.3 ?? "")
    }
    return out
  }

  nonisolated static func decodeEntities(_ s: String) -> String {
    var out = s
    for (e, c) in [("&nbsp;", " "), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">")] {
      out = out.replacingOccurrences(of: e, with: c)
    }
    out = out.replacing(#/&#(\d+);/#) { m in Int(m.1).flatMap(UnicodeScalar.init).map { String(Character($0)) } ?? String(m.0) }
    return out.replacingOccurrences(of: "&amp;", with: "&") // last, so "&amp;lt;" stays "&lt;"
  }
}

extension String {
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: matching and finding

/// A game the library wants a topic for.
public struct Wanted: Sendable, Hashable {
  public let id: String
  public let date: String   // "yyyy-MM-dd"
  public let away: String   // abbreviations
  public let home: String

  public init(id: String, date: String, away: String, home: String) {
    self.id = id; self.date = date; self.away = away; self.home = home
  }
  public init(_ g: Game) { self.init(id: g.id, date: g.date, away: g.away, home: g.home) }
  public init(_ g: ScheduledGame) { self.init(id: g.id, date: g.date, away: g.away.abbr, home: g.home.abbr) }
}

/// Forum team names -> abbreviations of a league's teams.
public struct TeamNames: Sendable {
  private var index: [String: String] = [:]

  /// `aliases`: other spellings -> abbreviation (only used if the team exists).
  public init(teams: [Team], aliases: [String: String] = [:]) {
    for t in teams {
      index[Self.key(t.name)] = t.abbr
    }
    for (alias, abbr) in aliases where teams.contains(where: { $0.abbr == abbr }) { index[Self.key(alias)] = abbr }
  }

  public func abbr(_ name: String) -> String? { index[Self.key(name)] }

  static func key(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
}

extension Pier720 {
  /// Listings that are one of the wanted games: same date and both teams. Game id -> listing (the
  /// newest topic if there are reposts). Listings of unknown teams (Summer League) match nothing.
  public nonisolated static func match(_ listings: [Listing], wanted: [Wanted], names: TeamNames) -> [String: Listing] {
    var byKey: [String: [Wanted]] = [:]
    for w in wanted { byKey["\(w.date)|\(w.away)|\(w.home)", default: []].append(w) }
    var out: [String: Listing] = [:]
    for l in listings {
      guard let away = names.abbr(l.away), let home = names.abbr(l.home) else { continue }
      for w in byKey["\(l.date)|\(away)|\(home)"] ?? [] where (out[w.id]?.id ?? 0) < l.id { out[w.id] = l }
    }
    return out
  }

  /// Read pages newest-first until every wanted game is found, or `olderPages` pages in a row have
  /// nothing newer than the oldest missing game (the forum is sorted by last reply, so one old page
  /// can be a fluke), or the pages run out, or `maxPages`.
  public nonisolated static func find(
    wanted: [Wanted], names: TeamNames, maxPages: Int = 80, olderPages: Int = 2, loadPage: (Int) async throws -> [Listing]
  ) async throws -> [String: Listing] {
    var missing = wanted, found: [String: Listing] = [:], older = 0
    for page in 0..<maxPages {
      guard let oldest = missing.map(\.date).min() else { break }
      let listings = try await loadPage(page)
      guard let newest = listings.map(\.date).max() else { break }
      let hits = match(listings, wanted: missing, names: names)
      found.merge(hits) { a, _ in a }
      missing.removeAll { hits[$0.id] != nil }
      older = newest < oldest ? older + 1 : 0
      if older >= olderPages { break }
    }
    return found
  }
}
