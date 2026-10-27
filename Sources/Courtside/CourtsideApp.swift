// The Courtside window. `swift run Courtside` launches without an app bundle, so the process
// asks for regular activation (Dock icon, menu bar, a window that can take focus).

import SwiftUI
import AppKit
import CourtsideCore

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationWillFinishLaunching(_ notification: Notification) {
    NSApplication.shared.setActivationPolicy(.regular)
  }
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.activate(ignoringOtherApps: true)
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct CourtsideApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @State private var model = AppModel()

  var body: some Scene {
    WindowGroup("Courtside") {
      ContentView(model: model)
        .frame(minWidth: 900, minHeight: 600)
        .task { await model.start() }
    }
    .defaultSize(width: 1280, height: 820)

    // CourtsideCore also has a `Settings`; the scene is SwiftUI's.
    SwiftUI.Settings {
      SettingsView(model: model)
    }
  }
}
