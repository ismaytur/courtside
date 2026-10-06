// config.json at the project root. Read fresh on every use, so edits apply without a restart.
//   leagues.fetch   leagues to save when fetching
//   leagues.ignore  leagues to skip (and remove with `npm run prune`)
// League names are the ones lib/classify.mjs produces: NBA, WNBA, EuroLeague, NCAA,
// International, Other. A league in neither list is fetched, with a note in the sync log.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const CONFIG_PATH = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'config.json');
export const KNOWN_LEAGUES = ['NBA', 'WNBA', 'EuroLeague', 'NCAA', 'International', 'Other'];

export function loadConfig() {
  let raw;
  try {
    raw = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
  } catch (err) {
    if (err.code === 'ENOENT') raw = {};
    else throw new Error(`config.json: ${err.message}`);
  }
  const fetch = new Set(raw.leagues?.fetch ?? KNOWN_LEAGUES);
  const ignore = new Set(raw.leagues?.ignore ?? []);
  const both = [...fetch].filter((l) => ignore.has(l));
  if (both.length) throw new Error(`config.json: ${both.join(', ')} is in both "fetch" and "ignore"`);
  const unknown = [...fetch, ...ignore].filter((l) => !KNOWN_LEAGUES.includes(l));
  return {
    fetch,
    ignore,
    warnings: unknown.length ? [`config.json: unknown league name(s) ${unknown.join(', ')} (known: ${KNOWN_LEAGUES.join(', ')})`] : [],
    isIgnored: (league) => ignore.has(league),
    isListed: (league) => fetch.has(league) || ignore.has(league),
  };
}
