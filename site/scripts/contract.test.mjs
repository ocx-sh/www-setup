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

/** Knobs an installer reads: the names left once its comment-only lines are dropped (a comment may say a knob is another dialect's). */
export const readKnobs = (text) => knobs(text.split('\n').filter((l) => !/^\s*#/.test(l)).join('\n'));

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
  assert.deepEqual([...readKnobs('# OCX_INSTALL_AA is sh-only\nx=$OCX_INSTALL_BB # not a comment line')], ["OCX_INSTALL_BB"]);
  assert.deepEqual([...knobs('OCX_INSTALL_FORCE, __OCX_TESTING_INSTALL_BINARY, OCX_INSTALL_ and OCX_INSTALL_*')], ['OCX_INSTALL_FORCE']);
  assert.deepEqual([...exitCodes('# Exit: 0 ok; 7 platform. No signal statuses (129 130 143): none')], [0, 7]);
  assert.deepEqual([...exitCodes('# Exit: 0 ok; 6 self setup; 7 platform; 129/130/143 signal')], [0, 6, 7, 129, 130, 143]);
});

test('there are five installers', () => {
  assert.equal(installers.length, 5, installers.join(' '));
});

/** Installer name (`install.<ext>`) to the name the pages use for it. */
const NAMES = { 'install.sh': 'POSIX', 'install.ps1': 'PowerShell', 'install.nu': 'Nushell', 'install.fish': 'fish', 'install.elv': 'Elvish' };

/** Rows of the configuration tables keyed by a knob: `| `OCX_INSTALL_X` | default | effect |`, knob -> effect cell. */
export const knobRows = (text) => new Map([...text.matchAll(/^\|\s*`(OCX_INSTALL_[A-Z0-9_]+)`\s*\|[^|]*\|(.*)\|\s*$/gm)].map((m) => [m[1], m[2]]));

test('the knob row extractor reads a table row and nothing else', () => {
  assert.deepEqual([...knobRows('| `OCX_INSTALL_A` | x | The POSIX installer only. |\nsee `OCX_INSTALL_B` in prose\n| `OCX_HOME` | y | z |')], [['OCX_INSTALL_A', ' The POSIX installer only. ']]);
});

test('each installer reads only knobs that have a configuration table row', () => {
  const rows = knobRows(page('configuration.mdx'));
  assert.ok(rows.size >= 10, `only ${rows.size} knob rows on configuration.mdx`);
  for (const f of installers) {
    const missing = [...readKnobs(source(f))].filter((k) => !rows.has(k));
    assert.deepEqual(missing.sort(), [], `${f} reads a knob with no table row on configuration.mdx`);
  }
});

test('each knob row is read by every installer, unless its row says the POSIX installer only', () => {
  for (const [knob, effect] of knobRows(page('configuration.mdx'))) {
    const readers = installers.filter((f) => readKnobs(source(f)).has(knob));
    const expected = /POSIX installer only/.test(effect) ? ['install.sh'] : installers;
    assert.deepEqual(readers.sort(), [...expected].sort(), `${knob}: installers that read it`);
  }
});

test('each installer header lists exit codes that the reference table has, and the signal rows name exactly the installers that trap', () => {
  const ref = page('reference.mdx');
  const rows = new Map([...ref.matchAll(/^\|\s*(\d+)\s*\|(.*)\|\s*$/gm)].map((m) => [Number(m[1]), m[2]]));
  const declared = new Map(); // code -> installers
  for (const f of installers) {
    const codes = exitCodes(source(f));
    assert.ok(codes?.size, `${f} has no "# Exit:" header with codes`);
    for (const c of codes) {
      assert.ok(rows.has(c), `${f} declares exit ${c}, which is not a row of the reference.mdx table`);
      declared.set(c, [...(declared.get(c) ?? []), f]);
    }
  }
  for (const c of rows.keys()) assert.ok(declared.has(c), `reference.mdx has a row for exit ${c}, which no installer header declares`);
  for (const c of [129, 130, 143]) {
    const named = installers.filter((f) => new RegExp(`\\b${NAMES[f]}\\b`).test(rows.get(c).split(':')[0]));
    assert.deepEqual(named.sort(), (declared.get(c) ?? []).sort(), `exit ${c}: installers the row names against the headers that declare it`);
  }
});
