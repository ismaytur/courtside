// Entry point used by Courtside.app (see mac/). Runs inside the app's own clone of the repo:
//   1. save local data and update from GitHub (GitHub wins on conflicts)
//   2. install dependencies if package-lock.json changed
//   3. start the server on $PORT (0 = random) and print COURTSIDE_PORT=<port>
//   4. commit + push data after fetches and (debounced) after favorites / watch progress
//   5. check GitHub again every 30 minutes; on SIGTERM save and push before exiting
// Exit code 75 asks the app to restart this process (new code was pulled).
//
// Lines starting with COURTSIDE_ are read by the app; everything else goes to its log.

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFile } from 'node:child_process';
import { ROOT, update, commitAndPush, currentVersion } from '../lib/gitsync.mjs';

const RESTART = 75;
const UPDATE_EVERY_MS = 30 * 60 * 1000;
const EDIT_DEBOUNCE_MS = 2 * 60 * 1000;
const EDIT_MAX_WAIT_MS = 10 * 60 * 1000;

const status = (msg) => console.log(`COURTSIDE_STATUS=${msg}`);

async function checkForUpdates() {
  try {
    return await update();
  } catch (err) {
    console.log(`[app] update check failed (offline?): ${err.message}`);
    return { changed: [], depsChanged: false };
  }
}

async function ensureDependencies() {
  const lock = path.join(ROOT, 'package-lock.json');
  const marker = path.join(ROOT, 'node_modules', '.courtside-lock-hash');
  const hash = crypto.createHash('sha1').update(fs.readFileSync(lock)).digest('hex');
  if (fs.existsSync(marker) && fs.readFileSync(marker, 'utf8') === hash) return;
  status('Installing dependencies…');
  await new Promise((resolve, reject) => {
    execFile('npm', ['ci', '--no-audit', '--no-fund', '--loglevel=error'], { cwd: ROOT, timeout: 10 * 60 * 1000 },
      (err, stdout, stderr) => (err ? reject(new Error(`npm ci failed: ${stderr || err.message}`)) : resolve()));
  });
  fs.writeFileSync(marker, hash);
}

// ---- 1-2. update before anything else is loaded ----------------------------
status('Checking GitHub for updates…');
const first = await checkForUpdates();
if (first.changed.length) {
  console.log(`[app] updated: ${first.changed.join(', ')}`);
  if (first.depsChanged) await ensureDependencies();
  status('Updated, restarting…');
  process.exit(RESTART); // run the new code from a fresh process
}
await ensureDependencies();

// ---- 3. server ---------------------------------------------------------------
status('Starting…');
const { startServer } = await import('../server.mjs');

let editTimer = null, editFirstAt = 0;
const saveEdits = () => {
  clearTimeout(editTimer);
  editTimer = null;
  editFirstAt = 0;
  return commitAndPush('Update favorites and watch progress');
};

const app = await startServer({
  port: Number(process.env.PORT) || 0,
  hooks: {
    onSyncDone(s) {
      if (!s.added) return;
      const parts = Object.entries(s.addedByLeague).sort((a, b) => b[1] - a[1]).map(([l, n]) => `${l} ${n}`);
      commitAndPush(`Fetch: +${s.added} game${s.added === 1 ? '' : 's'}${parts.length ? ` (${parts.join(', ')})` : ''}`);
    },
    onEdit() {
      // Favorites, "downloaded" marks and watch positions: one commit after things settle.
      if (!editFirstAt) editFirstAt = Date.now();
      clearTimeout(editTimer);
      const wait = Math.min(EDIT_DEBOUNCE_MS, Math.max(0, editFirstAt + EDIT_MAX_WAIT_MS - Date.now()));
      editTimer = setTimeout(saveEdits, wait);
    },
  },
});
console.log(`[app] version ${await currentVersion()}, serving http://127.0.0.1:${app.port}`);
console.log(`COURTSIDE_PORT=${app.port}`);

// ---- 5. periodic update check and shutdown ----------------------------------
setInterval(async () => {
  if (app.isBusy()) return; // don't restart in the middle of a game or a fetch
  const { changed, depsChanged } = await checkForUpdates();
  if (!changed.length || app.isBusy()) return;
  console.log(`[app] update found: ${changed.join(', ')}`);
  if (depsChanged) await ensureDependencies();
  await app.close();
  process.exit(RESTART);
}, UPDATE_EVERY_MS).unref();

let stopping = false;
async function shutdown() {
  if (stopping) return;
  stopping = true;
  const timeout = new Promise((r) => setTimeout(r, 8000));
  await Promise.race([saveEdits(), timeout]);
  await Promise.race([app.close(), timeout]);
  process.exit(0);
}
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
