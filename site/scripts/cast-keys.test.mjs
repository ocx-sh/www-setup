import assert from 'node:assert/strict';
import { test } from 'node:test';
import { castProblems } from './cast-keys.mjs';

const ok = () => ({ cited: new Map([['examples/a', ['/x/']]]), recorded: new Set(['examples/a']), scripts: new Set(['examples/a']) });

test('agreeing sets have no problem', () => {
  assert.deepEqual(castProblems(ok()), []);
});

test('a cited key with no cast file, or no script, is a problem', () => {
  assert.match(castProblems({ ...ok(), recorded: new Set() }).join('\n'), /cited but public\/casts\/examples\/a\.cast does not exist/);
  assert.match(castProblems({ ...ok(), scripts: new Set() }).join('\n'), /casts\/examples__a\.sh does not exist/);
});

test('an orphaned cast, and a script nobody recorded, are problems', () => {
  const k = ok();
  assert.match(castProblems({ ...k, recorded: new Set(['examples/a', 'examples/b']) }).join('\n'), /examples\/b\.cast is orphaned/);
  assert.match(castProblems({ ...k, scripts: new Set(['examples/a', 'examples/c']) }).join('\n'), /examples__c\.sh has no recorded/);
});
