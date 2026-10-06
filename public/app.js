import { openPlayer } from './player.js';
import { initSettings, openSettings, updateSyncStatus } from './settings.js';
import { $, esc, api, send, timeAgo, color } from './util.js';

const FILTER_KEYS = ['q', 'league', 'season', 'phase', 'team', 'new', 'fav', 'torrent', 'dl', 'sort'];
const PAGE = 48;

let filters = readHash();
let offset = 0, total = 0, loading = false, lastMonth = null, teamFacets = [], stats = {};

// ---------- helpers ----------
function readHash() {
  const p = new URLSearchParams(location.hash.slice(1));
  return Object.fromEntries(FILTER_KEYS.map((k) => [k, p.get(k) ?? '']));
}
function writeHash() {
  const p = new URLSearchParams();
  for (const k of FILTER_KEYS) if (filters[k]) p.set(k, filters[k]);
  history.replaceState(null, '', p.toString() ? `#${p}` : location.pathname);
}
function query(extra = {}) {
  const p = new URLSearchParams();
  for (const k of FILTER_KEYS) if (filters[k]) p.set(k, filters[k]);
  for (const [k, v] of Object.entries(extra)) p.set(k, v);
  return p.toString();
}
function abbr(name) {
  if (!name) return '';
  const words = name.replace(/[^\p{L}\p{N}' ]/gu, ' ').split(/\s+/).filter(Boolean);
  if (words.length === 1) return words[0].slice(0, 3).toUpperCase();
  let out = '';
  for (const w of words) out += /^[A-Z0-9]{2,4}$/.test(w) ? w : w[0].toUpperCase();
  return out.slice(0, 4);
}
const fmtDate = (d) => d
  ? new Date(d + 'T12:00:00').toLocaleDateString(undefined, { weekday: 'short', month: 'short', day: 'numeric', year: 'numeric' })
  : 'Unknown date';
const monthLabel = (d) => d ? new Date(d + 'T12:00:00').toLocaleDateString(undefined, { month: 'long', year: 'numeric' }) : 'Unknown date';
const imgSrc = (u) => `/img?u=${encodeURIComponent(u)}`;
function specs(r) {
  if (!r) return '';
  const out = [];
  if (r.resolution) out.push(r.resolution.replace(/^1920x1080$/, '1080p').replace(/^1280x720$/, '720p'));
  const fps = r.video_info?.match(/([\d.]+)\s*fps/i)?.[1];
  if (fps) out.push(`${fps} fps`);
  const lang = r.language?.trim();
  if (lang) out.push(lang);
  return out.join(' · ');
}

let toastTimer;
function toast(html, { ms = 7000 } = {}) {
  const t = $('#toast');
  t.innerHTML = html;
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.hidden = true; }, ms);
}

// ---------- stats / new games ----------
async function loadStats() {
  stats = await api('/api/stats');
  $('#stats').innerHTML = stats.total
    ? `<b>${stats.total.toLocaleString()}</b> games${stats.new ? ` · <b class="new-count">${stats.new} new</b>` : ''} · last fetch ${timeAgo(stats.lastSync)}`
    : 'Library is empty — press ↻ to fetch games';
  $('#newCount').textContent = stats.new || '';
  renderNewBanner();
  return stats;
}

function renderNewBanner() {
  const b = $('#newBanner');
  if (!stats.new) { b.hidden = true; return; }
  b.hidden = false;
  b.innerHTML = filters.new
    ? `<span>Showing <b>${stats.new} new game${stats.new === 1 ? '' : 's'}</b>. They stop being new when you watch them.</span>
       <button class="btn" data-banner="all">Show all games</button><button class="btn" data-banner="seen">Mark all as seen</button>`
    : `<span><b>${stats.new} new game${stats.new === 1 ? '' : 's'}</b> since you last looked.</span>
       <button class="btn primary" data-banner="show">Show them</button><button class="btn" data-banner="seen">Mark all as seen</button>`;
}

// ---------- facets / sidebar ----------
async function loadFacets() {
  const f = await api(`/api/facets?${query()}`);

  const all = f.leagues.reduce((a, b) => a + b.n, 0);
  $('#leagues').innerHTML = [{ value: '', n: all }, ...f.leagues].map((l) => `
    <button class="pill ${filters.league === l.value ? 'on' : ''}" data-league="${esc(l.value)}" style="--c:${l.value ? color(l.value) : 'var(--accent)'}">
      ${l.value ? '<span class="dot"></span>' : ''}${esc(l.value || 'All')} <span class="n">${l.n}</span>
    </button>`).join('');

  const opts = (list, label, cur) => `<option value="">${label}</option>` + list.map((x) =>
    `<option value="${esc(x.value)}" ${x.value === cur ? 'selected' : ''}>${esc(x.value)} (${x.n})</option>`).join('')
    + (cur && !list.some((x) => x.value === cur) ? `<option value="${esc(cur)}" selected>${esc(cur)}</option>` : '');
  $('#season').innerHTML = opts(f.seasons, 'All seasons', filters.season);
  $('#phase').innerHTML = opts(f.phases, 'All stages', filters.phase);

  teamFacets = f.teams;
  renderTeams();
}

function renderTeams() {
  const sel = $('#teamSelected');
  if (filters.team) {
    sel.hidden = false;
    sel.innerHTML = `<span>${esc(filters.team)}</span><button class="icon-btn" data-clear-team aria-label="Clear team">✕</button>`;
  } else sel.hidden = true;

  const needle = $('#teamSearch').value.trim().toLowerCase();
  const list = teamFacets
    .filter((t) => t.value !== filters.team && (!needle || t.value.toLowerCase().includes(needle)))
    .sort((a, b) => b.n - a.n || a.value.localeCompare(b.value));
  $('#teams').innerHTML = list.length
    ? list.map((t) => `<li data-team="${esc(t.value)}" style="--c:${color(t.league)}"><span class="dot"></span>${esc(t.value)}<span class="n">${t.n}</span></li>`).join('')
    : '<li class="none">No teams match</li>';
}

// ---------- results ----------
function heading() {
  const parts = [];
  if (filters.team) parts.push(filters.team);
  else if (filters.league) parts.push(filters.league);
  if (filters.season) parts.push(filters.season);
  if (filters.phase) parts.push(filters.phase);
  $('#heading').textContent = parts.length ? parts.join(' · ') : filters.new ? 'New games' : filters.fav ? 'Favorites' : 'All games';
  const bits = [`${total.toLocaleString()} game${total === 1 ? '' : 's'}`];
  if (filters.q) bits.push(`matching “${filters.q}”`);
  if (filters.team && filters.league) bits.push(`in ${filters.league}`);
  $('#subheading').textContent = bits.join(' ');
}

function card(g) {
  const c = color(g.league);
  const rels = g.releases ?? [];
  const best = rels[0];
  const playable = rels.some((r) => r.torrent_url);
  const torrent = rels.find((r) => r.torrent_url);
  const mega = rels.find((r) => r.mega_url);
  const source = best && (best.detail_url || best.other_url);
  const sourceCount = new Set(rels.map((r) => r.torrent_url || r.mega_url || r.id)).size;

  const poster = g.image_url
    ? `<img loading="lazy" src="${imgSrc(g.image_url)}" alt="" onerror="this.replaceWith(Object.assign(document.createElement('div'),{className:'ph',innerHTML:this.dataset.ph}))" data-ph="${esc(placeholderInner(g))}">`
    : `<div class="ph ${g.home_team ? '' : 'event'}">${placeholderInner(g)}</div>`;

  const teamBtn = (t) => `<button class="team-link" data-team="${esc(t)}">${esc(t)}</button>`;
  const matchup = g.home_team && g.away_team
    ? `<div class="matchup">
         <div class="row"><span class="ha" title="Away">A</span>${teamBtn(g.away_team)}</div>
         <div class="row"><span class="ha" title="Home">H</span>${teamBtn(g.home_team)}</div>
       </div>`
    : `<div class="matchup"><div class="row">${esc(g.title.replace(/\s*\d{1,2}\.\d{1,2}\.\d{0,4}\s*$/, ''))}</div></div>`;

  const sp = specs(torrent ?? best);
  const watched = g.watch_position && g.duration ? Math.min(100, (g.watch_position / g.duration) * 100) : 0;
  return `
  <article class="card ${g.downloaded ? 'downloaded' : ''} ${g.is_new ? 'is-new' : ''}" style="--c:${c}" data-id="${g.id}" title="${esc(g.title)}">
    <div class="poster ${playable ? 'playable' : ''}" ${playable ? 'data-play' : ''}>
      ${poster}
      ${playable ? '<span class="play-hint">▶</span>' : ''}
      ${watched ? `<div class="watched" title="Watched to ${Math.round(watched)}%"><span style="width:${watched}%"></span></div>` : ''}
      <span class="badges"><span class="badge">${esc(g.league)}</span>${g.is_new ? '<span class="badge new">NEW</span>' : ''}</span>
      <div class="flags">
        <button class="flag fav ${g.favorite ? 'on' : ''}" data-toggle="favorite" title="Favorite">${g.favorite ? '★' : '☆'}</button>
        <button class="flag dl ${g.downloaded ? 'on' : ''}" data-toggle="downloaded" title="Mark as downloaded">${g.downloaded ? '✓' : '○'}</button>
      </div>
    </div>
    <div class="card-body">
      ${matchup}
      <div class="meta">
        <span>${fmtDate(g.game_date)}</span>
        ${g.phase ? `<span class="tag">${esc(g.phase)}</span>` : ''}
        ${g.season ? `<span>${esc(g.season)}</span>` : ''}
      </div>
      ${sp || sourceCount > 1 ? `<div class="meta">${esc(sp)}${sourceCount > 1 ? `<span class="tag" title="${esc(rels.map((r) => r.source_name).join(', '))}">${sourceCount} sources</span>` : ''}</div>` : ''}
      <div class="actions">
        ${playable
          ? `<button class="btn primary" data-play>▶ ${watched ? 'Resume' : 'Play'}</button>
             <a class="btn" href="${esc(torrent.torrent_url)}" download title="Download .torrent file">⬇</a>
             ${mega ? `<a class="btn" href="${esc(mega.mega_url)}" target="_blank" rel="noreferrer">Mega</a>` : ''}`
          : mega
            ? `<a class="btn primary" href="${esc(mega.mega_url)}" target="_blank" rel="noreferrer" title="No torrent for this game">Mega ↗</a>`
            : `<span class="btn primary disabled">No download link</span>`}
        ${source ? `<a class="btn" href="${esc(source)}" target="_blank" rel="noreferrer" title="Open on ${esc(best.source_name)}">↗</a>` : ''}
      </div>
    </div>
  </article>`;
}

function placeholderInner(g) {
  if (g.home_team && g.away_team) return `<span>${esc(abbr(g.away_team))}</span><span class="vs">@</span><span>${esc(abbr(g.home_team))}</span>`;
  return esc(g.title.replace(/\s*\d{1,2}\.\d{1,2}\.\d{0,4}\s*$/, ''));
}

const gameById = new Map();

function appendGames(games) {
  for (const g of games) gameById.set(g.id, g);
  const results = $('#results');
  const byMonth = filters.sort !== 'added_desc';
  let grid = results.lastElementChild?.classList.contains('grid') ? results.lastElementChild : null;
  for (const g of games) {
    const m = byMonth ? monthLabel(g.game_date) : null;
    if (!grid || (byMonth && m !== lastMonth)) {
      if (byMonth) {
        results.insertAdjacentHTML('beforeend', `<h2 class="month">${esc(m)}</h2>`);
        lastMonth = m;
      }
      grid = document.createElement('div');
      grid.className = 'grid';
      results.append(grid);
    }
    grid.insertAdjacentHTML('beforeend', card(g));
  }
}

async function loadGames(reset) {
  if (loading) return;
  if (!reset && offset >= total) return;
  loading = true;
  if (reset) { offset = 0; lastMonth = null; }
  try {
    const data = await api(`/api/games?${query({ limit: PAGE, offset })}`);
    total = data.total;
    if (reset) { $('#results').innerHTML = ''; window.scrollTo({ top: 0 }); }
    appendGames(data.games);
    offset += data.games.length;
    heading();
    renderEmpty();
  } finally {
    loading = false;
  }
}

function renderEmpty() {
  const empty = $('#empty');
  if (total > 0) { empty.hidden = true; return; }
  empty.hidden = false;
  const anyFilter = FILTER_KEYS.some((k) => k !== 'sort' && filters[k]);
  empty.innerHTML = anyFilter
    ? `<h2>No games match these filters</h2><p>Try removing a filter or searching for something else.</p><button class="btn" data-reset>Reset filters</button>`
    : `<h2>Your library is empty</h2><p>Fetching reads the sources newest-first in batches and saves the games to your local library.<br>The first import walks the whole archive and takes a couple of minutes.</p><button class="btn primary" data-fetch>Fetch games now</button>`;
}

async function refresh() {
  writeHash();
  syncControls();
  renderNewBanner();
  await Promise.all([loadFacets(), loadGames(true)]);
}

function syncControls() {
  $('#q').value = filters.q;
  $('#newOnly').checked = filters.new === '1';
  $('#fav').checked = filters.fav === '1';
  $('#torrent').checked = filters.torrent === '1';
  $('#dl').value = filters.dl;
  $('#sort').value = filters.sort || 'date_desc';
}

function setFilter(patch) {
  Object.assign(filters, patch);
  refresh();
}

function updateCardAfterWatch(g) {
  gameById.set(g.id, { ...gameById.get(g.id), ...g, is_new: 0 });
  const cardEl = document.querySelector(`.card[data-id="${g.id}"]`);
  if (cardEl) cardEl.outerHTML = card(gameById.get(g.id));
  loadStats();
}

// ---------- fetching ----------
// One loop follows the server's fetch status (startup fetches, scheduled ones, manual ones).
let syncState = null, syncTimer = null, lastAdded = 0, lastLive = 0;

async function syncLoop() {
  clearTimeout(syncTimer);
  const s = await api('/api/sync').catch(() => null);
  if (s) onSync(s);
  syncTimer = setTimeout(syncLoop, s?.running ? 700 : 4000);
}

function onSync(s) {
  const wasRunning = syncState?.running;
  const isNewRun = syncState && s.startedAt !== syncState.startedAt;
  syncState = s;
  $('#quickFetch').classList.toggle('spinning', !!s.running);
  $('#quickFetch').title = s.running ? 'Fetching… (open settings for the log)' : 'Fetch new games';
  updateSyncStatus(s);
  if (s.running) {
    // Show new games as they arrive, without reshuffling the grid under someone who scrolled down.
    if (s.added !== lastAdded && Date.now() - lastLive > 3000) {
      lastAdded = s.added;
      lastLive = Date.now();
      loadStats();
      if (window.scrollY < 300) refresh();
    }
  } else if (wasRunning || (isNewRun && s.finishedAt)) {
    finished(s);
  }
}

function finished(s) {
  lastAdded = 0;
  loadStats();
  refresh();
  const quiet = s.trigger !== 'manual';
  if (s.error) toast(`<b>Fetch failed.</b> ${esc(s.error)} <button class="link" data-toast="settings">Details</button>`);
  else if (s.added) toast(`<b>${s.added} new game${s.added === 1 ? '' : 's'}</b> added. <button class="link" data-toast="new">Show</button>`);
  else if (s.linksAdded) toast(`${s.linksAdded} new link${s.linksAdded === 1 ? '' : 's'} for games you already had.`);
  else if (!quiet) toast('Up to date: no new games.', { ms: 3000 });
}

async function startFetch(opts = {}) {
  const s = await send('/api/sync', 'POST', opts);
  onSync(s);
  syncLoop();
}

// ---------- events ----------
let qTimer;
$('#q').addEventListener('input', (e) => {
  clearTimeout(qTimer);
  qTimer = setTimeout(() => setFilter({ q: e.target.value.trim() }), 250);
});
$('#leagues').addEventListener('click', (e) => {
  const b = e.target.closest('[data-league]');
  if (!b) return;
  const league = b.dataset.league;
  const keepTeam = !filters.team || teamFacets.find((t) => t.value === filters.team)?.league === league;
  setFilter({ league: filters.league === league ? '' : league, season: '', phase: '', team: keepTeam ? filters.team : '' });
});
$('#season').addEventListener('change', (e) => setFilter({ season: e.target.value }));
$('#phase').addEventListener('change', (e) => setFilter({ phase: e.target.value }));
$('#teamSearch').addEventListener('input', renderTeams);
$('#teams').addEventListener('click', (e) => {
  const li = e.target.closest('[data-team]');
  if (li) { $('#teamSearch').value = ''; setFilter({ team: li.dataset.team }); closeSidebar(); }
});
$('#teamSelected').addEventListener('click', (e) => { if (e.target.closest('[data-clear-team]')) setFilter({ team: '' }); });
$('#newOnly').addEventListener('change', (e) => setFilter({ new: e.target.checked ? '1' : '' }));
$('#fav').addEventListener('change', (e) => setFilter({ fav: e.target.checked ? '1' : '' }));
$('#torrent').addEventListener('change', (e) => setFilter({ torrent: e.target.checked ? '1' : '' }));
$('#dl').addEventListener('change', (e) => setFilter({ dl: e.target.value }));
$('#sort').addEventListener('change', (e) => setFilter({ sort: e.target.value === 'date_desc' ? '' : e.target.value }));
const resetAll = () => { $('#teamSearch').value = ''; setFilter(Object.fromEntries(FILTER_KEYS.map((k) => [k, '']))); };
$('#reset').addEventListener('click', resetAll);
$('.brand').addEventListener('click', (e) => { e.preventDefault(); resetAll(); });

$('#newBanner').addEventListener('click', async (e) => {
  const a = e.target.closest('[data-banner]')?.dataset.banner;
  if (a === 'show') setFilter({ new: '1' });
  if (a === 'all') setFilter({ new: '' });
  if (a === 'seen') {
    await send('/api/games/seen', 'POST');
    await loadStats();
    setFilter({ new: '' });
  }
});
$('#toast').addEventListener('click', (e) => {
  const a = e.target.closest('[data-toast]')?.dataset.toast;
  if (a === 'new') setFilter({ new: '1' });
  if (a === 'settings') openSettings('fetch');
  if (a) $('#toast').hidden = true;
});

$('#results').addEventListener('click', async (e) => {
  const play = e.target.closest('[data-play]');
  if (play && !e.target.closest('[data-toggle]')) {
    const g = gameById.get(Number(play.closest('.card').dataset.id));
    if (g) openPlayer(g, { color: color(g.league), onClose: updateCardAfterWatch });
    return;
  }
  const team = e.target.closest('.team-link');
  if (team) { setFilter({ team: team.dataset.team }); return; }
  const t = e.target.closest('[data-toggle]');
  if (t) {
    const cardEl = t.closest('.card');
    const field = t.dataset.toggle;
    const on = !t.classList.contains('on');
    const g = await send(`/api/games/${cardEl.dataset.id}`, 'PATCH', { [field]: on });
    t.classList.toggle('on', on);
    t.textContent = field === 'favorite' ? (on ? '★' : '☆') : (on ? '✓' : '○');
    cardEl.classList.toggle('downloaded', !!g.downloaded);
  }
});
$('#empty').addEventListener('click', (e) => {
  if (e.target.closest('[data-reset]')) resetAll();
  if (e.target.closest('[data-fetch]')) startFetch();
});

$('#quickFetch').addEventListener('click', () => {
  if (syncState?.running) openSettings('fetch');
  else startFetch();
});
initSettings({
  onFetch: (opts) => startFetch(opts),
  onChanged: () => { loadStats(); refresh(); },
});

function closeSidebar() { $('#sidebar').classList.remove('open'); $('#scrim').hidden = true; }
$('#filtersToggle').addEventListener('click', () => { $('#sidebar').classList.add('open'); $('#scrim').hidden = false; });
$('#scrim').addEventListener('click', closeSidebar);

window.addEventListener('hashchange', () => { filters = readHash(); refresh(); });

new IntersectionObserver((entries) => {
  if (entries[0].isIntersecting && offset > 0) loadGames(false);
}, { rootMargin: '600px' }).observe($('#sentinel'));

// ---------- boot ----------
await loadStats();
await refresh();
syncLoop();
setInterval(loadStats, 60000);
