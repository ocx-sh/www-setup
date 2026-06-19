#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }
# Pester tests for src/install.ps1 env-var knobs + the thin `ocx self setup`
# hand-off. Mirrors ../env-knobs.bats.
#
# Latest resolution + the per-target checksum/URL come from the self-hosted
# dist.json (OCX_INSTALL_DIST_URL). The manifest url is a dummy; OCX_INSTALL_MIRROR_URL
# redirects the download to the fixture server.
#
# Cross-platform gating: the fixture stub is a POSIX `#!/bin/sh` script named
# ocx.exe, so it only EXECUTES on a POSIX host — never on Windows (it is not a
# PE). Scenarios that execute the stub's `self setup` hand-off therefore run on
# ubuntu-pwsh and self-skip on Windows (-Skip:$IsWindows); a real native ocx is
# exercised by the workflow_dispatch real-release jobs. Scenarios that only check
# exit codes / file placement run everywhere.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Fixture.psm1') -Force
    $script:InstallPs1 = Join-Path $PSScriptRoot '..\..\..\src\install.ps1'
    $script:Target = Get-FixtureTarget

    $script:FixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-kn-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
    $fixture = New-OcxFixture -Root $FixtureRoot -ArgvLog 'on'
    $script:Server = Start-FixtureServer -SrvRoot $fixture.SrvRoot
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
        $env:OCX_INSTALL_DIST_URL = $Server.DistUrl
        $env:OCX_INSTALL_MIRROR_URL = $Server.MirrorUrl
        foreach ($v in 'GITHUB_PATH', '__OCX_TESTING_INSTALL_BINARY', 'OCX_INSTALL_PRINT_PATH',
            'OCX_INSTALL_QUIET', 'OCX_INSTALL_FORCE', 'OCX_INSTALL_NO_SETUP', 'OCX_INSTALL_VERSION') {
            Remove-Item "Env:$v" -ErrorAction SilentlyContinue
        }
    }
    AfterEach {
        if (Test-Path $OcxHome) { Remove-Item -Recurse -Force $OcxHome -ErrorAction SilentlyContinue }
        if (Test-Path $ArgvLog) { Remove-Item -Force $ArgvLog -ErrorAction SilentlyContinue }
    }

    It 'default install hands off to ocx self setup <version>' -Skip:$IsWindows {
        & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 0
        (Get-Content $ArgvLog) | Should -Contain 'self setup 0.0.0 --no-modify-path'
    }

    It 'OCX_INSTALL_VERSION pins the version' -Skip:$IsWindows {
        $env:OCX_INSTALL_VERSION = '0.0.0'
        & pwsh -NoProfile -File $InstallPs1 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 0
        (Get-Content $ArgvLog) | Should -Contain 'self setup 0.0.0 --no-modify-path'
    }

    It 'OCX_INSTALL_NO_SETUP places the binary and skips self setup' {
        $env:OCX_INSTALL_NO_SETUP = '1'
        & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 0
        $bin = Join-Path (Get-ExpectedBinDir -OcxHome $OcxHome) 'ocx.exe'
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

    It 'OCX_INSTALL_FORCE reinstalls when same version present' -Skip:(-not $IsWindows) {
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
        Test-Path (Join-Path (Get-ExpectedBinDir -OcxHome $OcxHome) 'ocx.exe') | Should -BeTrue
    }

    It '__OCX_TESTING_INSTALL_BINARY records --offline self setup' -Skip:$IsWindows {
        $binDir = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-kn-tb-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
        $stub = New-OcxTestBinary -Dir $binDir -ArgvLog 'on'
        try {
            $env:__OCX_TESTING_INSTALL_BINARY = $stub
            & pwsh -NoProfile -File $InstallPs1 2>$null | Out-Null
            $LASTEXITCODE | Should -Be 0
            Test-Path (Join-Path (Get-ExpectedBinDir -OcxHome $OcxHome) 'ocx.exe') | Should -BeTrue
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
}
