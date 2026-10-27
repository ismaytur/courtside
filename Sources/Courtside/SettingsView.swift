import SwiftUI
import CourtsideCore

struct SettingsView: View {
  var model: AppModel
  @State private var confirmClear = false

  var body: some View {
    Form {
      Section("Leagues") {
        ForEach(Leagues.all, id: \.id) { league in
          Toggle(league.name, isOn: Binding(
            get: { model.settings.isOn(league: league.id) },
            set: { on in model.update { $0.leagues[league.id] = on } }))
        }
      }
      Section("720pier account") {
        TextField("Username", text: account(\.username))
        SecureField("Password", text: account(\.password))
      }
      Section {
        Toggle("Allow AirPlay to Apple TV (serve on home network)", isOn: Binding(
          get: { model.settings.playback.airplayLAN },
          set: { on in model.update { $0.playback.airplayLAN = on } }))
      } header: { Text("Playback") } footer: {
        Text("An Apple TV fetches the video from this Mac itself, so the video is offered to your home network while it plays. Turn off to keep it on this Mac only.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("Storage") {
        TextField("Keep up to (GB)", value: Binding(
          get: { model.settings.storage.cacheGB },
          set: { v in model.update { $0.storage.cacheGB = min(10_000, max(1, v)) } }), format: .number)
        TextField("Upload limit (KB/s, 0 = no limit)", value: Binding(
          get: { model.settings.storage.uploadKBps },
          set: { v in model.update { $0.storage.uploadKBps = min(1_000_000, max(0, v)) } }), format: .number)
        Button("Clear all downloads…", role: .destructive) { confirmClear = true }
          .confirmationDialog("Delete every downloaded game?", isPresented: $confirmClear) {
            Button("Delete all downloads", role: .destructive) { model.clearAllDownloads() }
          } message: {
            Text("The games stay in your library and can be downloaded again.")
          }
      }
    }
    .formStyle(.grouped)
    .frame(width: 480, height: 560)
  }

  private func account(_ key: WritableKeyPath<CourtsideCore.Settings.Account, String>) -> Binding<String> {
    Binding(get: { model.settings.sources["720pier"]?[keyPath: key] ?? "" },
            set: { v in model.update { $0.sources["720pier", default: CourtsideCore.Settings.Account()][keyPath: key] = v } })
  }
}
