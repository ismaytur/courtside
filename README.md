# Courtside

A local library of basketball games collected from torrent/filesharing listing sites (currently
<https://www.sport-video.org.ua/basketball.html>), browsable by league, season, stage and team,
with a built-in torrent player.

Needs Node 22.13+ (built-in `node:sqlite`) and `ffmpeg` on the PATH for in-browser playback
(`brew install ffmpeg`).

```bash
npm install          # webtorrent, for streaming
npm start            # http://localhost:4321
```

Developer docs: [how it works](docs/architecture.md), [adding a source](docs/adding-a-source.md),
[development and testing](docs/development.md).

## Your data: `~/.courtside`

Everything local lives outside the repo, shared by every clone (dev folder, Mac app). Nothing
there is committed or pushed.

| Path | What |
| --- | --- |
| `games.db` | the library (SQLite): games, releases, favorites, watch progress, NEW flags |
| `config.json` | your settings, written by the settings popup |
| `img/` | poster cache |
| `streams/`, `torrents/` | streamed videos (size-capped cache) and .torrent files |

Set `COURTSIDE_HOME` to use another folder. `config.defaults.json` in the repo holds the default
settings; `~/.courtside/config.json` overrides them.

## Fetching

Each enabled source is read newest-first in batches (10 by default):

1. take the next batch of listings and check which ones are already saved
2. classify the new ones and skip ignored leagues; open the rest for their `.torrent` / Mega links
3. attach each to the game it belongs to, or add it as a new game
4. if any listing in the batch was already saved, that source is caught up; otherwise continue

Fetches run **when the server starts**, optionally **every N hours**, and from the **↻** button
(or **Fetch now** in settings). Games added by a fetch are marked **NEW** until you watch them
or click **Mark all as seen**; the banner, the "New only" filter and a toast point them out.

A source's first import walks its whole archive (about 1,000 games for sport-video.org.ua). If it
gets interrupted, the next fetch resumes instead of stopping at the top. **Full rescan** (in
settings) walks everything again and adds anything missing.

## Settings (⚙)

- **Fetch**: batch size, fetch on startup, fetch every N hours, Fetch/Ignore per league, sources
  on/off, the live fetch log and recent fetches, Full rescan, Reclassify all.
  - Switching a league to **Ignore** offers to delete its saved games, posters and cached videos.
    (`npm run prune` does the same from the command line.)
  - Switching it back to **Fetch** offers a full rescan to bring back its older games, since a
    normal fetch stops at the first game you already have.
- **Storage**: where your data is, video cache size and limit, upload limit while streaming,
  Clear video cache.
- **Updates** (Mac app only): running version, last check, Check for updates now.

## Sources, games and releases

A **game** is one actual game (date + teams). A **release** is one listing of it on a source,
with its links. The same game found on two sources, or listed twice, becomes one game with
several releases; the card shows "2 sources" and the player lets you pick one. A listing is
matched to a game by date plus both teams in either order ("A at B" = "B vs A"), or date plus
title for events like the All-Star Game. A release whose torrent is already attached to the game
is skipped.

**Adding a source:** see [docs/adding-a-source.md](docs/adding-a-source.md).

## Classification

Sources give a title per game (`Las Vegas Aces at Golden State Valkyries 04.10.2026`), so
`lib/classify.mjs` works out:

- **league**: NBA, WNBA, EuroLeague, International (national teams), NCAA (two teams that are
  neither pro nor national)
- **season**: `2025-26` for NBA/EuroLeague/NCAA, `2026` for WNBA/International
- **stage**: preseason, regular season, play-in, playoffs, finals, summer league, all-star,
  NCAA tournament… (estimated from the date)
- **home/away**: `A at B` means B is home; `A vs B` / `A - B` means A is listed as home
- team name typos and aliases (`OKC Thunder`, `Atalanta Dream`, `Anadolu Istanbul`, …)

If something lands in the wrong place, add an alias to the team lists in `lib/classify.mjs` and
use **Reclassify all** in settings.

## Streaming

**▶ Play** on any game with a `.torrent` link opens the built-in player. Mega-only releases
can't be streamed.

- The torrent runs in the Node server (browsers can't reach normal BitTorrent peers). It downloads
  the part you're watching first and fills in the rest in the background.
- **Several files in one torrent** (Part 1 / Part 2, halves, quarters): the video files are listed
  in natural name order, skipping samples and tiny files. A **Part** picker appears in the player,
  and the next part starts when one ends. The **Source** picker appears when a game has more than
  one release with a torrent.
- These releases have AC-3 5.1 audio, which browsers can't play, so ffmpeg converts the audio to
  stereo AAC on the fly. The video is passed through untouched, so CPU use stays low.
- The page feeds the stream to the `<video>` element through Media Source Extensions, so it plays
  in Safari as well as Chrome/Firefox. Safari's decoder stalls on the open-GOP frames these
  broadcasts use, so Safari (and the Mac app) gets a hardware re-encode (VideoToolbox, about 3× real
  time, little CPU). Chrome/Firefox get the original video.
- Seeking anywhere works. The green strip above the timeline shows what's already on disk, and
  seeking there is instant. Elsewhere, those pieces are fetched first (a few seconds with good peers).
- Where you stopped (and which source/part) is saved per game; the card then shows **Resume**.
- **Copy URL for VLC** gives the original file (with 5.1 audio) over HTTP for VLC/IINA.
- Keys: Space/K play-pause, ←/→ 10 s, J/L 30 s, F fullscreen, M mute, Esc close.

While a game is streaming the client also **uploads** to other peers, as all BitTorrent clients
do. Upload is capped (256 KB/s by default, see Storage settings), and a torrent stops seeding 3
minutes after you close the player.

## Mac app

```bash
npm run build:app    # -> dist/Courtside.app (needs Xcode or its Command Line Tools)
```

Drag `dist/Courtside.app` to Applications. No Apple developer account is needed; it's signed
locally for this Mac. It's a native window around the web app that runs from its **own clone**
of this repo in `~/Library/Application Support/Courtside/repo`, using the same `~/.courtside`:

- **On launch** it matches GitHub's `main` (GitHub always wins; your data isn't in git), runs
  `npm ci` if dependencies changed, and starts the server on a random port.
- **While open** it checks GitHub every 30 minutes (or via **Check for updates now**) and
  restarts into the new version when you're not watching or fetching; the window reloads.
- Links to Mega, source pages and .torrent files open in your default browser.
  **View → Open in Browser** opens the library there too; **View → Show Log** shows
  `~/Library/Logs/Courtside.log`.

Rebuild the app only when `mac/Courtside.swift` changes or Node moves (its path is recorded at
build time). Everything else updates itself from GitHub: develop in a separate clone (like this
folder), push to `main`, and the app picks it up.
