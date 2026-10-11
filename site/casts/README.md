# Cast keys

Each example on `/install/examples/` embeds one terminal cast through `<Cast name="examples/<slug>" />`.
The key `examples/<slug>` is recorded from the script `casts/examples__<slug>.sh` into `public/casts/examples/<slug>.cast`.
`public/casts/` is gitignored and regenerated; a key with no recorded file renders no player.

| Key | Example |
|---|---|
| `examples/dev-box-sh` | Dev box, POSIX shell |
| `examples/dev-box-pwsh` | Dev box, PowerShell |
| `examples/dev-box-nu` | Dev box, Nushell |
| `examples/dev-box-fish` | Dev box, fish |
| `examples/dev-box-elvish` | Dev box, Elvish |
| `examples/dockerfile` | Build an image with ocx installed |
| `examples/air-gapped` | Install without `ocx self setup`, print the bin dir |
| `examples/ci-wrapper` | Capture the bin dir in a generic CI job |
