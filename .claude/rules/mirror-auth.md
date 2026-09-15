# Mirror downloads assume anonymous read

`OCX_INSTALL_DIST_URL` / `OCX_INSTALL_MIRROR_URL` point the installers at a
corporate mirror (Artifactory generic repo, static host) holding a copy of
`dist.json` plus `<tag>/<filename>` archives. Today that mirror **must allow
anonymous read** — the download path has no credential knob in any dialect.

- The `OCX_INSTALL_*` grammar has no auth entry. Adding one means all five
  dialects (`sh ps1 nu fish elv`) implement it, plus bats/Pester coverage.
- **CA trust is covered; auth is not.** `OCX_INSTALL_CA_BUNDLE` (a PEM path or
  an inline PEM block, also settable via the `@OCX_INSTALL_CA_BUNDLE@` embedded
  placeholder) lets a mirror behind a TLS-intercepting proxy be reached, and is
  handed to `ocx self setup` as `OCX_EXTRA_CA_CERTS` so the CA persists into
  `config.toml`. That is trust in the transport, not a credential — the mirror
  must still allow anonymous read. `install.ps1` does not honor it for its own
  downloads (see `installers.md`).
- Future support (not now): a header knob (`curl -H`, `Invoke-WebRequest
  -Headers`) or netrc (`curl --netrc`). Pick one and keep it uniform.
- Same gap exists in `find_ocx` (`file(DOWNLOAD)`, has `HTTPHEADER`/`NETRC`)
  and `rules_ocx` (`ctx.download(auth = …)`). Align the knob naming if it lands.
- `ocx-mirror` already picked a naming for the credentialed *upstream* read:
  `OCX_AUTH_<slug>_{TYPE,USER,TOKEN}` (slug = host through ocx's `to_slug`),
  netrc as fallback. Adopt that rather than inventing an `OCX_INSTALL_*` one —
  it is tier-1 shared OCX env, so the `OCX_INSTALL_*` grammar is untouched.
- The inline sha256 in `dist.json` stays the security boundary either way —
  auth controls access, never trust. A mirror may relocate artifacts, never
  alter them.

## Why the auth gap is tolerable: pin the manifest

`ocx-mirror dist sync` and `scripts/publish-dist.sh` both publish every manifest
they emit at `dist/<sha256>.json`, immutable and append-only. Pointing
`OCX_INSTALL_DIST_URL` at one of those pins the whole closure, and the
installers **verify the served body against the digest in the URL** (mismatch →
exit 4). That closes the last unverified hop: with a pin, an anonymous mirror is
pure transport and a tampered manifest is caught, not trusted.

`dist.json.sha256` (the sidecar) is NOT a second boundary — same host, same
anonymous channel, so anything that can rewrite the manifest rewrites the
sidecar. It detects truncation and corruption, nothing more. The digest only
authenticates when it arrives out of band, which is exactly what a pinned URL
recorded in a consumer's config is.
