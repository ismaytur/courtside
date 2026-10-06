// Fetching. For each enabled source (lib/sources), walk its listing pages newest-first in batches:
//   - take the next N entries and check which are already saved (same source + source_key)
//   - classify the new ones; skip leagues set to "ignore"; resolve their links (detail pages)
//   - attach each to the existing game with the same date + teams, or create a new game
//     (marked NEW unless this is the source's first full import)
//   - if anything in the batch was already saved -> this source is caught up; next source
// Until a source's archive has been walked to the end once, saved entries don't stop it (so an
// interrupted first import resumes). mode 'full' never stops early.

import { classify, matchKey } from './classify.mjs';
import { getMeta, setMeta, addRelease } from './db.mjs';
import { loadSettings, leaguePolicy } from './settings.mjs';
import { SOURCES } from './sources/index.mjs';

const RESOLVE_CONCURRENCY = 4;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export function createSyncer(db, { onDone } = {}) {
  let state = idle();

  function idle() {
    return {
      running: false, mode: null, trigger: null, batchSize: null, startedAt: null, finishedAt: null,
      pages: 0, scanned: 0, added: 0, linksAdded: 0, addedByLeague: {}, ignored: 0, batches: 0,
      result: null, error: null, log: [],
    };
  }
  const log = (msg) => {
    state.log.push(`${new Date().toLocaleTimeString()}  ${msg}`);
    if (state.log.length > 300) state.log.shift();
  };

  const exists = db.prepare('SELECT id, detail_url, torrent_url, detail_error FROM releases WHERE source = ? AND source_key = ?');
  const fixRelease = db.prepare(`UPDATE releases SET torrent_url = coalesce(?, torrent_url), mega_url = coalesce(?, mega_url),
    image_url = coalesce(?, image_url), video_info = ?, resolution = ?, language = ?, detail_error = NULL WHERE id = ?`);

  async function mapLimit(items, limit, fn) {
    const out = new Array(items.length);
    let i = 0;
    await Promise.all(Array.from({ length: Math.min(limit, items.length) }, async () => {
      while (i < items.length) { const k = i++; out[k] = await fn(items[k]); await sleep(120); }
    }));
    return out;
  }

  async function runSource(source, { mode, batchSize, policy }) {
    const doneKey = `archive_complete:${source.id}`;
    const archiveComplete = getMeta(db, doneKey) === '1';
    const stopOnExisting = mode !== 'full' && archiveComplete;
    log(`${source.name}: ${mode === 'full' ? 'full rescan, skipping saved listings'
      : stopOnExisting ? `checking in batches of ${batchSize}; stops at the first batch with a saved listing`
        : `first import (or resuming one) in batches of ${batchSize}; walks the whole archive`}.`);

    const seen = new Set();
    const buffer = [];
    const unlisted = new Set();
    let pageNo = 0, exhausted = false, lastDate = null;

    const loadNextPage = async () => {
      const page = await source.listPage(pageNo);
      if (!page) { exhausted = true; log(`${source.name}: end of archive after ${pageNo} pages.`); return; }
      let fresh = 0;
      for (const e of page.entries) {
        if (seen.has(e.source_key)) continue; // same listing on several archive pages
        seen.add(e.source_key);
        buffer.push({ ...e, list_page: pageNo });
        fresh++;
      }
      state.pages++;
      log(`${source.name}: read ${page.label} (${page.entries.length} entries, ${fresh} not seen earlier this run).`);
      pageNo++;
    };

    while (true) {
      while (buffer.length < batchSize && !exhausted) await loadNextPage();
      if (!buffer.length) break;
      const batch = buffer.splice(0, batchSize);
      state.batches++;
      state.scanned += batch.length;

      // Classify in listing order so a title with a broken year can borrow its neighbour's.
      const classified = new Map();
      for (const e of batch) {
        const c = classify(e.raw_title, lastDate);
        if (c.game_date) lastDate = c.game_date;
        classified.set(e, c);
      }

      const known = [], fresh = [], ignored = [];
      for (const e of batch) {
        const row = exists.get(source.id, e.source_key);
        const { league } = classified.get(e);
        if (row) known.push({ e, row });
        else if (policy.isIgnored(league)) ignored.push(e);
        else {
          fresh.push(e);
          if (!policy.isListed(league) && !unlisted.has(league)) {
            unlisted.add(league);
            log(`Note: league "${league}" isn't in your fetch or ignore list; fetching it.`);
          }
        }
      }

      // Retry detail pages that failed in an earlier run.
      const retry = known.filter(({ row }) => row.detail_url && (row.detail_error || !row.torrent_url));
      if (retry.length) {
        const details = await mapLimit(retry, RESOLVE_CONCURRENCY, ({ e }) => source.resolve(e));
        retry.forEach(({ row }, i) => {
          const d = details[i];
          if (!d.detail_error) fixRelease.run(d.torrent_url ?? null, d.mega_url ?? null, d.image_url ?? null, d.video_info ?? null, d.resolution ?? null, d.language ?? null, row.id);
        });
      }

      const details = await mapLimit(fresh, RESOLVE_CONCURRENCY, (e) => source.resolve(e));
      let added = 0, linked = 0;
      fresh.forEach((e, i) => {
        const c = classified.get(e);
        const release = { ...e, source: source.id };
        for (const [k, v] of Object.entries(details[i])) if (v != null) release[k] = v;
        const result = addRelease(db, { ...c, match_key: matchKey(c) }, release, { markNew: archiveComplete });
        if (result === 'game') {
          added++;
          state.addedByLeague[c.league] = (state.addedByLeague[c.league] ?? 0) + 1;
        } else if (result === 'release') linked++;
      });
      state.added += added;
      state.linksAdded += linked;
      state.ignored += ignored.length;

      const parts = [`${added} new game${added === 1 ? '' : 's'}`];
      if (linked) parts.push(`${linked} new link${linked === 1 ? '' : 's'} for games you had`);
      parts.push(`${known.length} already saved`);
      if (ignored.length) parts.push(`${ignored.length} ignored (${[...new Set(ignored.map((e) => classified.get(e).league))].join(', ')})`);
      log(`${source.name}: batch ${state.batches}: ${batch.length} checked → ${parts.join(', ')}.`);

      if (stopOnExisting && known.length) {
        log(`${source.name}: caught up.`);
        return;
      }
    }
    setMeta(db, doneKey, '1');
  }

  async function run({ mode, batchSize }) {
    const settings = loadSettings();
    const policy = leaguePolicy(settings);
    if (policy.ignore.size) log(`Ignoring leagues: ${[...policy.ignore].join(', ')}.`);
    const sources = SOURCES.filter((s) => settings.sources?.[s.id] !== false);
    if (!sources.length) log('No sources are enabled.');
    for (const source of sources) {
      try {
        await runSource(source, { mode, batchSize, policy });
      } catch (err) {
        state.error = `${source.name}: ${err.message}`;
        log(`Error: ${state.error}`);
      }
    }
    const bits = [`${state.added} new game${state.added === 1 ? '' : 's'}`];
    if (state.linksAdded) bits.push(`${state.linksAdded} new link${state.linksAdded === 1 ? '' : 's'} for existing games`);
    state.result = state.added || state.linksAdded ? `Added ${bits.join(' and ')}.` : 'Up to date: no new games.';
    setMeta(db, 'last_sync', new Date().toISOString());
  }

  return {
    status: () => state,
    /** trigger: 'manual' | 'startup' | 'schedule' (shown in the UI) */
    start({ mode = 'incremental', batchSize, trigger = 'manual' } = {}) {
      if (state.running) return false;
      batchSize = Math.max(1, Math.min(100, Number(batchSize) || loadSettings().fetch.batchSize));
      state = { ...idle(), running: true, mode, trigger, batchSize, startedAt: new Date().toISOString() };
      run({ mode, batchSize })
        .catch((err) => { state.error = err.message; state.result = `Stopped with an error after adding ${state.added} games.`; log(`Error: ${err.message}`); })
        .finally(() => {
          state.running = false;
          state.finishedAt = new Date().toISOString();
          db.prepare('INSERT INTO sync_runs(mode, started_at, finished_at, pages, scanned, added, result) VALUES (?,?,?,?,?,?,?)')
            .run(`${mode}/${trigger}`, state.startedAt, state.finishedAt, state.pages, state.scanned, state.added, state.error ? `error: ${state.error}` : state.result);
          onDone?.(state);
        });
      return true;
    },
  };
}
