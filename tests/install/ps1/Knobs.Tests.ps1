#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }
# Pester tests for src/install.ps1 env-var knobs + the thin `ocx self setup`
# hand-off. Mirrors ../env-knobs.bats.
#
# Latest resolution + the per-target checksum/URL come from the self-hosted
# dist.json (OCX_INSTALL_DIST_URL). The manifest url is a dummy; OCX_INSTALL_MIRROR_URL
# redirects the download to the fixture server.
#
# Cross-platform gating: install.ps1 is cross-platform, but the fixture stub is a
# POSIX `#!/bin/sh` script, so it only EXECUTES on a POSIX host (ubuntu + macos) —
# never on Windows (it is not a PE). Scenarios that execute the stub (the `self
# setup` hand-off, the idempotent version probe) therefore run on the POSIX hosts
# and self-skip on Windows. The skip keys off `$env:OS -eq 'Windows_NT'` rather
# than `$IsWindows` because $IsWindows is undefined under Windows PowerShell 5.1
# (it would fail to skip there). Windows execution coverage lives in the 5.1 smoke
# + the workflow_dispatch real-release jobs. Scenarios that only check exit codes /
# file placement run everywhere; the bin name is ocx.exe on Windows / ocx on Unix
# (Get-FixtureBinName).

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Fixture.psm1') -Force
    $script:InstallPs1 = Join-Path $PSScriptRoot '..\..\..\src\install.ps1'
    $script:Target = Get-FixtureTarget

    $script:FixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-kn-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
    $fixture = New-OcxFixture -Root $FixtureRoot -ArgvLog 'on'
    $script:Server = Start-FixtureServer -SrvRoot $fixture.SrvRoot

    # Content-addressed manifest snapshots (what scripts/publish-dist.sh and
    # `ocx-mirror dist sync` publish beside the rolling dist.json). The "bad" one
    # carries a name whose digest the body does not match - the case a mirror
    # serving an altered manifest produces.
    $script:DistPinSha = Publish-DistSnapshot -SrvRoot $fixture.SrvRoot
    $script:DistPinBadSha = 'a' * 64
    Copy-Item -Path (Join-Path $fixture.SrvRoot 'dist.json') `
        -Destination (Join-Path $fixture.SrvRoot "dist/$DistPinBadSha.json") -Force
}

AfterAll {
    Stop-FixtureServer -Server $Server
    if (Test-Path $FixtureRoot) { Remove-Item -Recurse -Force $FixtureRoot -ErrorAction SilentlyContinue }
}

Describe 'install.ps1 env knobs' {
    BeforeEach {
        $script:OcxHome = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-kn-home-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:ArgvLog = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-kn-argv-$([System.Guid]::NewGuid().ToString('N').Substring(0,8)).log"
        $env:OCX_HOME = $OcxHome
        $env:OCX_NO_MODIFY_PATH = '1'
        $env:OCX_INSTALL_NO_SMOKETEST = '1'
        $env:OCX_STUB_ARGV = $ArgvLog
        $script:EnvLog = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-kn-env-$([System.Guid]::NewGuid().ToString('N').Substring(0,8)).log"
        $env:OCX_STUB_ENV = $EnvLog
        $env:OCX_INSTALL_DIST_URL = $Server.DistUrl
        $env:OCX_INSTALL_MIRROR_URL = $Server.MirrorUrl
        foreach ($v in 'GITHUB_PATH', '__OCX_TESTING_INSTALL_BINARY', 'OCX_INSTALL_PRINT_PATH',
            'OCX_INSTALL_QUIET', 'OCX_INSTALL_FORCE', 'OCX_INSTALL_NO_SETUP', 'OCX_INSTALL_VERSION',
            'OCX_INSTALL_CA_BUNDLE', 'OCX_MANAGED_CONFIG', 'SSL_CERT_FILE', 'SSL_CERT_DIR') {
            Remove-Item "Env:$v" -ErrorAction SilentlyContinue
        }
    }
    AfterEach {
        if (Test-Path $OcxHome) { Remove-Item -Recurse -Force $OcxHome -ErrorAction SilentlyContinue }
        if (Test-Path $ArgvLog) { Remove-Item -Force $ArgvLog -ErrorAction SilentlyContinue }
        if (Test-Path $EnvLog) { Remove-Item -Force $EnvLog -ErrorAction SilentlyContinue }
        # Pester runs every suite in ONE process: an env var left set by the last
        # test in this file leaks into the next file's tests. Clear on the way out.
        foreach ($v in 'OCX_INSTALL_CA_BUNDLE', 'OCX_MANAGED_CONFIG', 'SSL_CERT_FILE', 'SSL_CERT_DIR') {
            Remove-Item "Env:$v" -ErrorAction SilentlyContinue
        }
    }

    It 'default install hands off to ocx self setup <version>' -Skip:($env:OS -eq 'Windows_NT') {
        & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 0
        (Get-Content $ArgvLog) | Should -Contain 'self setup 0.0.0 --no-modify-path'
    }

    It 'OCX_INSTALL_VERSION pins the version' -Skip:($env:OS -eq 'Windows_NT') {
        $env:OCX_INSTALL_VERSION = '0.0.0'
        & pwsh -NoProfile -File $InstallPs1 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 0
        (Get-Content $ArgvLog) | Should -Contain 'self setup 0.0.0 --no-modify-path'
    }

    It 'OCX_INSTALL_NO_SETUP places the binary and skips self setup' {
        $env:OCX_INSTALL_NO_SETUP = '1'
        & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 0
        $bin = Join-Path (Get-ExpectedBinDir -OcxHome $OcxHome) (Get-FixtureBinName)
        Test-Path $bin | Should -BeTrue
        (Test-Path $ArgvLog) | Should -BeFalse
        Test-Path (Join-Path $OcxHome 'env.ps1') | Should -BeFalse
    }

    It 'OCX_INSTALL_PRINT_PATH emits the bin dir as the final stdout line' {
        $env:OCX_INSTALL_NO_SETUP = '1'
        $env:OCX_INSTALL_PRINT_PATH = '1'
        $out = & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' 2>$null
        $LASTEXITCODE | Should -Be 0
        ($out | Select-Object -Last 1) | Should -Be (Get-ExpectedBinDir -OcxHome $OcxHome)
    }

    It 'follows a 302 redirect to the artifact (cross-edition redirect resolver)' {
        # Drive the download through the fixture's /redirect 302 hop so
        # Resolve-DownloadUrl is exercised - the redirect path that crashed
        # Windows PowerShell 5.1 under Set-StrictMode (a bare .Response read on a
        # Location-less Invoke-WebRequest exception). NO_SETUP means no stub
        # execution is needed, so this runs on every host (incl. Windows pwsh 7).
        $env:OCX_INSTALL_NO_SETUP = '1'
        $env:OCX_INSTALL_MIRROR_URL = $Server.RedirectMirrorUrl
        & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 0
        $bin = Join-Path (Get-ExpectedBinDir -OcxHome $OcxHome) (Get-FixtureBinName)
        Test-Path $bin | Should -BeTrue
    }

    It 'checksum mismatch exits 4' {
        $tamperRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-kn-ck-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
        $fx = New-OcxFixture -Root $tamperRoot -TamperChecksum
        $srv = Start-FixtureServer -SrvRoot $fx.SrvRoot
        try {
            $env:OCX_INSTALL_DIST_URL = $srv.DistUrl
            $env:OCX_INSTALL_MIRROR_URL = $srv.MirrorUrl
            & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' 2>$null | Out-Null
            $LASTEXITCODE | Should -Be 4
        }
        finally {
            Stop-FixtureServer -Server $srv
            Remove-Item -Recurse -Force $tamperRoot -ErrorAction SilentlyContinue
        }
    }

    It 'invalid version exits 2' {
        & pwsh -NoProfile -File $InstallPs1 -Version 'foo;rm' 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 2
    }

    It 'unknown flag is rejected by the binder (accepted divergence: non-zero, not 2)' {
        & pwsh -NoProfile -File $InstallPs1 -BogusFlag 2>$null | Out-Null
        $LASTEXITCODE | Should -Not -Be 0
    }

    It 'no manifest row for the (version,target) exits 3' {
        & pwsh -NoProfile -File $InstallPs1 -Version '9.9.9' 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 3
    }

    It 'OCX_INSTALL_FORCE reinstalls when same version present' -Skip:($env:OS -eq 'Windows_NT') {
        $env:OCX_INSTALL_NO_SETUP = '1'
        & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 0
        & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 0
        $env:OCX_INSTALL_FORCE = '1'
        & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 0
    }

    It 'latest version resolves from dist.json (no version pin)' {
        $env:OCX_INSTALL_NO_SETUP = '1'
        & pwsh -NoProfile -File $InstallPs1 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 0
        Test-Path (Join-Path (Get-ExpectedBinDir -OcxHome $OcxHome) (Get-FixtureBinName)) | Should -BeTrue
    }

    It '__OCX_TESTING_INSTALL_BINARY records --offline self setup' -Skip:($env:OS -eq 'Windows_NT') {
        $binDir = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-kn-tb-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
        $stub = New-OcxTestBinary -Dir $binDir -ArgvLog 'on'
        try {
            $env:__OCX_TESTING_INSTALL_BINARY = $stub
            & pwsh -NoProfile -File $InstallPs1 2>$null | Out-Null
            $LASTEXITCODE | Should -Be 0
            Test-Path (Join-Path (Get-ExpectedBinDir -OcxHome $OcxHome) (Get-FixtureBinName)) | Should -BeTrue
            (Get-Content $ArgvLog) | Should -Contain '--offline self setup --no-modify-path'
        }
        finally {
            Remove-Item -Recurse -Force $binDir -ErrorAction SilentlyContinue
        }
    }

    It '__OCX_TESTING_INSTALL_BINARY pointing at a non-file exits 2' {
        $env:__OCX_TESTING_INSTALL_BINARY = Join-Path ([System.IO.Path]::GetTempPath()) 'no-such-ocx-binary.exe'
        & pwsh -NoProfile -File $InstallPs1 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 2
    }

    It 'pinned manifest dist/<sha256>.json installs and is digest-verified' {
        $env:OCX_INSTALL_NO_SETUP = '1'
        $env:OCX_INSTALL_DIST_URL = "http://127.0.0.1:$($Server.Port)/dist/$DistPinSha.json"
        & pwsh -NoProfile -File $InstallPs1 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 0
        Test-Path (Join-Path (Get-ExpectedBinDir -OcxHome $OcxHome) (Get-FixtureBinName)) | Should -BeTrue
    }

    It 'pinned manifest with an altered body exits 4' {
        $env:OCX_INSTALL_DIST_URL = "http://127.0.0.1:$($Server.Port)/dist/$DistPinBadSha.json"
        & pwsh -NoProfile -File $InstallPs1 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 4
    }

    # --- Embedded configuration block (corporate mirrors) ---
    # Mirrors the "embedded config" scenarios in ../env-knobs.bats.

    It 'a sed-ed dist URL is used when the env is unset' -Skip:($env:OS -eq 'Windows_NT') {
        $copy = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-embedded-$([System.Guid]::NewGuid().ToString('N').Substring(0,8)).ps1"
        New-EmbeddedInstaller -Source $InstallPs1 -Destination $copy -Tokens @{
            OCX_INSTALL_DIST_URL   = $Server.DistUrl
            OCX_INSTALL_MIRROR_URL = $Server.MirrorUrl
        } | Out-Null
        Remove-Item Env:OCX_INSTALL_DIST_URL, Env:OCX_INSTALL_MIRROR_URL -ErrorAction SilentlyContinue
        try {
            & pwsh -NoProfile -File $copy -Version '0.0.0' 2>$null | Out-Null
            $LASTEXITCODE | Should -Be 0
            (Get-Content $ArgvLog) | Should -Contain 'self setup 0.0.0 --no-modify-path'
        }
        finally { Remove-Item -Force $copy -ErrorAction SilentlyContinue }
    }

    It 'the environment wins over the embedded value' -Skip:($env:OS -eq 'Windows_NT') {
        $copy = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-embedded-$([System.Guid]::NewGuid().ToString('N').Substring(0,8)).ps1"
        # The embedded manifest URL is dead; BeforeEach still exports the fixture one.
        New-EmbeddedInstaller -Source $InstallPs1 -Destination $copy -Tokens @{
            OCX_INSTALL_DIST_URL = 'https://127.0.0.1:1/dead/dist.json'
        } | Out-Null
        try {
            & pwsh -NoProfile -File $copy -Version '0.0.0' 2>$null | Out-Null
            $LASTEXITCODE | Should -Be 0
            (Get-Content $ArgvLog) | Should -Contain 'self setup 0.0.0 --no-modify-path'
        }
        finally { Remove-Item -Force $copy -ErrorAction SilentlyContinue }
    }

    It 'an embedded managed-config ref is forwarded to ocx self setup' -Skip:($env:OS -eq 'Windows_NT') {
        $copy = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-managed-$([System.Guid]::NewGuid().ToString('N').Substring(0,8)).ps1"
        New-EmbeddedInstaller -Source $InstallPs1 -Destination $copy -Tokens @{
            OCX_MANAGED_CONFIG = 'registry.corp.example/ocx/managed-config:v1'
        } | Out-Null
        try {
            & pwsh -NoProfile -File $copy -Version '0.0.0' 2>$null | Out-Null
            $LASTEXITCODE | Should -Be 0
            (Get-Content $ArgvLog) | Should -Contain 'self setup 0.0.0 --no-modify-path --managed-config registry.corp.example/ocx/managed-config:v1'
        }
        finally { Remove-Item -Force $copy -ErrorAction SilentlyContinue }
    }

    It 'OCX_MANAGED_CONFIG in the env suppresses the embedded flag' -Skip:($env:OS -eq 'Windows_NT') {
        $copy = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-managed-$([System.Guid]::NewGuid().ToString('N').Substring(0,8)).ps1"
        New-EmbeddedInstaller -Source $InstallPs1 -Destination $copy -Tokens @{
            OCX_MANAGED_CONFIG = 'registry.corp.example/ocx/managed-config:v1'
        } | Out-Null
        # `ocx self setup` reads OCX_MANAGED_CONFIG itself, so the installer must
        # not override it with the embedded default.
        $env:OCX_MANAGED_CONFIG = 'registry.other.example/ocx/managed-config:v2'
        try {
            & pwsh -NoProfile -File $copy -Version '0.0.0' 2>$null | Out-Null
            $LASTEXITCODE | Should -Be 0
            (Get-Content $ArgvLog) | Should -Contain 'self setup 0.0.0 --no-modify-path'
            (Get-Content $ArgvLog) -join "`n" | Should -Not -Match '--managed-config'
        }
        finally { Remove-Item -Force $copy -ErrorAction SilentlyContinue }
    }

    # ACCEPTED DIVERGENCE (see .claude/rules/installers.md): Invoke-WebRequest has
    # no 5.1-safe CA-bundle parameter, so install.ps1 parses OCX_INSTALL_CA_BUNDLE
    # and warns instead of honoring it. A uniformly sed-ed installer set must still
    # install here rather than fail.
    It 'OCX_INSTALL_CA_BUNDLE warns and does not fail the install' -Skip:($env:OS -eq 'Windows_NT') {
        $env:OCX_INSTALL_CA_BUNDLE = Join-Path $PSScriptRoot '..\helpers\localhost-cert.pem'
        $errLog = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-ca-$([System.Guid]::NewGuid().ToString('N').Substring(0,8)).err"
        try {
            & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' 2>$errLog | Out-Null
            $LASTEXITCODE | Should -Be 0
            (Get-Content $errLog -Raw) | Should -Match "not honored by install.ps1's own downloads"
        }
        finally { Remove-Item -Force $errLog -ErrorAction SilentlyContinue }
    }

    It 'OCX_INSTALL_CA_BUNDLE is handed to ocx self setup via SSL_CERT_FILE' -Skip:($env:OS -eq 'Windows_NT') {
        # install.ps1 cannot use the bundle for its OWN downloads, but the second
        # hop can: `ocx self setup` pulls the package store itself and reads the
        # host trust store via SSL_CERT_FILE.
        $ca = Join-Path $PSScriptRoot '..\helpers\localhost-cert.pem'
        $env:OCX_INSTALL_CA_BUNDLE = $ca
        & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 0
        (Get-Content $EnvLog) | Should -Contain "SSL_CERT_FILE=$ca"
    }

    It 'OCX_INSTALL_CA_BUNDLE as an inline PEM block is materialized for SSL_CERT_FILE' -Skip:($env:OS -eq 'Windows_NT') {
        $ca = Join-Path $PSScriptRoot '..\helpers\localhost-cert.pem'
        $copy = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-ca-$([System.Guid]::NewGuid().ToString('N').Substring(0,8)).ps1"
        # Prefixed with the comment header a real distro bundle carries, so the
        # scenario exercises detection by CONTENT, not by a leading marker.
        New-EmbeddedInstaller -Source $InstallPs1 -Destination $copy -Tokens @{
            OCX_INSTALL_CA_BUNDLE = "# Corp Root CA`n#`n" + [System.IO.File]::ReadAllText($ca)
        } | Out-Null
        try {
            & pwsh -NoProfile -File $copy -Version '0.0.0' 2>$null | Out-Null
            $LASTEXITCODE | Should -Be 0
            # SSL_CERT_FILE is a PATH, so the inline PEM must be materialized.
            $recorded = (Get-Content $EnvLog) | Where-Object { $_ -like 'SSL_CERT_FILE=*' } | Select-Object -First 1
            $recorded | Should -Match '^SSL_CERT_FILE=.+\.pem$'
            $path = $recorded.Substring('SSL_CERT_FILE='.Length)
            (Get-Content $path -Raw) | Should -Match '-----BEGIN CERTIFICATE-----'
        }
        finally { Remove-Item -Force $copy -ErrorAction SilentlyContinue }
    }

    It 'OCX_INSTALL_CA_BUNDLE neither a file nor inline PEM exits 2' {
        $env:OCX_INSTALL_CA_BUNDLE = Join-Path ([System.IO.Path]::GetTempPath()) 'no-such-ca.pem'
        & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 2
    }

    It 'OCX_INSTALL_CA_BUNDLE does not override an existing SSL_CERT_FILE' -Skip:($env:OS -eq 'Windows_NT') {
        $ca = Join-Path $PSScriptRoot '..\helpers\localhost-cert.pem'
        $preset = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-preset-ca-$([System.Guid]::NewGuid().ToString('N').Substring(0,8)).pem"
        Copy-Item -Path $ca -Destination $preset -Force
        $env:OCX_INSTALL_CA_BUNDLE = $ca
        $env:SSL_CERT_FILE = $preset
        try {
            & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' 2>$null | Out-Null
            $LASTEXITCODE | Should -Be 0
            (Get-Content $EnvLog) | Should -Contain "SSL_CERT_FILE=$preset"
        }
        finally { Remove-Item -Force $preset -ErrorAction SilentlyContinue }
    }
}
