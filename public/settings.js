// Settings popup: Fetch (batch size, automatic fetching, leagues, sources, log), Storage (video
// cache) and, in the Mac app, Updates. Edits go into a draft; Save writes them to
// ~/.courtside/config.json through PUT /api/settings.

import { $, esc, api, send, timeAgo, fmtBytes, color } from './util.js';

let data = null;      // last GET /api/settings
let draft = null;     // edited copy: { settings, leagues: {name: mode}, sources: {id: bool} }
let section = 'fetch';
let syncState = null;
let hooks = {};
let updateNote = '';

const clone = (x) => JSON.parse(JSON.stringify(x));
const isOpen = () => !$('#settings').hidden;

function toDraft(d) {
  return {
    settings: clone(d.settings),
    leagues: Object.fromEntries(d.leagues.map((l) => [l.name, l.mode])),
    sources: Object.fromEntries(d.sources.map((s) => [s.id, s.enabled])),
  };
}
const dirty = () => data && JSON.stringify(draft) !== JSON.stringify(toDraft(data));

function refreshFooter() {
  $('#saveSettings').disabled = !dirty();
  $('#fetchNow').disabled = !!syncState?.running;
  $('#fetchNow').textContent = syncState?.running ? 'Fetching…' : 'Fetch now';
}

// ---------- sections ----------

function fetchStatusHtml() {
  const s = syncState;
  if (!s || (!s.running && !s.finishedAt)) {
    return `<p class="hint">No fetch has run since the server started. Last fetch: ${timeAgo(data.runs[0]?.finished_at && data.runs[0].finished_at)}.</p>`;
  }
  const state = s.running ? 'running' : s.error ? 'fail' : 'done';
  const title = s.running ? (s.mode === 'full' ? 'Full rescan in progress…' : 'Fetching…') : (s.result || 'Done');
  const when = s.running ? '' : ` <span class="muted">· ${s.trigger === 'startup' ? 'at startup' : s.trigger === 'schedule' ? 'scheduled' : 'manual'}, ${timeAgo(s.finishedAt)}</span>`;
  return `
    <div class="fetch-state ${state}"><span class="spinner ${state === 'running' ? '' : state}"></span><strong>${esc(title)}</strong>${when}</div>
    <div class="counters">
      <span>Pages <b>${s.pages}</b></span><span>Checked <b>${s.scanned}</b></span>
      <span>New games <b>${s.added}</b></span><span>New links <b>${s.linksAdded ?? 0}</b></span><span>Ignored <b>${s.ignored ?? 0}</b></span>
    </div>
    <pre class="log" id="fetchLog">${esc(s.log.join('\n'))}</pre>`;
}

function sectionFetch() {
  const f = draft.settings.fetch;
  const leagues = data.leagues.map((l) => {
    const mode = draft.leagues[l.name];
    return `
      <div class="row">
        <span class="row-label"><span class="dot" style="--c:${color(l.name)}"></span>${esc(l.name)}</span>
        <span class="muted">${l.games ? `${l.games} saved` : ''}</span>
        <div class="seg" data-league="${esc(l.name)}">
          <button data-mode="fetch" class="${mode === 'fetch' ? 'on' : ''}">Fetch</button>
          <button data-mode="ignore" class="${mode === 'ignore' ? 'on' : ''}">Ignore</button>
        </div>
      </div>`;
  }).join('');
  const sources = data.sources.map((s) => `
    <label class="row">
      <span class="row-label"><input type="checkbox" data-source="${esc(s.id)}" ${draft.sources[s.id] ? 'checked' : ''}> ${esc(s.name)}</span>
      <span class="muted">${s.releases} listings</span>
      <a href="${esc(s.homepage)}" target="_blank" rel="noreferrer">Open ↗</a>
    </label>`).join('');
  const runs = data.runs.map((r) => `
    <div class="run"><span>${esc(new Date(r.finished_at || r.started_at).toLocaleString())}</span>
    <span class="muted">${esc((r.mode || '').replace('incremental/', '').replace('/', ' · '))}</span><span>${esc(r.result || '')}</span></div>`).join('');

  return `
    <div class="fetch-status" id="fetchStatus">${fetchStatusHtml()}</div>

    <h3>Fetching</h3>
    <div class="field">
      <label for="sBatch">Batch size<small>Links checked per batch. A fetch stops at the first batch that contains a game you already have.</small></label>
      <input id="sBatch" type="number" min="1" max="100" data-k="fetch.batchSize" value="${f.batchSize}">
    </div>
    <div class="field">
      <label for="sStartup">Fetch when Courtside starts<small>New games are marked NEW until you watch them.</small></label>
      <input id="sStartup" type="checkbox" class="switch" data-k="fetch.onStartup" ${f.onStartup ? 'checked' : ''}>
    </div>
    <div class="field">
      <label for="sEvery">Fetch automatically every<small>While Courtside is running. 0 turns it off.</small></label>
      <span class="with-unit"><input id="sEvery" type="number" min="0" max="168" data-k="fetch.everyHours" value="${f.everyHours}"> hours</span>
    </div>

    <h3>Leagues</h3>
    <p class="hint">Ignored leagues are skipped when fetching. When you switch a league to Ignore, you can also remove the games you already saved.</p>
    <div class="rows">${leagues}</div>

    <h3>Sources</h3>
    <div class="rows">${sources}</div>

    <h3>Recent fetches</h3>
    <div class="runs">${runs || '<p class="hint">None yet.</p>'}</div>

    <h3>Maintenance</h3>
    <div class="buttons">
      <button class="btn" data-action="full">Full rescan<small>Walk every page of every source and add anything missing</small></button>
      <button class="btn" data-action="reclassify">Reclassify all<small>Re-run league / team / season detection</small></button>
    </div>`;
}

function sectionStorage() {
  const st = draft.settings.storage;
  return `
    <h3>Local data</h3>
    <p class="hint">Your library, settings, posters and downloaded videos are kept in this folder, outside the app's code.</p>
    <div class="field"><label>Folder</label><code class="path">${esc(data.storage.home)}</code></div>

    <h3>Video cache</h3>
    <div class="field">
      <label>In use<small>Streamed games stay here so watching them again is instant.</small></label>
      <span><b>${fmtBytes(data.storage.bytes)}</b> <span class="muted">· ${data.storage.releases} game${data.storage.releases === 1 ? '' : 's'}</span></span>
    </div>
    <div class="field">
      <label for="sCache">Size limit<small>The games you watched least recently are removed first.</small></label>
      <span class="with-unit"><input id="sCache" type="number" min="1" max="10000" data-k="storage.cacheGB" value="${st.cacheGB}"> GB</span>
    </div>
    <div class="field">
      <label for="sUp">Upload limit while streaming<small>BitTorrent shares pieces with other people while you watch. 0 = unlimited.</small></label>
      <span class="with-unit"><input id="sUp" type="number" min="0" max="1000000" data-k="storage.uploadKBps" value="${st.uploadKBps}"> KB/s</span>
    </div>
    <div class="buttons"><button class="btn danger" data-action="clear-cache" ${data.storage.releases ? '' : 'disabled'}>Clear video cache</button></div>`;
}

function sectionUpdates() {
  const a = data.app;
  if (!a?.isApp) return '<p class="hint">Updates are managed by git when running from a dev folder.</p>';
  return `
    <h3>Version</h3>
    <div class="field"><label>Running</label><span><code>${esc(a.version.hash)}</code> <span class="muted">· ${esc(new Date(a.version.date).toLocaleString())}</span><br><span class="muted">${esc(a.version.subject)}</span></span></div>
    <div class="field"><label>Last check<small>Courtside checks GitHub when it starts and every ${a.checkEveryMinutes} minutes; new versions are installed when nothing is playing.</small></label>
      <span>${a.lastCheck?.at ? `${timeAgo(a.lastCheck.at)} · ${esc(a.lastCheck.error ? `failed: ${a.lastCheck.error}` : a.lastCheck.result)}` : 'not yet'}</span></div>
    <div class="buttons"><button class="btn" data-action="check-updates">Check for updates now</button></div>
    <p class="hint" id="updateNote">${esc(updateNote)}</p>`;
}

function render() {
  for (const b of $('#settingsNav').querySelectorAll('button')) b.classList.toggle('on', b.dataset.section === section);
  $('#navUpdates').hidden = !data.app?.isApp;
  const body = $('#settingsBody');
  body.innerHTML = section === 'storage' ? sectionStorage() : section === 'updates' ? sectionUpdates() : sectionFetch();
  scrollLog();
  refreshFooter();
}

function scrollLog() {
  const log = $('#fetchLog');
  if (log) log.scrollTop = log.scrollHeight;
}

// ---------- open / close / save ----------

export async function openSettings(sec = 'fetch') {
  data = await api('/api/settings');
  draft = toDraft(data);
  section = sec;
  $('#settingsConfirm').hidden = true;
  $('#settingsNote').textContent = '';
  $('#settings').hidden = false;
  document.body.style.overflow = 'hidden';
  render();
}

function closeSettings() {
  if (dirty() && !confirm('Discard your unsaved settings changes?')) return;
  $('#settings').hidden = true;
  document.body.style.overflow = '';
}

/** Called by app.js on every fetch status poll. */
export function updateSyncStatus(s) {
  const finished = syncState?.running && !s.running;
  syncState = s;
  if (!isOpen()) return;
  const box = $('#fetchStatus');
  if (box) {
    const log = $('#fetchLog');
    const atBottom = !log || log.scrollTop + log.clientHeight >= log.scrollHeight - 8;
    box.innerHTML = fetchStatusHtml();
    if (atBottom) scrollLog();
  }
  refreshFooter();
  if (finished) api('/api/settings').then((d) => { data = { ...d }; if (section === 'fetch') render(); });
}

async function save(removeIgnored = null) {
  const newlyIgnored = Object.entries(draft.leagues)
    .filter(([name, mode]) => mode === 'ignore' && data.leagues.find((l) => l.name === name)?.mode !== 'ignore')
    .map(([name]) => name);
  const newlyFetched = Object.entries(draft.leagues)
    .filter(([name, mode]) => mode === 'fetch' && data.leagues.find((l) => l.name === name)?.mode === 'ignore')
    .map(([name]) => name);
  if (removeIgnored === null && newlyIgnored.length) {
    const p = await api(`/api/settings/prune-preview?leagues=${encodeURIComponent(newlyIgnored.join(','))}`);
    if (p.games) return askRemove(newlyIgnored, p);
  }
  const res = await send('/api/settings', 'PUT', {
    settings: { fetch: draft.settings.fetch, storage: draft.settings.storage, sources: draft.sources },
    leagues: draft.leagues,
    removeIgnored: removeIgnored || false,
  });
  data = res;
  draft = toDraft(data);
  $('#settingsConfirm').hidden = true;
  $('#settingsNote').textContent = res.pruned?.games ? `Saved. Removed ${res.pruned.games} games.` : 'Saved.';
  setTimeout(() => { $('#settingsNote').textContent = ''; }, 4000);
  render();
  hooks.onChanged?.({ pruned: !!res.pruned?.games });
  // A normal fetch stops at the first saved game, so older games of a re-enabled league need a full rescan.
  if (newlyFetched.length) {
    confirmBox(`<b>${esc(newlyFetched.join(', '))}</b> will be fetched from now on. Also get older ${esc(newlyFetched.join(' and '))} games?
      That walks every page of every source and takes a minute or two.`, 'Full rescan', () => hooks.onFetch?.({ mode: 'full' }), 'Not now');
  }
}

function askRemove(leagues, p) {
  const box = $('#settingsConfirm');
  const parts = [`${p.games} saved game${p.games === 1 ? '' : 's'}`];
  if (p.images) parts.push(`${p.images} poster${p.images === 1 ? '' : 's'}`);
  if (p.cachedVideos) parts.push(`${p.cachedVideos} downloaded video${p.cachedVideos === 1 ? '' : 's'} (${fmtBytes(p.cachedBytes)})`);
  box.innerHTML = `
    <p><b>You're switching ${esc(leagues.join(', '))} to Ignore.</b> Also delete ${esc(parts.join(', '))}?
    Favorites and watch progress for those games go with them.</p>
    <div class="buttons">
      <button class="btn" data-confirm="cancel">Cancel</button>
      <button class="btn" data-confirm="keep">Keep them</button>
      <button class="btn danger" data-confirm="remove">Delete them</button>
    </div>`;
  box.hidden = false;
}

function confirmBox(message, label, onYes, cancelLabel = 'Cancel') {
  const box = $('#settingsConfirm');
  const kind = label === 'Full rescan' ? 'primary' : 'danger';
  box.innerHTML = `<p>${message}</p><div class="buttons"><button class="btn" data-confirm="cancel">${esc(cancelLabel)}</button><button class="btn ${kind}" data-confirm="yes">${esc(label)}</button></div>`;
  box.hidden = false;
  confirmBox.onYes = onYes;
}

// ---------- events ----------

export function initSettings(h) {
  hooks = h;
  $('#settingsBtn').addEventListener('click', () => openSettings());
  $('#settingsClose').addEventListener('click', closeSettings);
  $('#settings').addEventListener('click', (e) => { if (e.target.id === 'settings') closeSettings(); });
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && isOpen() && $('#player').hidden) closeSettings();
  });
  $('#settingsNav').addEventListener('click', (e) => {
    const b = e.target.closest('[data-section]');
    if (b) { section = b.dataset.section; render(); }
  });

  const body = $('#settingsBody');
  body.addEventListener('input', (e) => {
    const k = e.target.dataset.k;
    if (k) {
      const [group, key] = k.split('.');
      draft.settings[group][key] = e.target.type === 'checkbox' ? e.target.checked : Number(e.target.value);
    }
    if (e.target.dataset.source) draft.sources[e.target.dataset.source] = e.target.checked;
    refreshFooter();
  });
  body.addEventListener('click', async (e) => {
    const seg = e.target.closest('.seg [data-mode]');
    if (seg) {
      const league = seg.parentElement.dataset.league;
      draft.leagues[league] = seg.dataset.mode;
      for (const b of seg.parentElement.children) b.classList.toggle('on', b === seg);
      refreshFooter();
      return;
    }
    const action = e.target.closest('[data-action]')?.dataset.action;
    if (action === 'full') hooks.onFetch?.({ mode: 'full' });
    if (action === 'reclassify') {
      const r = await send('/api/reclassify', 'POST');
      $('#settingsNote').textContent = `Reclassified ${r.updated} games.`;
      hooks.onChanged?.({});
    }
    if (action === 'clear-cache') {
      confirmBox(`Delete all downloaded videos (${esc(fmtBytes(data.storage.bytes))})? Games you watch again will be downloaded again.`, 'Clear cache', async () => {
        await send('/api/storage/clear', 'POST');
        data = await api('/api/settings');
        render();
      });
    }
    if (action === 'check-updates') {
      e.target.disabled = true;
      updateNote = 'Checking…';
      render();
      try {
        const r = await send('/api/app/check-updates', 'POST');
        updateNote = r.restarting ? 'A new version was installed. Courtside is restarting; the window will reload.'
          : r.error ? `Check failed: ${r.error}` : 'You have the latest version.';
      } catch (err) {
        updateNote = `Check failed: ${err.message}`;
      }
      data = await api('/api/settings').catch(() => data);
      render();
    }
  });

  $('#settingsConfirm').addEventListener('click', async (e) => {
    const c = e.target.closest('[data-confirm]')?.dataset.confirm;
    if (!c) return;
    if (c === 'cancel') { $('#settingsConfirm').hidden = true; return; }
    if (c === 'yes') { $('#settingsConfirm').hidden = true; return confirmBox.onYes?.(); }
    await save(c === 'remove');
  });
  $('#saveSettings').addEventListener('click', () => save());
  $('#fetchNow').addEventListener('click', () => {
    section = 'fetch';
    render();
    hooks.onFetch?.({ mode: 'incremental', batchSize: draft.settings.fetch.batchSize });
  });
}
