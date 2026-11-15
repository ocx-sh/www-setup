#!/usr/bin/env node
/**
 * `task site:lighthouse`: every HTML page of the built site, served by `astro preview` under the
 * base path, audited by Lighthouse (mobile) in Playwright's Chromium. Each run is judged alone and a
 * page passes on its first passing run of at most `RETRY_RUNS` (timing noise, not the page, flaps a
 * score); a page that never passes is reported with its run of fewest failures. Judged by lhci's
 * assertion engine: score 1 in all four categories plus the budgets in
 * `lighthouse.budgets.mjs`, and the HTML gzip cap. Trimmed from ocx-sh/website
 * `scripts/lighthouse.mjs`; ponytail: sequential and uncached (about 6 pages), add lanes and a
 * result cache when the page count makes CI slow. `--list` prints the pages and exits.
 */
import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire, Module } from 'node:module';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { gzipSync } from 'node:zlib';
import { assertMatrix, BASE, castPages, HTML_GZ_MAX, sitePages } from '../lighthouse.budgets.mjs';

const require = createRequire(import.meta.url);
const ROOT = fileURLToPath(new URL('..', import.meta.url));
// A free port per run: a stale preview of another site must not answer for this one.
const PORT = await new Promise((res) => {
  const srv = createServer().listen(0, () => {
    const { port } = /** @type {import('node:net').AddressInfo} */ (srv.address());
    srv.close(() => res(port));
  });
});
/** Runs a page gets in total; it passes on the first one that passes. */
export const RETRY_RUNS = 3;

/**
 * Run until one passes or `max` runs are used. `best` is the passing run, else the one with the
 * fewest failures.
 * @template R
 * @param {() => Promise<R>} run
 * @param {(r: R) => unknown[]} judge failed assertions of one run
 */
export async function bestOf(run, judge, max = RETRY_RUNS) {
  const runs = /** @type {{ r: R, failed: unknown[] }[]} */ ([]);
  while (runs.length < max) {
    const r = await run();
    runs.push({ r, failed: judge(r) });
    if (!runs[runs.length - 1].failed.length) break;
  }
  const best = runs.reduce((a, b) => (b.failed.length < a.failed.length ? b : a));
  return { runs: runs.map((x) => x.r), best: best.r, failed: best.failed };
}

const METRICS = ['first-contentful-paint', 'largest-contentful-paint', 'total-blocking-time', 'cumulative-layout-shift', 'speed-index'];

/** One failure line; a category score names the category and the run's paint metrics. */
export function failureLine(/** @type {string} */ p, /** @type {any} */ a, /** @type {any} */ lhr) {
  const line = `${p}: ${a.auditId} ${a.name} ${a.actual} (want ${a.operator} ${a.expected})`;
  if (a.auditId !== 'categories') return line;
  const m = METRICS.map((id) => `${id} ${lhr.audits?.[id]?.displayValue ?? '-'}`).join(', ');
  return `${p}: category ${a.auditProperty} ${a.name} ${a.actual} (want ${a.operator} ${a.expected}); ${m}`;
}

/** Gzipped size of every page's HTML above `HTML_GZ_MAX`, as failure lines. */
export function htmlFailures(/** @type {string[]} */ pages, distDir = join(ROOT, 'dist')) {
  return pages.flatMap((p) => {
    const file = join(distDir, p.slice(BASE.length), p.endsWith('/') ? 'index.html' : '');
    const size = gzipSync(readFileSync(file)).length;
    return size > HTML_GZ_MAX ? [`${p}: html gzip ${size} B (want <= ${HTML_GZ_MAX})`] : [];
  });
}

async function main() {
  const pages = sitePages(join(ROOT, 'dist'));
  if (process.argv.includes('--list')) return console.log(pages.join('\n'));

  // chrome-launcher's WSL branch hands this Linux Chrome a Windows profile path (a literal
  // `\\wsl.localhost\…` directory in the cwd): pin its `is-wsl` to false before it loads.
  const isWsl = createRequire(require.resolve('chrome-launcher')).resolve('is-wsl');
  require.cache[isWsl] = Object.assign(new Module(isWsl), { filename: isWsl, loaded: true, exports: false });
  const { default: lighthouse } = await import('lighthouse');
  const { launch } = await import('chrome-launcher');
  const { chromium } = require('playwright-core');
  const lhci = require.resolve('@lhci/utils/src/assertions.js', { paths: [require.resolve('@lhci/cli/package.json')] });
  const { getAllAssertionResults } = require(lhci);
  const judge = (/** @type {{ lhr: object }} */ r) =>
    getAllAssertionResults({ assertMatrix: assertMatrix(castPages(join(ROOT, 'dist'))) }, [r.lhr]);

  const preview = spawn('pnpm', ['exec', 'astro', 'preview', '--ignore-lock', '--port', String(PORT)], { cwd: ROOT, stdio: 'ignore', detached: true });
  const reports = join(ROOT, '.lighthouseci');
  rmSync(reports, { recursive: true, force: true });
  mkdirSync(reports, { recursive: true });
  const chrome = await launch({
    chromePath: process.env.CHROME_PATH || chromium.executablePath(),
    chromeFlags: ['--headless=new', '--no-sandbox'],
  });
  const failures = htmlFailures(pages);
  try {
    for (let i = 0; i < 50; i++) {
      if (await fetch(`http://localhost:${PORT}${BASE}`).then((r) => r.ok, () => false)) break;
      await new Promise((r) => setTimeout(r, 200));
    }
    const once = async (/** @type {string} */ p) => {
      const r = await lighthouse(`http://localhost:${PORT}${p}`, { port: chrome.port, output: 'json', logLevel: 'error' });
      if (!r) throw new Error('Lighthouse returned no result');
      return r;
    };
    for (const p of pages) {
      const { runs, best, failed } = await bestOf(() => once(p), judge);
      runs.forEach((r, i) => writeFileSync(join(reports, `${p.replace(/\W+/g, '_')}-${i + 1}.json`), JSON.stringify(r.lhr)));
      console.log(`${failed.length ? 'FAIL' : 'pass'} ${p} (${runs.length} run(s))`);
      for (const a of failed) failures.push(failureLine(p, a, best.lhr));
    }
  } finally {
    chrome.kill();
    // pnpm wraps node: kill the whole group or the server outlives the run.
    try { if (preview.pid) process.kill(-preview.pid); } catch {} // already gone
  }
  if (failures.length) {
    console.error(`\n${failures.length} failure(s):\n${failures.map((f) => `  ${f}`).join('\n')}`);
    process.exitCode = 1;
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((err) => {
    console.error(`lighthouse: FAILED - ${err instanceof Error ? (err.stack ?? err.message) : String(err)}`);
    process.exitCode = 1;
  });
}
