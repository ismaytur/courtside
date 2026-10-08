// Torrent streaming. WebTorrent (in Node, so it can reach normal TCP/UDP peers) downloads a
// release, prioritising whatever byte range is being read. Per session (one release):
//   /api/stream/:id/raw?file=N   original file N with HTTP Range support (VLC, IINA, ffmpeg input)
//   /api/stream/:id/play?file=N&t=seconds
//                                fragmented MP4 for the browser: ffmpeg copies the video and converts
//                                audio to AAC (these releases use AC-3, which browsers can't decode).
// Torrents with several video files (Part 1 / Part 2, halves, quarters…) expose them as `files`
// in natural name order; samples and tiny files are skipped. All of them download in the
// background, the one being watched first.

import WebTorrent from 'webtorrent';
import parseTorrent from 'parse-torrent';
import { spawn, execFile } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { STREAMS_DIR, TORRENTS_DIR, ensureHome } from './paths.mjs';
import { loadSettings } from './settings.mjs';

const VIDEO_EXT = /\.(mkv|mp4|m4v|ts|avi|mov|webm)$/i;
const MIN_VIDEO_BYTES = 50e6;
const IDLE_MS = 3 * 60 * 1000;

/** Video files worth offering, in natural order ("Part 2" before "Part 10"). */
function videoFiles(files) {
  const byName = (a, b) => a.path.localeCompare(b.path, undefined, { numeric: true, sensitivity: 'base' });
  let vids = files.filter((f) => VIDEO_EXT.test(f.name) && f.length >= MIN_VIDEO_BYTES && !/\bsample\b/i.test(f.path));
  if (!vids.length) vids = files.filter((f) => VIDEO_EXT.test(f.name));
  if (!vids.length) vids = [files.reduce((a, b) => (a.length >= b.length ? a : b))];
  return vids.sort(byName);
}

// `port` is a function returning the server's port (it may be chosen at random).
export function createStreamer({ port }) {
  ensureHome();
  let client = null;
  const sessions = new Map(); // releaseId -> session
  const failures = new Map(); // releaseId -> last start error

  const uploadRate = () => {
    const kb = loadSettings().storage.uploadKBps;
    return kb > 0 ? kb * 1024 : -1;
  };
  const getClient = () => {
    if (!client) {
      client = new WebTorrent({ uploadLimit: uploadRate() });
      client.on('error', (err) => console.error('[torrent]', err.message));
    }
    return client;
  };
  /** Apply changed settings (upload cap, cache size) to the running client. */
  function applySettings() {
    client?.throttleUpload(uploadRate());
    enforceCache();
  }

  async function loadTorrentFile(release) {
    const file = path.join(TORRENTS_DIR, `${release.id}.torrent`);
    if (!fs.existsSync(file)) {
      const res = await fetch(release.torrent_url, { headers: { 'User-Agent': 'Mozilla/5.0' }, signal: AbortSignal.timeout(20000) });
      if (!res.ok) throw new Error(`Couldn't download the .torrent file (HTTP ${res.status})`);
      fs.writeFileSync(file, Buffer.from(await res.arrayBuffer()));
    }
    return parseTorrent(fs.readFileSync(file));
  }

  const ffprobe = (url) => new Promise((resolve) => {
    execFile('ffprobe', ['-v', 'error', '-rw_timeout', '60000000', '-show_entries',
      'format=duration:stream=index,codec_type,codec_name,channels,profile,level', '-of', 'json', url],
    { timeout: 90000 }, (err, stdout) => {
      if (err) return resolve(null);
      try { resolve(JSON.parse(stdout)); } catch { resolve(null); }
    });
  });

  function touch(s) { s.lastAccess = Date.now(); }

  // Reads duration + codecs of one file through our own /raw endpoint. With no peers yet this
  // times out, so a failed result is retried later instead of being kept.
  function runProbe(s, fileIdx) {
    const p = { at: Date.now(), result: null };
    s.probes[fileIdx] = p;
    p.promise = ffprobe(`http://127.0.0.1:${port()}/api/stream/${s.id}/raw?file=${fileIdx}`).then((out) => {
      const streams = out?.streams ?? [];
      const v = streams.find((x) => x.codec_type === 'video');
      const a = streams.find((x) => x.codec_type === 'audio');
      p.result = {
        duration: Number(out?.format?.duration) || null,
        video: v?.codec_name ?? null,
        audio: a?.codec_name ?? null,
        channels: a?.channels ?? null,
        mime: mseType(v, a),
        mimeReencoded: mseType({ codec_name: 'h264', profile: 'High', level: 42 }, a && { ...a, codec_name: 'aac', profile: 'LC' }),
      };
      return p.result;
    });
    return p.promise;
  }
  const probeOf = (s, i) => s.probes[i] ?? (runProbe(s, i), s.probes[i]);

  // MIME type of what /play emits, for MediaSource.addSourceBuffer() in the browser.
  function mseType(v, a) {
    if (!v) return null;
    let video;
    if (v.codec_name === 'h264') {
      const prof = { Baseline: '42E0', 'Constrained Baseline': '42E0', Main: '4D40', High: '6400', 'High 10': '6E00' }[v.profile] ?? '6400';
      video = `avc1.${prof}${Math.max(10, Number(v.level) || 40).toString(16).padStart(2, '0').toUpperCase()}`;
    } else if (v.codec_name === 'hevc') {
      video = `hvc1.${v.profile === 'Main 10' ? 2 : 1}.6.L${Number(v.level) || 120}.90`;
    } else {
      video = 'avc1.640028'; // re-encoded with libx264
    }
    const audio = !a ? null
      : a.codec_name === 'aac' && /HE-AACv2/.test(a.profile ?? '') ? 'mp4a.40.29'
        : a.codec_name === 'aac' && /HE/.test(a.profile ?? '') ? 'mp4a.40.5'
          : 'mp4a.40.2'; // AAC-LC (copied, or what we transcode to)
    return `video/mp4; codecs="${[video, audio].filter(Boolean).join(', ')}"`;
  }

  /** Start (or reuse) a session for a release. Resolves once the file list is known. */
  async function start(release) {
    let s = sessions.get(release.id);
    if (s) { touch(s); return s.ready; }
    failures.delete(release.id);
    s = { id: release.id, lastAccess: Date.now(), streams: 0, probes: [] };
    sessions.set(release.id, s);
    s.ready = (async () => {
      const parsed = await loadTorrentFile(release);
      const torrent = getClient().add(parsed, { path: path.join(STREAMS_DIR, String(release.id)), deselect: true });
      s.torrent = torrent;
      await new Promise((resolve, reject) => {
        if (torrent.ready) return resolve();
        torrent.once('ready', resolve);
        torrent.once('error', reject);
      });
      s.files = videoFiles(torrent.files);
      s.files.forEach((f) => f.select()); // background download; playback ranges still go first
      enforceCache();
      return s;
    })().catch((err) => {
      sessions.delete(release.id);
      s.torrent?.destroy();
      failures.set(release.id, err.message);
      throw err;
    });
    return s.ready;
  }

  function stop(id) {
    const s = sessions.get(id);
    if (!s) return;
    sessions.delete(id);
    s.torrent?.destroy(); // stops downloading and seeding; files stay in the media dir
  }

  /** Downloaded fraction per bucket, so the timeline can show what's already local. */
  function pieceMap(torrent, file, buckets = 120) {
    const first = file._startPiece, last = file._endPiece;
    const total = last - first + 1;
    const out = [];
    for (let b = 0; b < buckets; b++) {
      const from = first + Math.floor((b * total) / buckets);
      const to = Math.max(from + 1, first + Math.floor(((b + 1) * total) / buckets));
      let have = 0;
      for (let i = from; i < to; i++) if (torrent.bitfield.get(i)) have++;
      out.push(Math.round((have / (to - from)) * 100) / 100);
    }
    return out;
  }

  async function status(id, fileIdx = 0) {
    const s = sessions.get(id);
    if (!s) return { active: false, error: failures.get(id) ?? null };
    touch(s);
    if (!s.files) return { active: true, stage: 'metadata', peers: s.torrent?.numPeers ?? 0 };
    const t = s.torrent;
    const idx = Math.min(Math.max(0, fileIdx), s.files.length - 1);
    const file = s.files[idx];
    const probe = probeOf(s, idx);
    if (probe.result && !probe.result.video && Date.now() - probe.at > 15000) runProbe(s, idx);
    return {
      active: true,
      stage: 'ready',
      file: idx,
      files: s.files.map((f, i) => ({ index: i, name: f.name, size: f.length, progress: f.progress })),
      name: file.name,
      size: file.length,
      downloaded: file.downloaded,
      progress: file.progress,
      peers: t.numPeers,
      down: t.downloadSpeed,
      up: t.uploadSpeed,
      pieces: pieceMap(t, file),
      ...(await Promise.race([probe.promise, new Promise((r) => setTimeout(() => r({}), 50))])),
    };
  }

  const fileOf = (s, fileIdx) => s.files[Math.min(Math.max(0, Number(fileIdx) || 0), s.files.length - 1)];

  /** Original file bytes with Range support. */
  async function serveRaw(req, res, id, fileIdx) {
    const s = sessions.get(id);
    if (!s) { res.writeHead(404); return res.end('no active stream'); }
    await s.ready;
    touch(s);
    const file = fileOf(s, fileIdx);
    const size = file.length;
    const m = (req.headers.range || '').match(/bytes=(\d*)-(\d*)/);
    let start = 0, end = size - 1;
    if (m) {
      if (m[1]) start = Number(m[1]);
      if (m[2]) end = Math.min(Number(m[2]), size - 1);
      if (!m[1] && m[2]) { start = size - Number(m[2]); end = size - 1; }
      if (start > end || start >= size) {
        res.writeHead(416, { 'Content-Range': `bytes */${size}` });
        return res.end();
      }
    }
    res.writeHead(m ? 206 : 200, {
      'Content-Type': /\.mp4$/i.test(file.name) ? 'video/mp4' : 'video/x-matroska',
      'Content-Length': end - start + 1,
      'Accept-Ranges': 'bytes',
      ...(m ? { 'Content-Range': `bytes ${start}-${end}/${size}` } : {}),
      'Content-Disposition': `inline; filename="${encodeURIComponent(file.name)}"`,
    });
    if (req.method === 'HEAD') return res.end();
    s.streams++;
    const rs = file.createReadStream({ start, end });
    rs.on('error', () => {}); // the reader hanging up early (seek, ffprobe) is normal
    rs.pipe(res);
    const done = () => { s.streams--; touch(s); rs.destroy(); };
    res.on('close', done);
  }

  /** Browser-friendly fragmented MP4 starting at ?t=seconds. */
  // Hardware H.264 encoder if this ffmpeg has one (macOS), else x264.
  let hwEncoder = null;
  execFile('ffmpeg', ['-hide_banner', '-encoders'], (err, out) => { hwEncoder = !err && /h264_videotoolbox/.test(out); });

  // `reencode`: Safari's decoder stalls on the open-GOP I-frames these broadcasts use, so for
  // Safari the video is re-encoded (cheap in hardware) into clean GOPs starting on an IDR frame.
  async function servePlay(req, res, id, t, { reencode = false, file: fileIdx = 0 } = {}) {
    const s = sessions.get(id);
    if (!s) { res.writeHead(404); return res.end('no active stream'); }
    await s.ready;
    const idx = s.files.indexOf(fileOf(s, fileIdx));
    let probe = await probeOf(s, idx).promise;
    if (!probe?.video) probe = await runProbe(s, idx);
    touch(s);
    if (!probe?.video) {
      res.writeHead(503, { 'Content-Type': 'text/plain' });
      return res.end('Not enough of the file has downloaded yet to read it (no peers?)');
    }
    const vcopy = ['h264', 'hevc'].includes(probe?.video) && !reencode;
    const acopy = probe?.audio === 'aac';
    // Bitrate follows the source: re-encoding can't add detail, and every extra Mbps fills the
    // browser's MSE buffer (WebKit's is small) faster. +15% covers generation loss; 3–8 Mbps is
    // the sane range for 1080p sports in H.264.
    const srcBps = probe.duration ? (s.files[idx].length * 8) / probe.duration - 192e3 : 0; // minus ~audio
    const vbps = Math.round(Math.min(8e6, Math.max(3e6, srcBps * 1.15 || 6e6)));
    const cap = ['-maxrate', String(Math.round(vbps * 1.4)), '-bufsize', String(vbps * 2)];
    const encode = hwEncoder
      ? ['-c:v', 'h264_videotoolbox', '-a53cc', '0', '-profile:v', 'high', '-level', '4.2', '-b:v', String(vbps), ...cap, '-g', '120', '-realtime', '1']
      : ['-c:v', 'libx264', '-a53cc', '0', '-preset', 'veryfast', '-crf', '20', ...cap, '-profile:v', 'high', '-level', '4.2', '-g', '120'];
    const args = ['-hide_banner', '-loglevel', 'error', '-nostdin',
      ...(!vcopy && hwEncoder ? ['-hwaccel', 'videotoolbox'] : []),
      ...(t > 0 ? ['-ss', String(t)] : []),
      '-rw_timeout', '120000000',
      '-i', `http://127.0.0.1:${port()}/api/stream/${id}/raw?file=${idx}`,
      '-map', '0:v:0', '-map', '0:a:0?',
      ...(vcopy ? ['-c:v', 'copy'] : [...encode, '-pix_fmt', 'yuv420p']),
      ...(vcopy && probe?.video === 'hevc' ? ['-tag:v', 'hvc1'] : []),
      ...(acopy ? ['-c:a', 'copy'] : ['-c:a', 'aac', '-ac', '2', '-b:a', '192k']),
      '-avoid_negative_ts', 'make_zero',
      '-movflags', 'frag_keyframe+empty_moov+default_base_moof',
      '-f', 'mp4', 'pipe:1'];
    const ff = spawn('ffmpeg', args, { stdio: ['ignore', 'pipe', 'pipe'] });
    let stderr = '';
    ff.stderr.on('data', (d) => { stderr = (stderr + d).slice(-2000); });
    ff.on('error', (err) => { if (!res.headersSent) { res.writeHead(500); res.end(`ffmpeg failed: ${err.message}`); } });
    ff.on('close', (code) => { if (code && code !== 255 && stderr) console.error('[ffmpeg]', stderr.trim()); });
    res.writeHead(200, { 'Content-Type': 'video/mp4', 'Cache-Control': 'no-store' });
    s.streams++;
    ff.stdout.on('error', () => {});
    ff.stdout.pipe(res);
    res.on('close', () => { s.streams--; touch(s); ff.kill('SIGKILL'); });
  }

  // Drop sessions nobody has looked at for a while (stops seeding).
  setInterval(() => {
    for (const [id, s] of sessions) if (!s.streams && Date.now() - s.lastAccess > IDLE_MS) stop(id);
  }, 30000).unref();

  // Keep the streams folder under the cache limit by deleting the least recently used releases.
  function cacheEntries() {
    return fs.readdirSync(STREAMS_DIR, { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => {
      const dir = path.join(STREAMS_DIR, d.name);
      let size = 0, mtime = 0;
      const walk = (p) => {
        for (const e of fs.readdirSync(p, { withFileTypes: true })) {
          const f = path.join(p, e.name);
          if (e.isDirectory()) walk(f);
          else { const st = fs.statSync(f); size += st.blocks * 512; mtime = Math.max(mtime, st.mtimeMs); }
        }
      };
      walk(dir);
      return { id: Number(d.name), dir, size, mtime };
    });
  }

  function enforceCache() {
    const limit = loadSettings().storage.cacheGB * 1e9;
    const dirs = cacheEntries();
    let total = dirs.reduce((a, d) => a + d.size, 0);
    for (const d of dirs.sort((a, b) => a.mtime - b.mtime)) {
      if (total <= limit) break;
      if (sessions.has(d.id)) continue;
      fs.rmSync(d.dir, { recursive: true, force: true });
      total -= d.size;
      console.log(`[cache] removed release ${d.id} (${(d.size / 1e9).toFixed(1)} GB)`);
    }
  }

  /** Size of the video cache, for the settings popup. */
  function usage() {
    const dirs = cacheEntries();
    return { bytes: dirs.reduce((a, d) => a + d.size, 0), releases: dirs.length };
  }

  /** Delete cached videos and .torrent files (all of them, or only these release ids). */
  function clearCache(ids = null) {
    const targets = ids ?? [...new Set([...cacheEntries().map((d) => d.id), ...sessions.keys()])];
    for (const id of targets) {
      stop(id);
      fs.rmSync(path.join(STREAMS_DIR, String(id)), { recursive: true, force: true });
      fs.rmSync(path.join(TORRENTS_DIR, `${id}.torrent`), { force: true });
    }
    if (!ids) for (const f of fs.readdirSync(TORRENTS_DIR)) fs.rmSync(path.join(TORRENTS_DIR, f), { force: true });
  }

  return {
    start, stop, status, serveRaw, servePlay, applySettings, usage, clearCache,
    isActive: (id) => sessions.has(id), activeCount: () => sessions.size,
  };
}
