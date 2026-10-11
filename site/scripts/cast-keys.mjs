// The four sets a cast key lives in must agree: cited by a page, recorded under public/casts, scripted under casts/.
// A cast is committed (nothing regenerates it), so a cited key with no file is a broken page and a file nothing cites is dead weight.

/**
 * Problems among the cast keys, as lines. `cited` maps a key to the pages citing it; the others are key sets.
 * @param {{ cited: Map<string, string[]>, recorded: Set<string>, scripts: Set<string> }} keys
 * @returns {string[]}
 */
export function castProblems({ cited, recorded, scripts }) {
  const out = [];
  for (const [key, pages] of cited) {
    if (!recorded.has(key)) out.push(`${pages[0]}: cast ${key} is cited but public/casts/${key}.cast does not exist (task site:casts)`);
    if (!scripts.has(key)) out.push(`${pages[0]}: cast ${key} is cited but casts/${key.replace('/', '__')}.sh does not exist`);
  }
  for (const key of recorded) if (!cited.has(key)) out.push(`public/casts/${key}.cast is orphaned: no page cites ${key}`);
  for (const key of scripts) if (!recorded.has(key)) out.push(`casts/${key.replace('/', '__')}.sh has no recorded public/casts/${key}.cast`);
  return out;
}
