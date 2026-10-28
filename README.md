# Courtside

A native macOS app for watching NBA games. The library is the official NBA schedule; each game is
found on [720pier.ru](https://720pier.ru) and streamed from its torrent into Apple's own video
player, with AirPlay to an Apple TV. One self-contained app — no server, no Node, nothing installed
on your Mac.

## Build and run

Needs [Xcode](https://developer.apple.com/xcode/) and [mise](https://mise.jdx.dev).

```bash
mise run build      # builds dist/Courtside.app (libtorrent + ffmpeg from source, bundled in)
mise run install    # copies it to /Applications
```

The first build compiles libtorrent and a trimmed ffmpeg into `vendor/` and takes a while; later
builds reuse them. To update the app later, run those two commands again.

Developer docs: [how it works](docs/architecture.md), [development](docs/development.md),
[adding a league](docs/adding-a-league.md), [adding a source](docs/adding-a-source.md).

## Using it

1. Open Settings and enter your 720pier username and password.
2. Browse the schedule as a timeline of game days; it opens at the next games and scrolls both ways.
   Filter by season, stage or team in the sidebar.
3. **Check 720pier** marks which played games are posted. Press **Play** on one to stream it; use the
   AirPlay button to send it to an Apple TV.

## Your data: `~/.courtside`

Everything local lives outside the repo; nothing there is committed.

| Path | What |
| --- | --- |
| `games.db` | the library (SQLite): the schedule, favorites, watch progress |
| `config.json` | your settings, including the 720pier login |
| `leagues/<league>/logos/` | team logos |
| `leagues/<league>/downloads/<game>/` | downloaded games (size-capped cache) |

Set `COURTSIDE_HOME` to use another folder (do this when testing, to leave your real library alone).
Logs are in `~/Library/Logs/Courtside/`.
