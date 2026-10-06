// Overlay player for torrent streams. The server sends a fragmented MP4 that starts at
// ?t=<seconds>; `offset` tracks that start so the timeline shows real game time. Seeking
// inside what the <video> already buffered is instant; anything else restarts the stream
// at the new time (the torrent fetches those pieces first).

const $ = (s) => document.querySelector(s);
const el = {
  root: $('#player'), video: $('#pVideo'), title: $('#pTitle'), badge: $('#pBadge'),
  msg: $('#pMsg'), msgText: $('#pMsgText'), bigPlay: $('#pBigPlay'), resume: $('#pResume'),
  play: $('#pPlay'), back: $('#pBack'), fwd: $('#pFwd'), time: $('#pTime'),
  timeline: $('#pTimeline'), pieces: $('#pPieces'), played: $('#pPlayed'), head: $('#pHead'), hover: $('#pHover'),
  mute: $('#pMute'), vol: $('#pVol'), full: $('#pFull'), stats: $('#pStats'), copy: $('#pCopy'), close: $('#pClose'),
  stage: $('#pStage'), box: $('#pBox'), release: $('#pRelease'), part: $('#pPart'),
};

let game = null, offset = 0, duration = null, statusTimer = null, saveTimer = null, started = false;
let lastStatus = null, dragging = false, onCloseCb = null, openedAt = 0;
// What's playing: one of the game's releases (sources) that has a torrent, and a file in it.
let releases = [], rel = null, fileIdx = 0, startAt = null;
const streamUrl = (action, extra = '') => `/api/stream/${rel.id}/${action}?file=${fileIdx}${extra}`;

const fmt = (s) => {
  if (s == null || !isFinite(s)) return '--:--';
  s = Math.max(0, Math.floor(s));
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
  return h ? `${h}:${String(m).padStart(2, '0')}:${String(sec).padStart(2, '0')}` : `${m}:${String(sec).padStart(2, '0')}`;
};
const mb = (b) => b >= 1e9 ? `${(b / 1e9).toFixed(2)} GB` : `${(b / 1e6).toFixed(0)} MB`;
const speed = (b) => b >= 1e6 ? `${(b / 1e6).toFixed(1)} MB/s` : `${(b / 1e3).toFixed(0)} KB/s`;
const now = () => offset + (el.video.currentTime || 0);

function showMsg(text, { error = false } = {}) {
  el.msg.hidden = false;
  el.msg.classList.toggle('error', error);
  el.msgText.innerHTML = text;
}
const hideMsg = () => { el.msg.hidden = true; };

async function api(path, opts) {
  const r = await fetch(path, opts);
  return r.json();
}

function savePosition() {
  if (!game || !started) return;
  const pos = now();
  // Near the end counts as finished; start from the top next time.
  const value = duration && pos > duration - 60 ? 0 : pos;
  game.watch_position = value;
  game.duration = duration;
  game.watch_release = rel.id;
  game.watch_file = fileIdx;
  api(`/api/games/${game.id}`, {
    method: 'PATCH', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ watch_position: value, duration, watch_release: rel.id, watch_file: fileIdx }),
  }).catch(() => {});
}

// ---------- MediaSource pipeline ----------
// Safari won't play a progressive MP4 of unknown length from a plain <video src>, so the
// stream is fetched here and appended to a SourceBuffer (works the same in Chrome/Firefox).
const MSE = window.MediaSource || window.ManagedMediaSource;
const AHEAD_MAX = 120; // seconds buffered ahead before we stop reading (ffmpeg then waits too)
const KEEP_BEHIND = 30; // seconds of already-played video kept for small rewinds
let pipe = null;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const bufferedAhead = () => {
  const b = el.video.buffered, t = el.video.currentTime;
  for (let i = 0; i < b.length; i++) if (t >= b.start(i) - 0.5 && t <= b.end(i)) return b.end(i) - t;
  return 0;
};

function stopPipe() {
  if (!pipe) return;
  pipe.dead = true;
  pipe.ctrl.abort();
  URL.revokeObjectURL(pipe.url);
  pipe = null;
}

function startMse(src, mime) {
  const ms = new MSE();
  const p = { dead: false, ctrl: new AbortController(), url: URL.createObjectURL(ms) };
  pipe = p;
  if (window.ManagedMediaSource && ms instanceof window.ManagedMediaSource) el.video.disableRemotePlayback = true;
  el.video.src = p.url;

  ms.addEventListener('sourceopen', async () => {
    let sb;
    try { sb = ms.addSourceBuffer(mime); } catch (err) { return pipeError(p, err); }
    const done = () => new Promise((r) => sb.addEventListener('updateend', r, { once: true }));
    const trim = async (keep) => {
      const b = el.video.buffered, t = el.video.currentTime;
      if (b.length && t - b.start(0) > keep + 5) { sb.remove(0, t - keep); await done(); }
    };
    const append = async (chunk) => {
      for (let attempt = 0; ; attempt++) {
        try { sb.appendBuffer(chunk); await done(); return; } catch (err) {
          if (err.name !== 'QuotaExceededError' || attempt > 20) throw err;
          await trim(5); // browser buffer full: drop more played video, or wait for playback to move on
          await sleep(500);
        }
      }
    };

    let res;
    try { res = await fetch(src, { signal: p.ctrl.signal }); } catch { return; }
    if (!res.ok) return pipeError(p, new Error(await res.text()));
    const reader = res.body.getReader();
    let first = true;
    try {
      while (!p.dead) {
        while (!p.dead && bufferedAhead() > AHEAD_MAX) await sleep(500);
        const { value, done: eof } = await reader.read();
        if (p.dead) return;
        if (eof) break;
        await trim(KEEP_BEHIND);
        await append(value);
        // Video may start slightly after 0 (keyframe); Safari stalls on a leading gap, so jump it.
        if (first && el.video.buffered.length) {
          first = false;
          if (el.video.currentTime < el.video.buffered.start(0)) el.video.currentTime = el.video.buffered.start(0);
        }
      }
      if (ms.readyState === 'open') ms.endOfStream();
    } catch (err) {
      if (!p.dead) pipeError(p, err);
    }
  }, { once: true });
}

// If playback is stuck right before a buffered range (a gap after a seek/restart), hop over it.
let lastT = -1, stuckFor = 0;
function nudgeGap() {
  const v = el.video;
  if (!game || !started || v.paused || v.seeking) { stuckFor = 0; return; }
  if (v.currentTime !== lastT) { lastT = v.currentTime; stuckFor = 0; return; }
  if (++stuckFor < 2) return;
  const b = v.buffered;
  for (let i = 0; i < b.length; i++) {
    if (b.start(i) > v.currentTime && b.start(i) - v.currentTime < 10) {
      v.currentTime = b.start(i) + 0.05;
      stuckFor = 0;
      return;
    }
  }
}
setInterval(nudgeGap, 500);

function pipeError(p, err) {
  if (p.dead) return;
  console.error('[player]', err);
  showMsg(`Playback failed: ${err.message || err}.<br>Use <b>Copy URL for VLC</b> to open it in VLC or IINA instead.`, { error: true });
}

// Safari (WebKit) stalls on the open-GOP I-frames these broadcasts use (at the start, after a seek,
// sometimes mid-stream), so Safari always gets a hardware re-encode with clean GOPs. Others get the original.
const IS_WEBKIT = /AppleWebKit/.test(navigator.userAgent) && !/Chrome|Chromium|Edg|OPR|Firefox/.test(navigator.userAgent);

function load(t) {
  offset = Math.max(0, duration ? Math.min(t, duration - 5) : t);
  stopPipe();
  const reencode = IS_WEBKIT;
  const src = streamUrl('play', `&t=${offset.toFixed(2)}${reencode ? '&reencode=1' : ''}`);
  const mime = reencode ? lastStatus?.mimeReencoded : lastStatus?.mime;
  if (MSE && mime && MSE.isTypeSupported(mime)) startMse(src, mime);
  else el.video.src = src; // no MediaSource (old iOS): let the browser try directly
  started = true;
  showMsg(`Buffering from ${fmt(offset)}…`);
  el.video.play().catch(() => { el.bigPlay.hidden = false; hideMsg(); });
  render();
}

function seek(t) {
  if (!game || !started) return;
  if (duration) t = Math.min(Math.max(0, t), duration - 1);
  const b = el.video.buffered;
  for (let i = 0; i < b.length; i++) {
    if (t >= offset + b.start(i) && t <= offset + b.end(i) - 0.5) {
      el.video.currentTime = t - offset;
      render();
      return;
    }
  }
  load(t);
}

function render() {
  const t = now();
  el.time.textContent = `${fmt(t)} / ${fmt(duration)}`;
  if (duration && !dragging) {
    const pct = Math.min(100, (t / duration) * 100);
    el.played.style.width = `${pct}%`;
    el.head.style.left = `${pct}%`;
  }
  el.play.textContent = el.video.paused ? '▶' : '❚❚';
}

function drawPieces(pieces) {
  const c = el.pieces;
  const w = c.clientWidth;
  if (!w || !pieces) return;
  c.width = w;
  const ctx = c.getContext('2d');
  ctx.clearRect(0, 0, w, 4);
  const step = w / pieces.length;
  pieces.forEach((v, i) => {
    if (!v) return;
    ctx.fillStyle = `rgba(60, 207, 126, ${0.35 + v * 0.65})`;
    ctx.fillRect(Math.floor(i * step), 0, Math.ceil(step), 4);
  });
}

async function pollStatus() {
  if (!game) return;
  const want = `${rel.id}/${fileIdx}`;
  const s = await api(streamUrl('status')).catch(() => null);
  if (!game || want !== `${rel.id}/${fileIdx}` || !s) return;
  lastStatus = s;
  renderPickers(s);
  if (!s.active) {
    if (s.error) { showMsg(`Couldn't start the torrent: ${s.error}`, { error: true }); return; }
    await api(streamUrl('start'), { method: 'POST' }); // dropped after idling; restart it
  } else if (s.stage === 'metadata' || (!started && !s.peers)) {
    const waited = (Date.now() - openedAt) / 1000;
    showMsg(waited > 45 && !s.peers
      ? `Still no peers after ${Math.round(waited)}s. This torrent may have no seeders left; you can keep waiting or try the Mega link.`
      : `Connecting to peers… <b>${s.peers}</b> found`);
    if (s.stage === 'metadata') return render();
  }
  if (s.active && s.stage === 'ready') {
    if (s.duration && !duration) duration = s.duration;
    if (!started && s.duration) {
      // Resume where you left off, if that was this release and file.
      const same = (game.watch_release ?? rel.id) === rel.id && (game.watch_file ?? 0) === fileIdx;
      const saved = same && game.watch_position > 30 && game.watch_position < s.duration - 60 ? game.watch_position : 0;
      const resumeAt = startAt ?? saved;
      startAt = null;
      load(resumeAt);
      if (resumeAt) {
        el.resume.hidden = false;
        el.resume.innerHTML = `Resumed at ${fmt(resumeAt)} <button data-restart>Start over</button>`;
        setTimeout(() => { el.resume.hidden = true; }, 8000);
      }
    }
    drawPieces(s.pieces);
    const audio = s.audio && s.audio !== 'aac' ? ` · audio ${s.audio.toUpperCase()} ${s.channels ?? ''}ch → stereo AAC in browser` : '';
    el.stats.innerHTML = `
      <span>Peers <b>${s.peers}</b></span>
      <span>↓ <b>${speed(s.down)}</b></span>
      <span>↑ <b>${speed(s.up)}</b></span>
      <span>Downloaded <b>${mb(s.downloaded)}</b> of ${mb(s.size)} (${(s.progress * 100).toFixed(1)}%)</span>
      <span class="legend"><i></i> on disk — instant to seek</span>
      <span>${s.video ? s.video.toUpperCase() : ''}${audio}</span>`;
    if (!el.msg.hidden && started && !el.msg.classList.contains('error') && el.video.readyState < 3) {
      showMsg(`Buffering ${fmt(now())}… ${speed(s.down)} from <b>${s.peers}</b> peers`);
    }
  }
  render();
}

// Source / part pickers: only shown when there's a choice.
function renderPickers(s) {
  const relOpts = releases.map((r) => `<option value="${r.id}" ${r.id === rel.id ? 'selected' : ''}>${escHtml(releaseLabel(r))}</option>`).join('');
  if (el.release.dataset.html !== relOpts) { el.release.innerHTML = relOpts; el.release.dataset.html = relOpts; }
  el.release.hidden = releases.length < 2;
  const files = s?.files ?? [];
  const partOpts = files.map((f) => `<option value="${f.index}" ${f.index === fileIdx ? 'selected' : ''}>${escHtml(partLabel(f, files.length))}</option>`).join('');
  if (el.part.dataset.html !== partOpts) { el.part.innerHTML = partOpts; el.part.dataset.html = partOpts; }
  el.part.hidden = files.length < 2;
}
const escHtml = (t) => String(t).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
function releaseLabel(r) {
  const res = r.resolution?.replace(/^1920x1080$/, '1080p').replace(/^1280x720$/, '720p');
  return [r.source_name, res].filter(Boolean).join(' · ');
}
function partLabel(f, n) {
  const name = f.name.replace(/\.[^.]+$/, '');
  return `Part ${f.index + 1} of ${n}${name.length < 60 ? ` — ${name}` : ''}`;
}

/** Switch to another release and/or file, starting at `t` (default: saved position or 0). */
function switchTo(nextRel, nextFile, t = null) {
  savePosition();
  stopPipe();
  el.video.pause();
  el.video.removeAttribute('src');
  el.video.load();
  rel = nextRel; fileIdx = nextFile; startAt = t;
  offset = 0; duration = null; started = false; lastStatus = null; openedAt = Date.now();
  el.pieces.getContext('2d').clearRect(0, 0, el.pieces.width, 4);
  showMsg('Connecting to peers…');
  render();
  api(streamUrl('start'), { method: 'POST' }).then(pollStatus);
}

export function openPlayer(g, { color, onClose } = {}) {
  game = { ...g };
  onCloseCb = onClose;
  releases = (g.releases ?? []).filter((r) => r.torrent_url);
  rel = releases.find((r) => r.id === g.watch_release) ?? releases[0];
  fileIdx = rel.id === g.watch_release ? (g.watch_file ?? 0) : 0;
  startAt = null;
  offset = 0; duration = g.duration || null; started = false; lastStatus = null; openedAt = Date.now();
  el.release.dataset.html = el.part.dataset.html = '';
  renderPickers(null);
  el.title.textContent = g.title;
  el.badge.textContent = g.league;
  el.badge.style.setProperty('--c', color ?? 'var(--accent)');
  el.stats.textContent = '';
  el.resume.hidden = true;
  el.bigPlay.hidden = true;
  el.pieces.getContext('2d').clearRect(0, 0, el.pieces.width, 4);
  el.root.hidden = false;
  document.body.style.overflow = 'hidden';
  showMsg('Fetching the .torrent and connecting to peers…');
  render();
  api(streamUrl('start'), { method: 'POST' }).then((s) => {
    if (s.error) showMsg(s.error, { error: true });
    pollStatus();
  });
  clearInterval(statusTimer);
  statusTimer = setInterval(pollStatus, 1000);
  clearInterval(saveTimer);
  saveTimer = setInterval(savePosition, 10000);
}

export function closePlayer() {
  if (!game) return;
  savePosition();
  clearInterval(statusTimer);
  clearInterval(saveTimer);
  el.video.pause();
  stopPipe(); // aborts the fetch, which stops ffmpeg on the server
  el.video.removeAttribute('src');
  el.video.load();
  exitFullscreen();
  clearTimeout(idleTimer);
  el.root.classList.remove('idle', 'fs');
  el.root.hidden = true;
  document.body.style.overflow = '';
  const g = game;
  game = null;
  onCloseCb?.(g);
}

// ---------- events ----------
const v = el.video;
v.addEventListener('timeupdate', render);
v.addEventListener('play', render);
v.addEventListener('pause', render);
v.addEventListener('playing', () => { hideMsg(); el.bigPlay.hidden = true; });
v.addEventListener('waiting', () => { if (game) showMsg(`Buffering ${fmt(now())}…`); });
v.addEventListener('canplay', hideMsg);
v.addEventListener('ended', () => {
  // The stream ends when the file does; if we're short of the end, it hiccupped — pick up again.
  if (duration && now() < duration - 10) return load(now());
  // Multi-part releases: go on to the next part.
  const files = lastStatus?.files ?? [];
  if (fileIdx + 1 < files.length) switchTo(rel, fileIdx + 1, 0);
});
el.release.addEventListener('change', () => {
  const next = releases.find((r) => r.id === Number(el.release.value));
  if (next && next !== rel) switchTo(next, 0, now()); // another copy of the same game: keep the time
});
el.part.addEventListener('change', () => {
  const next = Number(el.part.value);
  if (next !== fileIdx) switchTo(rel, next, 0);
});
v.addEventListener('error', () => {
  if (!game || !v.getAttribute('src')) return;
  showMsg(`The browser couldn't play this stream (${v.error?.message || 'decode error'}).<br>Use <b>Copy URL for VLC</b> and open it in VLC or IINA instead.`, { error: true });
});

const toggle = () => { if (!started) return; v.paused ? v.play() : v.pause(); };
el.play.addEventListener('click', toggle);
el.bigPlay.addEventListener('click', () => { v.play(); el.bigPlay.hidden = true; });
v.addEventListener('click', toggle);
v.addEventListener('dblclick', () => toggleFullscreen());
el.back.addEventListener('click', () => seek(now() - 10));
el.fwd.addEventListener('click', () => seek(now() + 30));
el.close.addEventListener('click', closePlayer);
el.resume.addEventListener('click', (e) => { if (e.target.closest('[data-restart]')) { el.resume.hidden = true; load(0); } });

el.mute.addEventListener('click', () => { v.muted = !v.muted; el.mute.textContent = v.muted ? '🔇' : '🔊'; });
el.vol.addEventListener('input', () => { v.volume = Number(el.vol.value); v.muted = v.volume === 0; el.mute.textContent = v.muted ? '🔇' : '🔊'; });
// Fullscreen: standard API, Safari's prefixed one, or (iPhone) the video's native fullscreen.
const fsElement = () => document.fullscreenElement || document.webkitFullscreenElement;
function exitFullscreen() {
  if (!fsElement()) return;
  (document.exitFullscreen || document.webkitExitFullscreen).call(document);
}
function toggleFullscreen() {
  if (fsElement()) return exitFullscreen();
  const r = el.box;
  if (r.requestFullscreen) r.requestFullscreen({ navigationUI: 'hide' }).catch(() => {});
  else if (r.webkitRequestFullscreen) r.webkitRequestFullscreen();
  else if (v.webkitEnterFullscreen) v.webkitEnterFullscreen();
}
const FS_ICON = {
  enter: '<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5"/></svg>',
  exit: '<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 4v5H4M15 4v5h5M9 20v-5H4M15 20v-5h5"/></svg>',
};
el.full.innerHTML = FS_ICON.enter;
function onFullscreenChange() {
  const on = !!fsElement();
  el.root.classList.toggle('fs', on);
  el.full.innerHTML = on ? FS_ICON.exit : FS_ICON.enter;
  el.full.setAttribute('aria-label', on ? 'Exit fullscreen (F)' : 'Fullscreen (F)');
  wake();
}
document.addEventListener('fullscreenchange', onFullscreenChange);
document.addEventListener('webkitfullscreenchange', onFullscreenChange);
el.full.addEventListener('click', toggleFullscreen);

// In fullscreen, hide the title bar, controls and cursor 3 s after the mouse stops (while playing).
let idleTimer = null;
function wake() {
  el.root.classList.remove('idle');
  clearTimeout(idleTimer);
  if (!fsElement()) return; // normal view: controls always visible
  idleTimer = setTimeout(() => {
    const overChrome = el.root.querySelector('.player-top:hover, .player-bottom:hover');
    if (game && !v.paused && !dragging && !overChrome) el.root.classList.add('idle');
    else if (game) wake();
  }, 3000);
}
el.root.addEventListener('pointermove', wake);
el.root.addEventListener('pointerdown', wake);
v.addEventListener('pause', wake);
v.addEventListener('play', wake);

el.copy.addEventListener('click', async () => {
  const url = `${location.origin}${streamUrl('raw')}`;
  try { await navigator.clipboard.writeText(url); } catch { prompt('Stream URL', url); return; }
  el.copy.textContent = 'Copied ✓';
  setTimeout(() => { el.copy.textContent = 'Copy URL for VLC'; }, 1800);
});

// Timeline: hover shows a time, click/drag seeks on release.
const timeAt = (e) => {
  const r = el.timeline.getBoundingClientRect();
  const x = Math.min(Math.max(0, e.clientX - r.left), r.width);
  return { t: duration ? (x / r.width) * duration : 0, pct: (x / r.width) * 100 };
};
el.timeline.addEventListener('pointermove', (e) => {
  if (!duration) return;
  const { t, pct } = timeAt(e);
  el.hover.hidden = false;
  el.hover.style.left = `${pct}%`;
  el.hover.textContent = fmt(t);
  if (dragging) { el.played.style.width = `${pct}%`; el.head.style.left = `${pct}%`; }
});
el.timeline.addEventListener('pointerleave', () => { if (!dragging) el.hover.hidden = true; });
el.timeline.addEventListener('pointerdown', (e) => {
  if (!duration) return;
  dragging = true;
  el.timeline.setPointerCapture(e.pointerId);
  const { pct } = timeAt(e);
  el.played.style.width = `${pct}%`;
  el.head.style.left = `${pct}%`;
});
el.timeline.addEventListener('pointerup', (e) => {
  if (!dragging) return;
  dragging = false;
  el.hover.hidden = true;
  seek(timeAt(e).t);
});

document.addEventListener('keydown', (e) => {
  if (!game || e.target.closest('input, select, textarea')) return;
  const keys = {
    ' ': toggle, k: toggle,
    ArrowLeft: () => seek(now() - 10), ArrowRight: () => seek(now() + 10),
    j: () => seek(now() - 30), l: () => seek(now() + 30),
    f: toggleFullscreen, m: () => el.mute.click(),
    Escape: () => { if (!fsElement()) closePlayer(); },
  };
  wake();
  const fn = keys[e.key];
  if (fn) { e.preventDefault(); fn(); }
});
window.addEventListener('resize', () => lastStatus?.pieces && drawPieces(lastStatus.pieces));
window.addEventListener('beforeunload', savePosition);
