// The library lives in ~/.courtside/games.db.
//
//   games     one row per actual game (date + teams), with your favorites / watch progress
//   releases  one row per listing on a source (sport-video.org.ua, …) with its links. The same
//             game found on several sources, or listed twice, becomes one game with several
//             releases; a release is identified by (source, source_key).

import { DatabaseSync } from 'node:sqlite';
import { DB_PATH, ensureHome } from './paths.mjs';

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
  const db = new DatabaseSync(file);
  db.exec('PRAGMA journal_mode = DELETE; PRAGMA foreign_keys = ON;');
  db.exec(SCHEMA);
  return db;
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
