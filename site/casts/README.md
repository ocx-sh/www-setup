# Cast keys

Each cast is embedded with `<Cast name="<page>/<slug>" />`, where `<page>` is the page file name, today `examples`.
The key `<page>/<slug>` is recorded from the script `casts/<page>__<slug>.sh` into `public/casts/<page>/<slug>.cast`.
`public/casts/` is gitignored and regenerated; a key with no recorded file renders no player.

| Key | Example |
|---|---|
| `examples/dockerfile` | Build an image with ocx installed |
| `examples/air-gapped` | Install without `ocx self setup`, print the bin dir |
| `examples/ci-wrapper` | Capture the bin dir in a generic CI job |
