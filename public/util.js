export const $ = (s) => document.querySelector(s);
export const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

export async function api(path, opts) {
  const r = await fetch(path, opts);
  const body = await r.json();
  if (!r.ok && r.status !== 409) throw new Error(body.error || r.statusText);
  return body;
}
export const send = (path, method, body) =>
  api(path, { method, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body ?? {}) });

export function timeAgo(iso) {
  if (!iso) return 'never';
  const s = (Date.now() - new Date(iso)) / 1000;
  if (s < 60) return 'just now';
  if (s < 3600) return `${Math.round(s / 60)} min ago`;
  if (s < 86400) return `${Math.round(s / 3600)} h ago`;
  return `${Math.round(s / 86400)} d ago`;
}

export const fmtBytes = (b) => b >= 1e9 ? `${(b / 1e9).toFixed(1)} GB` : b >= 1e6 ? `${Math.round(b / 1e6)} MB` : `${Math.round((b || 0) / 1e3)} KB`;

const LEAGUE_COLOR = {
  NBA: 'var(--nba)', WNBA: 'var(--wnba)', EuroLeague: 'var(--euroleague)',
  NCAA: 'var(--ncaa)', International: 'var(--international)', Other: 'var(--other)',
};
export const color = (league) => LEAGUE_COLOR[league] ?? 'var(--other)';
