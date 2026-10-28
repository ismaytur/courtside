# How Courtside works

Courtside is a native macOS app. It shows the official NBA schedule as a browsable library, finds
each game on 720pier.ru, and streams it from the torrent through a bundled ffmpeg into Apple's own
video player (with AirPlay to an Apple TV). There is no server and no web UI; everything runs in one
Swift process.

## Pieces

- **`CourtsideCore`** — all the non-UI logic, so `swift test` can exercise it:
  - `DB/` — a small SQLite wrapper (`Database`) and `Library` (the `games` and `teams` tables).
  - `Leagues/` — the `League` protocol and the NBA plug-in (schedule, teams, stages). *What games exist.*
  - `Sources/` — the `Source` protocol and `Pier720` (sign-in, listing/topic parsing, torrent link). *Where the video is.*
  - `Web/` — `Fetch.swift` (the single `fetch(_:)` every request goes through) and `Web.swift` (retries, decoding).
  - `Torrent/` — Swift over `TorrentBridge` (libtorrent): add, pick files, piece deadlines, progress.
  - `Media/` — keyframe index, an on-demand HLS playlist/segments, and a local HTTP server that feeds Apple's player.
  - `Playback/` — ties a game to its torrent, stream and watch state.
  - `Library/` — `ScheduleRefresh` and `Logos`.
  - `Log.swift`, `Paths.swift`, `Settings.swift`.
- **`Courtside`** — the SwiftUI app: the timeline of game days, sidebar filters, settings, the player overlay.
- **`TorrentBridge`** — a thin C API over libtorrent (C++), linked statically.

## Data

Everything local lives in `~/.courtside` (`COURTSIDE_HOME` to override):

```
games.db                         the library (all leagues)
config.json                      settings (incl. the 720pier login)
leagues/<league>/logos/          team logos, fetched once
leagues/<league>/downloads/<id>/ a game's torrent content (a file or folder) + hls/
logs/ or ~/Library/Logs/Courtside/  rotating logs
```

A game's id is readable and stable: `nba-2026-27-regular-2026-10-26-atl-hou`
(league-season-stage-date-away-home; the date is the league's local day). Schedule refreshes match
rows by the provider's event id, so a game that moves keeps its watch position and its 720pier link.
**Scores are never stored.**

## The schedule (library)

`ScheduleRefresh` asks each enabled league for its teams and this season's games and upserts them.
The NBA plug-in reads ESPN's public site API: each team's schedule, deduplicated by event id, is the
whole league's (30 requests per season type; nba.com refuses scripted requests, so it isn't used).
It runs on launch, weekly, on demand, and when the season rolls over (July).

## Finding and playing a game

1. The library shows every scheduled game. A game with no 720pier topic yet is "Not posted yet".
2. **Check 720pier** (or Play on a game with no topic) signs in, reads the newest forum pages, and
   matches each topic to a scheduled game by date + both teams; the match records the topic URL.
3. **Play**: Courtside downloads the `.torrent`, adds it to the shared libtorrent session (into the
   game's folder), picks the video file, and serves it as HLS. `Media` builds the playlist from the
   file's keyframe index and remuxes each ~6 s segment on demand (`-c copy`, no re-encode — 720pier
   files are already H.264 + AAC), asking libtorrent for that byte range first. Apple's `AVPlayer`
   plays it from a local HTTP server; far seeks fetch their pieces on demand.
4. **AirPlay**: the player offers the route picker. Because the Apple TV fetches the stream itself,
   the server binds to the Mac's LAN address when "Allow AirPlay" is on (the default).

Watch position is saved every 10 s and on close; a complete download marks the game Downloaded. The
download cache is capped (`storage.cacheGB`), dropping the least-recently-watched games first, never
the one playing.

## The app bundle

`mise run build` makes a self-contained `dist/Courtside.app`: the Swift binary, plus `ffmpeg` and
`ffprobe` in `Contents/Resources` (built from source, system libraries only — check with
`otool -L`). libtorrent is linked in statically. The bundle is ad-hoc signed. Nothing is installed
on the Mac and nothing auto-updates; `mise run install` copies it to /Applications.
