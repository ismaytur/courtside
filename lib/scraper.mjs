// Fetching + parsing sport-video.org.ua. The site is a WYSIWYG-builder export in
// windows-1251 with three kinds of listing entries:
//   1. title + "./SLUG.html" detail page (which holds the .torrent + Mega links)
//   2. title + inline "TORRENT" link
//   3. title + inline "FILESHARING" (Mega, sometimes a forum post) link

import { decodeEntities } from './classify.mjs';

export const BASE = 'https://www.sport-video.org.ua/';
const UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0 Safari/537.36';
const NAV = /^\.?\/?(basketball\d*|index|schedule|americanfootball|baseball|football|icehockey|hockey|rugby|other|filesharing|feedback_en)\.(html|php)$/i;
const DATE = /\d{1,2}\.\d{1,2}\.\d{2,4}/;
const decoder = new TextDecoder('windows-1251');

export const listPageUrl = (n) => `${BASE}basketball${n === 0 ? '' : n}.html`;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** GET a page; returns { status, html } (html is null on 404). Retries transient failures. */
export async function fetchPage(url, { retries = 2 } = {}) {
  for (let attempt = 0; ; attempt++) {
    try {
      const res = await fetch(url, { headers: { 'User-Agent': UA }, signal: AbortSignal.timeout(25000) });
      if (res.status === 404) return { status: 404, html: null };
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      return { status: res.status, html: decoder.decode(await res.arrayBuffer()) };
    } catch (err) {
      if (attempt >= retries) throw new Error(`${url}: ${err.message}`);
      await sleep(800 * (attempt + 1));
    }
  }
}

const abs = (href) => new URL(decodeEntities(href), BASE).href;

/** Parse a listing page into ordered entries. */
export function parseListing(html) {
  const body = html.slice(Math.max(0, html.indexOf('<body')));
  const re = /<strong>([\s\S]*?)<\/strong>|<a\s[^>]*?href="([^"]*)"|<img[^>]*?src="(images\/[^"]+?\.jpe?g)"/gi;
  const out = [];
  let cur = null, m;
  const flush = () => {
    if (cur && (cur.detail_url || cur.torrent_url || cur.mega_url || cur.other_url)) out.push(cur);
    cur = null;
  };
  while ((m = re.exec(body))) {
    let href = m[2];
    if (m[1] !== undefined) {
      const link = m[1].match(/href="([^"]*)"/);
      if (link) href = link[1];
      else {
        const text = decodeEntities(m[1].replace(/<[^>]+>/g, '')).replace(/\s+/g, ' ').trim();
        if (text && DATE.test(text)) { flush(); cur = { raw_title: text }; }
        continue; // labels like "GAME1", headings without a date
      }
    }
    if (!cur) continue;
    if (m[3]) { cur.image_url ??= abs(m[3]); continue; }
    if (!href || href === '#' || NAV.test(href) || /^javascript:/i.test(href)) continue;
    if (/\.torrent$/i.test(href)) cur.torrent_url ??= abs(href);
    else if (/mega\.nz/i.test(href)) cur.mega_url ??= href;
    else if (/^\.?\/?[\w-]+\.html$/i.test(href)) cur.detail_url ??= abs(href);
    else if (/^https?:/i.test(href)) cur.other_url ??= href;
  }
  flush();
  for (const e of out) {
    // Stable identity used to decide "do I already have this game?"
    e.source_key = e.detail_url || e.torrent_url || e.mega_url || `${e.other_url}#${e.raw_title}`;
  }
  return out;
}

/** Parse a game detail page (./SLUG.html). */
export function parseDetail(html) {
  const body = html.slice(Math.max(0, html.indexOf('<body')));
  const href = (re) => body.match(re)?.[1];
  const torrent = href(/href="([^"]+?\.torrent)"/i);
  const image = href(/src="(images\/(?!img\d)[^"]+?\.jpe?g)"/i);
  const cells = [...body.matchAll(/<td[^>]*>([\s\S]*?)<\/td>/gi)]
    .map((c) => decodeEntities(c[1].replace(/<[^>]+>/g, '')).replace(/\s+/g, ' ').trim());
  const spec = (label) => {
    const i = cells.findIndex((c) => c.replace(/\s/g, '').toLowerCase() === label);
    return i >= 0 && cells[i + 1] ? cells[i + 1] : null;
  };
  return {
    torrent_url: torrent ? abs(torrent) : null,
    mega_url: href(/href="(https?:\/\/mega\.nz\/[^"]+)"/i) ?? null,
    image_url: image ? abs(image) : null,
    video_info: spec('video'),
    resolution: spec('aspectratio'),
    language: spec('language'),
  };
}
