# Adding a source

A source is one file in `lib/sources/` that knows how to read one site. The fetch engine
(`lib/sync.mjs`) does everything else: batching, the stop rule, classification, ignoring
leagues, matching listings to existing games, NEW flags, retries of failed detail pages.

## 1. Write `lib/sources/<id>.mjs`

```js
// Source: example.org basketball replays.
import { decodeEntities } from '../classify.mjs';
import { fetchText } from './http.mjs';

const BASE = 'https://example.org/';

export default {
  id: 'example',                        // stable forever: stored with every release
  name: 'example.org',                  // shown in settings and fetch logs
  homepage: `${BASE}basketball/`,       // "Open ↗" link in settings
  imageHosts: ['example.org', 'cdn.example.org'], // posters the server may fetch and cache

  // Listing page n, newest first (n = 0, 1, 2, …). Return null when there are no more pages.
  async listPage(n) {
    const html = await fetchText(`${BASE}basketball/?page=${n + 1}`); // null on 404
    if (!html) return null;
    const entries = [...html.matchAll(/<article[\s\S]*?<\/article>/g)].map(([block]) => ({
      source_key: block.match(/href="([^"]+)"/)[1],                 // unique + stable per listing
      raw_title: decodeEntities(block.match(/<h2>(.*?)<\/h2>/)[1]),  // "Away at Home dd.mm.yyyy"
      detail_url: new URL(block.match(/href="([^"]+)"/)[1], BASE).href,
      image_url: block.match(/src="([^"]+\.jpg)"/)?.[1],
    }));
    if (!entries.length) return null;
    return { label: `page ${n + 1}`, entries };
  },

  // Extra fields for one new entry, e.g. links that only exist on its detail page.
  // Return {} if the listing already had everything. Don't throw: return { detail_error }.
  async resolve(entry) {
    if (!entry.detail_url) return {};
    try {
      const html = await fetchText(entry.detail_url);
      if (!html) return { detail_error: 'detail page 404' };
      return {
        torrent_url: html.match(/href="([^"]+\.torrent)"/)?.[1] ?? null,
        mega_url: html.match(/href="(https:\/\/mega\.nz\/[^"]+)"/)?.[1] ?? null,
        resolution: html.match(/(\d{3,4}x\d{3,4})/)?.[1] ?? null,
      };
    } catch (err) {
      return { detail_error: err.message };
    }
  },
};
```

### Entry fields

| Field | Required | Notes |
| --- | --- | --- |
| `source_key` | yes | Unique and **stable** within the source (a URL is ideal). It's how a listing is recognized as already saved, which drives the stop rule. If it changes, everything looks new. |
| `raw_title` | yes | Must contain the teams and the date, see below. |
| `torrent_url` | | Absolute URL of a `.torrent`; makes the game playable. |
| `mega_url`, `other_url` | | Shown as links; `other_url` is any other download/forum page. |
| `detail_url` | | Page to open in `resolve()`; also the "↗" link on the card. |
| `image_url` | | Poster; its host must be in `imageHosts`. |
| `video_info`, `resolution`, `language` | | Shown on the card (`resolution` like `1920x1080` becomes "1080p" and ranks releases). |

Anything `resolve()` returns is merged over the entry. Entries that are only `source_key` +
`raw_title` (no links) are still saved, but there's nothing to play or open.

### The title is the contract

Classification only reads `raw_title` (`lib/classify.mjs`). Use the same shape the first source
uses, and the league, season, stage, teams and cross-source matching all work:

- `Away Team at Home Team 04.10.2026`, or `Home Team vs Away Team 04.10.2026`
  (`v`, `-`, `@` also work; 2-digit years too)
- events without teams: `NBA All-Star Game 15.02.2026`

If the site gives structured data (separate date and team fields), build the title yourself:
`` raw_title: `${away} at ${home} ${dd}.${mm}.${yyyy}` ``. Full team names are best, and
nicknames/abbreviations need an alias (see "Teams it doesn't know" below).

### Page order and the stop rule

`listPage(0)` must be the **newest** listings. A normal fetch stops at the first batch that
contains a listing it already has, so if a site lists oldest-first, read its pages from the end
(e.g. find the last page number on page 1 and count backwards). The first import walks every page
until `listPage` returns null; cap runaway pagination yourself (sport-video stops at 80).

Duplicate entries across pages are fine (they're deduplicated per run by `source_key`).

## 2. Register it

- `lib/sources/index.mjs`: `import example from './example.mjs';` and add it to `SOURCES`.
  Order matters only for which source is fetched first.
- `config.defaults.json`: add `"example": true` under `"sources"` (users can switch it off in
  settings; a missing key also means enabled).

Nothing else needs to change: the source shows up in Settings → Sources with its listing count,
its posters are allowed through `/img`, and its releases appear on cards ("2 sources") and in
the player's Source picker.

## 3. Try it without touching your library

```bash
# parse the first page and resolve one entry
node --input-type=module -e "
import src from './lib/sources/example.mjs';
const p = await src.listPage(0);
console.log(p.label, p.entries.length, p.entries.slice(0, 3));
console.log(await src.resolve(p.entries[0]));
console.log('past the end:', await src.listPage(999));"

# run the whole app against a scratch data folder (first import walks every source)
COURTSIDE_HOME=/tmp/courtside-test PORT=4400 npm start
```

Then open <http://localhost:4400>, check Settings → Fetch for the log, and look for games that
picked up a second release from your source ("2 sources" on the card).

## How a new listing becomes a game

```
entry ─► classify(raw_title) ─► league ignored? ─► skip
                │
                ├─► resolve(entry) ─► release fields
                ▼
        matchKey = date + both teams (order-independent), or date + event title
                │
   addRelease:  same (source, source_key) saved ............ duplicate
                game with that match_key exists:
                  already has this torrent_url ............... duplicate
                  otherwise ..................................... new release on that game
                no such game ................................... new game (+ NEW flag)
```

Things to know:

- Matching needs the **same date** on both sources. A site that dates US games by European time
  (a day later) won't match; normalize the date in your source if needed.
- Team names must classify to the same canonical name on both sources. If your source writes
  "LA Lakers" and that isn't an alias yet, add it.
- The first import of a new source doesn't mark games NEW; later fetches do.

## Teams it doesn't know

Add aliases to the dictionaries at the top of `lib/classify.mjs` (`NBA`, `WNBA`, `EUROLEAGUE`,
`NATIONAL_ALIASES`, `NCAA_KNOWN`), then Settings → Fetch → **Reclassify all**. A pair of
unknown names falls back to NCAA, so a new pro league needs its own dictionary and league name
(see "Classification" in [architecture.md](architecture.md)).

## Checklist

- [ ] `listPage(0)` is newest-first, returns null past the end
- [ ] `source_key` is unique and stable
- [ ] `raw_title` is `Team at Team dd.mm.yyyy` / `Team vs Team dd.mm.yyyy`
- [ ] links are absolute URLs; `resolve()` never throws
- [ ] `imageHosts` covers the poster URLs
- [ ] registered in `lib/sources/index.mjs` and `config.defaults.json`
- [ ] tried against a scratch `COURTSIDE_HOME`
