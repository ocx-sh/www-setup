// Checks the source pages against the built site. Every page under src/content/docs is in the sidebar and every
// sidebar entry has a page. Every `{#id}` heading of a source page is an id in its built page. Every
// <Cast name="..."> key is well formed, and every cast a built page embeds exists under dist.
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { GROUPS } from '../sidebar.mjs';

const DOCS = new URL('../src/content/docs/', import.meta.url);
const dist = new URL('../dist/', import.meta.url);
const BASE = '/install/';

let bad = 0;
const fail = (msg) => (bad++, console.error(msg));
const walk = (dir, ext) =>
  readdirSync(dir, { withFileTypes: true }).flatMap((d) =>
    d.isDirectory() ? walk(new URL(`${d.name}/`, dir), ext) : d.name.endsWith(ext) ? [new URL(d.name, dir)] : [],
  );

const linkOf = (file) => `/${file.pathname.slice(DOCS.pathname.length).replace(/\.mdx?$/, '').replace(/(^|\/)index$/, '')}/`.replace(/^\/\/$/, '/');
const linked = new Set(GROUPS.flatMap((g) => g.items.map(([, link]) => link)));
const pages = walk(DOCS, '.mdx').concat(walk(DOCS, '.md'));
let cites = 0;
for (const file of pages) {
  const link = linkOf(file);
  const text = readFileSync(file, 'utf8');
  if (!linked.has(link)) fail(`sidebar: ${link} is in no sidebar group`);
  for (const m of text.matchAll(/<Cast\s+name="([^"]*)"/g)) {
    cites++;
    if (!/^[a-z0-9]+(?:-[a-z0-9]+)*\/[a-z0-9]+(?:-[a-z0-9]+)*$/.test(m[1])) fail(`${link}: cast key "${m[1]}" is not <group>/<slug> in kebab-case`);
  }
  const built = new URL(`${link.slice(1)}index.html`, dist);
  if (!existsSync(built)) {
    fail(`${link}: no built page`);
    continue;
  }
  const have = new Set([...readFileSync(built, 'utf8').matchAll(/\sid="([^"]+)"/g)].map((m) => m[1]));
  for (const m of text.matchAll(/^#{2,6} .*\{#([\w.:-]+)\}\s*$/gm)) if (!have.has(m[1])) fail(`${link}: heading anchor #${m[1]} is not an id in the built page`);
}
for (const link of linked) if (!pages.some((f) => linkOf(f) === link)) fail(`sidebar: ${link} has no page in src/content/docs`);

// A cast is embedded only once it is recorded, so the built pages may hold fewer than the sources cite.
let embedded = 0;
for (const page of walk(dist, '.html')) {
  for (const m of readFileSync(page, 'utf8').matchAll(/data-src="([^"]+)"/g)) {
    embedded++;
    if (!m[1].startsWith(BASE) || !existsSync(new URL(m[1].slice(BASE.length), dist))) fail(`${page.pathname}: cast ${m[1]} is not in dist`);
  }
}
console.log(`pages: ${pages.length} in src/content/docs, ${linked.size} in the sidebar`);
console.log(`casts: ${cites} cited, ${embedded} recorded and embedded`);
process.exit(bad ? 1 : 0);
