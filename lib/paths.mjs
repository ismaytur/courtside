// Everything local lives in ~/.courtside (override with COURTSIDE_HOME), outside the repo and
// shared by every clone: the library database, settings, poster cache, streamed videos and
// .torrent files. The repo only holds code and default settings.

import os from 'node:os';
import path from 'node:path';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

export const REPO_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
export const HOME_DIR = process.env.COURTSIDE_HOME || path.join(os.homedir(), '.courtside');

export const DB_PATH = path.join(HOME_DIR, 'games.db');
export const SETTINGS_PATH = path.join(HOME_DIR, 'config.json');
export const DEFAULT_SETTINGS_PATH = path.join(REPO_DIR, 'config.defaults.json');
export const IMG_DIR = path.join(HOME_DIR, 'img');
export const STREAMS_DIR = path.join(HOME_DIR, 'streams');
export const TORRENTS_DIR = path.join(HOME_DIR, 'torrents');

export function ensureHome() {
  for (const dir of [HOME_DIR, IMG_DIR, STREAMS_DIR, TORRENTS_DIR]) fs.mkdirSync(dir, { recursive: true });
}
