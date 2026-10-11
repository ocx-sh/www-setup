// Languages the site's fences may use; each one has a Shiki grammar that colours something. The fence gate
// (scripts/check-fences.mjs) and the markdownlint MD040 list (.markdownlint.jsonc) accept exactly these.
// `log` is for diagnostics and command output: it colours quoted strings, numbers and paths.
// Elvish has no Shiki grammar, so its commands are fenced as `sh`.
export const HIGHLIGHTED = new Set(['sh', 'bash', 'powershell', 'nu', 'fish', 'dockerfile', 'toml', 'json', 'diff', 'yaml', 'log']);
