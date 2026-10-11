// Drift guard: the installers are the source of truth for the knobs and the exit codes, the site documents them.
// Every OCX_INSTALL_* name in src/install.* is on the configuration page, and every code in an installer's
// `# Exit:` header is a row of the exit-code table on the reference page. Both directions: a page entry no
// installer carries fails too. CONTRACT_SRC points the test at another installer directory (the red proof).
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const SRC = process.env.CONTRACT_SRC ?? fileURLToPath(new URL('../../src/', import.meta.url));
const DOCS = process.env.CONTRACT_DOCS ?? fileURLToPath(new URL('../src/content/docs/', import.meta.url));

/** OCX_INSTALL_* names in `text`. `__OCX_TESTING_*` hatches never match, and a trailing underscore is no part of a name. */
export const knobs = (text) => new Set(text.match(/\bOCX_INSTALL_[A-Z][A-Z0-9_]*[A-Z0-9]\b/g) ?? []);

/** Exit codes of the first `# Exit:` header line: the numbers before its first sentence end. */
export function exitCodes(text) {
  const line = text.split('\n').find((l) => l.startsWith('# Exit:'));
  if (!line) return undefined;
  return new Set((line.slice('# Exit:'.length).split(/\.\s|\.$/)[0].match(/\d+/g) ?? []).map(Number));
}

const installers = readdirSync(SRC).filter((f) => /^install\.\w+$/.test(f));
const source = (f) => readFileSync(`${SRC}${f}`, 'utf8');
const page = (f) => readFileSync(`${DOCS}${f}`, 'utf8');

test('the extractors read what they should', () => {
  assert.deepEqual([...knobs('OCX_INSTALL_FORCE, __OCX_TESTING_INSTALL_BINARY, OCX_INSTALL_ and OCX_INSTALL_*')], ['OCX_INSTALL_FORCE']);
  assert.deepEqual([...exitCodes('# Exit: 0 ok; 7 platform. No signal statuses (129 130 143): none')], [0, 7]);
  assert.deepEqual([...exitCodes('# Exit: 0 ok; 6 self setup; 7 platform; 129/130/143 signal')], [0, 6, 7, 129, 130, 143]);
});

test('there are five installers', () => {
  assert.equal(installers.length, 5, installers.join(' '));
});

test('every OCX_INSTALL_* knob in the installers is on the configuration page, and no other', () => {
  const inSource = new Set(installers.flatMap((f) => [...knobs(source(f))]));
  const onPage = knobs(page('configuration.mdx'));
  assert.ok(inSource.size >= 10, `only ${inSource.size} knobs found in the installers`);
  assert.deepEqual([...inSource].filter((k) => !onPage.has(k)).sort(), [], 'in an installer, missing from configuration.mdx');
  assert.deepEqual([...onPage].filter((k) => !inSource.has(k)).sort(), [], 'on configuration.mdx, in no installer');
});

test('every exit code in an installer header is a row of the reference page table, and no other', () => {
  const declared = new Set();
  for (const f of installers) {
    const codes = exitCodes(source(f));
    assert.ok(codes?.size, `${f} has no "# Exit:" header with codes`);
    for (const c of codes) declared.add(c);
  }
  const rows = new Set([...page('reference.mdx').matchAll(/^\|\s*(\d+)\s*\|/gm)].map((m) => Number(m[1])));
  assert.deepEqual([...declared].filter((c) => !rows.has(c)).sort((a, b) => a - b), [], 'in an installer header, missing from reference.mdx');
  assert.deepEqual([...rows].filter((c) => !declared.has(c)).sort((a, b) => a - b), [], 'in the reference.mdx table, in no installer header');
});
