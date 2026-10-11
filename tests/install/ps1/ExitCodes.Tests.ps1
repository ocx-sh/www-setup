#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }
# Pester coverage for the numbered exit-code contract of src/install.ps1.
# Mirrors ../exit-codes.bats: exit 5 (extract), 6 (`ocx self setup`), 3 (manifest
# fetch), 2 (test hatch). Exit 4 is covered by Knobs; exit 7 by tests/docker/.
# The last two scenarios run the installer the documented way (`irm | iex`, a
# scriptblock), where `exit` would close the caller's session.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Fixture.psm1') -Force
    $script:InstallPs1 = Join-Path $PSScriptRoot '..\..\..\src\install.ps1'
    $script:RunInstaller = Join-Path $PSScriptRoot 'Run-Installer.ps1'
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
            'OCX_INSTALL_DIST_URL', 'OCX_INSTALL_MIRROR_URL',
            'OCX_INSTALL_CA_BUNDLE', 'OCX_MANAGED_CONFIG', 'SSL_CERT_FILE', 'SSL_CERT_DIR', 'OCX_EXTRA_CA_CERTS') {
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
        $sha = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLower()
        Write-OcxDist -SrvRoot $srvRoot -Target $Target -Sha $sha -Filename $file
        $srv = Start-FixtureServer -SrvRoot $srvRoot
        try {
            $env:OCX_INSTALL_DIST_URL = $srv.DistUrl
            $env:OCX_INSTALL_MIRROR_URL = $srv.MirrorUrl
            & pwsh -NoProfile -File $RunInstaller $InstallPs1 -Version '0.0.0' 2>$null | Out-Null
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
        $sha = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLower()
        Write-OcxDist -SrvRoot $srvRoot -Target $Target -Sha $sha -Filename $file
        $srv = Start-FixtureServer -SrvRoot $srvRoot
        try {
            $env:OCX_INSTALL_DIST_URL = $srv.DistUrl
            $env:OCX_INSTALL_MIRROR_URL = $srv.MirrorUrl
            & pwsh -NoProfile -File $RunInstaller $InstallPs1 -Version '0.0.0' 2>$null | Out-Null
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
            & pwsh -NoProfile -File $RunInstaller $InstallPs1 -Version '0.0.0' 2>$null | Out-Null
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
        $env:OCX_INSTALL_DIST_URL = 'https://127.0.0.1:1/dist.json'
        try {
            & pwsh -NoProfile -File $RunInstaller $InstallPs1 2>$errFile | Out-Null
            $LASTEXITCODE | Should -Be 3
            (Get-Content $errFile -Raw) | Should -Match 'latest version'
        }
        finally {
            Remove-Item -Force $errFile -ErrorAction SilentlyContinue
        }
    }

    It 'exit 2: __OCX_TESTING_INSTALL_BINARY pointing at a missing file' {
        $env:__OCX_TESTING_INSTALL_BINARY = Join-Path ([System.IO.Path]::GetTempPath()) 'no-such-binary.exe'
        & pwsh -NoProfile -File $RunInstaller $InstallPs1 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 2
    }

    # `irm | iex` has no script file, so $PSCommandPath is empty and `exit` would
    # kill the user's PowerShell. Run through -Command (not a wrapper file, whose
    # path iex would inherit) in the current host, so a 5.1 Pester run drives 5.1.
    It 'iex: a failure reports the error, throws, and the session survives' {
        $hostExe = (Get-Process -Id $PID).Path
        $errFile = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-ec-iex-$([System.Guid]::NewGuid().ToString('N').Substring(0,8)).log"
        $env:__OCX_TESTING_INSTALL_BINARY = Join-Path ([System.IO.Path]::GetTempPath()) 'no-such-binary.exe'
        $cmd = "try { Get-Content -Raw -LiteralPath '$InstallPs1' | Invoke-Expression } catch { 'CAUGHT ' + `$_ }; 'SURVIVED rc=' + `$LASTEXITCODE"
        try {
            $out = & $hostExe -NoProfile -Command $cmd 2>$errFile
            $LASTEXITCODE | Should -Be 0
            ($out -join "`n") | Should -Match 'CAUGHT ocx install failed \(exit code 2\)'
            ($out -join "`n") | Should -Match 'SURVIVED rc=2'
            (Get-Content $errFile -Raw) | Should -Match '__OCX_TESTING_INSTALL_BINARY'
        }
        finally {
            Remove-Item -Force $errFile -ErrorAction SilentlyContinue
        }
    }

    It 'iex: a non-interactive host still exits non-zero on a failed install' {
        $hostExe = (Get-Process -Id $PID).Path
        $env:__OCX_TESTING_INSTALL_BINARY = Join-Path ([System.IO.Path]::GetTempPath()) 'no-such-binary.exe'
        $cmd = "Get-Content -Raw -LiteralPath '$InstallPs1' | Invoke-Expression"
        & $hostExe -NoProfile -Command $cmd 2>$null | Out-Null
        $LASTEXITCODE | Should -Not -Be 0
    }

    It 'scriptblock: a failure throws and leaves the code in LASTEXITCODE' {
        $hostExe = (Get-Process -Id $PID).Path
        $env:__OCX_TESTING_INSTALL_BINARY = Join-Path ([System.IO.Path]::GetTempPath()) 'no-such-binary.exe'
        $cmd = "try { & ([scriptblock]::Create((Get-Content -Raw -LiteralPath '$InstallPs1'))) 2>`$null } catch { }; 'SURVIVED rc=' + `$LASTEXITCODE"
        $out = & $hostExe -NoProfile -Command $cmd
        ($out -join "`n") | Should -Match 'SURVIVED rc=2'
    }

    # Retry. The real incident: one CDN edge PoP answered 500 for dist.json while
    # every other PoP served it fine, and a single unretried GET aborted the whole
    # install with exit 3.
    It 'retry: a transient 500 on the manifest is retried and the install succeeds' -Skip:($env:OS -eq 'Windows_NT') {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-ec-r1-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
        $fx = New-OcxFixture -Root $root -ArgvLog 'on'
        $srv = Start-FixtureServer -SrvRoot $fx.SrvRoot
        try {
            $env:OCX_INSTALL_DIST_URL = "https://127.0.0.1:$($srv.Port)/flaky/2/dist.json"
            $env:OCX_INSTALL_MIRROR_URL = $srv.MirrorUrl
            & pwsh -NoProfile -File $RunInstaller $InstallPs1 -Version '0.0.0' 2>$null | Out-Null
            $LASTEXITCODE | Should -Be 0
            # Two failures then a success = three GETs of that URL.
            $hits = (Select-String -Path $srv.ErrLog -Pattern 'GET /flaky/2/dist.json' -AllMatches).Count
            $hits | Should -Be 3
        }
        finally {
            Stop-FixtureServer -Server $srv
            Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
        }
    }

    It 'retry: exhausted attempts still exit 3, after exactly 3 tries' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-ec-r2-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
        $fx = New-OcxFixture -Root $root -ArgvLog 'on'
        $srv = Start-FixtureServer -SrvRoot $fx.SrvRoot
        $errFile = Join-Path $root 'stderr.log'
        try {
            $env:OCX_INSTALL_DIST_URL = "https://127.0.0.1:$($srv.Port)/flaky/99/dist.json"
            $env:OCX_INSTALL_MIRROR_URL = $srv.MirrorUrl
            & pwsh -NoProfile -File $RunInstaller $InstallPs1 2>$errFile | Out-Null
            $LASTEXITCODE | Should -Be 3
            (Get-Content $errFile -Raw) | Should -Match 'latest version'
            $hits = (Select-String -Path $srv.ErrLog -Pattern 'GET /flaky/99/dist.json' -AllMatches).Count
            $hits | Should -Be 3
        }
        finally {
            Stop-FixtureServer -Server $srv
            Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
        }
    }

    It 'retry: the archive download is retried too' -Skip:($env:OS -eq 'Windows_NT') {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-ec-r3-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
        $fx = New-OcxFixture -Root $root -ArgvLog 'on'
        $srv = Start-FixtureServer -SrvRoot $fx.SrvRoot
        try {
            $env:OCX_INSTALL_DIST_URL = $srv.DistUrl
            # Flaky prefix on the MIRROR, so the archive fetch is the failing one.
            $env:OCX_INSTALL_MIRROR_URL = "https://127.0.0.1:$($srv.Port)/flaky/2/releases/download"
            & pwsh -NoProfile -File $RunInstaller $InstallPs1 -Version '0.0.0' 2>$null | Out-Null
            $LASTEXITCODE | Should -Be 0
            (Get-Content $ArgvLog) | Should -Contain 'self setup 0.0.0 --no-modify-path'
        }
        finally {
            Stop-FixtureServer -Server $srv
            Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
        }
    }

    # --- Refusals: input the installer must reject before it trusts it ---

    It 'exit 3: a non-https manifest URL is refused before any request' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-ec-h1-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
        $fx = New-OcxFixture -Root $root
        $srv = Start-FixtureServer -SrvRoot $fx.SrvRoot -Plain
        $errFile = Join-Path $root 'stderr.log'
        try {
            $env:OCX_INSTALL_DIST_URL = $srv.DistUrl
            & pwsh -NoProfile -File $RunInstaller $InstallPs1 2>$errFile | Out-Null
            $LASTEXITCODE | Should -Be 3
            (Get-Content -LiteralPath $errFile -Raw) | Should -Match 'refusing insecure \(non-https\) URL'
            @(Select-String -LiteralPath $srv.ErrLog -Pattern 'GET ' -AllMatches).Count | Should -Be 0
        }
        finally {
            Stop-FixtureServer -Server $srv
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'exit 3: a non-https mirror URL is refused before the archive is requested' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-ec-h2-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
        $fx = New-OcxFixture -Root $root
        $srv = Start-FixtureServer -SrvRoot $fx.SrvRoot
        $plain = Start-FixtureServer -SrvRoot $fx.SrvRoot -Plain
        $errFile = Join-Path $root 'stderr.log'
        try {
            $env:OCX_INSTALL_DIST_URL = $srv.DistUrl
            $env:OCX_INSTALL_MIRROR_URL = $plain.MirrorUrl
            & pwsh -NoProfile -File $RunInstaller $InstallPs1 -Version '0.0.0' 2>$errFile | Out-Null
            $LASTEXITCODE | Should -Be 3
            (Get-Content -LiteralPath $errFile -Raw) | Should -Match 'refusing insecure \(non-https\) URL'
            @(Select-String -LiteralPath $plain.ErrLog -Pattern 'GET ' -AllMatches).Count | Should -Be 0
        }
        finally {
            Stop-FixtureServer -Server $srv
            Stop-FixtureServer -Server $plain
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'exit 3: an https to http redirect hop is refused without a retry' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-ec-h3-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
        $fx = New-OcxFixture -Root $root
        $srv = Start-FixtureServer -SrvRoot $fx.SrvRoot
        $errFile = Join-Path $root 'stderr.log'
        try {
            $env:OCX_INSTALL_DIST_URL = $srv.DistUrl
            $env:OCX_INSTALL_MIRROR_URL = $srv.DowngradeMirrorUrl
            & pwsh -NoProfile -File $RunInstaller $InstallPs1 -Version '0.0.0' 2>$errFile | Out-Null
            $LASTEXITCODE | Should -Be 3
            (Get-Content -LiteralPath $errFile -Raw) | Should -Match 'refusing insecure \(non-https\) URL'
            # A downgrade is a refusal, not a transient failure: one request, no retries.
            @(Select-String -LiteralPath $srv.ErrLog -Pattern 'GET /downgrade/' -AllMatches).Count | Should -Be 1
        }
        finally {
            Stop-FixtureServer -Server $srv
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'exit 2: an unsafe OCX_HOME (<Label>) is refused' -ForEach @(
        @{ Label = 'relative'; Value = 'relative/ocx-home' }
        @{ Label = 'dot-dot component'; Value = (Join-Path ([System.IO.Path]::GetTempPath()) 'a/../b') }
        @{ Label = 'semicolon'; Value = (Join-Path ([System.IO.Path]::GetTempPath()) 'a;b') }
    ) {
        $errFile = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-ec-oh-$([System.Guid]::NewGuid().ToString('N').Substring(0,8)).log"
        $env:OCX_HOME = $Value
        try {
            & pwsh -NoProfile -File $RunInstaller $InstallPs1 2>$errFile | Out-Null
            $LASTEXITCODE | Should -Be 2
            (Get-Content -LiteralPath $errFile -Raw) | Should -Match 'OCX_HOME'
        }
        finally { Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue }
    }

    # A manifest row without a usable digest must abort before the archive is
    # fetched: warning and continuing would extract and run unverified bytes.
    It 'exit 3: a manifest row with a <Label> sha256 is refused before the download' -ForEach @(
        @{ Label = 'blank'; Sha = ''; Omit = $false }
        @{ Label = 'absent'; Sha = ''; Omit = $true }
        @{ Label = 'non-hex'; Sha = ('zz' * 32); Omit = $false }
        @{ Label = 'truncated'; Sha = 'abc123'; Omit = $false }
    ) {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-ec-sh-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
        $fx = New-OcxFixture -Root $root
        Write-OcxDist -SrvRoot $fx.SrvRoot -Target $Target -Sha $Sha -Filename $fx.Archive -OmitSha:$Omit
        $srv = Start-FixtureServer -SrvRoot $fx.SrvRoot
        $errFile = Join-Path $root 'stderr.log'
        try {
            $env:OCX_INSTALL_DIST_URL = $srv.DistUrl
            $env:OCX_INSTALL_MIRROR_URL = $srv.MirrorUrl
            $env:OCX_INSTALL_NO_SETUP = '1'
            & pwsh -NoProfile -File $RunInstaller $InstallPs1 -Version '0.0.0' 2>$errFile | Out-Null
            $LASTEXITCODE | Should -Be 3
            (Get-Content -LiteralPath $errFile -Raw) | Should -Match 'no valid sha256'
            @(Select-String -LiteralPath $srv.ErrLog -Pattern 'GET /releases/' -AllMatches).Count | Should -Be 0
            Test-Path -LiteralPath (Get-ExpectedBinDir -OcxHome $OcxHome) | Should -BeFalse
        }
        finally {
            Stop-FixtureServer -Server $srv
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- Hostile archives: exit 5, and nothing lands outside the extract dir ---

    It 'exit 5: a zip entry (<Label>) is refused' -ForEach @(
        @{ Label = 'parent traversal'; Entry = '..\..\{EVIL}' }
        @{ Label = 'forward-slash traversal'; Entry = '../../{EVIL}' }
        @{ Label = 'rooted'; Entry = '/{EVIL}' }
        @{ Label = 'drive letter'; Entry = 'C:{EVIL}' }
    ) {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-ec-zs-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $evil = "ocx-evil-$([System.Guid]::NewGuid().ToString('N').Substring(0,8)).txt"
        $zip = Join-Path $root 'hostile.zip'
        New-HostileZip -OutFile $zip -EntryNames @($Entry.Replace('{EVIL}', $evil))
        $fx = New-ArchiveFixture -Root $root -Archive $zip -Filename "ocx-$Target.zip"
        $srv = Start-FixtureServer -SrvRoot $fx.SrvRoot
        $errFile = Join-Path $root 'stderr.log'
        try {
            $env:OCX_INSTALL_DIST_URL = $srv.DistUrl
            $env:OCX_INSTALL_MIRROR_URL = $srv.MirrorUrl
            & pwsh -NoProfile -File $RunInstaller $InstallPs1 -Version '0.0.0' 2>$errFile | Out-Null
            $LASTEXITCODE | Should -Be 5
            (Get-Content -LiteralPath $errFile -Raw) | Should -Match 'unsafe entry'
            Test-Path -LiteralPath (Join-Path ([System.IO.Path]::GetTempPath()) $evil) | Should -BeFalse
            Test-Path -LiteralPath (Join-Path ([System.IO.Path]::GetPathRoot($root)) $evil) | Should -BeFalse
        }
        finally {
            Stop-FixtureServer -Server $srv
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'exit 5: a tar member (<Kind>) is refused' -Skip:($env:OS -eq 'Windows_NT') -ForEach @(
        @{ Kind = 'dotdot'; Pattern = 'unsafe path' }
        @{ Kind = 'abs'; Pattern = 'unsafe path' }
        @{ Kind = 'symlink'; Pattern = 'escaping link target' }
    ) {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-ec-ts-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $evil = "ocx-evil-$([System.Guid]::NewGuid().ToString('N').Substring(0,8)).txt"
        $tar = Join-Path $root 'hostile.tar.gz'
        New-HostileTar -OutFile $tar -Kind $Kind -EvilName $evil
        $fx = New-ArchiveFixture -Root $root -Archive $tar -Filename "ocx-$Target.tar.gz"
        $srv = Start-FixtureServer -SrvRoot $fx.SrvRoot
        $errFile = Join-Path $root 'stderr.log'
        try {
            $env:OCX_INSTALL_DIST_URL = $srv.DistUrl
            $env:OCX_INSTALL_MIRROR_URL = $srv.MirrorUrl
            & pwsh -NoProfile -File $RunInstaller $InstallPs1 -Version '0.0.0' 2>$errFile | Out-Null
            $LASTEXITCODE | Should -Be 5
            (Get-Content -LiteralPath $errFile -Raw) | Should -Match $Pattern
            Test-Path -LiteralPath (Join-Path ([System.IO.Path]::GetTempPath()) $evil) | Should -BeFalse
        }
        finally {
            Stop-FixtureServer -Server $srv
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- `irm | iex` hygiene: the caller's session is unchanged afterwards ---
    #
    # One child host of the current edition per outcome records the caller's
    # preferences, functions, variables, env and TLS setting, delivers the script
    # through Invoke-Expression, and prints what changed. Each property is its own
    # It, so a regression names the property that leaked. The downloading outcome
    # exists for TLS alone: the setting is only touched on a real fetch.
    # LASTEXITCODE is exempt from the diff: the exit-code delivery contract sets
    # it on purpose, and its own It pins the value.
    Context 'iex isolation' {
        BeforeAll {
            function Invoke-IexProbe {
                param([string]$Outcome)
                $hostExe = (Get-Process -Id $PID).Path
                $root = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-ec-sess-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
                $binDir = Join-Path $root 'bin'
                $stub = New-OcxTestBinary -Dir $binDir
                $trust = Join-Path $PSScriptRoot 'Trust-Fixture.ps1'
                $certPem = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'helpers') 'localhost-cert.pem'
                $installedBin = Join-Path (Get-ExpectedBinDir -OcxHome (Join-Path $root 'home')) (Get-FixtureBinName)
                $names = 'OCX_HOME', 'OCX_NO_MODIFY_PATH', 'OCX_INSTALL_NO_SMOKETEST', 'OCX_INSTALL_NO_SETUP',
                'OCX_INSTALL_CA_BUNDLE', 'OCX_INSTALL_DIST_URL', 'OCX_INSTALL_MIRROR_URL', 'OCX_INSTALL_VERSION',
                '__OCX_TESTING_INSTALL_BINARY', 'GITHUB_PATH', 'SSL_CERT_FILE', 'OCX_EXTRA_CA_CERTS'
                $saved = @{}
                foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }
                $srv = $null
                try {
                    foreach ($n in $names) { Remove-Item "Env:$n" -ErrorAction SilentlyContinue }
                    $env:OCX_HOME = Join-Path $root 'home'
                    $env:OCX_NO_MODIFY_PATH = '1'
                    $env:OCX_INSTALL_NO_SMOKETEST = '1'
                    $env:OCX_INSTALL_NO_SETUP = '1'
                    $env:OCX_INSTALL_CA_BUNDLE = "# Corp Root CA`n" + [System.IO.File]::ReadAllText($certPem)
                    if ($Outcome -eq 'failing') { $env:__OCX_TESTING_INSTALL_BINARY = Join-Path $binDir 'no-such-binary.exe' }
                    elseif ($Outcome -eq 'successful') { $env:__OCX_TESTING_INSTALL_BINARY = $stub }
                    else {
                        $fx = New-OcxFixture -Root (Join-Path $root 'fx')
                        $srv = Start-FixtureServer -SrvRoot $fx.SrvRoot
                        $env:OCX_INSTALL_DIST_URL = $srv.DistUrl
                        $env:OCX_INSTALL_MIRROR_URL = $srv.MirrorUrl
                    }
                    $probe = @"
. '$trust'
`$ErrorActionPreference = 'Continue'
Set-StrictMode -Off
`$__fn0 = @(Get-ChildItem function: | Where-Object { -not `$_.ModuleName } | ForEach-Object Name)
`$__v0 = @(Get-Variable | ForEach-Object Name)
`$__env0 = @(Get-ChildItem Env: | ForEach-Object Name)
`$__tls0 = [string][Net.ServicePointManager]::SecurityProtocol
`$global:LASTEXITCODE = 42
try { Get-Content -Raw -LiteralPath '$InstallPs1' | Invoke-Expression } catch { }
`$__fn1 = @(Get-ChildItem function: | Where-Object { -not `$_.ModuleName } | ForEach-Object Name | Where-Object { `$_ -notin `$__fn0 })
`$__v1 = @(Get-Variable | ForEach-Object Name | Where-Object { `$_ -notin `$__v0 -and `$_ -notmatch '^__' -and `$_ -notin '_', 'PSItem', 'switch', 'LASTEXITCODE' })
`$__env1 = @(Get-ChildItem Env: | ForEach-Object Name | Where-Object { `$_ -notin `$__env0 })
`$__strict = 'off'; try { `$null = `$__undefinedProbeVariable } catch { `$__strict = 'ON' }
'EAP=' + `$ErrorActionPreference
'STRICT=' + `$__strict
'FUNCTIONS=' + (`$__fn1 -join ',')
'VARIABLES=' + (`$__v1 -join ',')
'ENV=' + (`$__env1 -join ',')
'TLS=' + (([string][Net.ServicePointManager]::SecurityProtocol) -eq `$__tls0)
'LASTEXIT=' + `$global:LASTEXITCODE
'INSTALLED=' + (Test-Path -LiteralPath '$installedBin')
"@
                    $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($probe))
                    $lines = @(& $hostExe -NoProfile -NonInteractive -EncodedCommand $enc 2>$null)
                    $result = @{}
                    foreach ($line in $lines) {
                        if ("$line" -match '^([A-Z]+)=(.*)$') { $result[$Matches[1]] = $Matches[2] }
                    }
                    return $result
                }
                finally {
                    if ($srv) { Stop-FixtureServer -Server $srv }
                    foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) }
                    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
            $script:Probe = @{}
            foreach ($outcome in 'failing', 'successful', 'downloading') { $script:Probe[$outcome] = Invoke-IexProbe -Outcome $outcome }
        }

        # Without the install the properties below would hold vacuously.
        It 'iex: a <Outcome> run installs the binary: <Expected>' -ForEach @(
            @{ Outcome = 'failing'; Expected = 'False' }
            @{ Outcome = 'successful'; Expected = 'True' }
            @{ Outcome = 'downloading'; Expected = 'True' }
        ) {
            $script:Probe[$Outcome]['INSTALLED'] | Should -Be $Expected
        }

        It 'iex: a <Outcome> run leaves $ErrorActionPreference unchanged' -ForEach @(
            @{ Outcome = 'failing' }, @{ Outcome = 'successful' }, @{ Outcome = 'downloading' }
        ) {
            $script:Probe[$Outcome]['EAP'] | Should -Be 'Continue'
        }

        It 'iex: a <Outcome> run leaves StrictMode off' -ForEach @(
            @{ Outcome = 'failing' }, @{ Outcome = 'successful' }, @{ Outcome = 'downloading' }
        ) {
            $script:Probe[$Outcome]['STRICT'] | Should -Be 'off'
        }

        It 'iex: a <Outcome> run defines no function in the caller session' -ForEach @(
            @{ Outcome = 'failing' }, @{ Outcome = 'successful' }, @{ Outcome = 'downloading' }
        ) {
            $script:Probe[$Outcome]['FUNCTIONS'] | Should -BeNullOrEmpty
        }

        It 'iex: a <Outcome> run defines no variable in the caller session' -ForEach @(
            @{ Outcome = 'failing' }, @{ Outcome = 'successful' }, @{ Outcome = 'downloading' }
        ) {
            $script:Probe[$Outcome]['VARIABLES'] | Should -BeNullOrEmpty
        }

        It 'iex: a <Outcome> run leaves no environment variable behind' -ForEach @(
            @{ Outcome = 'failing' }, @{ Outcome = 'successful' }, @{ Outcome = 'downloading' }
        ) {
            $script:Probe[$Outcome]['ENV'] | Should -BeNullOrEmpty
        }

        It 'iex: a <Outcome> run leaves ServicePointManager.SecurityProtocol unchanged' -ForEach @(
            @{ Outcome = 'failing' }, @{ Outcome = 'successful' }, @{ Outcome = 'downloading' }
        ) {
            $script:Probe[$Outcome]['TLS'] | Should -Be 'True'
        }

        # A failed install delivers its code; a successful one hands back the caller's own.
        It 'iex: a <Outcome> run leaves LASTEXITCODE at <Expected>' -ForEach @(
            @{ Outcome = 'failing'; Expected = '2' }
            @{ Outcome = 'successful'; Expected = '42' }
            @{ Outcome = 'downloading'; Expected = '42' }
        ) {
            $script:Probe[$Outcome]['LASTEXIT'] | Should -Be $Expected
        }
    }

    # The two documented ways to pass a version without a script file. The decoy
    # manifest lists a newer stable release with no row for this host, so a
    # version that is dropped on the way in lands on it and fails with exit 3.
    It 'delivery: <Mode> installs the pinned version over the decoy latest' -ForEach @(
        @{ Mode = 'scriptblock -Version'; Pin = 'sb' }
        @{ Mode = 'iex with OCX_INSTALL_VERSION'; Pin = 'iex' }
    ) {
        $hostExe = (Get-Process -Id $PID).Path
        $trust = Join-Path $PSScriptRoot 'Trust-Fixture.ps1'
        $root = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-ec-dl-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
        $fx = New-OcxFixture -Root $root
        Write-OcxDecoyDist -SrvRoot $fx.SrvRoot
        $srv = Start-FixtureServer -SrvRoot $fx.SrvRoot
        try {
            $env:OCX_INSTALL_DIST_URL = $srv.DistUrl.Replace('dist.json', 'dist-decoy.json')
            $env:OCX_INSTALL_MIRROR_URL = $srv.MirrorUrl
            $env:OCX_INSTALL_NO_SETUP = '1'
            if ($Pin -eq 'sb') {
                $cmd = ". '$trust'; & ([scriptblock]::Create((Get-Content -Raw -LiteralPath '$InstallPs1'))) -Version '0.0.0'"
            }
            else {
                $env:OCX_INSTALL_VERSION = '0.0.0'
                $cmd = ". '$trust'; Get-Content -Raw -LiteralPath '$InstallPs1' | Invoke-Expression"
            }
            & $hostExe -NoProfile -Command $cmd 2>$null | Out-Null
            Test-Path -LiteralPath (Join-Path (Get-ExpectedBinDir -OcxHome $OcxHome) (Get-FixtureBinName)) | Should -BeTrue
        }
        finally {
            Stop-FixtureServer -Server $srv
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
