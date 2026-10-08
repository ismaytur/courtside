# Development

## Setup and workflow

```bash
npm install                 # webtorrent (the only dependency)
npm start                   # http://localhost:4321, uses ~/.courtside
```

Needs Node 22.13+ (`node:sqlite`), ffmpeg/ffprobe on PATH, and Xcode (or its Command Line Tools)
only for building the Mac app. On a Mac, `brew bundle` installs Node and ffmpeg from the
`Brewfile`; `scripts/install-mac.sh` does that plus the app build/install (it requires Homebrew, it doesn't install it). There's no build step: edit and reload. Server changes
(`server.mjs`, `lib/`) need a restart; `public/` files are served from disk.

**Pushing to `main` deploys to the Mac app.** It checks GitHub on launch, every 30 minutes, and
via Settings → Updates, then restarts itself into the new code. Rebuild the app
(`npm run build:app`, or `scripts/install-mac.sh` to also install it) only when
`mac/Courtside.swift` or `scripts/build-mac-app.sh` change, or Node moves. Because the app does `git reset --hard origin/main`, never keep anything it needs
in its clone; local state belongs in `~/.courtside`.

## Testing without touching the real library

Point the server at a scratch folder: the folder is created empty and the startup fetch imports
everything (about a minute).

```bash
COURTSIDE_HOME=/tmp/courtside-test PORT=4400 npm start
```

To start from a copy of the real library instead: `mkdir -p /tmp/ct && cp ~/.courtside/games.db /tmp/ct/`.

Useful one-offs:

```bash
# a source on its own
node --input-type=module -e "import s from './lib/sources/sport-video.mjs'; console.log((await s.listPage(0)).entries.slice(0,2))"

# classification of a title
node --input-type=module -e "import { classify } from './lib/classify.mjs'; console.log(classify('Miami Heat at Toronto Raptors 03.10.2026'))"

# query the library
node --input-type=module -e "import { DatabaseSync } from 'node:sqlite'; const db = new DatabaseSync(process.env.HOME + '/.courtside/games.db', { readOnly: true }); console.log(db.prepare('select league, count(*) n from games group by league').all())"
```

**Safari/WebKit**: the Mac app uses WebKit, and Safari-specific playback issues don't show up in
Chrome. Test with Playwright's WebKit (`npx playwright install webkit` in a scratch folder), which
uses the same engine and plays H.264/AAC via MSE.

**Torrents with several files**: there's no such torrent on the current source. To test, make
two short `ffmpeg -f lavfi -i testsrc2 …` files plus a `sample.mkv`, seed them with a
`WebTorrent` client and a local `bittorrent-tracker` `Server` (both already in `node_modules`),
serve the `.torrent` over HTTP, and insert a release pointing at it with `addRelease()`.

**The Mac app build** without touching the installed one or `~/.courtside`:

```bash
APP_OUT=/tmp/ct/Courtside.app npm run build:app
git clone --bare . /tmp/ct/github.git            # a stand-in for GitHub
COURTSIDE_SUPPORT_DIR=/tmp/ct/support COURTSIDE_REPO_URL=/tmp/ct/github.git \
COURTSIDE_HOME=/tmp/ct/home /tmp/ct/Courtside.app/Contents/MacOS/Courtside
```

Push commits to the bare repo to test updates. The launcher can also be run on its own in a
clone: `COURTSIDE_HOME=… PORT=0 node scripts/app.mjs` (exit code 75 = restart after update).

## Common changes

| Change | Where |
| --- | --- |
| New source | [adding-a-source.md](adding-a-source.md) |
| Team alias / misclassified game | dictionaries at the top of `lib/classify.mjs`, then Reclassify all |
| New league | `lib/classify.mjs` (dictionary, `classify`, `phaseFor`, `seasonFor`), `KNOWN_LEAGUES` in `lib/settings.mjs`, `color()` in `public/util.js`, `--<league>` in `public/style.css` |
| New setting | `config.defaults.json`, clamp in `loadSettings()`, a `data-k="group.key"` input in `public/settings.js` |
| New API route | `handle()` in `server.mjs` (exact `METHOD /path` cases first, then regex routes) |
| Schema | additive only (`CREATE … IF NOT EXISTS` / guarded `ALTER TABLE ADD COLUMN` in `lib/db.mjs`); a breaking change means a fresh library (`openDb` sets old files aside) |
| Card / library UI | `card()` and friends in `public/app.js` |
| Player | `public/player.js` (MSE pipeline, pickers, controls) |

## Things that bit us (and why the code looks the way it does)

- **sport-video.org.ua** is windows-1251 HTML from a WYSIWYG builder; titles and links sit in
  separate layout blocks, so `parseListing` pairs each title with the links that follow it.
  Archive pages 10-19 aren't linked from page 1 but exist until a 404. Some titles have typos,
  Cyrillic look-alike letters or a truncated year (handled in `classify.mjs`).
- **AC-3 audio**: these releases carry AC-3 5.1, which no browser decodes, so `/play`
  always transcodes audio to AAC.
- **Safari**: needs MSE (not `<video src>`) for a stream of unknown length, and stalls on open-GOP
  I-frames, hence `reencode=1` with `h264_videotoolbox`. `-a53cc 0` is required or the encoder
  fails on the broadcasts' caption SEI.
- **webtorrent**: `uint8-util` is pinned to 2.2.5 in `package.json` `overrides`; 2.3.x breaks
  `client.add()` (`arr2hex` on a string). Read streams error when the HTTP client hangs up; those
  errors are swallowed on purpose (otherwise the process crashes).
- **SQLite** runs in rollback-journal mode (no WAL) so `games.db` is always one complete file.
- **WKWebView** needs `isElementFullscreenEnabled` for the player's fullscreen and an Edit menu for
  copy/paste. The window title is hidden (it overlapped the traffic-light buttons on newer macOS).
- **GUI apps don't get your shell PATH**: the build script records node/git/ffmpeg locations.
  Rebuild after `nvm` switches Node versions.
