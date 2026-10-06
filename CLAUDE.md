# Courtside: notes for working on this repo

Local basketball game library: Node server (`server.mjs`, `lib/`) + vanilla JS UI (`public/`) +
a Swift wrapper (`mac/`) that runs it as a self-updating Mac app. No framework, no build step,
one dependency (webtorrent). Read these before larger changes:

- [docs/architecture.md](docs/architecture.md): components, data model, fetch flow, API, streaming, Mac app
- [docs/adding-a-source.md](docs/adding-a-source.md): how to add a site to fetch from
- [docs/development.md](docs/development.md): workflow, testing recipes, common changes, gotchas

## Ground rules

- **User data never goes in git.** Library, settings, posters and media live in `~/.courtside`
  (`lib/paths.mjs`). `data/` is ignored legacy.
- **Don't touch the real `~/.courtside` when testing.** Use `COURTSIDE_HOME=/tmp/… PORT=… npm start`.
  Don't delete or rewrite the user's data without asking.
- **Pushing to `main` deploys** to the user's Mac app (it pulls on launch and every 30 min and
  `git reset --hard`s to GitHub). Commit/push only when asked. Swift changes also need
  `npm run build:app`.
- **Schema**: additive changes only. No migration code; a breaking change means a fresh
  library (the user is fine re-fetching). `openDb` sets unknown layouts aside.
- **Sources** are plugins in `lib/sources/`; the fetch engine, classification and game matching
  are shared. Titles must look like `Away at Home dd.mm.yyyy`.
- **Playback**: test Safari/WebKit separately (Playwright WebKit); it needs the MSE pipeline and
  the hardware re-encode path. Chrome hides WebKit-only bugs.
- Match the existing style: plain ES modules, small functions, comments that explain why,
  `esc()` for anything put into HTML.

## Commands

```bash
npm start                 # server on :4321 using ~/.courtside
npm run build:app         # dist/Courtside.app (APP_OUT=… to build elsewhere)
npm run prune [-- --yes]  # remove games of ignored leagues
```
