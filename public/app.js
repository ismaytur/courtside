import { openPlayer } from './player.js';

const $ = (s) => document.querySelector(s);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const LEAGUE_COLOR = {
  NBA: 'var(--nba)', WNBA: 'var(--wnba)', EuroLeague: 'var(--euroleague)',
  NCAA: 'var(--ncaa)', International: 'var(--international)', Other: 'var(--other)',
};
const color = (league) => LEAGUE_COLOR[league] ?? 'var(--other)';

const FILTER_KEYS = ['q', 'league', 'season', 'phase', 'team', 'fav', 'torrent', 'dl', 'sort'];
const PAGE = 48;

let filters = readHash();
let offset = 0, total = 0, loading = false, lastMonth = null, teamFacets = [];

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
async function api(path, opts) {
  const r = await fetch(path, opts);
  const body = await r.json();
  if (!r.ok && r.status !== 409) throw new Error(body.error || r.statusText);
  return body;
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
function timeAgo(iso) {
  if (!iso) return 'never';
  const s = (Date.now() - new Date(iso)) / 1000;
  if (s < 60) return 'just now';
  if (s < 3600) return `${Math.round(s / 60)} min ago`;
  if (s < 86400) return `${Math.round(s / 3600)} h ago`;
  return `${Math.round(s / 86400)} d ago`;
}
const imgSrc = (u) => `/img?u=${encodeURIComponent(u)}`;
function specs(g) {
  const out = [];
  if (g.resolution) out.push(g.resolution.replace(/^1920x1080$/, '1080p').replace(/^1280x720$/, '720p'));
  const fps = g.video_info?.match(/([\d.]+)\s*fps/i)?.[1];
  if (fps) out.push(`${fps} fps`);
  const lang = g.language?.trim();
  if (lang) out.push(lang);
  return out.join(' · ');
}

// ---------- stats ----------
async function loadStats() {
  const s = await api('/api/stats');
  $('#stats').innerHTML = s.total
    ? `<b>${s.total.toLocaleString()}</b> games · ${esc(s.first?.slice(0, 4))}–${esc(s.last?.slice(0, 4))} · last fetch ${timeAgo(s.lastSync)}`
    : 'Library is empty — press <b>Fetch new games</b> to import';
  return s;
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
  $('#heading').textContent = parts.length ? parts.join(' · ') : (filters.fav ? 'Favorites' : 'All games');
  const bits = [`${total.toLocaleString()} game${total === 1 ? '' : 's'}`];
  if (filters.q) bits.push(`matching “${filters.q}”`);
  if (filters.team && filters.league) bits.push(`in ${filters.league}`);
  $('#subheading').textContent = bits.join(' ');
}

function card(g) {
  const c = color(g.league);
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

  const sp = specs(g);
  const source = g.detail_url || g.other_url;
  const watched = g.watch_position && g.duration ? Math.min(100, (g.watch_position / g.duration) * 100) : 0;
  return `
  <article class="card ${g.downloaded ? 'downloaded' : ''}" style="--c:${c}" data-id="${g.id}" title="${esc(g.title)}">
    <div class="poster ${g.torrent_url ? 'playable' : ''}" ${g.torrent_url ? 'data-play' : ''}>
      ${poster}
      ${g.torrent_url ? '<span class="play-hint">▶</span>' : ''}
      ${watched ? `<div class="watched" title="Watched to ${Math.round(watched)}%"><span style="width:${watched}%"></span></div>` : ''}
      <span class="badge">${esc(g.league)}</span>
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
      ${sp ? `<div class="meta">${esc(sp)}</div>` : ''}
      <div class="actions">
        ${g.torrent_url
          ? `<button class="btn primary" data-play>▶ ${watched ? 'Resume' : 'Play'}</button>
             <a class="btn" href="${esc(g.torrent_url)}" download title="Download .torrent file">⬇</a>
             ${g.mega_url ? `<a class="btn" href="${esc(g.mega_url)}" target="_blank" rel="noreferrer">Mega</a>` : ''}`
          : g.mega_url
            ? `<a class="btn primary" href="${esc(g.mega_url)}" target="_blank" rel="noreferrer" title="No torrent on the site for this game">Mega ↗</a>`
            : `<span class="btn primary disabled">No download link</span>`}
        ${source ? `<a class="btn" href="${esc(source)}" target="_blank" rel="noreferrer" title="Open on sport-video.org.ua">↗</a>` : ''}
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

async function renderEmpty() {
  const empty = $('#empty');
  if (total > 0) { empty.hidden = true; return; }
  empty.hidden = false;
  const anyFilter = FILTER_KEYS.some((k) => k !== 'sort' && filters[k]);
  empty.innerHTML = anyFilter
    ? `<h2>No games match these filters</h2><p>Try removing a filter or searching for something else.</p><button class="btn" data-reset>Reset filters</button>`
    : `<h2>Your library is empty</h2><p>Fetch pulls the newest games from sport-video.org.ua in batches and saves them to your local SQLite database.<br>The first import walks the whole archive (~1,000 games) and takes a couple of minutes.</p><button class="btn primary" data-fetch>Fetch games now</button>`;
}

async function refresh() {
  writeHash();
  syncControls();
  await Promise.all([loadFacets(), loadGames(true)]);
}

function syncControls() {
  $('#q').value = filters.q;
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
  gameById.set(g.id, { ...gameById.get(g.id), watch_position: g.watch_position, duration: g.duration });
  const cardEl = document.querySelector(`.card[data-id="${g.id}"]`);
  if (cardEl) cardEl.outerHTML = card(gameById.get(g.id));
}

// ---------- sync ----------
let pollTimer = null;
async function startSync(mode) {
  const batchSize = Number($('#batchSize').value) || 10;
  localStorage.setItem('batchSize', batchSize);
  const s = await api('/api/sync', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ mode, batchSize }) });
  showSync(s);
  poll();
}
function poll() {
  clearTimeout(pollTimer);
  pollTimer = setTimeout(async () => {
    const s = await api('/api/sync');
    showSync(s);
    if (s.running) {
      poll();
      // Show new games as they arrive, but don't reshuffle the grid under someone who has scrolled down.
      if (s.added !== showSync.lastAdded && Date.now() - (showSync.lastRefresh ?? 0) > 3000) {
        showSync.lastAdded = s.added;
        showSync.lastRefresh = Date.now();
        loadStats();
        if (window.scrollY < 300) refresh();
      }
    } else {
      await loadStats();
      refresh();
    }
  }, 700);
}
function showSync(s) {
  const panel = $('#syncPanel');
  panel.hidden = false;
  $('#fetchBtn').disabled = s.running;
  $('#syncSpinner').className = `spinner ${s.running ? '' : s.error ? 'fail' : 'done'}`;
  $('#syncTitle').textContent = s.running
    ? (s.mode === 'full' ? 'Full rescan in progress…' : 'Fetching new games…')
    : (s.result || 'Done');
  $('#syncCounters').innerHTML = `
    <span>Pages read <b>${s.pages}</b></span>
    <span>Links checked <b>${s.scanned}</b></span>
    <span>Batches <b>${s.batches}</b></span>
    <span>Added <b>${s.added}</b></span>
    <span>Ignored <b>${s.ignored ?? 0}</b></span>`;
  const log = $('#syncLog');
  const atBottom = log.scrollTop + log.clientHeight >= log.scrollHeight - 8;
  log.textContent = s.log.join('\n');
  if (atBottom) log.scrollTop = log.scrollHeight;
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
$('#fav').addEventListener('change', (e) => setFilter({ fav: e.target.checked ? '1' : '' }));
$('#torrent').addEventListener('change', (e) => setFilter({ torrent: e.target.checked ? '1' : '' }));
$('#dl').addEventListener('change', (e) => setFilter({ dl: e.target.value }));
$('#sort').addEventListener('change', (e) => setFilter({ sort: e.target.value === 'date_desc' ? '' : e.target.value }));
const resetAll = () => { $('#teamSearch').value = ''; setFilter(Object.fromEntries(FILTER_KEYS.map((k) => [k, '']))); };
$('#reset').addEventListener('click', resetAll);
$('.brand').addEventListener('click', (e) => { e.preventDefault(); resetAll(); });

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
    const g = await api(`/api/games/${cardEl.dataset.id}`, { method: 'PATCH', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ [field]: on }) });
    t.classList.toggle('on', on);
    t.textContent = field === 'favorite' ? (on ? '★' : '☆') : (on ? '✓' : '○');
    cardEl.classList.toggle('downloaded', !!g.downloaded);
  }
});
$('#empty').addEventListener('click', (e) => {
  if (e.target.closest('[data-reset]')) resetAll();
  if (e.target.closest('[data-fetch]')) startSync('incremental');
});

$('#fetchBtn').addEventListener('click', () => startSync('incremental'));
$('#moreBtn').addEventListener('click', (e) => { e.stopPropagation(); $('#morePop').hidden = !$('#morePop').hidden; });
document.addEventListener('click', () => { $('#morePop').hidden = true; });
$('#morePop').addEventListener('click', async (e) => {
  const b = e.target.closest('[data-action]');
  if (!b) return;
  if (b.dataset.action === 'full') startSync('full');
  if (b.dataset.action === 'reclassify') {
    const r = await api('/api/reclassify', { method: 'POST' });
    showSync({ running: false, result: `Reclassified ${r.updated} games.`, pages: 0, scanned: 0, batches: 0, added: 0, log: [] });
    refresh();
  }
});
$('#syncClose').addEventListener('click', () => { $('#syncPanel').hidden = true; });

function closeSidebar() { $('#sidebar').classList.remove('open'); $('#scrim').hidden = true; }
$('#filtersToggle').addEventListener('click', () => { $('#sidebar').classList.add('open'); $('#scrim').hidden = false; });
$('#scrim').addEventListener('click', closeSidebar);

window.addEventListener('hashchange', () => { filters = readHash(); refresh(); });

new IntersectionObserver((entries) => {
  if (entries[0].isIntersecting && offset > 0) loadGames(false);
}, { rootMargin: '600px' }).observe($('#sentinel'));

// ---------- boot ----------
try { $('#batchSize').value = localStorage.getItem('batchSize') || 10; } catch {}
await loadStats();
await refresh();
const s = await api('/api/sync');
if (s.running) { showSync(s); poll(); }
setInterval(loadStats, 60000);
