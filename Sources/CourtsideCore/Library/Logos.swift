// Team logos: downloaded once into leagues/<league>/logos/<abbr>.png, then served from disk.

import Foundation

public struct Logos: Sendable {
  public let paths: Paths

  public init(paths: Paths) { self.paths = paths }

  /// Where a team's logo lives (whether or not it's been downloaded yet).
  public func file(for team: Team) -> URL {
    paths.logos(team.league).appendingPathComponent("\(team.abbr.lowercased()).png")
  }

  /// The local logo file, downloading it first if needed; nil when the team has no logo or the download fails.
  public func local(for team: Team) async -> URL? {
    let dest = file(for: team)
    if FileManager.default.fileExists(atPath: dest.path) { return dest }
    guard let text = team.logoURL, let url = URL(string: text),
          let data = try? await Web.data(url), !data.isEmpty else { return nil }
    paths.ensure(dest.deletingLastPathComponent())
    do { try data.write(to: dest, options: .atomic) } catch { return nil }
    return dest
  }

  /// Fetch every missing logo (a few at a time).
  public func fetchAll(_ teams: [Team]) async {
    await withTaskGroup(of: Void.self) { group in
      for t in teams.filter({ !FileManager.default.fileExists(atPath: file(for: $0).path) }) {
        group.addTask { _ = await local(for: t) }
      }
    }
  }
}
