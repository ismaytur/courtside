// swift-tools-version: 6.0
// Courtside: native Mac app. CourtsideCore holds everything that isn't UI (database, leagues,
// sources, torrents, media) so it can be tested with `swift test`; Courtside is the SwiftUI app.
//
// Native parts are built by `mise run vendor` into vendor/build (gitignored): libtorrent (linked
// statically into TorrentBridge) and ffmpeg/ffprobe (separate binaries the app runs).
import Foundation
import PackageDescription

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let vendor = "\(root)/vendor/build"

let package = Package(
  name: "Courtside",
  platforms: [.macOS(.v14)],
  targets: [
    // C API over libtorrent (C++). Its defines must match how libtorrent was built
    // (vendor/build/libtorrent/defines.txt): they change struct layouts.
    .target(
      name: "TorrentBridge",
      cxxSettings: [
        .define("BOOST_ASIO_ENABLE_CANCELIO"),
        .define("BOOST_ASIO_NO_DEPRECATED"),
        .define("TORRENT_NO_DEPRECATE"),
        .define("TORRENT_USE_I2P", to: "0"),
        .unsafeFlags(["-I\(vendor)/libtorrent/include", "-I\(vendor)/boost/include", "-Wno-deprecated-declarations"]),
      ],
      linkerSettings: [
        .unsafeFlags(["-L\(vendor)/libtorrent/lib"]),
        .linkedLibrary("torrent-rasterbar"),
        .linkedFramework("CoreFoundation"),
        .linkedFramework("SystemConfiguration"),
      ]
    ),
    .target(name: "CourtsideCore", dependencies: ["TorrentBridge"]),
    .executableTarget(name: "Courtside", dependencies: ["CourtsideCore"]),
    // Step-0 prototype: a torrent streamed through ffmpeg into AVPlayer (see its main.swift).
    .executableTarget(name: "Prototype", dependencies: ["CourtsideCore"]),
    .testTarget(name: "CourtsideCoreTests", dependencies: ["CourtsideCore"], resources: [.copy("Fixtures")]),
  ],
  swiftLanguageModes: [.v5],
  cxxLanguageStandard: .cxx17
)
