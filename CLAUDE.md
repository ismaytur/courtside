# Courtside: notes for working on this repo

Native macOS app (Swift, SwiftUI). The library is the official NBA schedule (from ESPN), kept in
SQLite; games are found on 720pier.ru and streamed from their torrents through a bundled ffmpeg into
Apple's own player, with AirPlay. Built with SwiftPM; libtorrent and ffmpeg are built from source
into `vendor/` by mise. Read these before larger changes:

- [docs/architecture.md](docs/architecture.md): components, data model, the play flow, the app bundle
- [docs/development.md](docs/development.md): build, test, run, gotchas
- [docs/adding-a-league.md](docs/adding-a-league.md): add a league (NBA now)
- [docs/adding-a-source.md](docs/adding-a-source.md): add a site to find games on (720pier now)

## Layout

- `Sources/CourtsideCore/` — everything that isn't UI, so `swift test` can cover it: `DB/`,
  `Leagues/`, `Sources/`, `Web/`, `Torrent/`, `Media/`, `Playback/`, `Library/`, `Log.swift`,
  `Paths.swift`, `Settings.swift`.
- `Sources/Courtside/` — the SwiftUI app (library grid, timeline, settings, player overlay).
- `Sources/TorrentBridge/` — a C API over libtorrent (C++); `Torrent/` wraps it in Swift.
- `Sources/Prototype`, `Sources/PlayCheck` — throwaway/one-off executables for the engine.
- `vendor/` — libtorrent + boost + ffmpeg sources and builds (gitignored; `mise run vendor`).

## Ground rules

- **User data never goes in git.** The library, settings, logos and downloads live in `~/.courtside`
  (`Paths.swift`). Override with `COURTSIDE_HOME` and **never touch the real `~/.courtside` when
  testing** — always `COURTSIDE_HOME=<scratch>`. Don't delete or rewrite the user's data without asking.
- **Every web request goes through `fetch(_:)` in `Web/Fetch.swift`** (ESPN, 720pier, logos,
  .torrent files). That file is the user's; don't change its insides. Build on `Web.*` (text, data,
  json, postForm, retries). The only traffic not through it is libtorrent's own peer/tracker
  connections.
- **No scores, anywhere** — they're spoilers. Don't fetch, store or show them.
- **Schema**: additive only. No migrations; a breaking change starts a fresh library (`Library`
  sets an old `games.db` aside as `games.unsupported.db`). The user is fine re-fetching.
- **Leagues** (`Leagues/`) and **sources** (`Sources/`) are plug-ins; the database, play flow and
  media pipeline are shared. A league says *what games exist*; a source says *where the video is*.
- **720pier blocks programs.** Getting past its bot protection is the user's own work, in
  `Fetch.swift`; don't build or debug a bypass.
- Match the style: small types, comments that explain *why*, tests for anything pure.
- Updating the installed app is manual (`mise run build` then `mise run install`); there is no
  auto-update and nothing deploys on push.

## Commands

```bash
mise run build            # dist/Courtside.app (ffmpeg bundled); APP_OUT=… to build elsewhere
mise run install          # copy dist/Courtside.app to /Applications
mise run test             # swift test
mise run vendor           # (re)build libtorrent + ffmpeg into vendor/ (pinned, checksummed)
COURTSIDE_HOME=/tmp/ct swift run Courtside   # run against a scratch library
```
