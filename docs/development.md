# Development

## Setup

Needs Xcode (Swift 6+, with C++ interop) and [mise](https://mise.jdx.dev). mise pins the build
tools (cmake, ninja) and keeps them out of Homebrew and the system.

```bash
mise run vendor    # build libtorrent + ffmpeg/ffprobe into vendor/ (pinned tarballs, checksummed)
mise run build     # dist/Courtside.app
mise run test      # swift test
```

`mise run build` and `mise run test` run `vendor` first if `vendor/build` is missing. The first
vendor build takes a while; later builds reuse it.

## Running

```bash
COURTSIDE_HOME=/tmp/ct swift run Courtside          # a scratch library, not ~/.courtside
COURTSIDE_HOME=/tmp/ct swift run PlayCheck           # headless end-to-end check of the play flow
```

Always point `COURTSIDE_HOME` at a scratch folder. The first launch fills the library from the
schedule (a few seconds) and downloads the team logos.

## Updating the installed app

There is no auto-update. After changes:

```bash
mise run build && mise run install
```

`install` quits a running Courtside and copies the new bundle to /Applications. `APP_OUT=<path>`
overrides where `build` writes.

## Things to know

- **`vendor/` is gitignored and built, not committed.** If a build fails with `boost/config.hpp not
  found`, the headers are missing — `mise run vendor` rebuilds them (they're copied into
  `vendor/build/boost/include`, not symlinked, so cleaning `vendor/src` can't break the build).
- **All HTTP goes through `fetch(_:)` in `Web/Fetch.swift`.** That file is the user's; leave its
  insides alone and build on `Web.*`. Don't call `URLSession` elsewhere.
- **720pier blocks programs (403 to plain requests).** Getting past that is the user's own work in
  `Fetch.swift`; don't build or debug a bypass. Parsing and matching are tested offline against
  `Tests/CourtsideCoreTests/Fixtures/` — never hit 720pier.ru from code or tests.
- **Logs**: `~/Library/Logs/Courtside/courtside.log` (or `$COURTSIDE_HOME/logs/`), rotated at 5 MB ×
  5 files, mirrored to the system log. Passwords, cookies, form tokens and session ids are redacted
  (`Log.redact`). `Help ▸ Show Logs` and `Help ▸ Copy Last Sign-in Log` in the app.
- **ffmpeg** is bundled, LGPL, with only what Courtside needs (matroska/mov/mpegts/hls, h264/hevc/aac,
  VideoToolbox). `MediaTools` finds it in the app bundle, falling back to `vendor/build/ffmpeg/bin`
  for `swift run`.
- **Schema is additive only.** No migrations; an old-layout `games.db` is set aside as
  `games.unsupported.db` and a fresh one is created (`Library.compatible`).
- **Never show or store scores** (spoilers).

## Tests

`swift test` covers the pure logic: NBA schedule parsing, game IDs and stages, the library upsert,
720pier title/listing parsing and the find-missing-games stop rule, log rotation and redaction, the
HLS playlist/segment planning. UI and the live 720pier sign-in are checked by hand.
