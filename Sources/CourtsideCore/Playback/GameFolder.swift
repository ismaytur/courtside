// A game's download folder, leagues/<league>/downloads/<game-id>/:
//   <torrent content>     a file or a folder, as the torrent has it
//   game.torrent          the .torrent, so playing again doesn't need 720pier
//   courtside.json        which files are the parts, the part last played, whether it's complete
//   hls/part-N/           segments made for the player (index.json, seg-N.ts)

import Foundation

public struct GameFolder: Sendable {
  public let url: URL

  public init(paths: Paths, league: String, game: String) {
    url = paths.download(league: league, game: game)
  }

  public init(url: URL) { self.url = url }

  public struct State: Codable, Equatable, Sendable {
    public var parts: [String] = []     // paths relative to the folder, in playing order
    public var part = 0                 // the part the saved position belongs to
    public var complete = false         // every part downloaded
    public init() {}
  }

  public var torrentFile: URL { url.appendingPathComponent("game.torrent") }
  var stateFile: URL { url.appendingPathComponent("courtside.json") }
  public func hls(part: Int) -> URL { url.appendingPathComponent("hls/part-\(part)") }
  public func file(_ relative: String) -> URL { url.appendingPathComponent(relative) }

  public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

  public var state: State? {
    guard let d = try? Data(contentsOf: stateFile) else { return nil }
    return try? JSONDecoder().decode(State.self, from: d)
  }

  public func save(_ state: State) {
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try? JSONEncoder().encode(state).write(to: stateFile, options: .atomic)
  }

  public func update(_ change: (inout State) -> Void) {
    var s = state ?? State()
    change(&s)
    save(s)
  }

  public var isComplete: Bool { state?.complete == true }

  /// Bytes on disk (allocated, so a half-downloaded sparse file counts what it really uses).
  public var bytes: Int64 {
    guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
    else { return 0 }
    var total: Int64 = 0
    for case let f as URL in e {
      let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
      if v?.isRegularFile == true { total += Int64(v?.totalFileAllocatedSize ?? 0) }
    }
    return total
  }

  public var created: Date {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.creationDate] as? Date) ?? .distantPast
  }

  public func delete() { try? FileManager.default.removeItem(at: url) }

  // MARK: which files are the game

  static let videoExtensions: Set<String> = ["mkv", "mp4", "m4v", "mov", "ts"]

  /// The video files of a torrent in playing order: real videos (not samples or files much smaller
  /// than the biggest), sorted by name the way Finder does ("Part 2" before "Part 10").
  public static func parts(of files: [TorrentFile]) -> [TorrentFile] {
    let videos = files.filter { videoExtensions.contains(($0.path as NSString).pathExtension.lowercased()) }
    guard let biggest = videos.map(\.size).max() else { return files.max { $0.size < $1.size }.map { [$0] } ?? [] }
    return videos
      .filter { $0.size >= biggest / 5 && !$0.path.lowercased().contains("sample") }
      .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
  }

  /// "Part 2 · <file name>" for the part picker.
  public static func label(_ path: String, index: Int) -> String {
    "Part \(index + 1) · " + ((path as NSString).lastPathComponent as NSString).deletingPathExtension
  }
}
