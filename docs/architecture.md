# How Courtside works

Courtside is a Node server (no framework, no build step) plus a vanilla-JS single page. The server
collects basketball game listings from source sites, keeps them in SQLite, and streams torrents
to the browser. A small Swift app wraps it as a self-updating Mac app.

```
 sources (lib/sources/*)          ~/.courtside/                      browser (public/*)
 ┌──────────────────────┐         ┌───────────────────────┐          ┌───────────────────────┐
 │ sport-video.org.ua   │ listPage│ games.db   (SQLite)   │  /api/*  │ app.js     library    │
 │ …future sources      ├────────►│ config.json (settings)├─────────►│ settings.js  popup    │
 └──────────────────────┘ resolve │ img/  streams/        │          │ player.js  MSE player │
            ▲                     │ torrents/             │          └──────────▲────────────┘
            │                     └──────────▲────────────┘                     │ fMP4 stream
   lib/sync.mjs ── classify ── addRelease ───┘                                  │
                                                                                │
   lib/streamer.mjs: webtorrent ──► /raw (file bytes, Range) ──► ffmpeg ──► /play
```

## Files

| Path | Role |
| --- | --- |
| `server.mjs` | HTTP server and every API route; `startServer()` (also run directly by `npm start`); schedules startup/periodic fetches |
| `lib/paths.mjs` | All local paths (`~/.courtside`, overridable with `COURTSIDE_HOME`) |
| `lib/settings.mjs` | Settings = `config.defaults.json` overlaid with `~/.courtside/config.json` |
| `lib/db.mjs` | SQLite schema, `openDb()`, `addRelease()` (the match-or-create logic) |
| `lib/classify.mjs` | Title → date, league, season, stage, home/away team; `matchKey()` |
| `lib/sync.mjs` | The fetch engine (batches, stop rule, NEW flags, per-source runs) |
| `lib/sources/` | One module per source + `index.mjs` registry + `http.mjs` helper |
| `lib/streamer.mjs` | Torrent sessions, file selection, `/raw` + `/play` output, video cache |
| `lib/images.mjs` | Poster cache naming/allow-list |
| `lib/prune.mjs` | Delete all games of given leagues (+ posters, cached videos) |
| `lib/gitsync.mjs` | Mac app self-update (match GitHub `main`) |
| `scripts/app.mjs` | Mac app entry point: update → `npm ci` if needed → `startServer()` |
| `scripts/build-mac-app.sh` | Builds `dist/Courtside.app` |
| `scripts/prune.mjs` | CLI for `lib/prune.mjs` |
| `mac/Courtside.swift` | The native window (WKWebView) and Node process supervisor |
| `public/` | `index.html`, `style.css`, `app.js` (library), `settings.js` (popup), `player.js`, `util.js` |
| `config.defaults.json` | Default settings, versioned |

## Local data

Nothing personal is in git. Everything lives in `~/.courtside` (`lib/paths.mjs`):

- `games.db`: SQLite, rollback-journal mode (no `-wal`/`-shm` files)
- `config.json`: written by the settings popup; only keys you saved
- `img/<host>-<file>`: poster cache (`lib/images.mjs`)
- `streams/<releaseId>/…`: torrent data per release (size-capped LRU cache)
- `torrents/<releaseId>.torrent`

A missing or empty folder means a fresh library; the startup fetch imports everything. If
`games.db` doesn't have the current layout, `openDb()` renames it to `games.unsupported.db` and
starts fresh. There is no conversion code: if the schema ever needs a breaking change, a fresh
library plus a re-fetch is the policy. Additive changes (new column/table) go in `SCHEMA` as
`CREATE … IF NOT EXISTS` / an `ALTER TABLE … ADD COLUMN` guarded by `PRAGMA table_info`.

## Database (`lib/db.mjs`)

```
games      id, match_key, title, game_date, league, season, phase, home_team, away_team, is_event,
           image_url, favorite, downloaded, is_new, watch_position, watch_release, watch_file,
           duration, added_at
releases   id, game_id → games, source, source_key, raw_title, detail_url, torrent_url, mega_url,
           other_url, image_url, video_info, resolution, language, detail_error, list_page, added_at
           UNIQUE (source, source_key)
meta       key/value: last_sync, archive_complete:<sourceId>
sync_runs  history shown under "Recent fetches"
```

- A **game** is a real game; your state (favorite, watch progress, NEW) lives here.
- A **release** is one listing on one source with its links. Streaming, the video cache and
  `.torrent` files are keyed by **release id**.
- `match_key` (`classify.matchKey`) identifies a game across listings/sources:
  `date|teamA|teamB` with the two normalized team names sorted (so "A at B" = "B vs A"), or
  `date|normalized title` for events without teams. Same date + teams on two sources → one game.
- `addRelease(db, game, release, { markNew })` returns `'duplicate'` (same source+key, or the
  game already has that exact torrent URL), `'release'` (attached to an existing game) or
  `'game'` (new game created; `is_new = markNew`).

## Fetching (`lib/sync.mjs`)

For each enabled source (`settings.sources[id] !== false`), in `SOURCES` order:

1. Read listing pages (`source.listPage(n)`, n = 0,1,2,… until it returns null) into a buffer,
   dropping entries already seen in this run (sites repeat entries across pages).
2. Take `batchSize` entries. Classify each title in listing order (a broken year borrows the
   previous entry's date).
3. Split: **known** (same `source`+`source_key` saved), **ignored** (league in
   `leagues.ignore`), **fresh**. Known entries whose detail page failed before are re-resolved.
4. `source.resolve(entry)` for fresh entries (4 at a time, 120 ms apart), then `addRelease`.
5. Stop rule: if the batch had any known entry and the source's archive was fully walked once
   (`meta archive_complete:<id>`), this source is caught up. Otherwise next batch. Reaching the
   end of the archive sets `archive_complete:<id>`.

`mode: 'full'` never stops early (Full rescan). New games are marked NEW only when the source's
archive was already complete (so a first import doesn't flag 1,000 games). Triggers:
`startup` (1.5 s after `startServer`, if `fetch.onStartup`), `schedule` (checked every minute
against `fetch.everyHours` and `meta last_sync`), `manual` (↻ / Fetch now / Full rescan).
Status (`GET /api/sync`) includes a log the UI shows live.

## Classification (`lib/classify.mjs`)

Input is a title like `Las Vegas Aces at Golden State Valkyries 04.10.2026`:

- Date: `dd.mm.yy(yy)` at the end.
- Teams: split on ` at `/`@` (away at home) or ` vs `/` v `/` - ` (home first). Leading ranks
  (`16 Siena Saints`) are stripped.
- Each side is resolved against team dictionaries (NBA, WNBA, EuroLeague, national teams) by
  exact alias, alias + one trailing word ("Warriors Blue"), or Levenshtein ≤ 2 ("Connecticuy
  Sun"); Cyrillic look-alike letters are normalized. Unknown pairs are NCAA (with a short-name
  expander, e.g. "Kansas" → "Kansas Jayhawks").
- League = shared league of both teams, else the pro team's league, else International, else
  NCAA. Event titles (All-Star, Draft…) are NBA/WNBA with stage "All-Star & Events".
- Season (`2025-26` vs `2026`) and stage (Preseason/Playoffs/Finals/…) are date heuristics per
  league in `phaseFor()`.

To fix a misclassified team, add an alias in the dictionaries at the top, then **Reclassify all**
(settings) which re-runs `classify` on each game's first release and recomputes `match_key`.
Adding a league means: dictionary + league in `classify()` + `KNOWN_LEAGUES` (settings) +
color in `public/util.js` and `--<league>` in `style.css` + `phaseFor`/`seasonFor` rules.

## HTTP API (`server.mjs`)

| Route | |
| --- | --- |
| `GET /api/games?q&league&season&phase&team&new&fav&dl&torrent&sort&limit&offset` | games, each with `releases[]` (best first: has torrent, higher resolution) |
| `GET /api/facets?…` | leagues/seasons/stages/teams with counts for the current filters |
| `GET /api/stats` | totals incl. `new`, `lastSync` |
| `PATCH /api/games/:id` | `favorite`, `downloaded`, `is_new`, `watch_position`, `watch_release`, `watch_file`, `duration` |
| `POST /api/games/seen` | `{ids?}` clear NEW (all if no ids) |
| `GET/POST /api/sync` | fetch status / start `{mode: 'incremental'|'full', batchSize?}` (409 if running) |
| `POST /api/reclassify` | re-run classification |
| `GET/PUT /api/settings` | settings payload (settings, leagues with counts, sources, storage, runs, app) / save `{settings, leagues: {name: 'fetch'|'ignore'}, removeIgnored?}` |
| `GET /api/settings/prune-preview?leagues=A,B` | what removing those leagues would delete |
| `POST /api/storage/clear` | delete all cached videos/torrents |
| `POST /api/app/check-updates` | Mac app only (hook) |
| `POST /api/stream/:releaseId/start` | start a torrent session (also clears the game's NEW) |
| `GET /api/stream/:releaseId/status?file=N[&play=id&at=sec&ahead=sec]` | peers, speed, progress, piece map, `files[]`, probe (duration, codecs, MSE mime types) |
| `GET /api/stream/:releaseId/raw?file=N` | original file bytes, Range support (VLC/IINA, and ffmpeg's input) |
| `GET /api/stream/:releaseId/play?file=N&t=sec[&reencode=1][&play=id]` | fragmented MP4 for the browser (paced to the player's reports when `play` is set) |
| `POST /api/stream/:releaseId/stop` | stop the torrent (also happens 3 min after last access) |
| `GET /img?u=<url>` | poster through the cache (only `imageHosts` of registered sources) |

## Streaming (`lib/streamer.mjs`, `public/player.js`)

- **Torrent**: webtorrent runs in Node because browsers can't talk to TCP/UDP BitTorrent peers.
  `start(release)` downloads the .torrent once, adds it with `deselect`, picks the video files
  (`videoFiles()`: video extensions, ≥ 50 MB, not "sample", natural sort), selects them all for
  background download. Reads via `createReadStream` get priority, so seeking works anywhere.
- **Multi-file torrents**: the player shows a Part picker when `files.length > 1` and moves to
  the next part on `ended`. Watch progress stores `watch_release` + `watch_file`.
- **Probe**: ffprobe reads `/raw?file=N` for duration, codecs and builds MSE codec strings
  (`mime`, `mimeReencoded`). It's retried if it failed (no peers yet).
- **`/play`**: ffmpeg `-ss t -i /raw` → `-c:v copy` (H.264/HEVC) + audio → AAC stereo (the
  releases use AC-3, which browsers can't decode) → fragmented MP4 on stdout. Seeking outside
  the buffered range restarts `/play` at the new `t`; the player tracks `offset` so the timeline
  shows game time.
- **Safari/WebKit** stalls on the open-GOP I-frames in these broadcasts (at start, after seeks,
  even mid-stream), so `player.js` always requests `reencode=1` in WebKit: video is re-encoded
  with `h264_videotoolbox` (`-a53cc 0` is required: the broadcasts carry caption SEI that breaks
  the encoder). Chrome/Firefox get the copied video.
- **Player**: the page fetches `/play` and appends to a `MediaSource` SourceBuffer (Safari won't
  play a progressive MP4 of unknown length from `<video src>`), keeps 30 s behind, hops small
  buffer gaps. Overlay controls in fullscreen auto-hide after 3 s.
- **Pacing**: the server, not the page, keeps `/play` ~120 s ahead of playback. WebKit keeps
  downloading a `fetch()` body the page isn't reading, so not reading can't hold ffmpeg back.
  Each `/play` carries a `play=<id>`; the player's status polls add `play`, `at` (its
  `currentTime`) and `ahead` (its budget, lowered after a `QuotaExceededError`), and
  `pacedPipe()` stops reading ffmpeg's stdout (ffmpeg blocks) once its `-progress` `out_time`
  is `ahead` seconds past `at`.
- **Cache**: `streams/` is LRU-trimmed to `storage.cacheGB`; upload is capped at
  `storage.uploadKBps` (`client.throttleUpload`). Sessions stop 3 minutes after last access.

## Settings (`lib/settings.mjs`, `public/settings.js`)

`loadSettings()` merges defaults and the user file on every call (no restart needed). Keys:
`fetch.{batchSize,onStartup,everyHours}`, `leagues.{fetch,ignore}`, `sources.<id>`,
`storage.{cacheGB,uploadKBps}`. The popup edits a draft and `PUT`s it; switching a league to
Ignore offers `removeIgnored` (prune), switching back offers a full rescan. To add a setting:
default in `config.defaults.json` → clamp in `loadSettings()` if numeric → read it where needed →
add a field in `settings.js` (`data-k="group.key"` inputs are wired automatically).

## Mac app

`mac/Courtside.swift` (built by `scripts/build-mac-app.sh`, which records the node/git/ffmpeg
paths in `Resources/launch.json`) does only this:

1. Clone the repo into `~/Library/Application Support/Courtside/repo` if missing.
2. Run `node scripts/app.mjs` there with `PORT` (0 the first time, then the same port), log to
   `~/Library/Logs/Courtside.log`, read `COURTSIDE_STATUS=` (loading text) and
   `COURTSIDE_PORT=` (load/reload the page) lines.
3. Exit code **75** means "restart me" (an update was installed) → restart and reload the page.
4. ⌘Q sends SIGTERM and waits up to 10 s. External links open in the default browser.

`scripts/app.mjs`: `update()` (fetch `origin/main`, `reset --hard`; **GitHub always wins**) →
if code changed: `npm ci` when the lockfile changed, exit 75 → else start the server with hooks
(`appInfo`, `checkForUpdates`) → every 30 min check again and restart when idle (not streaming
or fetching). So **pushing to `main` is deploying** to the app. Only Swift changes need a rebuild.

Env overrides for testing a build: `COURTSIDE_SUPPORT_DIR` (clone + log location),
`COURTSIDE_REPO_URL` (clone from e.g. a local bare repo), `COURTSIDE_HOME` (data folder).
