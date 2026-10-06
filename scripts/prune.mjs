// Removes games whose league is in config.json "ignore" from the database, together with their
// poster image (data/img), .torrent file (data/torrents) and streamed video (data/streams).
//
//   npm run prune          show what would be removed
//   npm run prune -- --yes remove it

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { openDb } from '../lib/db.mjs';
import { loadConfig } from '../lib/config.mjs';

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const DATA = path.join(ROOT, 'data');
const apply = process.argv.includes('--yes');

const config = loadConfig();
config.warnings.forEach((w) => console.warn(`Warning: ${w}`));
const ignore = [...config.ignore];
if (!ignore.length) {
  console.log('config.json has no leagues under "ignore"; nothing to prune.');
  process.exit(0);
}

const db = openDb(path.join(DATA, 'games.db'));
const marks = ignore.map(() => '?').join(',');
const games = db.prepare(`SELECT id, league, image_url FROM games WHERE league IN (${marks})`).all(...ignore);

// Poster files still used by a game we keep are left alone.
const keptImages = new Set(
  db.prepare(`SELECT image_url FROM games WHERE image_url IS NOT NULL AND league NOT IN (${marks})`).all(...ignore)
    .map((r) => path.basename(new URL(r.image_url).pathname)),
);

const files = [];
for (const g of games) {
  if (g.image_url) {
    const name = path.basename(new URL(g.image_url).pathname);
    if (!keptImages.has(name)) files.push(path.join(DATA, 'img', name));
  }
  files.push(path.join(DATA, 'torrents', `${g.id}.torrent`));
  files.push(path.join(DATA, 'streams', String(g.id)));
}
const existing = files.filter((f) => fs.existsSync(f));

const sizeOf = (p) => {
  const st = fs.statSync(p);
  if (!st.isDirectory()) return st.blocks * 512;
  return fs.readdirSync(p).reduce((a, n) => a + sizeOf(path.join(p, n)), 0);
};
const bytes = existing.reduce((a, f) => a + sizeOf(f), 0);
const byLeague = Object.entries(games.reduce((a, g) => ({ ...a, [g.league]: (a[g.league] ?? 0) + 1 }), {}));
const count = (dir) => existing.filter((f) => f.startsWith(path.join(DATA, dir) + path.sep)).length;

console.log(`Ignored leagues: ${ignore.join(', ')}`);
console.log(`Games: ${games.length}${byLeague.length ? ` (${byLeague.map(([l, n]) => `${l} ${n}`).join(', ')})` : ''}`);
console.log(`Files: ${count('img')} images, ${count('torrents')} .torrent files, ${count('streams')} streamed videos (${(bytes / 1e9).toFixed(2)} GB)`);

if (!games.length && !existing.length) {
  console.log('Nothing to prune.');
  process.exit(0);
}
if (!apply) {
  console.log('\nDry run. Run `npm run prune -- --yes` to delete these.');
  process.exit(0);
}

db.exec('BEGIN');
db.prepare(`DELETE FROM games WHERE league IN (${marks})`).run(...ignore);
db.exec('COMMIT');
db.exec('VACUUM');
for (const f of existing) fs.rmSync(f, { recursive: true, force: true });
console.log(`\nRemoved ${games.length} games and ${existing.length} files.`);
