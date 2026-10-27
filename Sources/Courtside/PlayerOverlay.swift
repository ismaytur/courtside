// The player, over the whole window: getting the torrent, then (if there's a choice) resume /
// start over / which part, then Apple's player view with AirPlay and fullscreen. Esc closes it.

import AVKit
import SwiftUI
import CourtsideCore

struct PlayerOverlay: View {
  var model: AppModel
  let playing: Playing

  var body: some View {
    ZStack {
      Color.black
      switch playing.stage {
      case .loading(let text):
        Waiting(text: text, progress: model.downloadProgress[playing.game.id])
      case .choose(let open, let resume):
        Chooser(model: model, open: open, resume: resume)
      case .playing(let player):
        PlayerScreen(model: model, player: player)
      case .failed(let text):
        Problem(text: text) { model.closePlayer() }
      }
      if !isPlaying {
        TopBar(model: model, title: title, player: nil)
      }
    }
    .foregroundStyle(.white)
    .background { Button("") { model.closePlayer() }.keyboardShortcut(.cancelAction).hidden() }
  }

  private var isPlaying: Bool { if case .playing = playing.stage { return true } else { return false } }

  private var title: String { "\(playing.game.awayName) at \(playing.game.homeName)" }
}

/// Close button, title, part menu and AirPlay picker along the top.
struct TopBar: View {
  var model: AppModel
  let title: String
  let player: GamePlayer?

  var body: some View {
    VStack {
      HStack(spacing: 14) {
        Button { model.closePlayer() } label: {
          Image(systemName: "xmark").font(.title3.weight(.semibold)).frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .help("Close (Esc)")
        Text(title).font(.headline).lineLimit(1)
        Spacer()
        if let player, player.open.parts.count > 1 {
          Menu("Part \(player.part + 1) of \(player.open.parts.count)") {
            ForEach(Array(player.open.labels.enumerated()), id: \.offset) { i, label in
              Button(label) { player.start(part: i, at: 0) }.disabled(i == player.part)
            }
          }
          .fixedSize()
        }
        if let player {
          RoutePicker(player: player.player).frame(width: 30, height: 30).help("AirPlay")
        }
      }
      .padding(.horizontal, 16).padding(.vertical, 10)
      .background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom))
      Spacer()
    }
  }
}

struct PlayerScreen: View {
  var model: AppModel
  let player: GamePlayer

  var body: some View {
    ZStack {
      VideoView(player: player.player)
      switch player.phase {
      case .preparing(let text):
        Waiting(text: text, progress: model.downloadProgress[player.game.id])
      case .failed(let text):
        Problem(text: "The video couldn't play: \(text)") { model.closePlayer() }
      case .ended:
        VStack(spacing: 14) {
          Text("That's the game.").font(.title2.bold())
          Button("Close") { model.closePlayer() }.controlSize(.large)
        }
        .padding(30).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
      case .playing:
        EmptyView()
      }
      TopBar(model: model, title: player.title, player: player)
    }
  }
}

struct Waiting: View {
  let text: String
  let progress: Double?
  var body: some View {
    VStack(spacing: 14) {
      ProgressView().controlSize(.large).tint(.white)
      Text(text).font(.title3)
      if let progress, progress > 0 {
        Text("Downloaded \(Int(progress * 100))%").font(.callout).foregroundStyle(.white.opacity(0.7))
      }
    }
  }
}

struct Problem: View {
  let text: String
  let close: () -> Void
  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "exclamationmark.triangle").font(.largeTitle)
      Text(text).font(.title3).multilineTextAlignment(.center).frame(maxWidth: 520)
      Button("Close", action: close).controlSize(.large)
    }
  }
}

/// Resume or start over, and which part when the game comes in several.
struct Chooser: View {
  var model: AppModel
  let open: OpenGame
  let resume: WatchRules.Start?

  var body: some View {
    VStack(spacing: 14) {
      if let resume {
        Button { model.startPlayer(open, at: resume) } label: {
          Text("Resume" + (open.parts.count > 1 ? " part \(resume.part + 1)" : "") + " at \(Self.clock(resume.position))")
            .frame(minWidth: 260)
        }
        .keyboardShortcut(.defaultAction)
        Button { model.startPlayer(open, at: .beginning) } label: { Text("Start over").frame(minWidth: 260) }
      }
      if open.parts.count > 1 {
        Text(resume == nil ? "This game comes in \(open.parts.count) parts" : "Or pick a part")
          .font(.headline).padding(.top, resume == nil ? 0 : 12)
        ForEach(Array(open.labels.enumerated()), id: \.offset) { i, label in
          Button { model.startPlayer(open, at: WatchRules.Start(part: i, position: 0)) } label: {
            Text(label).lineLimit(1).frame(minWidth: 260)
          }
        }
      }
    }
    .controlSize(.large)
  }

  static func clock(_ s: Double) -> String {
    let t = Int(s)
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
  }
}

/// Apple's player view: play/pause, the scrubber (jump anywhere), volume, fullscreen.
struct VideoView: NSViewRepresentable {
  let player: AVPlayer

  func makeNSView(context: Context) -> AVPlayerView {
    let v = AVPlayerView()
    v.player = player
    v.controlsStyle = .floating
    v.showsFullScreenToggleButton = true
    v.allowsPictureInPicturePlayback = true
    return v
  }

  func updateNSView(_ v: AVPlayerView, context: Context) {
    if v.player !== player { v.player = player }
  }
}

/// The AirPlay button: lists Apple TVs and speakers on the network.
struct RoutePicker: NSViewRepresentable {
  let player: AVPlayer

  func makeNSView(context: Context) -> AVRoutePickerView {
    let v = AVRoutePickerView()
    v.player = player
    v.isRoutePickerButtonBordered = false   // bordered draws a white box over dark video
    v.setRoutePickerButtonColor(.white, for: .normal)
    return v
  }

  func updateNSView(_ v: AVRoutePickerView, context: Context) {}
}
