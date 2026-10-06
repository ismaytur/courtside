// Registered sources. A source is a module whose default export has:
//
//   id          stable identifier, stored with every release (e.g. 'sport-video')
//   name        shown in settings and logs
//   homepage    link shown in settings
//   imageHosts  hostnames whose images the server may fetch and cache for posters
//   listPage(n)    -> { label, entries } for listing page n (0 = newest first), or null at the end
//   resolve(entry) -> extra fields for one entry (e.g. from its detail page), or {}
//
// An entry is { source_key, raw_title, detail_url?, torrent_url?, mega_url?, other_url?,
// image_url?, video_info?, resolution?, language? }. raw_title should contain the teams and the
// date ("Team A at Team B 04.10.2026"); lib/classify.mjs turns it into league/season/teams.
// source_key must be unique and stable within the source.
//
// To add a source: create lib/sources/<id>.mjs, add it below, and add "<id>": true under
// "sources" in config.defaults.json.

import sportVideo from './sport-video.mjs';

export const SOURCES = [sportVideo];

export const getSource = (id) => SOURCES.find((s) => s.id === id);
export const imageHosts = () => SOURCES.flatMap((s) => s.imageHosts ?? []);
