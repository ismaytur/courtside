// Git plumbing for the Mac app, which runs from its own clone of the repo:
//   - commitData(): commit data/games.db and data/img (new games, favorites, watch positions)
//   - push(): push main to GitHub
//   - update(): bring the clone up to GitHub's main. Local data commits are replayed on top
//     when possible; if they can't be, GitHub wins and they're dropped.
// Every git command goes through one queue, so commits, pushes and updates never overlap.

import { execFile } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const DATA_PATHS = ['data/games.db', 'data/img'];
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

let queue = Promise.resolve();
/** Run fn after every earlier git job; errors are logged, not thrown, unless `rethrow`. */
function serial(fn, { rethrow = false } = {}) {
  const job = queue.then(fn);
  queue = job.catch((err) => log(err.message));
  return rethrow ? job : job.catch(() => null);
}

const head = () => git(['rev-parse', 'HEAD']);
const count = async (range) => Number(await git(['rev-list', '--count', range]));

async function commitDataNow(message) {
  const changes = await git(['status', '--porcelain', '--', ...DATA_PATHS]);
  if (!changes) return false;
  await git(['add', '-A', '--', ...DATA_PATHS]);
  await git(['commit', '--no-verify', '-q', '-m', message, '--', ...DATA_PATHS]);
  log(`committed: ${message}`);
  return true;
}

async function pushNow() {
  if (!(await count(`origin/${BRANCH}..HEAD`))) return false;
  await git(['push', '-q', 'origin', `HEAD:${BRANCH}`], { timeout: 60000 });
  log('pushed to GitHub');
  return true;
}

export const commitData = (message) => serial(() => commitDataNow(message));
export const push = () => serial(() => pushNow());
export const commitAndPush = (message) => serial(async () => {
  await commitDataNow(message);
  await pushNow();
});

/**
 * Save local data, then match GitHub's main.
 * Resolves to { changed: string[] } listing files that changed apart from our own data commit
 * (code updates, or a database replaced because GitHub won), plus `depsChanged`.
 */
export const update = () => serial(async () => {
  await commitDataNow('Save local changes');
  // This clone isn't for development: drop stray edits to tracked files outside data/
  // (data/ was just committed, and the server may have the database open).
  await git(['reset', '-q']);
  await git(['checkout', '-q', '--', '.', ':(exclude)data']);
  const base = await head();

  await git(['fetch', '-q', 'origin', BRANCH], { timeout: 30000 });
  const ahead = await count(`origin/${BRANCH}..HEAD`);
  const behind = await count(`HEAD..origin/${BRANCH}`);
  if (behind && !ahead) {
    await git(['merge', '-q', '--ff-only', `origin/${BRANCH}`]);
    log(`updated to GitHub (${behind} new commit${behind === 1 ? '' : 's'})`);
  } else if (behind && ahead) {
    try {
      await git(['rebase', '-q', `origin/${BRANCH}`]);
      log(`updated to GitHub and replayed ${ahead} local commit${ahead === 1 ? '' : 's'} on top`);
    } catch {
      await git(['rebase', '--abort']).catch(() => {});
      await git(['reset', '-q', '--hard', `origin/${BRANCH}`]);
      log(`local commits conflicted with GitHub; GitHub wins (${ahead} local commit${ahead === 1 ? '' : 's'} dropped)`);
    }
  }
  try { await pushNow(); } catch (err) { log(`push failed, will retry later: ${err.message}`); }

  const changed = (await git(['diff', '--name-only', base, 'HEAD'])).split('\n').filter(Boolean)
    .filter((f) => !f.startsWith('data/img/'));
  return { changed, depsChanged: changed.some((f) => f === 'package.json' || f === 'package-lock.json') };
}, { rethrow: true });

export const currentVersion = () => git(['rev-parse', '--short', 'HEAD']);
