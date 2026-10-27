// swift-tools-version: 6.0
// Courtside: native Mac app. CourtsideCore holds everything that isn't UI (database, leagues,
// sources, torrents, media) so it can be tested with `swift test`; Courtside is the SwiftUI app.
import PackageDescription

let package = Package(
  name: "Courtside",
  platforms: [.macOS(.v14)],
  targets: [
    .target(name: "CourtsideCore"),
    .executableTarget(name: "Courtside", dependencies: ["CourtsideCore"]),
    .testTarget(name: "CourtsideCoreTests", dependencies: ["CourtsideCore"], resources: [.copy("Fixtures")]),
  ],
  swiftLanguageModes: [.v5]
)
