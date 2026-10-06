// The library lives in ~/.courtside/games.db.
//
//   games     one row per actual game (date + teams), with your favorites / watch progress
//   releases  one row per listing on a source (sport-video.org.ua, …) with its links. The same
//             game found on several sources, or listed twice, becomes one game with several
//             releases; a release is identified by (source, source_key).

import { DatabaseSync } from 'node:sqlite';
import fs from 'node:fs';
import path from 'node:path';
import { DB_PATH, REPO_DIR, ensureHome } from './paths.mjs';
import { matchKey } from './classify.mjs';

const SCHEMA = `
  CREATE TABLE IF NOT EXISTS games (
    id             INTEGER PRIMARY KEY,
    match_key      TEXT,
    title          TEXT NOT NULL,
    game_date      TEXT,
    league         TEXT,
    season         TEXT,
    phase          TEXT,
    home_team      TEXT,
    away_team      TEXT,
    is_event       INTEGER NOT NULL DEFAULT 0,
    image_url      TEXT,
    favorite       INTEGER NOT NULL DEFAULT 0,
    downloaded     INTEGER NOT NULL DEFAULT 0,
    is_new         INTEGER NOT NULL DEFAULT 0,
    watch_position REAL,
    watch_release  INTEGER,
    watch_file     INTEGER,
    duration       REAL,
    added_at       TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE INDEX IF NOT EXISTS games_match  ON games(match_key);
  CREATE INDEX IF NOT EXISTS games_date   ON games(game_date);
  CREATE INDEX IF NOT EXISTS games_league ON games(league, season);
  CREATE INDEX IF NOT EXISTS games_home   ON games(home_team);
  CREATE INDEX IF NOT EXISTS games_away   ON games(away_team);
  CREATE INDEX IF NOT EXISTS games_new    ON games(is_new);

  CREATE TABLE IF NOT EXISTS releases (
    id           INTEGER PRIMARY KEY,
    game_id      INTEGER NOT NULL REFERENCES games(id) ON DELETE CASCADE,
    source       TEXT NOT NULL,
    source_key   TEXT NOT NULL,
    raw_title    TEXT NOT NULL,
    detail_url   TEXT,
    torrent_url  TEXT,
    mega_url     TEXT,
    other_url    TEXT,
    image_url    TEXT,
    video_info   TEXT,
    resolution   TEXT,
    language     TEXT,
    detail_error TEXT,
    list_page    INTEGER,
    added_at     TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE (source, source_key)
  );
  CREATE INDEX IF NOT EXISTS releases_game ON releases(game_id);

  CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
  CREATE TABLE IF NOT EXISTS sync_runs (
    id          INTEGER PRIMARY KEY,
    mode        TEXT,
    started_at  TEXT,
    finished_at TEXT,
    pages       INTEGER,
    scanned     INTEGER,
    added       INTEGER,
    result      TEXT
  );
`;

export function openDb(file = DB_PATH) {
  ensureHome();
  // First run after the database moved out of the repo: bring the old one along.
  const old = path.join(REPO_DIR, 'data', 'games.db');
  if (file === DB_PATH && !fs.existsSync(file) && fs.existsSync(old)) fs.copyFileSync(old, file);

  const db = new DatabaseSync(file);
  db.exec('PRAGMA journal_mode = DELETE; PRAGMA foreign_keys = ON;');
  const cols = new Set(db.prepare('PRAGMA table_info(games)').all().map((c) => c.name));
  if (cols.has('source_key')) migrateV1(db, file);
  db.exec(SCHEMA);
  return db;
}

// v1: one `games` row per sport-video listing, links on the row. Same ids are kept for games and
// their release, so cached videos (keyed by release id) keep working.
function migrateV1(db, file) {
  fs.copyFileSync(file, file.replace(/\.db$/, '.v1.db'));
  db.exec('BEGIN');
  db.exec('ALTER TABLE games RENAME TO games_v1');
  db.exec(SCHEMA);
  const rows = db.prepare('SELECT * FROM games_v1 ORDER BY id').all();
  const insGame = db.prepare(`INSERT INTO games (id, match_key, title, game_date, league, season, phase, home_team, away_team,
    is_event, image_url, favorite, downloaded, watch_position, watch_release, duration, added_at)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`);
  const insRel = db.prepare(`INSERT INTO releases (id, game_id, source, source_key, raw_title, detail_url, torrent_url, mega_url,
    other_url, image_url, video_info, resolution, language, detail_error, list_page, added_at)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`);
  for (const r of rows) {
    insGame.run(r.id, matchKey(r), r.title, r.game_date, r.league, r.season, r.phase, r.home_team, r.away_team,
      r.is_event, r.image_url, r.favorite, r.downloaded, r.watch_position ?? null, r.watch_position ? r.id : null,
      r.duration ?? null, r.added_at);
    insRel.run(r.id, r.id, 'sport-video', r.source_key, r.raw_title, r.detail_url, r.torrent_url, r.mega_url,
      r.other_url, r.image_url, r.video_info, r.resolution, r.language, r.detail_error, r.list_page, r.added_at);
  }
  db.exec('DROP TABLE games_v1');
  // The same game listed more than once becomes one game with several releases.
  const dups = db.prepare(`SELECT match_key, min(id) keep FROM games WHERE match_key IS NOT NULL
    GROUP BY match_key HAVING count(*) > 1`).all();
  for (const { match_key, keep } of dups) {
    const flags = db.prepare(`SELECT max(favorite) f, max(downloaded) d FROM games WHERE match_key = ?`).get(match_key);
    const watched = db.prepare(`SELECT watch_position, watch_release, duration FROM games
      WHERE match_key = ? AND watch_position IS NOT NULL ORDER BY watch_position DESC LIMIT 1`).get(match_key);
    db.prepare('UPDATE releases SET game_id = ? WHERE game_id IN (SELECT id FROM games WHERE match_key = ? AND id <> ?)').run(keep, match_key, keep);
    db.prepare(`UPDATE games SET favorite = ?, downloaded = ?, watch_position = ?, watch_release = ?, duration = ? WHERE id = ?`)
      .run(flags.f, flags.d, watched?.watch_position ?? null, watched?.watch_release ?? null, watched?.duration ?? null, keep);
    db.prepare('DELETE FROM games WHERE match_key = ? AND id <> ?').run(match_key, keep);
  }
  const done = db.prepare("SELECT value FROM meta WHERE key = 'archive_complete'").get();
  if (done) db.prepare("INSERT OR REPLACE INTO meta(key, value) VALUES ('archive_complete:sport-video', ?)").run(done.value);
  db.exec('COMMIT');
}

export const getMeta = (db, key) => db.prepare('SELECT value FROM meta WHERE key = ?').get(key)?.value ?? null;
export const setMeta = (db, key, value) =>
  db.prepare('INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value').run(key, String(value));

const GAME_COLS = ['match_key', 'title', 'game_date', 'league', 'season', 'phase', 'home_team', 'away_team', 'is_event', 'image_url', 'is_new'];
const RELEASE_COLS = ['game_id', 'source', 'source_key', 'raw_title', 'detail_url', 'torrent_url', 'mega_url', 'other_url',
  'image_url', 'video_info', 'resolution', 'language', 'detail_error', 'list_page'];

const insertRow = (db, table, cols, obj) =>
  db.prepare(`INSERT INTO ${table} (${cols.join(',')}) VALUES (${cols.map(() => '?').join(',')})`)
    .run(...cols.map((c) => obj[c] ?? null)).lastInsertRowid;

/**
 * Add a release, attaching it to the existing game with the same match key or creating one.
 * Returns 'game' (new game), 'release' (new links for a game we had), or 'duplicate'.
 */
export function addRelease(db, game, release, { markNew }) {
  if (db.prepare('SELECT 1 FROM releases WHERE source = ? AND source_key = ?').get(release.source, release.source_key)) return 'duplicate';
  const existing = game.match_key && db.prepare('SELECT id, image_url FROM games WHERE match_key = ? ORDER BY id LIMIT 1').get(game.match_key);
  if (existing) {
    // Same torrent already attached (e.g. the same file listed twice): nothing new.
    if (release.torrent_url && db.prepare('SELECT 1 FROM releases WHERE game_id = ? AND torrent_url = ?').get(existing.id, release.torrent_url)) {
      return 'duplicate';
    }
    insertRow(db, 'releases', RELEASE_COLS, { ...release, game_id: existing.id });
    if (!existing.image_url && release.image_url) db.prepare('UPDATE games SET image_url = ? WHERE id = ?').run(release.image_url, existing.id);
    return 'release';
  }
  const gameId = insertRow(db, 'games', GAME_COLS, { ...game, image_url: release.image_url, is_new: markNew ? 1 : 0 });
  insertRow(db, 'releases', RELEASE_COLS, { ...release, game_id: gameId });
  return 'game';
}
