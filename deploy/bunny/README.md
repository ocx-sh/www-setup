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
task zone:plan       # diff the zone resilience settings (needs BUNNY_API_KEY)
task zone:apply      # push the differing settings + purge (needs BUNNY_API_KEY)
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

## Zone resilience settings

`ZONE_SETTINGS` in `edge-rules.py` owns these, applied by `task zone:apply`.
They are a **separate axis from routing**: `zone-apply` never touches edge rules
and `apply` never touches settings.

| Setting | Value | Why |
|---|---|---|
| `EnableOriginShield` | `True` | Every PoP pulls through one FR shield instead of reaching origin itself — this is what routes around a PoP whose own origin path is broken |
| `EnableSafeHop` | `True` | Umbrella toggle for the origin-retry behaviour below |
| `OriginRetries` | `2` | Retry the origin before surfacing a failure |
| `OriginRetryDelay` | `1` | **Seconds, and an enum — only 0/1/3/5/10.** Any other value is silently clamped down and the API still answers 200 |
| `OriginRetry5XXResponses` | `True` | Off by default, which is the surprising part: without it the edge does not retry a 5xx even with retries enabled |
| `UseStaleWhileUpdating` | `True` | Serve the last good copy while revalidating |
| `UseStaleWhileOffline` | `True` | Serve the last good copy when origin is down |
| `EnableRequestCoalescing` | `True` | Collapse concurrent misses for one object into a single origin pull — the nightly docker matrix fires ~40 at once |

Deliberately left alone: `CacheErrorResponses=False` (never cache a 5xx),
`EnableCacheSlice`, and the storage zone's `SG/NY/MI` replication regions.

`zone-apply` **reads every setting back** after the POST and fails loudly if one
did not land. That is not paranoia: the API answers `200` for a body it
partially ignored, which is exactly how `OriginRetryDelay` was found to be an
enum.

### Why this exists

From 2026-08-27 to 2026-08-30 the **PHX** PoP returned HTTP 500 on **23 of 23**
requests for `/dist.json` (100%, always `MISS`), while ~16 other PoPs served it
fine. With every resilience knob off, that 500 went straight to `curl` and the
installer exited 3 — for CI and for real `curl | sh` users routed through
Phoenix alike. Config cannot fix a broken PoP, but a shield routes around it.

### Reading the CDN logs

The diagnostic of record — it is what turned "flaky 8% CI failure" into "one
named PoP, 100% broken":

```sh
curl -H "AccessKey: $BUNNY_API_KEY" \
  https://logging.bunnycdn.com/$(date -u +%m-%d-%y)/6415130.log
```

Pipe-separated, retained ~4 days, one line per request:

```
CacheStatus|Status|Timestamp|BytesSent|ZoneId|IP|Referer|Url|PoP|UserAgent|RequestId|Country
```

Group 5xx by the **PoP** column before assuming a random failure rate. A
per-request random failure and one wholly broken PoP look identical from a CI
pass rate, and only the first is fixed by retrying.

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
