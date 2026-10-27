// Where to start a game and when it counts as watched. Pure, so the rules are tested on their own.
// A game may come in parts (halves, quarters); the saved position belongs to the saved part.

import Foundation

public enum WatchRules {
  /// Positions this early aren't worth resuming (someone opened it and closed it again).
  public static let minResume: Double = 30

  /// The last few minutes of a broadcast are the post-game show: reaching them is "watched".
  public static func nearEnd(duration: Double) -> Double { max(60, duration * 0.03) }

  /// Whether this position of a part is close enough to its end.
  public static func isAtEnd(position: Double, duration: Double) -> Bool {
    duration > 0 && position >= duration - nearEnd(duration: duration)
  }

  /// The whole game is watched once the last part reaches its end.
  public static func isWatched(position: Double?, duration: Double?, part: Int, parts: Int) -> Bool {
    guard let position, let duration else { return false }
    return part >= parts - 1 && isAtEnd(position: position, duration: duration)
  }

  public struct Start: Equatable, Sendable {
    public let part: Int
    public let position: Double
    public init(part: Int, position: Double) { self.part = part; self.position = position }
    public static let beginning = Start(part: 0, position: 0)
  }

  /// Where "Resume" picks up: nil when there's nothing to resume (never played, barely started,
  /// or watched to the end, which starts over). The end of an earlier part resumes at the next one.
  public static func resume(position: Double?, duration: Double?, part: Int, parts: Int) -> Start? {
    guard let position, position >= minResume, parts > 0 else { return nil }
    let part = min(max(0, part), parts - 1)
    if let duration, isAtEnd(position: position, duration: duration) {
      return part + 1 < parts ? Start(part: part + 1, position: 0) : nil
    }
    return Start(part: part, position: position)
  }
}

/// The downloads cap: which games' folders to delete to get under it.
public enum DownloadCap {
  public struct Entry: Equatable, Sendable {
    public let id: String
    public let bytes: Int64
    public let lastUsed: Date   // last watched, or when the download started
    public init(id: String, bytes: Int64, lastUsed: Date) { self.id = id; self.bytes = bytes; self.lastUsed = lastUsed }
  }

  /// Least recently watched first, until the rest fits in `capBytes`. `keep` (the game playing
  /// now) is never removed, even if it alone is over the cap.
  public static func evictions(_ entries: [Entry], capBytes: Int64, keep: Set<String>) -> [String] {
    var total = entries.reduce(0) { $0 + $1.bytes }
    var out: [String] = []
    for e in entries.sorted(by: { ($0.lastUsed, $0.id) < ($1.lastUsed, $1.id) }) where total > capBytes {
      if keep.contains(e.id) { continue }
      out.append(e.id)
      total -= e.bytes
    }
    return out
  }
}
