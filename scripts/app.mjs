// Entry point used by Courtside.app (see mac/). Runs inside the app's own clone of the repo:
//   1. update from GitHub (GitHub always wins; your library lives in ~/.courtside, not git)
//   2. install dependencies if package-lock.json changed
//   3. start the server on $PORT (0 = random) and print COURTSIDE_PORT=<port>
//   4. check GitHub again every 30 minutes (and from the settings popup) and restart into
//      new code when nothing is playing or fetching
// Exit code 75 asks the app to restart this process.
//
// Lines starting with COURTSIDE_ are read by the app; everything else goes to its log.

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFile } from 'node:child_process';
import { REPO_DIR as ROOT } from '../lib/paths.mjs';
import { update, currentVersion } from '../lib/gitsync.mjs';

const RESTART = 75;
const UPDATE_EVERY_MS = 30 * 60 * 1000;

const status = (msg) => console.log(`COURTSIDE_STATUS=${msg}`);
let lastCheck = { at: null, result: null, error: null };

async function checkForUpdates() {
  try {
    const r = await update();
    lastCheck = { at: new Date().toISOString(), result: r.changed.length ? 'updated' : 'up to date', error: null };
    return r;
  } catch (err) {
    console.log(`[app] update check failed (offline?): ${err.message}`);
    lastCheck = { at: new Date().toISOString(), result: null, error: err.message };
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
  if (first.depsChanged) await ensureDependencies();
  status('Updated, restarting…');
  process.exit(RESTART); // run the new code from a fresh process
}
await ensureDependencies();

// ---- 3. server ---------------------------------------------------------------
status('Starting…');
const { startServer } = await import('../server.mjs');
const version = await currentVersion();
let app;

async function restartIfUpdated(r, { force = false } = {}) {
  if (!r.changed.length) return false;
  if (r.depsChanged) await ensureDependencies();
  if (!force && app.isBusy()) return false; // try again at the next check
  console.log('[app] restarting into the new version');
  setTimeout(async () => { await app.close(); process.exit(RESTART); }, 300); // let the HTTP reply go out first
  return true;
}

app = await startServer({
  port: Number(process.env.PORT) || 0,
  hooks: {
    appInfo: () => ({ isApp: true, version, lastCheck, checkEveryMinutes: UPDATE_EVERY_MS / 60000 }),
    async checkForUpdates() {
      const r = await checkForUpdates();
      const restarting = await restartIfUpdated(r, { force: true });
      return { ...lastCheck, restarting, changed: r.changed.length };
    },
  },
});
console.log(`[app] version ${version.hash}, serving http://127.0.0.1:${app.port}`);
console.log(`COURTSIDE_PORT=${app.port}`);

// ---- 4. periodic update check and shutdown ----------------------------------
let pending = null; // an update that arrived while busy
setInterval(async () => {
  if (app.isBusy()) return;
  const r = pending ?? await checkForUpdates();
  pending = r.changed.length && !(await restartIfUpdated(r)) ? r : null;
}, UPDATE_EVERY_MS).unref();

async function shutdown() {
  await Promise.race([app.close(), new Promise((r) => setTimeout(r, 5000))]);
  process.exit(0);
}
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
