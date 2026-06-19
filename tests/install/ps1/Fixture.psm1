# Shared Pester fixtures for src/install.ps1.
# Imported via `Import-Module $PSScriptRoot/Fixture.psm1 -Force` from each suite.
#
# PowerShell analogue of tests/install/helpers/server.bash: it builds a fake
# release tree (FLAT zip archive + a dist.json manifest with an INLINE sha256)
# and spins a `python http.server` against it so install.ps1 runs end-to-end
# without network access.
#
# The installer resolves latest + the per-target checksum/URL from dist.json.
# The manifest `url` is a dummy (example.invalid); suites set OCX_INSTALL_MIRROR_URL
# to $Server.MirrorUrl so the archive download is redirected to the fixture
# (mirror rewrites url -> <MirrorUrl>/<tag>/<filename>).
#
# Layout: the archive is FLAT (ocx.exe at the root). Detect-Architecture returns
# x86_64-pc-windows-msvc for any X64 host (it keys off RuntimeInformation), so the
# fixture target is always x86_64-pc-windows-msvc and the suites run meaningfully
# on ubuntu-pwsh as well as windows-latest.

$script:Target = 'x86_64-pc-windows-msvc'

function Get-FixtureTarget {
    return $script:Target
}

function Wait-FixturePort {
    param(
        [Parameter(Mandatory)][string]$OutLog,
        [Parameter(Mandatory)][string]$ErrLog
    )
    for ($i = 0; $i -lt 100; $i++) {
        foreach ($lf in @($ErrLog, $OutLog)) {
            if (Test-Path $lf) {
                $content = Get-Content $lf -Raw -ErrorAction SilentlyContinue
                if ($content -match 'port (\d+)') { return $Matches[1] }
            }
        }
        Start-Sleep -Milliseconds 100
    }
    return $null
}

function Get-PythonExe {
    foreach ($name in @('python3', 'python')) {
        if (Get-Command $name -ErrorAction SilentlyContinue) { return $name }
    }
    throw 'No python3/python interpreter found on PATH for the fixture server.'
}

# Write the stub `ocx.exe` into $BuildDir.
#   - default: answers `version` -> 0.0.0, `about`, and the `ocx self setup`
#     hand-off (records "$*" to $ArgvLog when set, exits 0).
#   - $FailSelfSetup: the `self setup` hand-off exits 9 (drives the exit-6 path).
# The stub is a `#!/bin/sh` script (named ocx.exe). On Windows it is invoked as a
# real exe; on Linux a shebang + a caller chmod makes `& <bin>` runnable — but the
# DOWNLOAD path extracts via .NET zip (no +x on Linux), so suites that execute the
# extracted binary self-skip off Windows (see -Skip:(-not $IsWindows)).
function New-OcxStub {
    param(
        [Parameter(Mandatory)][string]$BuildDir,
        [string]$ArgvLog,
        [switch]$FailSelfSetup
    )
    New-Item -ItemType Directory -Path $BuildDir -Force | Out-Null
    $stubPath = Join-Path $BuildDir 'ocx.exe'

    $record = ''
    if ($ArgvLog) {
        $record = "if [ -n `"`$OCX_STUB_ARGV`" ]; then printf '%s\n' `"`$*`" >> `"`$OCX_STUB_ARGV`"; fi`n"
    }
    $setupExit = if ($FailSelfSetup) { '9' } else { '0' }
    $body = "#!/bin/sh`n" +
            $record +
            "case `"`$1`" in`n" +
            "  version) echo 0.0.0 ;;`n" +
            "  about) echo 'ocx 0.0.0 (fixture stub)' ;;`n" +
            "  --offline) shift; [ `"`$1`" = self ] && [ `"`$2`" = setup ] && exit $setupExit; echo 'stub ocx' ;;`n" +
            "  self) [ `"`$2`" = setup ] && exit $setupExit; echo 'stub ocx' ;;`n" +
            "  *) echo 'stub ocx' ;;`n" +
            "esac`n"
    [System.IO.File]::WriteAllText($stubPath, $body)
    return $stubPath
}

# Build a standalone local test binary for the __OCX_TESTING_INSTALL_BINARY hatch
# and return its path. chmod +x on non-Windows so `& <bin> version` runs there.
function New-OcxTestBinary {
    param(
        [Parameter(Mandatory)][string]$Dir,
        [string]$Name = 'ocx.exe',
        [string]$ArgvLog
    )
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    $binPath = Join-Path $Dir $Name
    New-OcxStub -BuildDir $Dir -ArgvLog $ArgvLog | Out-Null
    if ($Name -ne 'ocx.exe') {
        Move-Item -Path (Join-Path $Dir 'ocx.exe') -Destination $binPath -Force
    }
    if ($env:OS -ne 'Windows_NT') {
        & chmod +x $binPath 2>$null
    }
    return $binPath
}

# Write a single-release dist.json under $SrvRoot. $Sha is the inline checksum
# ('0'*64 when $TamperChecksum). The url is a dummy; suites use OCX_INSTALL_MIRROR_URL.
function Write-OcxDist {
    param(
        [Parameter(Mandatory)][string]$SrvRoot,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Sha,
        [Parameter(Mandatory)][string]$Filename
    )
    $json = @"
{
  "schema": 1,
  "latest": {"version":"0.0.0","channel":"stable"},
  "latest_next": null,
  "releases": [
    {"version":"0.0.0","channel":"stable","tag":"v0.0.0","target":"$Target","filename":"$Filename","sha256":"$Sha","url":"https://example.invalid/ocx/releases/download/v0.0.0/$Filename"}
  ]
}
"@
    Set-Content -Path (Join-Path $SrvRoot 'dist.json') -Value $json -Encoding ASCII -NoNewline
}

# Build the fake release tree under $Root and return a hashtable describing it.
function New-OcxFixture {
    param(
        [Parameter(Mandatory)][string]$Root,
        [switch]$TamperChecksum,
        [string]$ArgvLog,
        [switch]$FailSelfSetup
    )

    $target = $script:Target
    $build = Join-Path $Root 'build'
    New-OcxStub -BuildDir $build -ArgvLog $ArgvLog -FailSelfSetup:$FailSelfSetup | Out-Null

    $srvDir = Join-Path $Root 'srv/releases/download/v0.0.0'
    New-Item -ItemType Directory -Path $srvDir -Force | Out-Null
    $srvRoot = Join-Path $Root 'srv'

    # FLAT archive: compress the *contents* of $build (ocx.exe at the root).
    $archive = "ocx-$target.zip"
    $archivePath = Join-Path $srvDir $archive
    Compress-Archive -Path (Join-Path $build '*') -DestinationPath $archivePath -Force

    if ($TamperChecksum) {
        $hash = '0' * 64
    }
    else {
        $hash = (Get-FileHash -Path $archivePath -Algorithm SHA256).Hash.ToLower()
    }
    Write-OcxDist -SrvRoot $srvRoot -Target $target -Sha $hash -Filename $archive

    return @{
        Root    = $Root
        SrvRoot = $srvRoot
        Target  = $target
        Archive = $archive
    }
}

# Spin a python http.server against $SrvRoot. Returns @{ Process; Port; DistUrl;
# MirrorUrl }. dist.json is served as application/json so ConvertFrom-Json is happy.
function Start-FixtureServer {
    param([Parameter(Mandatory)][string]$SrvRoot)

    $python = Get-PythonExe
    $parent = Split-Path $SrvRoot -Parent
    $outLog = Join-Path $parent 'srv.out.log'
    $errLog = Join-Path $parent 'srv.err.log'

    $serverPy = Join-Path $parent 'fixture-server.py'
    $pyBody = @'
import http.server, socketserver

class Handler(http.server.SimpleHTTPRequestHandler):
    def guess_type(self, path):
        if path.endswith('dist.json') or path.endswith('/dist'):
            return 'application/json'
        return super().guess_type(path)

with socketserver.TCPServer(('127.0.0.1', 0), Handler) as httpd:
    print('Serving HTTP on 127.0.0.1 port %d' % httpd.server_address[1], flush=True)
    httpd.serve_forever()
'@
    [System.IO.File]::WriteAllText($serverPy, $pyBody)

    $proc = Start-Process -FilePath $python `
        -ArgumentList '-u', $serverPy `
        -WorkingDirectory $SrvRoot `
        -RedirectStandardOutput $outLog `
        -RedirectStandardError $errLog `
        -PassThru

    $port = Wait-FixturePort -OutLog $outLog -ErrLog $errLog
    if (-not $port) {
        if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
        throw "Failed to start fixture server (logs: $outLog / $errLog)"
    }

    return @{
        Process   = $proc
        Port      = $port
        DistUrl   = "http://127.0.0.1:$port/dist.json"
        MirrorUrl = "http://127.0.0.1:$port/releases/download"
    }
}

function Stop-FixtureServer {
    param($Server)
    if ($Server -and $Server.Process -and -not $Server.Process.HasExited) {
        Stop-Process -Id $Server.Process.Id -Force -ErrorAction SilentlyContinue
    }
}

# Canonical OCX bin dir under $OcxHome (the real on-disk store layout).
function Get-ExpectedBinDir {
    param([Parameter(Mandatory)][string]$OcxHome)
    return (Join-Path $OcxHome 'symlinks/ocx.sh/ocx/cli/current/content/bin')
}

Export-ModuleMember -Function `
    Get-FixtureTarget, New-OcxFixture, New-OcxStub, New-OcxTestBinary, Write-OcxDist, `
    Start-FixtureServer, Stop-FixtureServer, Get-ExpectedBinDir, `
    Wait-FixturePort, Get-PythonExe
