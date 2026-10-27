import SwiftUI
import CourtsideCore

extension Color {
  /// "1D428A" (no #) -> Color; nil when it isn't six hex digits.
  init?(hex: String?) {
    guard let hex, hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
    self.init(red: Double(v >> 16 & 255) / 255, green: Double(v >> 8 & 255) / 255, blue: Double(v & 255) / 255)
  }
}

/// A generated poster: both logos over a diagonal blend of the two teams' colors.
struct Poster: View {
  var model: AppModel
  let game: Game

  var body: some View {
    let away = model.team(game.league, game.away), home = model.team(game.league, game.home)
    ZStack {
      LinearGradient(colors: [Color(hex: away?.color) ?? .gray, Color(hex: home?.color) ?? .gray],
                     startPoint: .topLeading, endPoint: .bottomTrailing)
      Color.black.opacity(0.18)
      HStack {
        logo(game.away)
        Spacer()
        Text("AT").font(.caption.bold()).foregroundStyle(.white.opacity(0.8))
        Spacer()
        logo(game.home)
      }
      .padding(.horizontal, 18)
    }
    .aspectRatio(16.0 / 9.0, contentMode: .fit)
  }

  @ViewBuilder private func logo(_ abbr: String) -> some View {
    if let img = model.logo(game.league, abbr) {
      Image(nsImage: img).resizable().scaledToFit().frame(width: 76, height: 76)
        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
    } else {
      Text(abbr).font(.title2.bold()).foregroundStyle(.white).frame(width: 76, height: 76)
    }
  }
}

struct GameCard: View {
  var model: AppModel
  let game: Game

  var body: some View {
    let status = model.status(game)
    VStack(alignment: .leading, spacing: 0) {
      Poster(model: model, game: game)
        .overlay(alignment: .topTrailing) {
          if game.favorite { Image(systemName: "heart.fill").foregroundStyle(.white).padding(8) }
        }
        .overlay(alignment: .bottom) {
          if let p = watched { WatchedBar(fraction: p) }
        }
      VStack(alignment: .leading, spacing: 4) {
        Text("\(shortName(game.away, game.awayName)) at \(shortName(game.home, game.homeName))")
          .font(.headline).lineLimit(1)
        Text(AppModel.shortDay(game.date)).font(.subheadline).foregroundStyle(.secondary)
        Text(stageText).font(.caption).foregroundStyle(.secondary)
        HStack {
          Badge(status: status, progress: model.downloadProgress[game.id])
          Spacer()
          Button("Play") { model.play(game) }
            .controlSize(.small)
            .disabled(status == .upcoming)
        }
        .padding(.top, 4)
      }
      .padding(10)
    }
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .contextMenu {
      Button(game.favorite ? "Remove from Favorites" : "Favorite") { model.toggleFavorite(game) }
      Button("Clear download") { model.clearDownload(game) }.disabled(!model.hasFiles.contains(game.id))
    }
  }

  private func shortName(_ abbr: String, _ full: String) -> String {
    model.team(game.league, abbr)?.shortName ?? full
  }

  /// How far it's been watched (0…1), when it has been started.
  private var watched: Double? {
    guard let p = game.watchPosition, let d = game.duration, d > 0, p >= WatchRules.minResume else { return nil }
    return min(1, p / d)
  }

  private var stageText: String {
    game.gameNumber.map { "\(game.stageLabel) · Game \($0)" } ?? game.stageLabel
  }
}

/// A thin red line along the poster's bottom edge, like a video app's "continue watching".
struct WatchedBar: View {
  let fraction: Double
  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Rectangle().fill(.black.opacity(0.35))
        Rectangle().fill(.red).frame(width: geo.size.width * fraction)
      }
    }
    .frame(height: 4)
  }
}

struct Badge: View {
  let status: Status
  var progress: Double?

  var body: some View {
    Text(progress.map { "\(status.rawValue) \(Int($0 * 100))%" } ?? status.rawValue)
      .font(.caption.weight(.semibold))
      .padding(.horizontal, 8).padding(.vertical, 3)
      .background(color.opacity(0.18), in: Capsule())
      .foregroundStyle(color)
  }

  private var color: Color {
    switch status {
    case .upcoming: .secondary
    case .notPosted: .orange
    case .available: .blue
    case .downloading: .teal
    case .downloaded: .green
    }
  }
}
