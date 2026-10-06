import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { openDb, getMeta } from './lib/db.mjs';
import { createSyncer } from './lib/sync.mjs';
import { classify, matchKey } from './lib/classify.mjs';
import { createStreamer } from './lib/streamer.mjs';
import { loadSettings, saveSettings, KNOWN_LEAGUES } from './lib/settings.mjs';
import { SOURCES } from './lib/sources/index.mjs';
import { HOME_DIR } from './lib/paths.mjs';
import { imageCacheFile, migrateRepoImages } from './lib/images.mjs';
import { prunePreview, pruneLeagues } from './lib/prune.mjs';

const ROOT = path.dirname(fileURLToPath(import.meta.url));

// Set up in startServer().
let db, syncer, streamer, hooks = {};

const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml', '.jpg': 'image/jpeg' };

function send(res, status, body, type = 'application/json; charset=utf-8') {
  res.writeHead(status, { 'Content-Type': type, 'Cache-Control': 'no-store' });
  res.end(type.startsWith('application/json') ? JSON.stringify(body) : body);
}

async function readJson(req) {
  let raw = '';
  for await (const chunk of req) raw += chunk;
  return raw ? JSON.parse(raw) : {};
}

// ---- queries -------------------------------------------------------------

function buildWhere(p, skip = []) {
  const where = [], args = [];
  const has = (k) => p.get(k) && !skip.includes(k);
  if (has('league')) { where.push('league = ?'); args.push(p.get('league')); }
  if (has('season')) { where.push('season = ?'); args.push(p.get('season')); }
  if (has('phase')) { where.push('phase = ?'); args.push(p.get('phase')); }
  if (has('team')) { where.push('(home_team = ? OR away_team = ?)'); args.push(p.get('team'), p.get('team')); }
  if (has('from')) { where.push('game_date >= ?'); args.push(p.get('from')); }
  if (has('to')) { where.push('game_date <= ?'); args.push(p.get('to')); }
  if (p.get('fav') === '1' && !skip.includes('fav')) where.push('favorite = 1');
  if (p.get('new') === '1' && !skip.includes('new')) where.push('is_new = 1');
  if (p.get('dl') === '1' && !skip.includes('dl')) where.push('downloaded = 1');
  if (p.get('dl') === '0' && !skip.includes('dl')) where.push('downloaded = 0');
  if (p.get('torrent') === '1' && !skip.includes('torrent')) {
    where.push('EXISTS (SELECT 1 FROM releases r WHERE r.game_id = games.id AND r.torrent_url IS NOT NULL)');
  }
  if (has('q')) {
    for (const word of p.get('q').trim().split(/\s+/).slice(0, 8)) {
      where.push("(title LIKE ? OR coalesce(home_team,'') LIKE ? OR coalesce(away_team,'') LIKE ? OR coalesce(league,'') LIKE ? OR coalesce(phase,'') LIKE ?)");
      const w = `%${word}%`;
      args.push(w, w, w, w, w);
    }
  }
  return { sql: where.length ? `WHERE ${where.join(' AND ')}` : '', args };
}

const SORTS = {
  date_desc: 'game_date DESC, id ASC',
  date_asc: 'game_date ASC, id DESC',
  added_desc: 'added_at DESC, id ASC',
};

const RELEASE_FIELDS = 'id, game_id, source, raw_title, detail_url, torrent_url, mega_url, other_url, image_url, video_info, resolution, language';

/** Attach each game's releases (best first: has a torrent, higher resolution, older). */
function withReleases(games) {
  if (!games.length) return games;
  const ids = games.map((g) => g.id);
  const rows = db.prepare(`SELECT ${RELEASE_FIELDS} FROM releases WHERE game_id IN (${ids.map(() => '?').join(',')})`).all(...ids);
  const px = (r) => Number(r.resolution?.match(/x(\d+)/)?.[1] ?? 0);
  const byGame = new Map(ids.map((id) => [id, []]));
  for (const r of rows) byGame.get(r.game_id).push({ ...r, source_name: SOURCES.find((s) => s.id === r.source)?.name ?? r.source });
  for (const list of byGame.values()) list.sort((a, b) => (!!b.torrent_url - !!a.torrent_url) || (px(b) - px(a)) || (a.id - b.id));
  return games.map((g) => ({ ...g, releases: byGame.get(g.id) }));
}

function listGames(p) {
  const { sql, args } = buildWhere(p);
  const limit = Math.min(200, Math.max(1, Number(p.get('limit')) || 48));
  const offset = Math.max(0, Number(p.get('offset')) || 0);
  const order = SORTS[p.get('sort')] ?? SORTS.date_desc;
  const total = db.prepare(`SELECT count(*) n FROM games ${sql}`).get(...args).n;
  const games = db.prepare(`SELECT * FROM games ${sql} ORDER BY ${order} LIMIT ? OFFSET ?`).all(...args, limit, offset);
  return { total, games: withReleases(games) };
}

function facets(p) {
  const group = (col, skip) => {
    const { sql, args } = buildWhere(p, skip);
    const cond = sql ? `${sql} AND ${col} IS NOT NULL` : `WHERE ${col} IS NOT NULL`;
    return db.prepare(`SELECT ${col} value, count(*) n FROM games ${cond} GROUP BY ${col}`).all(...args);
  };
  // Teams: unnest home/away, respecting every filter except the team itself.
  const { sql, args } = buildWhere(p, ['team']);
  const teams = db.prepare(`
    SELECT team value, league, count(*) n FROM (
      SELECT home_team team, league FROM games ${sql}
      UNION ALL SELECT away_team team, league FROM games ${sql}
    ) WHERE team IS NOT NULL GROUP BY team ORDER BY team`).all(...args, ...args);
  return {
    leagues: group('league', ['league', 'season', 'phase', 'team']).sort((a, b) => b.n - a.n),
    seasons: group('season', ['season', 'phase']).sort((a, b) => b.value.localeCompare(a.value)),
    phases: group('phase', ['phase']).sort((a, b) => b.n - a.n),
    teams,
  };
}

function stats() {
  const s = db.prepare(`SELECT count(*) total, sum(favorite) favorites, sum(downloaded) downloaded, sum(is_new) new,
    min(game_date) first, max(game_date) last FROM games`).get();
  return { ...s, lastSync: getMeta(db, 'last_sync') };
}

function reclassify() {
  const rows = db.prepare(`SELECT g.id, (SELECT raw_title FROM releases r WHERE r.game_id = g.id ORDER BY r.id LIMIT 1) raw_title
    FROM games g ORDER BY g.id`).all();
  const upd = db.prepare('UPDATE games SET title=?, game_date=?, league=?, season=?, phase=?, home_team=?, away_team=?, is_event=?, match_key=? WHERE id=?');
  let lastDate = null;
  db.exec('BEGIN');
  for (const r of rows) {
    if (!r.raw_title) continue;
    const c = classify(r.raw_title, lastDate);
    if (c.game_date) lastDate = c.game_date;
    upd.run(c.title, c.game_date, c.league, c.season, c.phase, c.home_team, c.away_team, c.is_event, matchKey(c), r.id);
  }
  db.exec('COMMIT');
  return { updated: rows.length };
}

// ---- settings -------------------------------------------------------------

function settingsPayload() {
  const settings = loadSettings();
  const counts = Object.fromEntries(db.prepare('SELECT league, count(*) n FROM games GROUP BY league').all().map((r) => [r.league, r.n]));
  const relCounts = Object.fromEntries(db.prepare('SELECT source, count(*) n FROM releases GROUP BY source').all().map((r) => [r.source, r.n]));
  return {
    settings,
    leagues: KNOWN_LEAGUES.map((name) => ({
      name,
      games: counts[name] ?? 0,
      mode: settings.leagues.ignore.includes(name) ? 'ignore' : 'fetch',
    })),
    sources: SOURCES.map((s) => ({ id: s.id, name: s.name, homepage: s.homepage, enabled: settings.sources?.[s.id] !== false, releases: relCounts[s.id] ?? 0 })),
    storage: { home: HOME_DIR, ...streamer.usage() },
    runs: db.prepare('SELECT mode, started_at, finished_at, added, result FROM sync_runs ORDER BY id DESC LIMIT 8').all(),
    app: hooks.appInfo?.() ?? { isApp: false },
  };
}

function updateSettings(body) {
  const before = loadSettings();
  const next = { ...body.settings };
  // Leagues come in as { name: 'fetch' | 'ignore' }.
  if (body.leagues) {
    next.leagues = {
      fetch: Object.entries(body.leagues).filter(([, m]) => m !== 'ignore').map(([l]) => l),
      ignore: Object.entries(body.leagues).filter(([, m]) => m === 'ignore').map(([l]) => l),
    };
  }
  const saved = saveSettings(next);
  streamer.applySettings();
  const newlyIgnored = saved.leagues.ignore.filter((l) => !before.leagues.ignore.includes(l));
  let pruned = null;
  if (body.removeIgnored) {
    pruned = pruneLeagues(db, body.removeIgnored === 'all' ? saved.leagues.ignore : newlyIgnored, { clearReleases: (ids) => streamer.clearCache(ids) });
  }
  return { ...settingsPayload(), pruned };
}

// ---- images ---------------------------------------------------------------

// Posters are fetched from the source site once, then served from ~/.courtside/img.
async function serveImage(res, u) {
  const file = imageCacheFile(u);
  if (!file) return send(res, 400, { error: 'not allowed' });
  if (!fs.existsSync(file)) {
    try {
      const r = await fetch(u, { headers: { 'User-Agent': 'Mozilla/5.0' }, signal: AbortSignal.timeout(20000) });
      if (!r.ok || !/image/.test(r.headers.get('content-type') ?? '')) return send(res, 404, { error: 'no image' });
      fs.writeFileSync(file, Buffer.from(await r.arrayBuffer()));
    } catch {
      return send(res, 502, { error: 'fetch failed' });
    }
  }
  res.writeHead(200, { 'Content-Type': 'image/jpeg', 'Cache-Control': 'public, max-age=31536000, immutable' });
  fs.createReadStream(file).pipe(res);
}

// ---- routing ---------------------------------------------------------------

async function handle(req, res) {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const p = url.searchParams;
  const route = `${req.method} ${url.pathname}`;
  try {
    switch (route) {
      case 'GET /api/games': return send(res, 200, listGames(p));
      case 'GET /api/facets': return send(res, 200, facets(p));
      case 'GET /api/stats': return send(res, 200, stats());
      case 'GET /api/sync': return send(res, 200, syncer.status());
      case 'POST /api/sync': {
        const body = await readJson(req);
        const ok = syncer.start({ mode: body.mode === 'full' ? 'full' : 'incremental', batchSize: body.batchSize, trigger: 'manual' });
        return send(res, ok ? 202 : 409, syncer.status());
      }
      case 'POST /api/reclassify': return send(res, 200, reclassify());
      case 'POST /api/games/seen': {
        const body = await readJson(req);
        const ids = Array.isArray(body.ids) ? body.ids.map(Number) : null;
        const r = ids
          ? db.prepare(`UPDATE games SET is_new = 0 WHERE id IN (${ids.map(() => '?').join(',') || 'NULL'})`).run(...ids)
          : db.prepare('UPDATE games SET is_new = 0 WHERE is_new = 1').run();
        return send(res, 200, { updated: r.changes });
      }
      case 'GET /api/settings': return send(res, 200, settingsPayload());
      case 'PUT /api/settings': return send(res, 200, updateSettings(await readJson(req)));
      case 'GET /api/settings/prune-preview': {
        const leagues = (p.get('leagues') ?? '').split(',').filter(Boolean);
        return send(res, 200, prunePreview(db, leagues));
      }
      case 'POST /api/storage/clear': streamer.clearCache(); return send(res, 200, settingsPayload().storage);
      case 'POST /api/app/check-updates':
        if (!hooks.checkForUpdates) return send(res, 400, { error: 'Updates are only available in the Mac app.' });
        return send(res, 200, await hooks.checkForUpdates());
      case 'GET /img': return serveImage(res, p.get('u'));
    }

    const m = url.pathname.match(/^\/api\/games\/(\d+)$/);
    if (m && req.method === 'PATCH') {
      const body = await readJson(req);
      const id = Number(m[1]);
      for (const k of ['favorite', 'downloaded', 'is_new']) {
        if (k in body) db.prepare(`UPDATE games SET ${k} = ? WHERE id = ?`).run(body[k] ? 1 : 0, id);
      }
      for (const k of ['watch_position', 'duration', 'watch_release', 'watch_file']) {
        if (k in body) db.prepare(`UPDATE games SET ${k} = ? WHERE id = ?`).run(body[k] == null ? null : Number(body[k]), id);
      }
      return send(res, 200, withReleases([db.prepare('SELECT * FROM games WHERE id = ?').get(id)])[0]);
    }

    const st = url.pathname.match(/^\/api\/stream\/(\d+)\/(start|status|stop|raw|play)$/);
    if (st) {
      const id = Number(st[1]); // release id
      const file = Number(p.get('file')) || 0;
      switch (st[2]) {
        case 'start': {
          const release = db.prepare('SELECT * FROM releases WHERE id = ?').get(id);
          if (!release?.torrent_url) return send(res, 400, { error: 'This release has no .torrent link (Mega only).' });
          db.prepare('UPDATE games SET is_new = 0 WHERE id = ?').run(release.game_id); // watching = seen
          streamer.start(release).catch(() => {}); // progress is reported through /status
          return send(res, 202, await streamer.status(id, file));
        }
        case 'status': return send(res, 200, await streamer.status(id, file));
        case 'stop': streamer.stop(id); return send(res, 200, { stopped: true });
        case 'raw': return streamer.serveRaw(req, res, id, file);
        case 'play': return streamer.servePlay(req, res, id, Math.max(0, Number(p.get('t')) || 0), { reencode: p.get('reencode') === '1', file });
      }
    }

    // static
    const rel = url.pathname === '/' ? 'index.html' : url.pathname.slice(1);
    const filePath = path.join(ROOT, 'public', path.normalize(rel));
    if (filePath.startsWith(path.join(ROOT, 'public')) && fs.existsSync(filePath) && fs.statSync(filePath).isFile()) {
      res.writeHead(200, { 'Content-Type': MIME[path.extname(filePath)] ?? 'application/octet-stream' });
      return fs.createReadStream(filePath).pipe(res);
    }
    send(res, 404, { error: 'not found' });
  } catch (err) {
    console.error(err);
    send(res, 500, { error: err.message });
  }
}

// ---- automatic fetching ----------------------------------------------------

function scheduleFetches() {
  // On startup (if enabled), then every `fetch.everyHours` (checked each minute, so settings
  // changes apply without a restart).
  setTimeout(() => {
    if (loadSettings().fetch.onStartup) syncer.start({ trigger: 'startup' });
  }, 1500).unref();
  setInterval(() => {
    const { everyHours } = loadSettings().fetch;
    if (!everyHours) return;
    const last = Date.parse(getMeta(db, 'last_sync') ?? 0) || 0;
    if (Date.now() - last >= everyHours * 3600e3) syncer.start({ trigger: 'schedule' });
  }, 60e3).unref();
}

/**
 * Start the server. `port` 0 picks a free port. Optional `hooks` (used by the Mac app):
 *   appInfo()           -> { isApp, version, … } shown in settings
 *   checkForUpdates()   -> runs an update check from the settings popup
 * Resolves to { port, isBusy(), close() }.
 */
export async function startServer({ port = 4321, hooks: h = {} } = {}) {
  hooks = h;
  db = openDb();
  migrateRepoImages();
  syncer = createSyncer(db);
  let actualPort = port;
  streamer = createStreamer({ port: () => actualPort });

  const server = http.createServer(handle);
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, '127.0.0.1', resolve);
  });
  actualPort = server.address().port;
  scheduleFetches();
  return {
    port: actualPort,
    isBusy: () => syncer.status().running || streamer.activeCount() > 0,
    close: () => new Promise((resolve) => { server.close(() => resolve()); server.closeAllConnections?.(); }),
  };
}

// `npm start` / `node server.mjs`
if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const { port } = await startServer({ port: Number(process.env.PORT) || 4321 });
  console.log(`Courtside library running at http://localhost:${port}`);
}
