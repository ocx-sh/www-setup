// Offline: budgets never exceed the website's `content` class; page discovery and the HTML cap.
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { ASSERT_MATRIX, assertMatrix, BASE, BUDGET, CATEGORIES, HTML_GZ_MAX, TERMINAL_JS, castPages, sitePages } from '../lighthouse.budgets.mjs';
import { htmlFailures } from './lighthouse.mjs';

const KB = 1024;
test('budgets stay within the website content class', () => {
  assert.ok(BUDGET.jsBytes <= 11 * KB && BUDGET.totalBytes <= 147 * KB && BUDGET.domElements <= 800);
  assert.ok(HTML_GZ_MAX <= 14_200);
});

test('every category must score 1', () => {
  const a = ASSERT_MATRIX[0].assertions;
  for (const c of CATEGORIES) assert.deepEqual(a[`categories:${c}`], ['error', { minScore: 1 }]);
});

function dist() {
  const d = mkdtempSync(join(tmpdir(), 'dist-'));
  for (const f of ['index.html', '404.html', 'examples/index.html']) {
    mkdirSync(join(d, f, '..'), { recursive: true });
    writeFileSync(join(d, f), '<html></html>');
  }
  return d;
}

test('pages are base-prefixed, sorted, without 404', () => {
  assert.deepEqual(sitePages(dist()), [`${BASE}`, `${BASE}examples/`]);
  assert.throws(() => sitePages(join(tmpdir(), 'nope-dist')), /missing dist/);
});

test('an oversized html page fails', () => {
  const d = dist();
  writeFileSync(join(d, 'examples/index.html'), Buffer.from(Array.from({ length: 200_000 }, () => Math.random() * 255 | 0)));
  assert.deepEqual(htmlFailures(sitePages(d), d).length, 1);
});

test('a cast page gets the script allowance, the others the content budget', () => {
  const d = dist();
  writeFileSync(join(d, 'examples/index.html'), '<div class="ocx-terminal not-content"></div>');
  const casts = castPages(d);
  assert.deepEqual(casts, [`${BASE}examples/`]);
  const [, rest, cast] = assertMatrix(casts);
  const re = (m) => new RegExp(m.matchingUrlPattern);
  assert.ok(re(cast).test(`http://x${BASE}examples/`) && !re(rest).test(`http://x${BASE}examples/`));
  assert.ok(re(rest).test(`http://x${BASE}`) && !re(cast).test(`http://x${BASE}`));
  assert.equal(cast.assertions['resource-summary:script:size'][1].maxNumericValue, BUDGET.jsBytes + TERMINAL_JS);
  assert.equal(rest.assertions['resource-summary:script:size'][1].maxNumericValue, BUDGET.jsBytes);
});
