// Plays one open game in an AVPlayer: starts a part (at a position), saves where it is every 10 s
// and on close, moves on to the next part at the end, and keeps the system's Now Playing info and
// remote commands (media keys, Control Center, the Apple TV remote while AirPlaying) in step.

import AVFoundation
import Foundation
import MediaPlayer
import Observation

@MainActor @Observable
public final class GamePlayer {
  public enum Phase: Equatable { case preparing(String), playing, failed(String), ended }

  public let game: Game
  public let open: OpenGame
  public let player = AVPlayer()
  public private(set) var part: Int
  public private(set) var phase: Phase = .preparing("Preparing the video…")
  public private(set) var duration: Double = 0

  @ObservationIgnored private let engine: PlaybackEngine
  @ObservationIgnored private let library: Library
  @ObservationIgnored private var tick: Any?
  @ObservationIgnored private var endObserver: NSObjectProtocol?
  @ObservationIgnored private var rateObserver: NSKeyValueObservation?
  @ObservationIgnored private var commands: [(MPRemoteCommand, Any)] = []
  @ObservationIgnored private var startTask: Task<Void, Never>?
  @ObservationIgnored private var closed = false

  public init(game: Game, open: OpenGame, engine: PlaybackEngine, library: Library) {
    self.game = game
    self.open = open
    self.engine = engine
    self.library = library
    part = open.folder.state?.part ?? 0
    player.allowsExternalPlayback = true   // AirPlay sends the stream's URL to the Apple TV
    player.preventsDisplaySleepDuringVideoPlayback = true
    tick = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1), queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.saveAndUpdateNowPlaying() }
    }
    endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) {
      [weak self] note in
      MainActor.assumeIsolated {
        guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
        self.reachedEnd()
      }
    }
    rateObserver = player.observe(\.rate) { [weak self] _, _ in
      Task { @MainActor in self?.updateNowPlaying() }
    }
    setUpRemoteCommands()
  }

  public var position: Double {
    let t = player.currentTime().seconds
    return t.isFinite ? t : 0
  }

  // MARK: playing

  /// Play a part from a position (seconds). Replaces whatever was playing; saves its position first.
  public func start(part: Int, at position: Double) {
    if player.currentItem != nil { save() }
    startTask?.cancel()
    self.part = part
    open.folder.update { $0.part = part }
    phase = .preparing(open.torrent == nil ? "Preparing the video…" : "Getting the first minutes from peers…")
    startTask = Task { [weak self] in
      guard let self else { return }
      do {
        let playable = try await engine.play(open, part: part)
        try Task.checkCancellation()
        duration = playable.duration
        let item = AVPlayerItem(url: playable.url)
        item.preferredForwardBufferDuration = 30
        player.replaceCurrentItem(with: item)
        try await waitUntilReady(item)
        if position > 0 {
          await player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        try Task.checkCancellation()
        player.play()
        phase = .playing
        updateNowPlaying()
      } catch is CancellationError {
      } catch {
        phase = .failed(error.localizedDescription)
      }
    }
  }

  private func waitUntilReady(_ item: AVPlayerItem) async throws {
    while item.status != .readyToPlay {
      if item.status == .failed {
        throw item.error ?? PlaybackError.noVideo
      }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
  }

  private func reachedEnd() {
    if part + 1 < open.parts.count {
      start(part: part + 1, at: 0)
    } else {
      save()
      phase = .ended
    }
  }

  // MARK: saving

  /// Where we are, into the library (the part goes into the game's folder state).
  public func save() {
    guard player.currentItem != nil, duration > 0 else { return }
    library.setWatch(game.id, position: position, duration: duration)
  }

  private func saveAndUpdateNowPlaying() {
    if phase == .playing { save() }
    updateNowPlaying()
  }

  /// Save, stop and let go of the system's Now Playing (the torrent keeps downloading).
  public func close() {
    guard !closed else { return }
    closed = true
    startTask?.cancel()
    save()
    player.pause()
    player.replaceCurrentItem(with: nil)
    if let tick { player.removeTimeObserver(tick) }
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    rateObserver?.invalidate()
    for (command, target) in commands { command.removeTarget(target) }
    commands = []
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    MPNowPlayingInfoCenter.default().playbackState = .stopped
  }

  // MARK: Now Playing

  public var title: String { "\(game.awayName) at \(game.homeName)" }

  private func updateNowPlaying() {
    guard !closed else { return }
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: title,
      MPMediaItemPropertyArtist: game.gameNumber.map { "\(game.stageLabel) · Game \($0)" } ?? game.stageLabel,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
      MPNowPlayingInfoPropertyPlaybackRate: Double(player.rate),
    ]
    if open.parts.count > 1 { info[MPMediaItemPropertyAlbumTitle] = "Part \(part + 1) of \(open.parts.count)" }
    if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    MPNowPlayingInfoCenter.default().playbackState = player.rate > 0 ? .playing : .paused
  }

  private func setUpRemoteCommands() {
    let c = MPRemoteCommandCenter.shared()
    func on(_ command: MPRemoteCommand, _ body: @escaping @MainActor (MPRemoteCommandEvent) -> Bool) {
      command.isEnabled = true
      let target = command.addTarget { event in
        MainActor.assumeIsolated { body(event) ? .success : .commandFailed }
      }
      commands.append((command, target))
    }
    on(c.playCommand) { [weak self] _ in self?.player.play(); return true }
    on(c.pauseCommand) { [weak self] _ in self?.player.pause(); return true }
    on(c.togglePlayPauseCommand) { [weak self] _ in
      guard let p = self?.player else { return false }
      if p.rate > 0 { p.pause() } else { p.play() }
      return true
    }
    c.skipForwardCommand.preferredIntervals = [15]
    c.skipBackwardCommand.preferredIntervals = [15]
    on(c.skipForwardCommand) { [weak self] _ in self?.jump(by: 15); return true }
    on(c.skipBackwardCommand) { [weak self] _ in self?.jump(by: -15); return true }
    on(c.changePlaybackPositionCommand) { [weak self] event in
      guard let self, let e = event as? MPChangePlaybackPositionCommandEvent else { return false }
      player.seek(to: CMTime(seconds: e.positionTime, preferredTimescale: 600))
      return true
    }
  }

  public func jump(by seconds: Double) {
    let target = max(0, min(duration > 0 ? duration - 1 : .infinity, position + seconds))
    player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
  }
}
