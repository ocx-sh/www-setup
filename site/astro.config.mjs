// The install section of ocx.sh: `/install/` (a claim in the theme's nav.json). setup.ocx.sh itself, the raw
// installer scripts, is a separate deployment and untouched by this site.
import { existsSync } from 'node:fs';
import { satteri } from '@astrojs/markdown-satteri';
import starlight from '@astrojs/starlight';
import ocxTheme from '@ocx-sh/theme/starlight';
import { defineConfig } from 'astro/config';
import { GROUPS } from './sidebar.mjs';

const DOCS = new URL('./src/content/docs/', import.meta.url);
const built = (link) => {
  const slug = link.replace(/^\/|\/$/g, '');
  return ['.md', '.mdx', '/index.md', '/index.mdx'].some((ext) => existsSync(new URL(`${slug || 'index'}${ext}`, DOCS)));
};

// A sidebar entry with no page is a dead link in every page: fail instead of dropping it.
const dangling = GROUPS.flatMap((g) => g.items.map(([, link]) => link)).filter((link) => !built(link));
if (dangling.length) throw new Error(`sidebar: no page for ${dangling.join(', ')}`);
const sidebar = GROUPS.map(({ label, items }) => ({ label, items: items.map(([label, link]) => ({ label, link })) }));

export default defineConfig({
  base: '/install/',
  // Starlight reads it before plugins run, so the theme checks it rather than sets it.
  trailingSlash: 'always',
  devToolbar: { enabled: false },
  // headingAttributes: `## Title {#kebab-id}` gives the heading that id, in .md and .mdx alike (DOC-NAV-07).
  markdown: { processor: satteri({ features: { headingAttributes: true } }) },
  integrations: [
    starlight({
      title: 'Install OCX',
      description: 'Install OCX with one command in bash, PowerShell, Nushell, fish or Elvish, and configure, pin and mirror the installers.',
      social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/ocx-sh/www-setup' }],
      plugins: [ocxTheme()],
      sidebar,
    }),
  ],
});
