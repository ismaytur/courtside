import { DatabaseSync } from 'node:sqlite';
import fs from 'node:fs';
import path from 'node:path';

export function openDb(file) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const db = new DatabaseSync(file);
  db.exec(`
    PRAGMA journal_mode = WAL;
    CREATE TABLE IF NOT EXISTS games (
      id           INTEGER PRIMARY KEY,
      source_key   TEXT NOT NULL UNIQUE,
      raw_title    TEXT NOT NULL,
      title        TEXT NOT NULL,
      game_date    TEXT,
      league       TEXT,
      season       TEXT,
      phase        TEXT,
      home_team    TEXT,
      away_team    TEXT,
      is_event     INTEGER NOT NULL DEFAULT 0,
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
      favorite     INTEGER NOT NULL DEFAULT 0,
      downloaded   INTEGER NOT NULL DEFAULT 0,
      added_at     TEXT NOT NULL DEFAULT (datetime('now'))
    );
    CREATE INDEX IF NOT EXISTS games_date   ON games(game_date);
    CREATE INDEX IF NOT EXISTS games_league ON games(league, season);
    CREATE INDEX IF NOT EXISTS games_home   ON games(home_team);
    CREATE INDEX IF NOT EXISTS games_away   ON games(away_team);
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
  `);
  // Columns added after the first version.
  const cols = new Set(db.prepare('PRAGMA table_info(games)').all().map((c) => c.name));
  if (!cols.has('watch_position')) db.exec('ALTER TABLE games ADD COLUMN watch_position REAL');
  if (!cols.has('duration')) db.exec('ALTER TABLE games ADD COLUMN duration REAL');
  return db;
}

export const getMeta = (db, key) => db.prepare('SELECT value FROM meta WHERE key = ?').get(key)?.value ?? null;
export const setMeta = (db, key, value) =>
  db.prepare('INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value').run(key, String(value));

const COLS = ['source_key', 'raw_title', 'title', 'game_date', 'league', 'season', 'phase', 'home_team', 'away_team',
  'is_event', 'detail_url', 'torrent_url', 'mega_url', 'other_url', 'image_url', 'video_info', 'resolution',
  'language', 'detail_error', 'list_page'];

export function insertGame(db, g) {
  const sql = `INSERT OR IGNORE INTO games (${COLS.join(',')}) VALUES (${COLS.map(() => '?').join(',')})`;
  return db.prepare(sql).run(...COLS.map((c) => g[c] ?? null)).changes > 0;
}
