import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { driver, leaks, parseScript, sanitize, scriptName } from './record-casts.mjs';

const script = `#!/usr/bin/env bash
# cast: true
# doc: a/b
# title: T
# eval: pwsh -c
set -e
# region cast
echo one

echo two
# endregion cast
test 1
`;

test('parseScript reads headers and the cast region', () => {
  const s = parseScript(script);
  assert.deepEqual([s.meta.cast, s.meta.doc, s.meta.title, s.meta.eval], ['true', 'a/b', 'T', 'pwsh -c']);
  assert.equal(s.cast.body, 'echo one\n\necho two\n');
  assert.equal(scriptName('a/b'), 'a__b.sh');
});

test('driver types every block and runs the text around the region silently, into the log', () => {
  const plain = driver({ ...parseScript(script), meta: {} });
  assert.equal([...plain.matchAll(/^__block <<'/gm)].length, 2);
  assert.match(plain, /\{\n[\s\S]*set -e\n\n\} >>"\$CAST_TMP\/silent.log" 2>&1\n__block/);
  assert.match(plain, /\{\ntest 1\n\n\} >>"\$CAST_TMP\/silent.log" 2>&1\n$/);
  assert.match(plain, /^ {2}eval "\$b"; sleep 1$/m);
  assert.match(driver(parseScript(script)), /^ {2}pwsh -c "\$b"; sleep 1$/m);
});

test('sanitize merges bursts, rewrites paths, shortens temp names and timings, keeps typing events', () => {
  const cast = [
    { version: 3, term: { cols: 100, rows: 40 }, timestamp: 1, command: '/home/u/x', env: { SHELL: '/bin/zsh' } },
    [2, 'o', 'built in /tmp/r/wor'], [0.001, 'o', 'k/temp/0123456789abcdef0123456789abcdef\r\n'],
    [0.04, 'o', 'x'], [9, 'o', 'slow\r\n'], [0.1, 'x', '0'],
  ].map((x) => JSON.stringify(x)).join('\n');
  const [hdr, ...ev] = sanitize(cast, [['/tmp/r/work', '~/p']], 'T').trim().split('\n').map((l) => JSON.parse(l));
  assert.deepEqual(Object.keys(hdr), ['version', 'term', 'idle_time_limit', 'title']);
  assert.equal(hdr.term.rows, 5);
  assert.equal(ev[0][0], 0.3);
  assert.equal(ev[0][2], 'built in ~/p/temp/0123456789ab\r\n');
  assert.equal(ev[2][0], 2); // a nine second wait is capped at the idle limit
  assert.equal(ev.length, 4);
});

test('sanitize leaves a 64-hex digest whole', () => {
  const dig = 'a'.repeat(64);
  const out = sanitize([{ version: 3, term: { cols: 100, rows: 40 } }, [1, 'o', `sha256:${dig}`]].map((x) => JSON.stringify(x)).join('\n'), [], 'T');
  assert.ok(out.includes(dig));
});

test('leaks reports the recording machine home and scratch directory', () => {
  assert.deepEqual(leaks('all clean ~/x', '/tmp/cast-1'), []);
  assert.deepEqual(leaks(`see ${homedir()}/x and /tmp/cast-1/run`, '/tmp/cast-1'), [homedir(), '/tmp/cast-1']);
});

// The file name, the key and the headers of every cast script must agree.
test('every cast script declares a doc key that matches its file name', () => {
  const dir = fileURLToPath(new URL('../casts/', import.meta.url));
  const files = readdirSync(dir).filter((f) => f.endsWith('.sh'));
  assert.ok(files.length > 0);
  for (const f of files) {
    const s = parseScript(readFileSync(dir + f, 'utf8'));
    assert.equal(s.meta.cast, 'true', f);
    assert.equal(scriptName(s.meta.doc), f);
    assert.ok(s.meta.title && s.meta.description && s.cast, f);
  }
});
