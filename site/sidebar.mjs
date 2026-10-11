// The sidebar of the site. scripts/check-anchors.mjs asserts every page under src/content/docs is listed here
// and every entry has a page, so neither a page nor a link goes missing unnoticed.
export const GROUPS = [
  { label: 'Get started', items: [['Install OCX', '/'], ['Examples', '/examples/'], ['Installer output', '/examples/dev-box/']] },
  { label: 'Everyday', items: [['Pin a version', '/versions/'], ['Configuration', '/configuration/']] },
  { label: 'Integrate', items: [['Mirrors and proxies', '/mirrors/']] },
  { label: 'Reference', items: [['Exit codes and contract', '/reference/']] },
];
