// Poster cache: images from source sites are fetched once and kept in ~/.courtside/img,
// named <host>-<file> so two sources can't collide.

import path from 'node:path';
import { IMG_DIR } from './paths.mjs';
import { imageHosts } from './sources/index.mjs';

export function imageCacheFile(u) {
  let url;
  try { url = new URL(u); } catch { return null; }
  if (!imageHosts().includes(url.hostname) || !/\.(jpe?g|png|webp)$/i.test(url.pathname)) return null;
  return path.join(IMG_DIR, `${url.hostname}-${path.basename(url.pathname)}`.replace(/[^\w.-]/g, '_'));
}
