// Poster cache: images from source sites are fetched once and kept in ~/.courtside/img,
// named <host>-<file> so two sources can't collide.

import fs from 'node:fs';
import path from 'node:path';
import { IMG_DIR, REPO_DIR } from './paths.mjs';
import { imageHosts } from './sources/index.mjs';

export function imageCacheFile(u) {
  let url;
  try { url = new URL(u); } catch { return null; }
  if (!imageHosts().includes(url.hostname) || !/\.(jpe?g|png|webp)$/i.test(url.pathname)) return null;
  return path.join(IMG_DIR, `${url.hostname}-${path.basename(url.pathname)}`.replace(/[^\w.-]/g, '_'));
}

// Posters used to be cached (and committed) in the repo's data/img.
export function migrateRepoImages() {
  const old = path.join(REPO_DIR, 'data', 'img');
  if (!fs.existsSync(old)) return;
  for (const name of fs.readdirSync(old)) {
    const target = path.join(IMG_DIR, `www.sport-video.org.ua-${name}`);
    if (!fs.existsSync(target)) fs.copyFileSync(path.join(old, name), target);
  }
}
