// Remove every game in the given leagues: database rows (games + releases), cached posters,
// streamed videos and .torrent files. Used by the settings popup and `npm run prune`.

import fs from 'node:fs';
import path from 'node:path';
import { STREAMS_DIR, TORRENTS_DIR } from './paths.mjs';
import { imageCacheFile } from './images.mjs';

function collect(db, leagues) {
  if (!leagues.length) return { games: [], releases: [], images: [] };
  const marks = leagues.map(() => '?').join(',');
  const games = db.prepare(`SELECT id, league FROM games WHERE league IN (${marks})`).all(...leagues);
  const releases = db.prepare(`SELECT r.id, r.image_url FROM releases r JOIN games g ON g.id = r.game_id
    WHERE g.league IN (${marks})`).all(...leagues);
  const kept = new Set(db.prepare(`SELECT r.image_url FROM releases r JOIN games g ON g.id = r.game_id
    WHERE r.image_url IS NOT NULL AND g.league NOT IN (${marks})`).all(...leagues).map((r) => imageCacheFile(r.image_url)));
  const images = [...new Set(releases.map((r) => r.image_url && imageCacheFile(r.image_url)).filter((f) => f && !kept.has(f) && fs.existsSync(f)))];
  return { games, releases, images };
}

const dirSize = (p) => {
  if (!fs.existsSync(p)) return 0;
  const st = fs.statSync(p);
  if (!st.isDirectory()) return st.blocks * 512;
  return fs.readdirSync(p).reduce((a, n) => a + dirSize(path.join(p, n)), 0);
};

/** What removing these leagues would delete. */
export function prunePreview(db, leagues) {
  const { games, releases, images } = collect(db, leagues);
  const byLeague = {};
  for (const g of games) byLeague[g.league] = (byLeague[g.league] ?? 0) + 1;
  const cached = releases.filter((r) => fs.existsSync(path.join(STREAMS_DIR, String(r.id))));
  return {
    games: games.length,
    byLeague,
    images: images.length,
    cachedVideos: cached.length,
    cachedBytes: cached.reduce((a, r) => a + dirSize(path.join(STREAMS_DIR, String(r.id))), 0),
  };
}

/**
 * Delete them. `clearReleases(ids)` removes cached videos/torrents (the server passes its
 * streamer so running torrents are stopped first); the default deletes the files directly.
 */
export function pruneLeagues(db, leagues, { clearReleases } = {}) {
  const preview = prunePreview(db, leagues);
  const { releases, images } = collect(db, leagues);
  if (!releases.length && !preview.games) return preview;
  const ids = releases.map((r) => r.id);
  (clearReleases ?? ((list) => {
    for (const id of list) {
      fs.rmSync(path.join(STREAMS_DIR, String(id)), { recursive: true, force: true });
      fs.rmSync(path.join(TORRENTS_DIR, `${id}.torrent`), { force: true });
    }
  }))(ids);
  for (const f of images) fs.rmSync(f, { force: true });
  const marks = leagues.map(() => '?').join(',');
  db.exec('BEGIN');
  db.prepare(`DELETE FROM releases WHERE game_id IN (SELECT id FROM games WHERE league IN (${marks}))`).run(...leagues);
  db.prepare(`DELETE FROM games WHERE league IN (${marks})`).run(...leagues);
  db.exec('COMMIT');
  db.exec('VACUUM');
  return preview;
}
