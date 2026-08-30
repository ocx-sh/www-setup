#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors
"""Apply and verify the setup.ocx.sh routing rules on the Bunny pull zone.

The pull zone's Edge Rules ARE the routing contract — the friendly per-shell
URLs are not stored objects (Edge Storage is directory-backed, so `sh` and
`sh/next` cannot coexist as files). This script keeps that contract in git
instead of in dashboard clicks. The same applies to the zone's resilience
settings (ZONE_SETTINGS below) — see `zone` / `zone-apply`.

  python3 edge-rules.py plan       # print what would be applied
  python3 edge-rules.py apply      # delete existing rules, apply this set, purge
  python3 edge-rules.py verify     # probe every route against the live zone
  python3 edge-rules.py zone       # diff the live zone settings against desired
  python3 edge-rules.py zone-apply # push the differing settings, then purge

Env: BUNNY_API_KEY (account key, NOT the storage zone password).
     BUNNY_PULLZONE_ID (default 6415130), BUNNY_CDN_HOST, BUNNY_PUBLIC_HOST.
"""
import json, os, sys, time, urllib.request, urllib.error

ZONE = os.environ.get("BUNNY_PULLZONE_ID", "6415130")
CDN = os.environ.get("BUNNY_CDN_HOST", "sh-ocx-setup.b-cdn.net")
PUBLIC = os.environ.get("BUNNY_PUBLIC_HOST", "setup.ocx.sh")
API = f"https://api.bunny.net/pullzone/{ZONE}"
SHELLS = ["sh", "pwsh", "nu", "fish", "elvish"]
HOSTS = [CDN, PUBLIC]

# ActionType: 1=Redirect 2=OriginUrl 3=OverrideCacheTime 5=SetResponseHeader
#             16=OverrideBrowserCacheTime
# TriggerType 0=Url; PatternMatchingType 0=MatchAny 2=MatchNone
ORIGIN = 2
SET_HEADER = 5
EDGE_CACHE = 3
BROWSER_CACHE = 16
IMMUTABLE = "31536000"


MAX_PATTERNS = 5  # hard API limit: "Maximum 5 triggers are allowed per condition"

# Zone resilience settings. These shipped ALL DISABLED, which is how a single
# bad edge PoP became a user-visible outage: from 2026-08-27 to 2026-08-30 the
# PHX PoP returned HTTP 500 on 23 of 23 requests for /dist.json (100%), while
# ~16 other PoPs served it fine. With no origin retry, no shield and no stale
# fallback, that 500 went straight to `curl` and the installer exited 3 — for
# CI and for real `curl | sh` users routed through Phoenix alike.
#
# Nothing here changes routing or cache lifetimes; `zone-apply` and `apply` are
# independent. Anything not listed is left exactly as the dashboard has it.
ZONE_SETTINGS = {
    # Pull through one shield (FR, nearest the DE storage primary) instead of
    # every PoP reaching origin on its own. This is what routes around a PoP
    # whose own origin path is broken.
    "EnableOriginShield": True,
    # SafeHop is the umbrella toggle for the origin retry behaviour below.
    "EnableSafeHop": True,
    "OriginRetries": 2,
    # SECONDS, and an enum: only 0/1/3/5/10 are accepted. Any other value is
    # silently clamped down to the nearest allowed one and the API still
    # answers 200 — which is exactly why zone-apply reads every setting back
    # instead of trusting the status code.
    "OriginRetryDelay": 1,
    # Off by default, which is the surprising part: without it the edge does
    # not retry a 5xx even when retries are otherwise enabled.
    "OriginRetry5XXResponses": True,
    # Serve the last good copy while revalidating, and when origin is down.
    # Bounded by the 300s zone default, so a published dist.json is still
    # visible within the usual window.
    "UseStaleWhileUpdating": True,
    "UseStaleWhileOffline": True,
    # Collapse concurrent misses for the same object into one origin pull —
    # the nightly docker matrix fires ~40 of them at once.
    "EnableRequestCoalescing": True,
}


def rule(desc, patterns, target, action=ORIGIN, p2=""):
    # Patterns are chunked across multiple Trigger objects because each trigger
    # caps at 5 PatternMatches. TriggerMatchingType 0 (MatchAny) ORs them, so
    # chunking is transparent.
    chunks = [patterns[i:i + MAX_PATTERNS]
              for i in range(0, len(patterns), MAX_PATTERNS)]
    return {
        "ActionType": action,
        "ActionParameter1": target,
        "ActionParameter2": p2,
        "TriggerMatchingType": 0,
        "Enabled": True,
        "Description": desc,
        "Triggers": [{"Type": 0, "PatternMatchingType": 0, "Parameter1": "",
                      "PatternMatches": c} for c in chunks],
    }


def x(*suffixes):
    """Expand a path suffix across both hostnames."""
    return [f"https://{h}{s}" for h in HOSTS for s in suffixes]


def ruleset():
    # Order matters: the MORE SPECIFIC channel rule precedes the version
    # wildcard, because `/sh/next` also matches `/sh/*`.
    #
    # `*` is GREEDY ACROSS `/` — verified the hard way: a pattern of
    # `https://*/sh` matched `/latest/sh` and `/archive/0.1.1/sh` too and 404'd
    # the whole zone. So every wildcard here sits behind a fully anchored
    # literal prefix (`https://<host>/<shell>/`), never in the host position,
    # and exact patterns are used wherever the path set is finite.
    return [
        rule("dist alias", x("/dist", "/releases"), f"https://{CDN}/dist.json"),
        rule("bare shell -> latest",
             x(*[f"/{s}" for s in SHELLS]),
             f"https://{CDN}/latest/%{{Path.0}}"),
        rule("next/canary -> next",
             x(*[f"/{s}/{c}" for s in SHELLS for c in ("next", "canary")]),
             f"https://{CDN}/next/%{{Path.0}}"),
        rule("pinned version -> archive",
             x(*[f"/{s}/*" for s in SHELLS]),
             f"https://{CDN}/archive/%{{Path.1}}/%{{Path.0}}"),
        rule("docs upstream", x("/docs/*"), "https://ocx.sh/docs/%{Path.1-}"),
        rule("actions upstream", x("/actions/*"), "https://ocx.sh/actions/%{Path.1-}"),

        # Immutable namespaces. archive/<VERSION>/ and dist/<sha256>.json can
        # never change under a given key, so they cache for a year. Everything
        # else falls through to the zone default (300s) — which is what keeps a
        # published release and the dispatch-triggered dist.json refresh
        # actually visible instead of sitting stale at the edge.
        rule("immutable: edge cache", x("/archive/*", "/dist/*"),
             IMMUTABLE, action=EDGE_CACHE),
        rule("immutable: browser cache", x("/archive/*", "/dist/*"),
             IMMUTABLE, action=BROWSER_CACHE),

        # nginx served these as text/plain (immaterial to `curl | <shell>`, but
        # it keeps them inline-viewable in a browser). Bunny infers
        # application/octet-stream from the extensionless / .sh names, so set it
        # back. Expressed as MatchNone over the JSON paths — one rule instead of
        # enumerating every installer URL.
        header_rule("content-type: text/plain",
                    x("/dist.json", "/dist/*", "/dist", "/releases"),
                    "Content-Type", "text/plain; charset=utf-8"),
    ]


def header_rule(desc, exclude_patterns, name, value):
    """SetResponseHeader on everything EXCEPT the given patterns (MatchNone)."""
    chunks = [exclude_patterns[i:i + MAX_PATTERNS]
              for i in range(0, len(exclude_patterns), MAX_PATTERNS)]
    return {
        "ActionType": SET_HEADER,
        "ActionParameter1": name,
        "ActionParameter2": value,
        "TriggerMatchingType": 1,   # MatchAll — every chunk must say "not this"
        "Enabled": True,
        "Description": desc,
        "Triggers": [{"Type": 0, "PatternMatchingType": 2, "Parameter1": "",
                      "PatternMatches": c} for c in chunks],
    }


def call(method, url, data=None):
    key = os.environ["BUNNY_API_KEY"]
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(url, data=body, method=method,
                                 headers={"AccessKey": key,
                                          "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:300]


def existing():
    _, z = call("GET", API)
    return z.get("EdgeRules", []) if isinstance(z, dict) else []


def cmd_plan():
    for i, r in enumerate(ruleset(), 1):
        print(f"{i}. {r['Description']}")
        print(f"     -> {r['ActionParameter1']}")
        for p in r["Triggers"][0]["PatternMatches"]:
            print(f"        {p}")


def zone_diff():
    """[(key, current, desired)] for every ZONE_SETTINGS key that differs."""
    _, z = call("GET", API)
    if not isinstance(z, dict):
        sys.exit(f"could not read pull zone {ZONE}: {z}")
    missing = [k for k in ZONE_SETTINGS if k not in z]
    if missing:
        # A renamed/removed API field must not be silently skipped — it would
        # look like "no drift" forever.
        sys.exit(f"pull zone has no such field(s): {', '.join(missing)}")
    return [(k, z[k], v) for k, v in ZONE_SETTINGS.items() if z[k] != v]


def cmd_zone():
    diff = zone_diff()
    if not diff:
        print("  zone settings already match")
        return 0
    for k, cur, want in diff:
        print(f"  {k:28} {str(cur):>6} -> {want}")
    return 0


def cmd_zone_apply():
    diff = zone_diff()
    if not diff:
        print("  zone settings already match — nothing to apply")
        return 0
    payload = {k: want for k, _, want in diff}
    for k, cur, want in diff:
        print(f"  {k:28} {str(cur):>6} -> {want}")
    s, resp = call("POST", API, payload)
    print(f"  POST -> {s}")
    if s not in (200, 201, 204):
        sys.exit(f"update rejected: {resp}")
    # Re-read: the API answers 204 for a body it partially ignored, so the
    # write is only proven by reading it back.
    left = zone_diff()
    if left:
        for k, cur, want in left:
            print(f"  NOT APPLIED {k:24} {str(cur):>6} != {want}")
        sys.exit("some settings did not take effect")
    print("  all settings confirmed")
    s, _ = call("POST", f"{API}/purgeCache")
    print(f"  purge -> {s}")
    return 0


def cmd_apply():
    for r in existing():
        s, _ = call("DELETE", f"{API}/edgerules/{r['Guid']}")
        print(f"  deleted {r['Guid']} ({r.get('Description')!r}) -> {s}")
    for r in ruleset():
        s, resp = call("POST", f"{API}/edgerules/addOrUpdate", r)
        ok = "ok" if s == 201 else f"FAILED {resp}"
        print(f"  + {r['Description']:28} -> {s} {ok}")
    s, _ = call("POST", f"{API}/purgeCache")
    print(f"  purge -> {s}")


def fetch(path, host=None):
    url = f"https://{host or CDN}{path}"
    try:
        with urllib.request.urlopen(url, timeout=30) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, b""


def cmd_verify():
    bad = 0
    def check(label, path, ref):
        nonlocal bad
        c1, b1 = fetch(path)
        c2, b2 = fetch(ref)
        ok = c1 == 200 and b1 == b2 and len(b1) > 0
        if not ok:
            bad += 1
        print(f"  [{'OK ' if ok else 'XX '}] {label:34} {path:26} {c1} {len(b1)}b  (ref {ref} {c2} {len(b2)}b)")

    for s in SHELLS:
        check(f"bare /{s}", f"/{s}", f"/latest/{s}")
    for s in SHELLS:
        check(f"next /{s}/next", f"/{s}/next", f"/next/{s}")
        check(f"canary /{s}/canary", f"/{s}/canary", f"/next/{s}")
    for s in SHELLS:
        check(f"pinned /{s}/0.1.1", f"/{s}/0.1.1", f"/archive/0.1.1/{s}")
    check("dist alias", "/dist", "/dist.json")
    check("releases alias", "/releases", "/dist.json")

    print("  --- must NOT be rewritten ---")
    for p in ["/archive/0.1.1/install.sh", "/archive/0.1.1/sh", "/dist.json",
              "/dist.json.sha256"]:
        c, b = fetch(p)
        ok = c == 200 and len(b) > 0
        if not ok:
            bad += 1
        print(f"  [{'OK ' if ok else 'XX '}] passthrough {p:34} {c} {len(b)}b")
    print(f"\n  {'ALL PASS' if bad == 0 else str(bad) + ' FAILURES'}")
    return 1 if bad else 0


if __name__ == "__main__":
    c = sys.argv[1] if len(sys.argv) > 1 else "plan"
    if c == "plan":
        cmd_plan()
    elif c == "apply":
        cmd_apply()
    elif c == "verify":
        sys.exit(cmd_verify())
    elif c == "zone":
        sys.exit(cmd_zone())
    elif c == "zone-apply":
        sys.exit(cmd_zone_apply())
    else:
        print(__doc__)
        sys.exit(2)
