// Settings: config.defaults.json in the repo, overlaid with ~/.courtside/config.json (written by
// the settings popup). Read fresh on every use, so changes apply without a restart.
//
//   fetch.batchSize     links checked per batch
//   fetch.onStartup     fetch when the server starts
//   fetch.everyHours    fetch again every N hours while running (0 = off)
//   leagues.fetch / leagues.ignore   which leagues to save; a league in neither list is fetched
//   sources.<id>        enable/disable each source (lib/sources)
//   storage.cacheGB     size limit of the streamed-video cache
//   storage.uploadKBps  upload cap while streaming (0 = unlimited)

import fs from 'node:fs';
import { SETTINGS_PATH, DEFAULT_SETTINGS_PATH, ensureHome } from './paths.mjs';

export const KNOWN_LEAGUES = ['NBA', 'WNBA', 'EuroLeague', 'NCAA', 'International', 'Other'];

const readJson = (file) => {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (err) {
    if (err.code === 'ENOENT') return {};
    throw new Error(`${file}: ${err.message}`);
  }
};

const merge = (base, over) => {
  const out = { ...base };
  for (const [k, v] of Object.entries(over ?? {})) {
    out[k] = v && typeof v === 'object' && !Array.isArray(v) ? merge(base?.[k] ?? {}, v) : v;
  }
  return out;
};

export function loadSettings() {
  const s = merge(readJson(DEFAULT_SETTINGS_PATH), readJson(SETTINGS_PATH));
  s.fetch.batchSize = clamp(s.fetch.batchSize, 1, 100, 10);
  s.fetch.everyHours = clamp(s.fetch.everyHours, 0, 168, 0);
  s.storage.cacheGB = clamp(s.storage.cacheGB, 1, 10000, 30);
  s.storage.uploadKBps = clamp(s.storage.uploadKBps, 0, 1e6, 256);
  s.leagues.fetch ??= [];
  s.leagues.ignore = (s.leagues.ignore ?? []).filter((l) => !s.leagues.fetch.includes(l));
  return s;
}

function clamp(v, min, max, fallback) {
  const n = Number(v);
  return Number.isFinite(n) ? Math.min(max, Math.max(min, n)) : fallback;
}

/** Save the full settings object (as edited in the popup) to ~/.courtside/config.json. */
export function saveSettings(next) {
  ensureHome();
  const current = loadSettings();
  const s = merge(current, next);
  if (next.leagues) s.leagues = { fetch: [...new Set(next.leagues.fetch ?? [])], ignore: [...new Set(next.leagues.ignore ?? [])] };
  fs.writeFileSync(SETTINGS_PATH, JSON.stringify(s, null, 2) + '\n');
  return loadSettings();
}

export function leaguePolicy(s = loadSettings()) {
  const fetch = new Set(s.leagues.fetch), ignore = new Set(s.leagues.ignore);
  return {
    ignore,
    isIgnored: (league) => ignore.has(league),
    isListed: (league) => fetch.has(league) || ignore.has(league),
  };
}
