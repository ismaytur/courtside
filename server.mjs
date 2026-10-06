import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { openDb } from './lib/db.mjs';
import { createSyncer } from './lib/sync.mjs';
import { classify } from './lib/classify.mjs';
import { getMeta } from './lib/db.mjs';
import { createStreamer } from './lib/streamer.mjs';
import { MEDIA_DIR } from './lib/config.mjs';

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const DATA = path.join(ROOT, 'data');
const IMG_CACHE = path.join(DATA, 'img');

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
  if (has('opponent')) { where.push('(home_team = ? OR away_team = ?)'); args.push(p.get('opponent'), p.get('opponent')); }
  if (has('from')) { where.push('game_date >= ?'); args.push(p.get('from')); }
  if (has('to')) { where.push('game_date <= ?'); args.push(p.get('to')); }
  if (p.get('fav') === '1' && !skip.includes('fav')) where.push('favorite = 1');
  if (p.get('dl') === '1' && !skip.includes('dl')) where.push('downloaded = 1');
  if (p.get('dl') === '0' && !skip.includes('dl')) where.push('downloaded = 0');
  if (p.get('torrent') === '1' && !skip.includes('torrent')) where.push('torrent_url IS NOT NULL');
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

function listGames(p) {
  const { sql, args } = buildWhere(p);
  const limit = Math.min(200, Math.max(1, Number(p.get('limit')) || 48));
  const offset = Math.max(0, Number(p.get('offset')) || 0);
  const order = SORTS[p.get('sort')] ?? SORTS.date_desc;
  const total = db.prepare(`SELECT count(*) n FROM games ${sql}`).get(...args).n;
  const games = db.prepare(`SELECT * FROM games ${sql} ORDER BY ${order} LIMIT ? OFFSET ?`).all(...args, limit, offset);
  return { total, games };
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
  const s = db.prepare(`SELECT count(*) total, sum(favorite) favorites, sum(downloaded) downloaded,
    min(game_date) first, max(game_date) last, sum(torrent_url IS NOT NULL) torrents FROM games`).get();
  return { ...s, lastSync: getMeta(db, 'last_sync'), archiveComplete: getMeta(db, 'archive_complete') === '1' };
}

function reclassify() {
  const rows = db.prepare('SELECT id, raw_title FROM games ORDER BY list_page, id').all();
  const upd = db.prepare('UPDATE games SET title=?, game_date=?, league=?, season=?, phase=?, home_team=?, away_team=?, is_event=? WHERE id=?');
  let lastDate = null;
  db.exec('BEGIN');
  for (const r of rows) {
    const c = classify(r.raw_title, lastDate);
    if (c.game_date) lastDate = c.game_date;
    upd.run(c.title, c.game_date, c.league, c.season, c.phase, c.home_team, c.away_team, c.is_event, r.id);
  }
  db.exec('COMMIT');
  hooks.onEdit?.();
  return { updated: rows.length };
}

// Images are fetched from the site once, then served from data/img.
async function serveImage(res, u) {
  let url;
  try { url = new URL(u); } catch { return send(res, 400, { error: 'bad url' }); }
  if (!/(^|\.)sport-video\.org\.ua$/.test(url.hostname) || !/^\/images\/[\w.-]+\.jpe?g$/i.test(url.pathname)) {
    return send(res, 400, { error: 'not allowed' });
  }
  const file = path.join(IMG_CACHE, path.basename(url.pathname));
  if (!fs.existsSync(file)) {
    try {
      const r = await fetch(url, { headers: { 'User-Agent': 'Mozilla/5.0' }, signal: AbortSignal.timeout(20000) });
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
  try {
    if (url.pathname === '/api/games' && req.method === 'GET') return send(res, 200, listGames(p));
    if (url.pathname === '/api/facets' && req.method === 'GET') return send(res, 200, facets(p));
    if (url.pathname === '/api/stats' && req.method === 'GET') return send(res, 200, stats());
    if (url.pathname === '/api/sync' && req.method === 'POST') {
      const body = await readJson(req);
      const ok = syncer.start({ mode: body.mode === 'full' ? 'full' : 'incremental', batchSize: body.batchSize });
      return send(res, ok ? 202 : 409, syncer.status());
    }
    if (url.pathname === '/api/sync' && req.method === 'GET') return send(res, 200, syncer.status());
    if (url.pathname === '/api/reclassify' && req.method === 'POST') return send(res, 200, reclassify());
    const m = url.pathname.match(/^\/api\/games\/(\d+)$/);
    if (m && req.method === 'PATCH') {
      const body = await readJson(req);
      for (const k of ['favorite', 'downloaded']) {
        if (k in body) db.prepare(`UPDATE games SET ${k} = ? WHERE id = ?`).run(body[k] ? 1 : 0, Number(m[1]));
      }
      for (const k of ['watch_position', 'duration']) {
        if (k in body) db.prepare(`UPDATE games SET ${k} = ? WHERE id = ?`).run(Number(body[k]) || null, Number(m[1]));
      }
      hooks.onEdit?.();
      return send(res, 200, db.prepare('SELECT * FROM games WHERE id = ?').get(Number(m[1])));
    }

    const st = url.pathname.match(/^\/api\/stream\/(\d+)\/(start|status|stop|raw|play)$/);
    if (st) {
      const id = Number(st[1]);
      switch (st[2]) {
        case 'start': {
          const game = db.prepare('SELECT * FROM games WHERE id = ?').get(id);
          if (!game?.torrent_url) return send(res, 400, { error: 'This game has no .torrent link (Mega only).' });
          streamer.start(game).catch(() => {}); // progress is reported through /status
          return send(res, 202, await streamer.status(id));
        }
        case 'status': return send(res, 200, await streamer.status(id));
        case 'stop': streamer.stop(id); return send(res, 200, { stopped: true });
        case 'raw': return streamer.serveRaw(req, res, id);
        case 'play': return streamer.servePlay(req, res, id, Math.max(0, Number(p.get('t')) || 0), { reencode: p.get('reencode') === '1' });
      }
    }
    if (url.pathname === '/img' && req.method === 'GET') return serveImage(res, p.get('u'));

    // static
    const rel = url.pathname === '/' ? 'index.html' : url.pathname.slice(1);
    const file = path.join(ROOT, 'public', path.normalize(rel));
    if (file.startsWith(path.join(ROOT, 'public')) && fs.existsSync(file) && fs.statSync(file).isFile()) {
      res.writeHead(200, { 'Content-Type': MIME[path.extname(file)] ?? 'application/octet-stream' });
      return fs.createReadStream(file).pipe(res);
    }
    send(res, 404, { error: 'not found' });
  } catch (err) {
    console.error(err);
    send(res, 500, { error: err.message });
  }
}

/**
 * Start the server. `port` 0 picks a free port. `hooks` (used by the Mac app):
 *   onSyncDone(status)  after every fetch finishes
 *   onEdit()            after favorites / watch positions / reclassify change the database
 * Resolves to { port, isBusy(), close() }.
 */
export async function startServer({ port = 4321, hooks: h = {} } = {}) {
  hooks = h;
  fs.mkdirSync(IMG_CACHE, { recursive: true });
  db = openDb(path.join(DATA, 'games.db'));
  syncer = createSyncer(db, { onDone: (status) => hooks.onSyncDone?.(status) });
  let actualPort = port;
  streamer = createStreamer({ mediaDir: MEDIA_DIR, port: () => actualPort, db });

  const server = http.createServer(handle);
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, '127.0.0.1', resolve);
  });
  actualPort = server.address().port;
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
