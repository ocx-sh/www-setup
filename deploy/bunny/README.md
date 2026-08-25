# setup.ocx.sh on Bunny

Live. Replaces the self-hosted nginx + rsync deployment.

| Piece | Role |
|---|---|
| **Storage Zone** `sh-ocx-setup` (Frankfurt) | The docroot. Written by `scripts/publish-installers.sh` + `publish-dist.sh` via `scripts/lib/bunny.sh` |
| **Pull Zone** `6415130` | Public serving on `setup.ocx.sh`, the routing edge rules, the cache split, and the monthly bandwidth cap |

## Stored layout

Edge Storage is **directory-backed**, not a flat keyspace: a path is either a
file or a directory, never both. So `sh` and `sh/next` cannot both exist as
stored objects, and the friendly URLs are *routed*, never stored.

```
archive/<VERSION>/install.<ext>   pinned, immutable, append-only (canonical artifact URL)
archive/<VERSION>/<shell>         same bytes, shell-segment name
latest/<shell>                    stable pointer
next/<shell>                      next pointer
dist.json  dist.json.sha256  dist/<sha256>.json
```

Pointers are named by **shell segment** rather than extension so a single rule
using path-segment variable expansion serves all five shells. Naming them
`latest/install.<ext>` would cost five rules per route shape and blow the
20-rule-per-pull-zone budget.

## Routing

`edge-rules.py` owns the rules. It is the routing contract — applied, not
reference.

```sh
task rules:plan      # render the set offline, no credentials
task rules:apply     # delete + reapply + purge (needs BUNNY_API_KEY)
task rules:verify    # probe every routed URL against the live zone
```

| Rule | Effect |
|---|---|
| `/dist`, `/releases` | → `dist.json` |
| `/<shell>` | → `latest/%{Path.0}` |
| `/<shell>/next`, `/<shell>/canary` | → `next/%{Path.0}` |
| `/<shell>/<VERSION>` | → `archive/%{Path.1}/%{Path.0}` |
| `/docs/*`, `/actions/*` | → `ocx.sh` upstream, transparently |
| `/archive/*`, `/dist/*` | cache 1 year (edge + browser) |
| everything else | `Content-Type: text/plain; charset=utf-8` |

Nine rules of a 20 budget. `rules:verify` currently passes 26/26 against
`setup.ocx.sh`.

### Bunny behaviours that bite

- **`*` is greedy across `/`.** `https://*/sh` also matches `/latest/sh` and
  `/archive/0.1.1/sh`. Every wildcard must sit behind a fully anchored literal
  prefix and never in the host position — otherwise a pinned URL silently serves
  `latest`, an immutability violation that still returns 200.
- **Max 5 patterns per trigger.** `edge-rules.py` chunks across trigger objects;
  `TriggerMatchingType` 0 (MatchAny) makes that transparent.
- **Lua patterns, not PCRE** — no alternation, no lookaround.
- **`ActionParameter1` must be a full URL.** A relative path is rejected with
  "The entered path is not a valid URL."
- **Rule order decides precedence** — first match wins, which is why the
  `next`/`canary` rule precedes the version wildcard.
- Pinned *friendly* URLs (`/sh/0.1.1`) get the 300s default, not the immutable
  year: the cache rule matches on the request path, and `/sh/*` cannot be
  distinguished from `/sh/next` by pattern. The canonical
  `/archive/<VERSION>/install.<ext>` does get the year.

## Cost controls

Storage has no spend cap and needs none — its cost is bounded by what the
pipeline uploads. The runaway risk is bandwidth: **Pull Zone → Limits → monthly
bandwidth limit**, currently **100 GB** (~5M installs, ~$1). When reached the
zone is disabled and stops serving, and further requests are not billed. That
ceiling is the reason this project is on Bunny rather than Cloudflare or AWS,
neither of which offers a hard cap.

## Credentials

| Name | Scope | Where |
|---|---|---|
| `BUNNY_STORAGE_KEY` | one storage zone; write access to the installer docroot | GitHub env `setup.ocx.sh` |
| `BUNNY_STORAGE_ZONE` | `sh-ocx-setup` | GitHub env `setup.ocx.sh` |
| `BUNNY_API_KEY` | **account-wide** — edge rules, purges, zone config | local only, deliberately NOT in CI |

Publishing content never touches routing; applying routing never touches
content. That separation is why the account-wide key stays out of the release
pipeline.
