// Removes games whose league is set to "ignore" (in settings), with their posters, streamed
// videos and .torrent files. The settings popup offers the same when you switch a league off.
//
//   npm run prune          show what would be removed
//   npm run prune -- --yes remove it

import { openDb } from '../lib/db.mjs';
import { loadSettings } from '../lib/settings.mjs';
import { prunePreview, pruneLeagues } from '../lib/prune.mjs';

const leagues = loadSettings().leagues.ignore;
if (!leagues.length) {
  console.log('No leagues are set to "ignore"; nothing to prune.');
  process.exit(0);
}
const db = openDb();
const p = prunePreview(db, leagues);
console.log(`Ignored leagues: ${leagues.join(', ')}`);
console.log(`Games: ${p.games}${p.games ? ` (${Object.entries(p.byLeague).map(([l, n]) => `${l} ${n}`).join(', ')})` : ''}`);
console.log(`Files: ${p.images} posters, ${p.cachedVideos} streamed videos (${(p.cachedBytes / 1e9).toFixed(2)} GB)`);
if (!p.games) { console.log('Nothing to prune.'); process.exit(0); }
if (!process.argv.includes('--yes')) {
  console.log('\nDry run. Run `npm run prune -- --yes` to delete these.');
  process.exit(0);
}
pruneLeagues(db, leagues);
console.log(`\nRemoved ${p.games} games.`);
