// Fails when a code block in the built site has no language, a plain-text one, or one Shiki would not highlight.
// A block that really is plain output goes in ALLOW as `<page path under dist>`: `<reason>`; keep the list near empty.
import { readFileSync, readdirSync } from 'node:fs';
import { join, relative } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { HIGHLIGHTED } from '../fence-langs.mjs';

export const ALLOW = {};

/** Findings (strings) for the `<pre>` blocks of one built page. */
export function fenceFindings(html, page = 'page', allow = ALLOW) {
  const out = [];
  for (const [, attrs] of html.matchAll(/<pre\b([^>]*)>/g)) {
    const lang = attrs.match(/\bdata-language="([^"]*)"/)?.[1] ?? '';
    if (HIGHLIGHTED.has(lang) || allow[page]) continue;
    out.push(`${page}: code block with ${lang ? `language "${lang}"` : 'no language'} is not highlighted`);
  }
  return out;
}

const walk = (dir) => readdirSync(dir, { withFileTypes: true }).flatMap((d) => (d.isDirectory() ? walk(join(dir, d.name)) : [join(dir, d.name)]));

export function main(dist = fileURLToPath(new URL('../dist', import.meta.url))) {
  const pages = walk(dist).filter((f) => f.endsWith('.html'));
  if (!pages.length) throw new Error(`check-fences: no built pages in ${dist}`);
  const findings = pages.flatMap((f) => fenceFindings(readFileSync(f, 'utf8'), relative(dist, f)));
  if (findings.length) {
    console.error(findings.join('\n'));
    process.exitCode = 1;
  }
  return findings;
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) main(process.argv[2]);
