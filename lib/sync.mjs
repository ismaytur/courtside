// The "Fetch" button. Walks the site's listing pages newest-first, in batches:
//   - take the next N entries, check which ones are already in SQLite
//   - add the new ones (fetching each detail page for its .torrent link)
//   - if anything in the batch was already known -> stop, we've caught up
//   - otherwise take the next batch
// Until the archive has been walked to the end once, existing games don't stop the
// run (so an interrupted first import resumes instead of stalling at the top).

import { classify } from './classify.mjs';
import { fetchPage, listPageUrl, parseListing, parseDetail } from './scraper.mjs';
import { getMeta, setMeta, insertGame } from './db.mjs';
import { loadConfig } from './config.mjs';

const MAX_PAGES = 80;
const DETAIL_CONCURRENCY = 4;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export function createSyncer(db) {
  let state = idle();

  function idle() {
    return { running: false, mode: null, batchSize: null, startedAt: null, finishedAt: null, page: 0, pages: 0, scanned: 0, added: 0, ignored: 0, batches: 0, result: null, error: null, log: [] };
  }
  const log = (msg) => {
    state.log.push(`${new Date().toLocaleTimeString()}  ${msg}`);
    if (state.log.length > 200) state.log.shift();
  };

  const exists = db.prepare('SELECT id, detail_url, torrent_url, detail_error FROM games WHERE source_key = ?');
  const fixDetail = db.prepare(`UPDATE games SET torrent_url = coalesce(?, torrent_url), mega_url = coalesce(?, mega_url),
    image_url = coalesce(?, image_url), video_info = ?, resolution = ?, language = ?, detail_error = NULL WHERE id = ?`);

  async function loadDetail(entry) {
    try {
      const { html } = await fetchPage(entry.detail_url);
      if (!html) return { detail_error: 'detail page 404' };
      return parseDetail(html);
    } catch (err) {
      return { detail_error: err.message };
    }
  }

  async function mapLimit(items, limit, fn) {
    const out = new Array(items.length);
    let i = 0;
    await Promise.all(Array.from({ length: Math.min(limit, items.length) }, async () => {
      while (i < items.length) { const k = i++; out[k] = await fn(items[k]); await sleep(120); }
    }));
    return out;
  }

  async function run({ mode, batchSize }) {
    const config = loadConfig();
    config.warnings.forEach((w) => log(`Warning: ${w}`));
    if (config.ignore.size) log(`Skipping leagues listed under "ignore" in config.json: ${[...config.ignore].join(', ')}.`);
    const unlisted = new Set();
    const archiveComplete = getMeta(db, 'archive_complete') === '1';
    const stopOnExisting = mode !== 'full' && archiveComplete;
    log(mode === 'full'
      ? 'Full rescan: walking every listing page, skipping games you already have.'
      : stopOnExisting
        ? `Incremental fetch in batches of ${batchSize}; stops at the first batch containing a game you already have.`
        : `First import (or resuming one) in batches of ${batchSize}; walks the whole archive.`);

    const seen = new Set();
    const buffer = [];
    let pageNo = 0, exhausted = false, lastDate = null, stopped = false;

    const loadNextPage = async () => {
      if (pageNo >= MAX_PAGES) { exhausted = true; return; }
      state.page = pageNo;
      const { html } = await fetchPage(listPageUrl(pageNo));
      if (!html) { exhausted = true; log(`basketball${pageNo || ''}.html → 404, end of archive.`); return; }
      const entries = parseListing(html);
      let fresh = 0;
      for (const e of entries) {
        if (seen.has(e.source_key)) continue; // same game listed on several archive pages
        seen.add(e.source_key);
        buffer.push({ ...e, list_page: pageNo });
        fresh++;
      }
      state.pages++;
      log(`Read basketball${pageNo || ''}.html: ${entries.length} entries (${fresh} not seen earlier this run).`);
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
        const row = exists.get(e.source_key);
        const league = classified.get(e).league;
        if (row) known.push({ e, row });
        else if (config.isIgnored(league)) ignored.push(e);
        else {
          fresh.push(e);
          if (!config.isListed(league) && !unlisted.has(league)) {
            unlisted.add(league);
            log(`Note: league "${league}" isn't in config.json; fetching it. Add it to "fetch" or "ignore".`);
          }
        }
      }

      // Retry detail pages that failed in an earlier run.
      const retry = known.filter(({ row }) => row.detail_url && (row.detail_error || !row.torrent_url));
      if (retry.length) {
        const details = await mapLimit(retry, DETAIL_CONCURRENCY, ({ row }) => loadDetail({ detail_url: row.detail_url }));
        retry.forEach(({ row }, i) => {
          const d = details[i];
          if (!d.detail_error) fixDetail.run(d.torrent_url, d.mega_url, d.image_url, d.video_info, d.resolution, d.language, row.id);
        });
      }

      const details = await mapLimit(fresh, DETAIL_CONCURRENCY, (e) => (e.detail_url ? loadDetail(e) : {}));
      let added = 0;
      fresh.forEach((e, i) => {
        const game = { ...e, ...classified.get(e) };
        for (const [k, v] of Object.entries(details[i])) if (v != null) game[k] = v;
        if (insertGame(db, game)) added++;
      });
      state.added += added;

      state.ignored += ignored.length;
      const skipped = ignored.length
        ? `, ${ignored.length} ignored (${[...new Set(ignored.map((e) => classified.get(e).league))].join(', ')})`
        : '';
      log(`Batch ${state.batches}: ${batch.length} checked → ${added} new, ${known.length} already saved${skipped}.`);
      if (stopOnExisting && known.length) {
        stopped = true;
        state.result = state.added ? `Added ${state.added} new game${state.added === 1 ? '' : 's'}. Caught up with your library.` : 'Already up to date — no new games.';
        log('Found games you already have — stopping.');
        break;
      }
    }

    if (!stopped) {
      setMeta(db, 'archive_complete', '1');
      state.result = `Walked the whole archive (${state.pages} pages). Added ${state.added} new game${state.added === 1 ? '' : 's'}.`;
    }
    setMeta(db, 'last_sync', new Date().toISOString());
  }

  return {
    status: () => state,
    start({ mode = 'incremental', batchSize = 10 } = {}) {
      if (state.running) return false;
      batchSize = Math.max(1, Math.min(100, Number(batchSize) || 10));
      state = { ...idle(), running: true, mode, batchSize, startedAt: new Date().toISOString() };
      run({ mode, batchSize })
        .catch((err) => { state.error = err.message; state.result = `Stopped with an error after adding ${state.added} games.`; log(`Error: ${err.message}`); })
        .finally(() => {
          state.running = false;
          state.finishedAt = new Date().toISOString();
          db.prepare('INSERT INTO sync_runs(mode, started_at, finished_at, pages, scanned, added, result) VALUES (?,?,?,?,?,?,?)')
            .run(mode, state.startedAt, state.finishedAt, state.pages, state.scanned, state.added, state.error ? `error: ${state.error}` : state.result);
        });
      return true;
    },
  };
}
