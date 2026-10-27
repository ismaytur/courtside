// Settings in ~/.courtside/config.json. Missing or unreadable keys fall back to defaults, so an
// older or hand-edited file never stops the app (the Node version's file has a different shape).
//
//   { "leagues": { "nba": true },
//     "sources": { "720pier": { "username": "…", "password": "…" } },
//     "storage": { "cacheGB": 30, "uploadKBps": 256 } }

import Foundation

public struct Settings: Codable, Sendable, Equatable {
  public struct Account: Codable, Sendable, Equatable {
    public var username = ""
    public var password = ""
    public init() {}
  }
  public struct Storage: Codable, Sendable, Equatable {
    public var cacheGB = 30.0      // downloads cap; least recently watched games go first
    public var uploadKBps = 256.0  // 0 = unlimited
    public init() {}
  }

  public var leagues: [String: Bool] = [:]   // league id -> on; missing = on
  public var sources: [String: Account] = [:]
  public var storage = Storage()

  public init() {}

  public func isOn(league id: String) -> Bool { leagues[id] ?? true }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    leagues = (try? c.decodeIfPresent([String: Bool].self, forKey: .leagues)) ?? [:]
    sources = (try? c.decodeIfPresent([String: Account].self, forKey: .sources)) ?? [:]
    storage = (try? c.decodeIfPresent(Storage.self, forKey: .storage)) ?? Storage()
    storage.cacheGB = min(10_000, max(1, storage.cacheGB))
    storage.uploadKBps = min(1_000_000, max(0, storage.uploadKBps))
  }

  public static func load(_ paths: Paths) -> Settings {
    guard let data = try? Data(contentsOf: paths.config) else { return Settings() }
    return (try? JSONDecoder().decode(Settings.self, from: data)) ?? Settings()
  }

  public func save(_ paths: Paths) throws {
    paths.ensure(paths.home)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(self).write(to: paths.config, options: .atomic)
  }
}

extension Settings.Account {
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    username = (try? c.decodeIfPresent(String.self, forKey: .username)) ?? ""
    password = (try? c.decodeIfPresent(String.self, forKey: .password)) ?? ""
  }
}

extension Settings.Storage {
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    cacheGB = (try? c.decodeIfPresent(Double.self, forKey: .cacheGB)) ?? 30
    uploadKBps = (try? c.decodeIfPresent(Double.self, forKey: .uploadKBps)) ?? 256
  }
}
