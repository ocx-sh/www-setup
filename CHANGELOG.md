# Changelog

All notable changes to this project will be documented in this file.

## [0.2.2](https://github.com/ocx-sh/www-setup/releases/tag/v0.2.2) — 2026-10-11

### Documentation

- Sync README, CONTRIBUTING, CLAUDE.md and the rules with the quality gates by @michael-herwig ([a71822b](https://github.com/ocx-sh/www-setup/commit/a71822bd3cfebdb861fecc0c17d4e5cbdffb5f31))

### Fixed

- **dist:** Widen gen-dist curl retries to survive a release-CDN 500 by @michael-herwig ([bee4f23](https://github.com/ocx-sh/www-setup/commit/bee4f2315008d038eb00285e2998412d0e80cb6f))
- **dist:** Retry manifest generation as a whole on a release-CDN blip by @michael-herwig ([a251c36](https://github.com/ocx-sh/www-setup/commit/a251c3631047ac5bce922aeab6c87d6c4c468a1e))
- **install:** Keep the PowerShell session alive when install.ps1 fails under irm | iex by @michael-herwig ([cdaeb03](https://github.com/ocx-sh/www-setup/commit/cdaeb03b9724564a920aa6346d7cc31eeca6276a))
- **install:** Harden install.sh (fail-closed integrity, signals, probed downloader flags) by @michael-herwig ([3d3aa3c](https://github.com/ocx-sh/www-setup/commit/3d3aa3c534e40b19c577ef81ec3ab091c494ef23))
- **install:** Harden install.ps1 against irm | iex leaks and unverified downloads by @michael-herwig ([f9fcdc7](https://github.com/ocx-sh/www-setup/commit/f9fcdc73e88ea25edb00ce6166f738d2015380c2))
- **install:** Harden install.nu for nu 0.105.1..0.116.1 by @michael-herwig ([9024d69](https://github.com/ocx-sh/www-setup/commit/9024d69419e65a5da6eeec2b08d5804980c33935))
- **install:** Harden install.fish (transport, integrity, signals, cleanup) by @michael-herwig ([db75500](https://github.com/ocx-sh/www-setup/commit/db75500ab8833e90f6628c78a8d51ab2598d5720))
- **install:** Harden install.elv (fail-closed integrity, https-only, cleanup, libc) by @michael-herwig ([00a78f5](https://github.com/ocx-sh/www-setup/commit/00a78f5b57bb07da7f76f2615c9c1650ce844f17))
- **scripts:** Keep publish credentials off argv and stop on a signal by @michael-herwig ([ab4bd92](https://github.com/ocx-sh/www-setup/commit/ab4bd92cc75bea0a7a4bb1c5f40dbf379225d2d9))
- **docker:** Fail the matrix cell when a shell is missing or a download fails by @michael-herwig ([97952a8](https://github.com/ocx-sh/www-setup/commit/97952a8a9f025154a40c53bd3f98623e0149999b))
## [0.2.1](https://github.com/ocx-sh/www-setup/releases/tag/v0.2.1) — 2026-09-15

### Added

- **bunny:** Codify the pull-zone resilience settings by @michael-herwig ([08f68ab](https://github.com/ocx-sh/www-setup/commit/08f68ab59ca4f4c548f272428a44fe6721cfa3f0))
- **install:** Hand OCX_INSTALL_CA_BUNDLE to ocx self setup as OCX_EXTRA_CA_CERTS by @michael-herwig ([d759d12](https://github.com/ocx-sh/www-setup/commit/d759d12e6d538136547adcfcf91d889681a66760))

### Fixed

- **install:** Retry transient download failures in all five installers by @michael-herwig ([f1c6745](https://github.com/ocx-sh/www-setup/commit/f1c67459569b7df7f0bc68065b482d86195872a5))
## [0.2.0](https://github.com/ocx-sh/www-setup/releases/tag/v0.2.0) — 2026-08-26

### Added

- **install:** Sed-able embedded configuration block for corporate mirrors by @michael-herwig ([e8c62c0](https://github.com/ocx-sh/www-setup/commit/e8c62c035b5e8f552520496557b6f6589846a158))

### Documentation

- Document corporate-mirror patching and the CA bundle by @michael-herwig ([da4f5d9](https://github.com/ocx-sh/www-setup/commit/da4f5d91cf1e2641b8387422fa86cb0a2071410b))

### Fixed

- **ci:** Declare the release commit type so cog check passes on PRs by @michael-herwig ([2ae27fd](https://github.com/ocx-sh/www-setup/commit/2ae27fd4f49e1f5e7fa4bf237d02a1dc6cc1606a))
## [0.1.2](https://github.com/ocx-sh/www-setup/releases/tag/v0.1.2) — 2026-08-25

### Added

- **install:** Verify content-addressed manifest pins by @michael-herwig ([3dade84](https://github.com/ocx-sh/www-setup/commit/3dade84725e9945ef4ff30917183f26409d77819))
- **publish:** Move setup.ocx.sh to Bunny CDN by @michael-herwig ([0fea12b](https://github.com/ocx-sh/www-setup/commit/0fea12bdb5e6096f61e15d613dfe42cf6e0569ce))

### Documentation

- Fix duplicated ordered-list prefix in testing-pwsh rules by @michael-herwig ([b583d63](https://github.com/ocx-sh/www-setup/commit/b583d631935dc2e4b46c22725f0cd60090bfe5d1))

### Fixed

- **release:** Unbreak release:prepare and add interactive bump by @michael-herwig ([abe68a5](https://github.com/ocx-sh/www-setup/commit/abe68a5d1706d952afd9cd11e423cd5539da2654))
## [0.1.1](https://github.com/ocx-sh/www-setup/releases/tag/v0.1.1) — 2026-06-30

### Fixed

- **release:** Generate full stable notes across prerelease tags by @michael-herwig ([93c02d7](https://github.com/ocx-sh/www-setup/commit/93c02d70253015d97382a37e34b31e4366180543))
- **publish:** Advance next/ pointer on stable releases by @michael-herwig ([30ae693](https://github.com/ocx-sh/www-setup/commit/30ae6933017e4af011d2530f1a503bfeb7609ea0))
- **ci:** Scope fish to ocx.toml [group.unix] so Windows project ops resolve by @michael-herwig ([0f3af46](https://github.com/ocx-sh/www-setup/commit/0f3af46b52fb931cba679480eefb90655f619e49))
- **install:** Follow GitHub asset redirect on Windows PowerShell 5.1 by @michael-herwig ([c6eac98](https://github.com/ocx-sh/www-setup/commit/c6eac98b5443334e132d859a3525703256083ccd))
## [0.1.0](https://github.com/ocx-sh/www-setup/releases/tag/v0.1.0) — 2026-06-29

### Added

- Bootstrap setup.ocx.sh as installer-script host by @michael-herwig ([1bf221a](https://github.com/ocx-sh/www-setup/commit/1bf221af89090b4c50012adb47252138a7dd6070))
- Reconcile installers with real OCX CLI and harden by @michael-herwig ([f621247](https://github.com/ocx-sh/www-setup/commit/f621247b2711d1bc25bd591e524a4a5f708ea58b))
- Thin all-shell installers, dist.json manifest, vendored bats by @michael-herwig ([2f25bbc](https://github.com/ocx-sh/www-setup/commit/2f25bbc8cd1caf0cbbd96d92355e832abbb22a7a))
- **install:** Make install.ps1 cross-platform (Windows + Linux + macOS) by @michael-herwig ([a38cc69](https://github.com/ocx-sh/www-setup/commit/a38cc695f5edc68be811d43b92a48e3e5d7fa7e2))

### Changed

- **publish:** Version-major installer URL layout (archive/latest/next) by @michael-herwig ([ff1ffa2](https://github.com/ocx-sh/www-setup/commit/ff1ffa256e1c7265f38e72e347743596f2a5d565))

### Fixed

- **install:** Correct nu/elvish activation; add docker shell-axis tests by @michael-herwig ([e29b696](https://github.com/ocx-sh/www-setup/commit/e29b696d4c713d47e2e428ff73f675057539f6fa))
- **install:** Use macOS bsdtar-compatible tar extraction flags by @michael-herwig ([6bd59b2](https://github.com/ocx-sh/www-setup/commit/6bd59b2eb2dfa98c2d37bb30fedc039d04501687))
- **publish:** Make uploaded dist.json world-readable by @michael-herwig ([83c2744](https://github.com/ocx-sh/www-setup/commit/83c274401bc4f88bb821caa00e7f9eddc55c3aae))
- **publish:** Create remote dirs with rsync --mkpath, not ssh mkdir by @michael-herwig ([0d9e3c1](https://github.com/ocx-sh/www-setup/commit/0d9e3c13bbffe132d80d6bd4c78f37b8945f4c50))
