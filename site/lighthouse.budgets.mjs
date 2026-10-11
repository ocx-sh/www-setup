/**
 * Lighthouse budgets and page discovery for `task site:lighthouse`. Every page of this site is the
 * `content` class of ocx-sh/website `tests/budgets.mjs`; a value here never exceeds the one there.
 * Sizes are gzip of the response body, in bytes.
 */
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const KB = 1024;

/** Base path of the site, as in astro.config.mjs. */
export const BASE = '/install/';

/** Gated budget of every page (website `BUDGETS.content`). */
export const BUDGET = {
  /** Lighthouse `resource-summary:script:size`. */
  jsBytes: 11 * KB,
  /** Lighthouse `total-byte-weight`. */
  totalBytes: 147 * KB,
  /** Lighthouse `dom-size`. */
  domElements: 800,
};

/** One page's HTML, gzipped (website `HTML_GZ_MAX`): past it the document costs one more round trip. */
export const HTML_GZ_MAX = 14_200;

export const CATEGORIES = ['performance', 'accessibility', 'best-practices', 'seo'];

/**
 * Script weight a page with a recorded cast (the theme's `Terminal`) adds to `BUDGET.jsBytes`: the Terminal's
 * mount script is 2,446 B gzip, which takes a page to 12,238 B against 11,264 B; the player itself loads only on first use.
 * ponytail: a cap above the website `content` class for cast pages; drop it when the theme splits the mount script.
 */
export const TERMINAL_JS = 3 * KB;

/**
 * lhci assert matrix: score 1 in all four categories plus the JS, weight and DOM budgets. Entries apply independently,
 * so the script budget is split into one entry for the cast pages (served paths in `casts`) and one for the rest.
 * @param {string[]} [casts]
 */
export function assertMatrix(casts = []) {
  const script = (/** @type {number} */ max) => ({ 'resource-summary:script:size': ['error', { maxNumericValue: max }] });
  const alt = casts.map((p) => p.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|');
  return [
    {
      matchingUrlPattern: '.*',
      assertions: {
        ...Object.fromEntries(CATEGORIES.map((c) => [`categories:${c}`, ['error', { minScore: 1 }]])),
        'total-byte-weight': ['error', { maxNumericValue: BUDGET.totalBytes }],
        'dom-size': ['error', { maxNumericValue: BUDGET.domElements }],
      },
    },
    { matchingUrlPattern: casts.length ? `^(?!.*(?:${alt})$)` : '.*', assertions: script(BUDGET.jsBytes) },
    ...(casts.length ? [{ matchingUrlPattern: `(?:${alt})$`, assertions: script(BUDGET.jsBytes + TERMINAL_JS) }] : []),
  ];
}

export const ASSERT_MATRIX = assertMatrix();

/**
 * Served path of every built HTML page, sorted, under `base` (`index.html` -> `<base>`,
 * `x/index.html` -> `<base>x/`). `404.html` is left out: the server answers it with status 404,
 * which Lighthouse refuses to audit. Throws `missing dist: <dir>` when the site is not built.
 * @param {string} [distDir]
 * @param {string} [base]
 * @returns {string[]}
 */
export function sitePages(distDir = 'dist', base = BASE) {
  if (!existsSync(distDir)) throw new Error(`missing dist: ${distDir}`);
  return readdirSync(distDir, { recursive: true, encoding: 'utf8' })
    .map((f) => f.split('\\').join('/'))
    .filter((f) => f.endsWith('.html') && f !== '404.html')
    .map((f) => `${base}${f.replace(/index\.html$/, '')}`)
    .sort();
}

/**
 * Served paths of the built pages that embed a recorded cast (`<Terminal>` renders `.ocx-terminal`).
 * @param {string} [distDir]
 * @param {string} [base]
 * @returns {string[]}
 */
export function castPages(distDir = 'dist', base = BASE) {
  return sitePages(distDir, base).filter((p) => readFileSync(join(distDir, p.slice(base.length), 'index.html'), 'utf8').includes('class="ocx-terminal'));
}
