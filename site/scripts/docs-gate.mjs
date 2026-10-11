// The docs-quality gate (.claude/rules/docs-quality): the rule set's checks over the pages in src/content/docs.
// The checks read a gate view of the pages in .docs-check, the same text with each MDX `import` line replaced by a
// comment (code, not prose; line numbers stay put). Every page is written by hand, so there is no baseline: one finding fails the gate.
// Each check also proves itself against its own fixtures (--self-test). Exit 1 on any finding.
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { delimiter, dirname, join, relative } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const SITE = fileURLToPath(new URL('../', import.meta.url));
const CHECKS = '../.claude/rules/docs-quality/checks';
const SOURCE = 'src/content/docs';
const PAGES = '.docs-check';
// The checks are standard library only and need 3.11; `uv` (ocx.toml, group site) finds or fetches one.
const PY = ['uv', 'run', '--no-project', '--quiet', '--python', '>=3.11', 'python', '-I'];
const FINDING = /^\S.*:\d+(?::\d+)?:? (?:DOC-[A-Z]+-\d+|MD\d+\/)/m;
const PAGE_CHECKS = ['doc_declaration', 'prose', 'page_type', 'landing_check', 'doc_examples'];

// markdownlint-cli2 is always on PATH: prose.py leaves heading hygiene to it when it is, so the counts do not depend on how the gate is started.
const env = { ...process.env, PYTHONDONTWRITEBYTECODE: '1', PATH: `${join(SITE, 'node_modules/.bin')}${delimiter}${process.env.PATH}` };
const sh = (cmd, args) => {
  const r = spawnSync(cmd, args, { cwd: SITE, encoding: 'utf8', env });
  if (r.error) throw r.error;
  return { code: r.status, lines: `${r.stdout}\n${r.stderr}`.split('\n').filter((l) => FINDING.test(l)), out: `${r.stdout}${r.stderr}` };
};
const py = (script, args) => sh(PY[0], [...PY.slice(1), `${CHECKS}/${script}.py`, ...args]);
const walk = (dir) => readdirSync(dir, { withFileTypes: true }).flatMap((d) => (d.isDirectory() ? walk(join(dir, d.name)) : [join(dir, d.name)]));

/** Writes the gate view of every page and returns its paths relative to the site. */
export function gateView() {
  rmSync(join(SITE, PAGES), { recursive: true, force: true });
  const sources = walk(join(SITE, SOURCE)).filter((f) => /\.mdx?$/.test(f));
  if (!sources.length) throw new Error(`docs-gate: no pages in ${SOURCE}`);
  return sources.map((f) => {
    const out = join(SITE, PAGES, relative(join(SITE, SOURCE), f));
    mkdirSync(dirname(out), { recursive: true });
    writeFileSync(out, readFileSync(f, 'utf8').replace(/^import .*;$/gm, '{/* import */}'));
    return relative(SITE, out);
  });
}

export function main() {
  const pages = gateView();

  const results = {};
  const broken = [];
  const record = (name, r) => ((results[name] ??= []).push(...r.lines), r);
  for (const name of PAGE_CHECKS) {
    const r = record(name, py(name, ['--root', PAGES, ...pages]));
    if (r.code > 1) broken.push(`${name}: exit ${r.code}\n${r.out}`);
  }
  const md = record('markdownlint', sh('markdownlint-cli2', ['--config', '.markdownlint.jsonc', ...pages]));
  if (md.code > 1) broken.push(`markdownlint: exit ${md.code}\n${md.out}`);
  // The pages link to each other under the site's base path, /install/: a root that holds it as a directory resolves those links.
  const root = mkdtempSync(join(tmpdir(), 'docs-gate-'));
  symlinkSync(join(SITE, PAGES), join(root, 'install'));
  const raw = record('links_raw', py('links_raw', ['--root', root, ...pages.map((f) => join(root, 'install', relative(PAGES, f)))]));
  rmSync(root, { recursive: true, force: true });
  if (raw.code > 1) broken.push(`links_raw: exit ${raw.code}\n${raw.out}`);
  for (const name of [...PAGE_CHECKS, 'links_raw', 'strip_prose']) {
    const r = py(name, ['--self-test']);
    if (r.code !== 0) broken.push(`${name} --self-test: exit ${r.code}\n${r.out}`);
  }
  if (broken.length) throw new Error(`docs-gate: a check did not run\n${broken.join('\n')}`);

  let bad = 0;
  for (const [name, lines] of Object.entries(results)) {
    for (const l of lines) (bad++, console.error(l));
    console.log(`${name}: ${lines.length} findings`);
  }
  console.log(`docs-gate: ${pages.length} pages`);
  return bad ? 1 : 0;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) process.exitCode = main();
