// Every ShellSession on a page shows bytes from a real run (DOC-EX-12): its command is the line the cast typed and its
// output lines appear, in order, on the cast's final screen. The page may drop lines and trailing spaces, never add a byte.
// The Dockerfile on the examples page is the one the Dockerfile cast builds.
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { screenLines } from './cast-screen.mjs';

const site = (p) => fileURLToPath(new URL(`../${p}`, import.meta.url));
const page = (name) => readFileSync(site(`src/content/docs/${name}.mdx`), 'utf8');

// A session with no <Cast> right after it shows the run of the cast named here.
const SHARED = { 'examples:Install the latest ocx': 'examples/dev-box-sh' };

/** [{ title, command, output, cast }] for each ShellSession; `cast` is the key of the <Cast> right after it. */
export function sessions(name) {
  const re = /<ShellSession title="([^"]+)">\n([\s\S]*?)<\/ShellSession>(?:\s*<Cast name="([^"]+)")?/g;
  return [...page(name).matchAll(re)].map(([, title, body, cast]) => {
    const fences = [...body.matchAll(/```\w*\n([\s\S]*?)```/g)].map((m) => m[1].trimEnd());
    assert.equal(fences.length, 2, `${name}: "${title}" needs one command and one output fence`);
    return { title, command: fences[0], output: fences[1], cast: cast ?? SHARED[`${name}:${title}`] };
  });
}

for (const name of ['examples']) {
  for (const s of sessions(name)) {
    test(`${name}: "${s.title}" matches its recorded run`, () => {
      assert.ok(s.cast, 'no cast follows this session');
      const file = site(`public/casts/${s.cast}.cast`);
      assert.ok(existsSync(file), `record ${s.cast} (task site:casts)`);
      const screen = screenLines(readFileSync(file, 'utf8'));
      const typed = s.command.split('\n');
      const at0 = screen.indexOf(`$ ${typed[0]}`);
      assert.ok(at0 >= 0, `the cast ${s.cast} did not type "${typed[0]}"`);
      assert.deepEqual(screen.slice(at0 + 1, at0 + typed.length), typed.slice(1));
      let at = at0 + typed.length;
      for (const line of s.output.split('\n').map((l) => l.trimEnd())) {
        const i = screen.indexOf(line, at);
        assert.ok(i >= 0, `"${line}" is not on the screen after line ${at} of ${s.cast}`);
        at = i + 1;
      }
    });
  }
}

test('the Dockerfile on the examples page is the one the cast builds', () => {
  const shown = page('examples').match(/```dockerfile\n([\s\S]*?)```/)[1];
  const built = readFileSync(site('casts/examples__dockerfile.sh'), 'utf8').match(/<<'DOCKERFILE'\n([\s\S]*?)^DOCKERFILE$/m)[1];
  assert.equal(shown, built);
});
