// Self-update for the Mac app, which runs from its own clone of the repo. Nothing local is
// tracked by git any more (the library and media live in ~/.courtside), so updating is simply:
// fetch GitHub's main and match it exactly. GitHub always wins.

import { execFile } from 'node:child_process';
import { REPO_DIR as ROOT } from './paths.mjs';

const BRANCH = 'main';
const log = (msg) => console.log(`[git] ${msg}`);

function git(args, { timeout = 60000 } = {}) {
  return new Promise((resolve, reject) => {
    execFile('git', args, { cwd: ROOT, timeout, maxBuffer: 16 * 1024 * 1024, env: { ...process.env, GIT_TERMINAL_PROMPT: '0' } },
      (err, stdout, stderr) => {
        if (err) return reject(new Error(`git ${args[0]}: ${(stderr || err.message).trim()}`));
        resolve(stdout.trim());
      });
  });
}

let running = null;

/**
 * Match GitHub's main. Resolves to { changed: string[], depsChanged, from, to }; `changed` lists
 * files that differ, so the caller knows whether to restart.
 */
export function update() {
  running ??= (async () => {
    const from = await git(['rev-parse', 'HEAD']);
    await git(['fetch', '-q', 'origin', BRANCH], { timeout: 30000 });
    const to = await git(['rev-parse', `origin/${BRANCH}`]);
    // Discards local commits and edits to tracked files; ignored/untracked files are untouched.
    await git(['reset', '-q', '--hard', `origin/${BRANCH}`]);
    const changed = from === to ? [] : (await git(['diff', '--name-only', from, to])).split('\n').filter(Boolean);
    if (changed.length) log(`updated ${from.slice(0, 7)} → ${to.slice(0, 7)} (${changed.length} file${changed.length === 1 ? '' : 's'})`);
    return { changed, depsChanged: changed.some((f) => f === 'package.json' || f === 'package-lock.json'), from, to };
  })().finally(() => { running = null; });
  return running;
}

export const currentVersion = async () => {
  const [hash, date, subject] = (await git(['log', '-1', '--format=%h%x09%cI%x09%s'])).split('\t');
  return { hash, date, subject };
};
