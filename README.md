# Courtside

A local library of the basketball games listed on
<https://www.sport-video.org.ua/basketball.html>, saved to SQLite and browsable by
league, season, stage and team.

Needs Node 22.13+ (built-in `node:sqlite`) and `ffmpeg` on the PATH for in-browser playback
(`brew install ffmpeg`).

```bash
npm install          # webtorrent, for streaming
npm start            # http://localhost:4321
```

## Fetching

**Fetch new games** walks the site's listing pages newest-first, in batches (10 by default,
configurable in the header):

1. take the next batch of links and check which ones are already in the database
2. add the new ones (opening each game's page to get its `.torrent` / Mega link)
3. if any link in the batch was already saved, stop; you're caught up
4. otherwise continue with the next batch

The very first import walks the whole archive (`basketball.html` … `basketball19.html`, about
1,000 games). If it gets interrupted, the next fetch resumes instead of stopping at the top.
**⋯ → Full rescan** walks everything again and adds anything missing.

## Choosing leagues (`config.json`)

```json
{
  "leagues": {
    "fetch": ["NBA", "EuroLeague", "International"],
    "ignore": ["WNBA", "NCAA", "Other"]
  }
}
```

League names are `NBA`, `WNBA`, `EuroLeague`, `NCAA`, `International` and `Other`.

- **Fetch** skips games in `ignore` leagues: they're never saved and their pages aren't opened.
  A league in neither list is fetched, and the sync log says so. The file is read on every fetch,
  so edits apply without a restart.
- **`npm run prune`** shows how many saved games (and their posters, `.torrent` files and streamed
  videos) belong to `ignore` leagues; `npm run prune -- --yes` deletes them.
- Moving a league from `ignore` to `fetch` later: run **⋯ → Full rescan** to pick up its older games
  (a normal fetch stops at the first game you already have).

## Classification

The site only has a title per game (`Las Vegas Aces at Golden State Valkyries 04.10.2026`), so
`lib/classify.mjs` works out:

- **league**: NBA, WNBA, EuroLeague, International (national teams), NCAA (two teams that are
  neither pro nor national)
- **season**: `2025-26` for NBA/EuroLeague/NCAA, `2026` for WNBA/International
- **stage**: preseason, regular season, play-in, playoffs, finals, summer league, all-star,
  NCAA tournament… (estimated from the date)
- **home/away**: `A at B` means B is home; `A vs B` / `A - B` means A is listed as home
- team name typos and aliases (`OKC Thunder`, `Atalanta Dream`, `Anadolu Istanbul`, …)

If something lands in the wrong place, add an alias to the team lists in
`lib/classify.mjs` and use **⋯ → Reclassify all**.

## Streaming

**▶ Play** on any game with a `.torrent` link opens the built-in player. Mega-only games can't
be streamed.

- The torrent runs in the Node server (browsers can't reach normal BitTorrent peers). It downloads
  the parts you're watching first and fills in the rest of the file in the background.
- These releases have AC-3 5.1 audio, which browsers can't play, so ffmpeg converts the audio to
  stereo AAC on the fly. The video is passed through untouched, so CPU use stays low.
- The page feeds the stream to the `<video>` element through Media Source Extensions, so it plays
  in Safari as well as Chrome/Firefox. Safari's decoder can't start on some of the keyframes a
  seek lands on, so for Safari a mid-game start re-encodes the video with the Mac's hardware
  encoder (VideoToolbox, about 3× real time, little CPU). Chrome/Firefox always get the original video.
- Seeking anywhere works. The green strip above the timeline shows what's already on disk, and
  seeking there is instant. Elsewhere, those pieces are fetched first (a few seconds with good peers).
- Where you stopped is saved per game; the card then shows **Resume** and a progress bar.
- **Copy URL for VLC** gives the original file (with 5.1 audio) over HTTP for VLC/IINA
  (File → Open Network), with seeking.
- Keys: Space/K play-pause, ←/→ 10 s, J/L 30 s, F fullscreen, M mute, Esc close.

While a game is streaming the client also **uploads** to other peers, as all BitTorrent clients
do. Upload is capped at 256 KB/s, and a torrent stops (no more seeding) 3 minutes after you close
the player. Settings (environment variables):

| Variable | Default | Meaning |
| --- | --- | --- |
| `STREAM_UPLOAD_KBPS` | `256` | upload cap in KB/s (`0` = unlimited) |
| `STREAM_CACHE_GB` | `30` | max size of `data/streams`; least recently watched games are deleted first |

## Data

- `data/games.db`: SQLite (tables `games`, `meta`, `sync_runs`)
- `data/img/`: cached poster images
- `data/streams/`: streamed game files (cache, size-capped); `data/torrents/`: .torrent files

Favorites, "downloaded" marks and watch positions are stored per game in the same database.
