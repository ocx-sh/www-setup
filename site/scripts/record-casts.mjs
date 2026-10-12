// Records site/casts/*.sh (`# cast: true`) into site/public/casts/<doc>.cast (asciicast v3, committed).
// A cast is a view on a real run: each script runs in a fresh container (or, for the Dockerfile example, on the
// host with docker) against the published setup.ocx.sh. Every byte comes from that run; only the typed command
// line is simulated (DOC-EX-12). The recorder is no gate (DOC-EX-11): CI builds the site from the committed casts.
//   ocx exec -g site -g casts -- node scripts/record-casts.mjs [--only <doc>] [--out <dir>] [--jobs <n>]
import { spawn } from 'node:child_process';
import { availableParallelism, homedir, tmpdir } from 'node:os';
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const SITE = fileURLToPath(new URL('..', import.meta.url));
const IMAGE = 'ocx-casts';
const WIDTH = 100, ROWS = 30, TYPE_DELAY = 0.04, IDLE_LIMIT = 2; // the header rows shrink to the used rows in sanitize()

/** `# key: value` header lines before the first non-comment line, plus the `cast` region. */
export function parseScript(text) {
  const meta = {};
  for (const l of text.split('\n').slice(1)) {
    const m = l.match(/^# (\w+): (.*)$/);
    if (m) meta[m[1]] = m[2];
    else if (!l.startsWith('#')) break;
  }
  const m = text.match(/^# region cast\n([\s\S]*?)^# endregion cast\n/m);
  return { meta, cast: m ? { start: m.index, end: m.index + m[0].length, body: m[1] } : null, text };
}

/** The file a doc key lives in: `a/b` is `a__b.sh`. */
export const scriptName = (doc) => `${doc.replace(/\//g, '__')}.sh`;

/**
 * Driver: the script text before the cast region runs silently, the region is typed and run block by block
 * (blank lines split it into commands), the text after it runs silently. Silent output goes to
 * $CAST_TMP/silent.log, which the recorder prints when the recording fails. Brace groups, not fd copies, so
 * a background process started by setup cannot hold the terminal open. `# eval: pwsh -Command` runs each block through
 * that command (a PowerShell one-liner is not bash; an eval holding `$b` places the block itself); the default is `eval` in the driver's own bash.
 */
export function driver({ text, cast, meta = {} }) {
  const blocks = cast.body.trimEnd().split(/\n\s*\n/);
  const typed = blocks
    .map((b, i) => `__block <<'__CAST_EOF_${i}__'\n${b}\n__CAST_EOF_${i}__`)
    .join('\n');
  const run = !meta.eval ? 'eval "$b"' : meta.eval.includes('$b') ? meta.eval : `${meta.eval} "$b"`;
  return `#!/usr/bin/env bash
set -euo pipefail
__block() {
  local b; b=$(cat)
  printf '\\033[1;32m$\\033[0m '
  for ((i = 0; i < \${#b}; i++)); do printf '%s' "\${b:i:1}"; sleep ${TYPE_DELAY}; done
  printf '\\n'; sleep 0.4
  ${run}; sleep 1
}
{
${text.slice(text.indexOf('\n') + 1, cast.start)}
} >>"$CAST_TMP/silent.log" 2>&1
${typed}
{
${text.slice(cast.end)}
} >>"$CAST_TMP/silent.log" 2>&1
`;
}

const asObjects = (t) => t.trim().split('\n').map((l) => JSON.parse(l));

/** Merge read-burst events (< 10 ms apart; typing is 30+ ms) so no path or digest is split across two events, then sanitize. */
export function sanitize(castText, subs, title) {
  const [hdr, ...ev] = asObjects(castText);
  const merged = [];
  for (const [dt, code, data] of ev) {
    const prev = merged.at(-1);
    if (prev && code === 'o' && prev[1] === 'o' && dt < 0.01) prev[2] += data;
    else merged.push([dt, code, data]);
  }
  const clean = (s) => {
    for (const [from, to] of subs) s = s.split(from).join(to);
    return s.replace(/\b([0-9a-f]{12})[0-9a-f]{20}\b/g, '$1'); // a 32-hex temp name, random per run
  };
  merged[0][0] = Math.min(merged[0][0], 0.3); // the silent setup ran before the first byte
  // Rows: wrapped lines of the output. A progress bar redraws one line (carriage return or cursor-up), so a line
  // counts as its longest redraw, not the sum of them.
  const visible = merged.filter((e) => e[1] === 'o').map((e) => e[2]).join('');
  const width = (l) => Math.max(...l.split(/\r|\x1b\[[0-9;]*[ABCDGHJKf]/).map((x) => x.replace(/\x1b\[[0-9;]*[A-Za-z]/g, '').length));
  const rows = visible.split('\n').reduce((n, l) => n + Math.max(1, Math.ceil(width(l) / hdr.term.cols)), 0);
  const out = { version: 3, term: { cols: hdr.term.cols, rows: Math.max(rows + 1, 5) }, idle_time_limit: IDLE_LIMIT, title }; // auto height; drops timestamp, command, env
  // Timings: a wait is capped at the idle limit and rounded to a millisecond, so a slow network cannot stretch a cast.
  return [out, ...merged.map(([dt, code, d]) => [Math.round(Math.min(dt, IDLE_LIMIT) * 1000) / 1000, code, code === 'o' ? clean(d) : d])]
    .map((x) => JSON.stringify(x)).join('\n') + '\n';
}

/** What a published cast must not contain: the recording machine's home or scratch directories. */
export const leaks = (castText, scratch) =>
  [homedir(), scratch, tmpdir()].filter((s) => s.length > 3 && s !== '/tmp' && castText.includes(s));

const run = (cmd, args, env) => new Promise((resolve) => {
  const p = spawn(cmd, args, { env, stdio: ['ignore', 'inherit', 'inherit'] });
  p.on('error', (e) => { console.error(`${cmd}: ${e.message}`); resolve(127); });
  p.on('close', (code) => resolve(code ?? 1));
});

async function record(file, outDir) {
  const s = parseScript(readFileSync(file, 'utf8'));
  if (s.meta.cast !== 'true') return null;
  const base = file.split('/').pop();
  if (!s.cast || !s.meta.doc || !s.meta.title || !s.meta.description) {
    throw new Error(`${base}: needs "# doc:", "# title:", "# description:" and a "# region cast"`);
  }
  if (scriptName(s.meta.doc) !== base) throw new Error(`${base}: "# doc: ${s.meta.doc}" belongs in ${scriptName(s.meta.doc)}`);
  const scratch = mkdtempSync(join(tmpdir(), 'cast-'));
  try {
    const drv = join(scratch, 'driver.sh');
    writeFileSync(drv, driver({ ...s }));
    const raw = join(scratch, 'raw.cast');
    const home = join(scratch, 'run'); // the wrapper's temp dir, known up front so its paths can be rewritten
    mkdirSync(home, { recursive: true });
    const wrapper = join(SITE, 'scripts/run-cast-script.sh');
    const code = await run('asciinema', ['rec', '--headless', '--overwrite', '--return', '--quiet',
      '--window-size', `${WIDTH}x${ROWS}`, '--command', `${wrapper} ${drv}`, raw],
    { ...process.env, CAST_TMP: home, CAST_RUNNER: s.meta.runner || 'container', CAST_IMAGE: IMAGE, CAST_COLUMNS: String(WIDTH) });
    if (code !== 0) {
      let silent = '';
      try { silent = readFileSync(join(home, 'silent.log'), 'utf8').split('\n').slice(-40).join('\n'); } catch { /* no setup ran */ }
      throw new Error(`${base}: recording failed (exit ${code})\n--- silent setup/verification output (tail) ---\n${silent}`);
    }
    const subs = [[home, '/tmp/cast'], [scratch, '/tmp/cast'], [homedir(), '~']];
    const text = sanitize(readFileSync(raw, 'utf8'), subs, s.meta.title);
    const found = leaks(text, scratch);
    if (found.length) throw new Error(`${base}: the cast still contains ${found.map((f) => JSON.stringify(f)).join(', ')}`);
    const dest = join(outDir, `${s.meta.doc}.cast`);
    mkdirSync(dirname(dest), { recursive: true });
    writeFileSync(dest, text);
    return dest;
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}

if (process.argv[1] && import.meta.url === new URL(process.argv[1], 'file:').href) {
  const arg = (k, d) => (process.argv.includes(k) ? process.argv[process.argv.indexOf(k) + 1] : d);
  const only = arg('--only', null);
  const outDir = arg('--out', join(SITE, 'public/casts'));
  const jobs = Number(arg('--jobs', Math.min(4, availableParallelism())));
  const dir = join(SITE, 'casts');
  const files = readdirSync(dir).filter((f) => f.endsWith('.sh')).sort()
    .filter((f) => !only || f.startsWith(only.replace(/\//g, '__')));
  if (!files.length) {
    console.error(`record-casts: no cast script in casts/ matches --only ${only}`);
    process.exit(1);
  }
  // The image holds every installer's shell; the build context is the repository, which owns tests/docker/install-shells.sh.
  const built = await run('docker', ['build', '--quiet', '--file', join(dir, 'Dockerfile'), '--tag', IMAGE, join(SITE, '..')], process.env);
  if (built !== 0) process.exit(built);
  if (!only && outDir === join(SITE, 'public/casts')) rmSync(outDir, { recursive: true, force: true }); // a cast whose script is gone must not ship
  const failed = [];
  let next = 0;
  await Promise.all(Array.from({ length: Math.max(1, jobs) }, async () => {
    while (next < files.length) {
      const f = files[next++];
      try {
        const dest = await record(join(dir, f), outDir);
        if (dest) console.log(`recorded ${dest}`);
      } catch (e) {
        failed.push(f);
        console.error(e.message);
      }
    }
  }));
  if (failed.length) {
    console.error(`record-casts: ${failed.length} of ${files.length} failed: ${failed.join(', ')}`);
    process.exit(1);
  }
}
