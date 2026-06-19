#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }
# Stdout/stderr discipline for src/install.ps1. Mirrors ../print-path.bats.
#
# The load-bearing contract: all informational/warning/error output goes to
# STDERR; STDOUT is silent on success unless OCX_INSTALL_PRINT_PATH=1 (or
# -PrintPath), in which case the FINAL stdout line is the absolute bin dir.
#
# We split the streams with `2>$errFile`, so $out is pure stdout. These tests use
# OCX_INSTALL_NO_SETUP (and the test hatch) so they never execute the extracted
# .zip binary — that has no +x on a non-Windows pwsh host — keeping the discipline
# assertions meaningful on ubuntu-pwsh as well as windows-latest.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Fixture.psm1') -Force
    $script:InstallPs1 = Join-Path $PSScriptRoot '..\..\..\src\install.ps1'
    $script:Target = Get-FixtureTarget

    $script:FixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-pp-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
    $fixture = New-OcxFixture -Root $FixtureRoot
    $script:Server = Start-FixtureServer -SrvRoot $fixture.SrvRoot
}

AfterAll {
    Stop-FixtureServer -Server $Server
    if (Test-Path $FixtureRoot) { Remove-Item -Recurse -Force $FixtureRoot -ErrorAction SilentlyContinue }
}

Describe 'install.ps1 stdout/stderr discipline' {
    BeforeEach {
        $script:OcxHome = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-pp-home-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:ErrFile = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-pp-err-$([System.Guid]::NewGuid().ToString('N').Substring(0,8)).log"
        $env:OCX_HOME = $OcxHome
        $env:OCX_NO_MODIFY_PATH = '1'
        $env:OCX_INSTALL_NO_SMOKETEST = '1'
        $env:OCX_INSTALL_NO_SETUP = '1'
        $env:OCX_INSTALL_DIST_URL = $Server.DistUrl
        $env:OCX_INSTALL_MIRROR_URL = $Server.MirrorUrl
        foreach ($v in 'GITHUB_PATH', '__OCX_TESTING_INSTALL_BINARY', 'OCX_INSTALL_PRINT_PATH',
            'OCX_INSTALL_QUIET', 'OCX_INSTALL_FORCE', 'OCX_INSTALL_VERSION', 'OCX_STUB_ARGV') {
            Remove-Item "Env:$v" -ErrorAction SilentlyContinue
        }
    }
    AfterEach {
        if (Test-Path $OcxHome) { Remove-Item -Recurse -Force $OcxHome -ErrorAction SilentlyContinue }
        if (Test-Path $ErrFile) { Remove-Item -Force $ErrFile -ErrorAction SilentlyContinue }
    }

    It 'stdout is empty on success (no PRINT_PATH)' {
        $out = & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' 2>$ErrFile
        $LASTEXITCODE | Should -Be 0
        ($out | Where-Object { $_ -ne '' }) | Should -BeNullOrEmpty
        # ...and the installer was not silent: its banner went to stderr.
        (Get-Content $ErrFile -Raw) | Should -Not -BeNullOrEmpty
    }

    It 'OCX_INSTALL_PRINT_PATH prints the bin dir as the final stdout line' {
        $env:OCX_INSTALL_PRINT_PATH = '1'
        $out = & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' 2>$ErrFile
        $LASTEXITCODE | Should -Be 0
        ($out | Select-Object -Last 1) | Should -Be (Get-ExpectedBinDir -OcxHome $OcxHome)
    }

    It 'stderr carries informational lines even with PRINT_PATH set' {
        $env:OCX_INSTALL_PRINT_PATH = '1'
        $out = & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' 2>$ErrFile
        $LASTEXITCODE | Should -Be 0
        (Get-Content $ErrFile -Raw) | Should -Match 'Installing|Detected|Downloading|Verified|Installed'
        # The banner must NOT have leaked onto stdout.
        (($out -join "`n")) | Should -Not -Match 'Installing|Detected|Downloading'
    }

    It 'OCX_INSTALL_QUIET silences stderr informational lines' {
        $env:OCX_INSTALL_QUIET = '1'
        & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' 2>$ErrFile | Out-Null
        $LASTEXITCODE | Should -Be 0
        $err = Get-Content $ErrFile -Raw
        if ($err) { $err | Should -Not -Match 'Installing|Downloading|Detected platform' }
    }

    It 'error messages go to stderr (exit 2 path)' {
        $out = & pwsh -NoProfile -File $InstallPs1 -Version 'foo;rm' 2>$ErrFile
        $LASTEXITCODE | Should -Be 2
        ($out | Where-Object { $_ -ne '' }) | Should -BeNullOrEmpty
        (Get-Content $ErrFile -Raw) | Should -Match 'Invalid|invalid|error'
    }

    It '__OCX_TESTING_INSTALL_BINARY honors PRINT_PATH on the final stdout line' {
        $binDir = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-pp-tb-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
        $stub = New-OcxTestBinary -Dir $binDir
        try {
            $env:__OCX_TESTING_INSTALL_BINARY = $stub
            $env:OCX_INSTALL_PRINT_PATH = '1'
            $out = & pwsh -NoProfile -File $InstallPs1 2>$ErrFile
            $LASTEXITCODE | Should -Be 0
            ($out | Select-Object -Last 1) | Should -Be (Get-ExpectedBinDir -OcxHome $OcxHome)
        }
        finally {
            Remove-Item -Recurse -Force $binDir -ErrorAction SilentlyContinue
        }
    }
}
