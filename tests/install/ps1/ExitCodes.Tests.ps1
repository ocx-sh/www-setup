#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }
# Pester coverage for the numbered exit-code contract of src/install.ps1.
# Mirrors ../exit-codes.bats: exit 5 (extract), 6 (`ocx self setup`), 3 (manifest
# fetch), 2 (test hatch). Exit 4 is covered by Knobs; exit 7 by tests/docker/.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Fixture.psm1') -Force
    $script:InstallPs1 = Join-Path $PSScriptRoot '..\..\..\src\install.ps1'
    $script:Target = Get-FixtureTarget
}

Describe 'install.ps1 exit codes' {
    BeforeEach {
        $script:OcxHome = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-ec-home-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:ArgvLog = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-ec-argv-$([System.Guid]::NewGuid().ToString('N').Substring(0,8)).log"
        $env:OCX_HOME = $OcxHome
        $env:OCX_NO_MODIFY_PATH = '1'
        $env:OCX_INSTALL_NO_SMOKETEST = '1'
        $env:OCX_STUB_ARGV = $ArgvLog
        foreach ($v in 'GITHUB_PATH', '__OCX_TESTING_INSTALL_BINARY', 'OCX_INSTALL_PRINT_PATH',
            'OCX_INSTALL_QUIET', 'OCX_INSTALL_FORCE', 'OCX_INSTALL_NO_SETUP', 'OCX_INSTALL_VERSION',
            'OCX_INSTALL_DIST_URL', 'OCX_INSTALL_MIRROR_URL') {
            Remove-Item "Env:$v" -ErrorAction SilentlyContinue
        }
    }
    AfterEach {
        if (Test-Path $OcxHome) { Remove-Item -Recurse -Force $OcxHome -ErrorAction SilentlyContinue }
        if (Test-Path $ArgvLog) { Remove-Item -Force $ArgvLog -ErrorAction SilentlyContinue }
    }

    It 'exit 5: corrupt archive fails to extract' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-ec-cx-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
        $srvRoot = Join-Path $root 'srv'
        $srvDir = Join-Path $srvRoot 'releases/download/v0.0.0'
        New-Item -ItemType Directory -Path $srvDir -Force | Out-Null
        $file = "ocx-$Target.$(Get-FixtureArchiveExt)"
        $archive = Join-Path $srvDir $file
        Set-Content -Path $archive -Value 'not a real archive' -Encoding ASCII -NoNewline
        $sha = (Get-FileHash -Path $archive -Algorithm SHA256).Hash.ToLower()
        Write-OcxDist -SrvRoot $srvRoot -Target $Target -Sha $sha -Filename $file
        $srv = Start-FixtureServer -SrvRoot $srvRoot
        try {
            $env:OCX_INSTALL_DIST_URL = $srv.DistUrl
            $env:OCX_INSTALL_MIRROR_URL = $srv.MirrorUrl
            & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' 2>$null | Out-Null
            $LASTEXITCODE | Should -Be 5
        }
        finally {
            Stop-FixtureServer -Server $srv
            Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
        }
    }

    It 'exit 5: archive missing the ocx binary' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-ec-mb-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
        $srvRoot = Join-Path $root 'srv'
        $srvDir = Join-Path $srvRoot 'releases/download/v0.0.0'
        New-Item -ItemType Directory -Path $srvDir -Force | Out-Null
        $build = Join-Path $root 'build'
        New-Item -ItemType Directory -Path $build -Force | Out-Null
        Set-Content -Path (Join-Path $build 'README.txt') -Value 'no binary here' -Encoding ASCII
        $file = "ocx-$Target.$(Get-FixtureArchiveExt)"
        $archive = Join-Path $srvDir $file
        New-OcxArchive -BuildDir $build -OutFile $archive
        $sha = (Get-FileHash -Path $archive -Algorithm SHA256).Hash.ToLower()
        Write-OcxDist -SrvRoot $srvRoot -Target $Target -Sha $sha -Filename $file
        $srv = Start-FixtureServer -SrvRoot $srvRoot
        try {
            $env:OCX_INSTALL_DIST_URL = $srv.DistUrl
            $env:OCX_INSTALL_MIRROR_URL = $srv.MirrorUrl
            & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' 2>$null | Out-Null
            $LASTEXITCODE | Should -Be 5
        }
        finally {
            Stop-FixtureServer -Server $srv
            Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
        }
    }

    It 'exit 6: ocx self setup failure (asserts the corrected hand-off argv)' -Skip:($env:OS -eq 'Windows_NT') {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-ec-ss-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
        $fx = New-OcxFixture -Root $root -ArgvLog 'on' -FailSelfSetup
        $srv = Start-FixtureServer -SrvRoot $fx.SrvRoot
        try {
            $env:OCX_INSTALL_DIST_URL = $srv.DistUrl
            $env:OCX_INSTALL_MIRROR_URL = $srv.MirrorUrl
            & pwsh -NoProfile -File $InstallPs1 -Version '0.0.0' 2>$null | Out-Null
            $LASTEXITCODE | Should -Be 6
            (Get-Content $ArgvLog) | Should -Contain 'self setup 0.0.0 --no-modify-path'
        }
        finally {
            Stop-FixtureServer -Server $srv
            Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
        }
    }

    It 'exit 3: latest-version resolution fails when the manifest URL is dead' {
        $errFile = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-ec-e3-$([System.Guid]::NewGuid().ToString('N').Substring(0,8)).log"
        $env:OCX_INSTALL_DIST_URL = 'http://127.0.0.1:1/dist.json'
        try {
            & pwsh -NoProfile -File $InstallPs1 2>$errFile | Out-Null
            $LASTEXITCODE | Should -Be 3
            (Get-Content $errFile -Raw) | Should -Match 'latest version'
        }
        finally {
            Remove-Item -Force $errFile -ErrorAction SilentlyContinue
        }
    }

    It 'exit 2: __OCX_TESTING_INSTALL_BINARY pointing at a missing file' {
        $env:__OCX_TESTING_INSTALL_BINARY = Join-Path ([System.IO.Path]::GetTempPath()) 'no-such-binary.exe'
        & pwsh -NoProfile -File $InstallPs1 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 2
    }
}
