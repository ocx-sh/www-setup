# Bash testing rules (Bats)

## Vendored Bats

Bats is vendored as git submodules under `external/` — run
`git submodule update --init --recursive` (or `task test:bootstrap`) once, then
invoke `external/bats-core/bin/bats -r tests/install/`. `tests/install/helpers/load.bash`
loads `bats-support` + `bats-assert` so new suites can use
`assert_success`/`assert_output`; the existing top-level suites keep raw
`[ "$status" -eq N ]` and gain library availability.

## Layout

```
tests/install/
├── env-knobs.bats             # OCX_INSTALL_* env var behavior + the self-setup hand-off
├── exit-codes.bats            # Numbered exit codes 3/4/5/6 (2 + no-row/3 in env-knobs)
├── print-path.bats            # Stdout/stderr discipline + OCX_INSTALL_PRINT_PATH
├── dist.bats                  # scripts/gen-dist.sh manifest generator (offline hatches)
├── {nu,fish,elvish}/          # Per-shell installer suites (gate on `command -v <shell>`)
├── helpers/
│   ├── server.bash            # Runtime fixture builder + HTTPS server helpers
│   ├── load.bash              # loads bats-support + bats-assert (from external/)
│   ├── localhost-cert.pem     # CA cert tests trust (CURL_CA_BUNDLE)
│   └── localhost-combined.pem # key + cert the python HTTPS server loads
└── fixtures/                  # EMPTY — fixtures are built at runtime (see below)
```

> `fixtures/` is intentionally empty. There are **no** static tarballs checked
> in. The whole release tree (archive + a `dist.json` manifest with an inline
> `sha256`) is generated per-test by `helpers/server.bash`.

## Runtime fixture builder (`helpers/server.bash`)

`load helpers/server` (or `load ../helpers/server` from the per-shell dirs)
exposes:

| Function | Purpose |
|---|---|
| `server_detect_target` | Echo the current `<arch>-<os>-<libc>` triple so the fixture archive name matches what the installer's `detect_target` will request. |
| `server_build_fixture ROOT [LAYOUT]` | Build a v0.0.0 release tree under `ROOT`: `releases/download/v0.0.0/ocx-<target>.tar.xz`, then a `dist.json` manifest with the archive's inline `sha256`. Echoes the target triple. |
| `server_write_dist ROOT TARGET SHA FILE` | (Re)write a single-release `dist.json` — used by tamper tests (e.g. a wrong `sha256` for the exit-4 path). |
| `server_publish_dist_snapshot ROOT` | Copy `dist.json` to the content-addressed `dist/<sha256>.json` and echo the digest — the pinned-manifest path. Appending a byte to the snapshot afterwards produces the altered-body (exit 4) case. |
| `server_finalize_dist_url ROOT BASE` | Rewrite the dummy manifest `url` to the real fixture server (for the one URL-passthrough test that drops `OCX_INSTALL_MIRROR_URL`). |
| `server_stub_body` | Emit the body of the fixture `ocx` stub binary packed into the archive. |
| `server_sha256 FILE` | Portable sha256 of `FILE` — coreutils `sha256sum` (Linux) or BSD/macOS `shasum -a 256`. Use this in suites instead of bare `sha256sum` so the tamper tests run on the macOS Bats leg. |
| `server_start ROOT LOGFILE` | Spin a python3 `ssl`-wrapped server on an ephemeral port against `ROOT`; echo `PID PORT`. Serves **HTTPS** (see below). |
| `server_stop PID` | Kill the server. |
| `server_path_without_curl` | Echo a PATH mirroring the current one with `curl` genuinely absent (a symlink farm, built once per file). The only portable way to force a dialect's **wget** fallback — `command -v curl` skips non-executables and keeps searching, so shadowing does not work. |
| `server_ca_bundle` | Echo the path to the vendored localhost CA cert; export as `CURL_CA_BUNDLE`. |
| `server_embed_config SRC DEST TOKEN=VALUE...` | Copy an installer and substitute its embedded-config placeholders, the way a corporate mirror patches its copy. TOKEN is the bare env name (`OCX_INSTALL_DIST_URL`); the `@...@` wrapper is added for you. A plain literal replace with NO per-shell special-casing — that is what makes it a regression test for the uniform-sed contract. VALUE may contain newlines (an inline PEM). |
| `server_request_count LOGFILE NEEDLE` | Count `GET` lines matching NEEDLE in the server log. The python access log already lands in LOGFILE, so this is a `grep -c` — it is what lets a test assert the installer really did try N times. |

### The `/flaky/<n>/<path>` route

`server_start`'s handler answers **HTTP 500 for the first `<n>` requests** to a
given `/flaky/<n>/<path>` URL, then serves `<path>` normally. The hit counter is
a **class** attribute, because `BaseHTTPRequestHandler` builds a new instance
per request — instance state would reset every time.

This is how the retry contract is tested. Point a knob at a flaky prefix:

```bash
OCX_INSTALL_DIST_URL="${FIXTURE_URL}/flaky/2/dist.json"          # manifest fails twice
OCX_INSTALL_MIRROR_URL="${FIXTURE_URL}/flaky/2/releases/download" # archive fails twice
OCX_INSTALL_DIST_URL="${FIXTURE_URL}/flaky/99/dist.json"          # never succeeds → exit 3
```

It reproduces the real incident (one CDN edge PoP 500ing while the object is
fine) without a live CDN. Pair the exit-code assertion with
`server_request_count` — asserting only the exit code would pass even if retry
were silently removed.

### HTTPS, not HTTP

The installers enforce TLS on every download — curl runs with `--proto '=https'`
and the wget path calls `assert_https_url`. So the fixture server **must** speak
HTTPS, and every fixture URL uses `https://127.0.0.1:PORT`. A static, long-lived
self-signed cert for `127.0.0.1` is vendored next to the helper
(`localhost-cert.pem` = the CA tests trust via `CURL_CA_BUNDLE`;
`localhost-combined.pem` = key + cert python's `ssl` loads). Trusting one
localhost test cert does **not** disable TLS verification. If the cert ever
expires (dated ~100 years out), regenerate a 127.0.0.1 self-signed cert and
replace both PEMs.

### dist.json + the mirror redirect

`server_build_fixture` writes a `dist.json` whose single `releases[]` row carries
the archive's inline `sha256`, but whose `url` is a **dummy**
(`https://example.invalid/...`). Tests redirect the artifact download to the
fixture by setting `OCX_INSTALL_MIRROR_URL=${FIXTURE_URL}/releases/download` — the
installer rewrites the `url` to `<MIRROR_URL>/<tag>/<filename>`. One dedicated
test calls `server_finalize_dist_url` and drops the mirror to exercise the
manifest-`url` passthrough. There is **no** separate `sha256.sum` file — the
checksum is inline in the manifest.

### Archive layout variants

`server_build_fixture` takes a second arg:

- `nested` (default) — binary at `ocx-<target>/ocx`.
- `flat` — binary at the **archive root** (`ocx`). The real cargo-dist layout; at
  least one test must use it.

### The `ocx` stub binary

The stub packed into the fixture archive (`server_stub_body`):

- answers `version` (`0.0.0`) and `about` (a plausible banner),
- answers the `ocx self setup [...]` and `--offline self setup [...]` hand-off by
  exiting **0** (the thin installer hands off to `ocx self setup`; the stub no
  longer emits shims or completion — `ocx self setup` owns that),
- **records its full argv** (one line per invocation) to `$OCX_STUB_ARGV` when set,
- **records `SSL_CERT_FILE`** to `$OCX_STUB_ENV` when set — the CA suites assert the
  installer hands its bundle down to the `ocx self setup` hop, not just to curl/wget.

The argv recording is load-bearing: it lets a test assert the **exact** hand-off

```
self setup 0.0.0 --no-modify-path          # default path (version positional)
--offline self setup --no-modify-path      # test-hatch path (global --offline pre-flag)
```

A regression to the old `--remote package install` bootstrap would fail the
assertion.

## `__OCX_TESTING_INSTALL_BINARY` — internal test-only download-skip hatch

`__OCX_TESTING_INSTALL_BINARY` is the installer's internal, **undocumented**,
test-only hatch (double-underscore; never in `usage()`/README env matrix). Set it
to a path and the installer skips download + checksum + extract + the network
manifest probe, copies that file to the canonical bin dir + `chmod +x`, then
either runs `<bin> --offline self setup [--no-modify-path]` (default) or, under
`OCX_INSTALL_NO_SETUP`, places the binary only. It honors `OCX_INSTALL_PRINT_PATH`.
The tests **own** this hatch. Assert:

- happy path: binary present + executable at the canonical bin dir, the recorded
  `--offline self setup` argv, **no** archive fetched;
- bad path (`__OCX_TESTING_INSTALL_BINARY=/nonexistent`) → exit **2** (message
  contains the substring `__OCX_TESTING_INSTALL_BINARY`);
- `OCX_INSTALL_PRINT_PATH` still emits the bin dir as the final stdout line.

## Install modes under test

| Mode | How | What happens | What to assert |
|---|---|---|---|
| **self setup** (default) | leave `OCX_INSTALL_NO_SETUP` unset | downloads + verifies + extracts, then runs `ocx self setup <version> [--no-modify-path]`. The binary is NOT copied to the bin dir (a real `self setup` would populate the store; the stub no-ops). | the recorded `self setup <version>` argv + exit 0. |
| **no-setup** | `OCX_INSTALL_NO_SETUP=1` | copies the binary to `$OCX_HOME/symlinks/ocx.sh/ocx/cli/current/content/bin/ocx`; **no** `self setup`. The CI/air-gapped path. | the binary present + executable at the canonical bin dir; **no** `self setup` argv; no env shims. |

The idempotent fast-path keys off the binary being present at the canonical bin
dir, so tests for `OCX_INSTALL_FORCE` / idempotency must run in **no-setup** mode.

## Standard `setup_file` / `setup` shape

```bash
setup_file() {
  export FIXTURE_DIR="${BATS_FILE_TMPDIR}/srv"
  FIXTURE_TARGET=$(server_build_fixture "$FIXTURE_DIR")
  export FIXTURE_TARGET
  local _info
  _info=$(server_start "$FIXTURE_DIR" "${BATS_FILE_TMPDIR}/server.log")
  export FIXTURE_PID="${_info% *}" FIXTURE_PORT="${_info#* }"
  export FIXTURE_URL="https://127.0.0.1:${FIXTURE_PORT}"
}
teardown_file() { server_stop "${FIXTURE_PID:-}"; }

setup() {
  export OCX_HOME="${BATS_TEST_TMPDIR}/.ocx"
  export OCX_NO_MODIFY_PATH=1
  export CURL_CA_BUNDLE; CURL_CA_BUNDLE="$(server_ca_bundle)"   # trust fixture cert
  export OCX_STUB_ARGV="${BATS_TEST_TMPDIR}/stub-argv.log"
  export OCX_INSTALL_DIST_URL="${FIXTURE_URL}/dist.json"               # manifest at the fixture
  export OCX_INSTALL_MIRROR_URL="${FIXTURE_URL}/releases/download"     # redirect the artifact download
  unset GITHUB_PATH OCX_INSTALL_NO_SETUP OCX_INSTALL_VERSION __OCX_TESTING_INSTALL_BINARY
}
```

The canonical bin subpath asserted in tests is
`symlinks/ocx.sh/ocx/cli/current/content/bin` (mirrors `OCX_BIN_SUBPATH` in
`src/install.sh`).

## Per-shell suites (`tests/install/{nu,fish,elvish}/`)

Each exotic installer has a per-shell suite that `load ../helpers/server` +
`load ../helpers/load` and gates every test on `command -v <shell>` (skip when
absent — fish runs locally; nu/elvish run in the docker matrix). fish/elvish use
curl/`e:curl` (trust `CURL_CA_BUNDLE`) so the full download path runs; nu falls
back to `^curl` for the same reason. Assert the same contract: exit codes 2–4,
print-path = bin dir, the recorded `self setup` argv, and the `__OCX_TESTING_INSTALL_BINARY`
hatch.

## Conventions

- Use `run` for commands that may fail — never bare `sh "$INSTALL_SH"`.
- Assert exit code AND output when both are meaningful. For the hand-off, assert
  the recorded argv, not just the exit code.
- Tests must not require network. The runtime fixture server (HTTPS, localhost)
  is the only network endpoint allowed.
- `dist.bats` drives `gen-dist.sh` via its offline hatches (`--releases-file`,
  `--checksums-dir`) — use `run --separate-stderr` so the generator's "skipping"
  warnings (stderr) don't corrupt the parsed `$output`.
- **macOS / bash-3.2 safety.** The suites run on the `bats-macos` CI leg under the
  stock `/bin/bash` (3.2). Keep them 3.2-safe: NO negative array subscripts — use
  `${lines[${#lines[@]}-1]}`, not `${lines[-1]}` (array subscripts are arithmetic
  context, so count-1 works; a literal `-1` does not). No `declare -A`, `mapfile`,
  or `${var,,}`/`${var^^}`. For checksums use `server_sha256`, never bare
  `sha256sum` (macOS ships `shasum`, not `sha256sum`). The macOS leg runs the
  install suites (sh + nu + fish + elvish, via `ocx run -g all nushell fish
  elvish`); `dist.bats` is excluded (CI-side Linux generator). `-g all` is
  required because fish lives in ocx.toml `[group.unix]` (no windows leaf), not
  the default `[tools]` scope; pwsh lives in `[group.linux]` (linux-glibc
  leaves only) — `ocx run` resolves only named tools, so neither blocks a
  macOS run, but the setup-ocx pull is scoped `default,unix` on macOS.

## When to update tests

| Change | Tests to add/update |
|---|---|
| New env knob | `env-knobs.bats` — happy path + invalid value |
| New exit code | `exit-codes.bats` — at least one triggering scenario |
| Stdout/stderr change | `print-path.bats` — verify the discipline still holds |
| New flag | `env-knobs.bats` — long form parses, short form (if any) parses |
| Bin-path / `self setup` argv change | flip the path string in all suites, update the `server_stub_body` + the argv assertions, update this file |
| New archive layout | add a `server_build_fixture ... <layout>` variant + a test |
| Latest-resolution / manifest format change | `env-knobs.bats` (latest via `dist.json`) + `exit-codes.bats` (dead manifest → exit 3, message contains `latest version`) + `dist.bats` (generator shape) |
| Manifest-pin (`dist/<sha256>.json`) behavior change | `env-knobs.bats` + every `tests/install/{nu,fish,elvish}/` suite — the happy path (installs) and the altered-body path (exit 4), both via `server_publish_dist_snapshot` |
| `__OCX_TESTING_INSTALL_BINARY` behavior change | `env-knobs.bats` (happy: no download, binary placed, `--offline self setup` argv) + `exit-codes.bats` (bad → exit 2) + `print-path.bats` (PRINT_PATH honored) |
| Download-retry behavior change | `exit-codes.bats` + every `tests/install/{nu,fish,elvish}/` suite + `ps1/ExitCodes.Tests.ps1` — the transient-500-then-success path (`/flaky/2/`), the never-succeeds path (`/flaky/99/` → exit 3), and the archive-retry path, each asserting the ATTEMPT COUNT via `server_request_count`, not just the exit code |
| Embedded-config placeholder added/renamed | `env-knobs.bats` + every `tests/install/{nu,fish,elvish}/` suite + `ps1/Knobs.Tests.ps1` — patch a copy via `server_embed_config` / `New-EmbeddedInstaller` and assert the effect, plus one case proving the environment still wins |
| `OCX_INSTALL_CA_BUNDLE` behavior change | all five suites — the inline-PEM happy path with `CURL_CA_BUNDLE` UNSET (that is what proves the flag reaches curl), the matching **negative control** (no bundle → non-zero; without it the happy path proves nothing), the `SSL_CERT_FILE` hand-down assertion, and the neither-file-nor-PEM → exit 2 case. `env-knobs.bats` additionally covers the **wget** backend via `OCX_INSTALL_DOWNLOADER=wget`, and the fish suite via `server_path_without_curl`. ps1 asserts the divergence warning + the hand-down instead |
| New exotic installer behavior | the matching `tests/install/{nu,fish,elvish}/` suite |
