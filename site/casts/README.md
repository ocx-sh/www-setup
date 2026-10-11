# Cast keys

Each example on `/install/examples/` embeds one terminal cast through `<Cast name="examples/<slug>" />`.
The key `examples/<slug>` is recorded from the script `casts/examples__<slug>.sh` into `public/casts/examples/<slug>.cast`.
`public/casts/` is committed: no build step regenerates it, and CI does not record. Re-record with `task site:casts`
(one cast: `task site:casts -- --only examples/dev-box-sh`) after an installer or an `ocx self setup` output changes,
then run `task site:test`, whose `session-casts.test.mjs` fails when a page session shows a byte the cast does not.

| Key | Example |
|---|---|
| `examples/dev-box-sh` | Dev box, POSIX shell (also the landing page session) |
| `examples/dev-box-pwsh` | Dev box, PowerShell 7 on Linux |
| `examples/dev-box-nu` | Dev box, Nushell |
| `examples/dev-box-fish` | Dev box, fish |
| `examples/dev-box-elvish` | Dev box, Elvish |
| `examples/dockerfile` | Build an image with ocx installed |
| `examples/air-gapped` | Install without `ocx self setup`, print the bin dir |
| `examples/ci-wrapper` | Capture the bin dir in a generic CI job |

## How a cast is recorded

Every cast is a real run against the published `setup.ocx.sh`, so recording needs network and docker.
The recorder builds `casts/Dockerfile` (Ubuntu with every installer's shell, from `tests/docker/install-shells.sh`, and a
user `runner`), then runs each script's driver in a fresh container under `asciinema rec` (`scripts/run-cast-script.sh`).
Only the typed command line is simulated. `examples/dockerfile` is the exception: it drives docker itself, so
`# runner: host` runs it on the recording machine.

- The `cast` region is what the page shows and the recording types. `setup` and the verification after it run silently.
- Headers (`# cast`, `# doc`, `# title`, `# description`, optional `# runner` and `# eval`) come first, then a blank line.
  `# eval: pwsh -NoProfile -Command` runs each typed block through that command instead of bash.
- The recorder sanitises the cast (random temp names, timings, the recording machine's home) and fails when a host path is left.
- The air-gapped run uses `setup.ocx.sh` itself, not a corporate mirror; the page's mirror variables are prose.

Run one script by hand: `docker build -f site/casts/Dockerfile -t ocx-casts . && docker run --rm -it -v "$PWD/site/casts:/c:ro" ocx-casts bash /c/examples__dev-box-sh.sh`
(the headers and region markers are comments, so a script also runs as plain bash).
