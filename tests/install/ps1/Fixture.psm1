# Shared Pester fixtures for src/install.ps1.
# Imported via `Import-Module $PSScriptRoot/Fixture.psm1 -Force` from each suite.
#
# PowerShell analogue of tests/install/helpers/server.bash: it builds a fake
# release tree (a platform-appropriate archive + a dist.json manifest with an
# INLINE sha256) and spins a `python http.server` against it so install.ps1 runs
# end-to-end without network access.
#
# The installer resolves latest + the per-target checksum/URL from dist.json.
# The manifest `url` is a dummy (example.invalid); suites set OCX_INSTALL_MIRROR_URL
# to $Server.MirrorUrl so the archive download is redirected to the fixture
# (mirror rewrites url -> <MirrorUrl>/<tag>/<filename>).
#
# Cross-platform: install.ps1 is now a cross-platform installer. Detect-Architecture
# returns the real host target (*-pc-windows-msvc on Windows, *-unknown-linux-{gnu,musl}
# on Linux, *-apple-darwin on macOS) and the binary is ocx.exe on Windows / ocx on
# Unix. The fixture mirrors that: on Windows it builds a FLAT .zip with ocx.exe at
# the root; on Unix it builds a FLAT .tar.xz with an executable `ocx` at the root
# (so the full download -> extract -> `self setup` hand-off path EXECUTES on the
# POSIX hosts — ubuntu + macos). The stub is a `#!/bin/sh` script; on Windows it is
# not a PE, so suites that execute it self-skip there (see -Skip:($env:OS -eq
# 'Windows_NT')). Windows execution coverage lives in the 5.1 smoke + real-release
# dispatch jobs.

# --- Platform predicates (mirror install.ps1) ---

function Test-FixtureIsWindows {
    if ($PSVersionTable.PSEdition -eq 'Desktop') { return $true }
    return [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [System.Runtime.InteropServices.OSPlatform]::Windows)
}

# Resolve the host target triple, mirroring install.ps1 Detect-Architecture so the
# fixture archive name matches exactly what the installer will request.
function Resolve-FixtureTarget {
    if (Test-FixtureIsWindows) {
        switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
            'X64'   { return 'x86_64-pc-windows-msvc' }
            'Arm64' { return 'aarch64-pc-windows-msvc' }
            default { throw "unsupported test host architecture" }
        }
    }
    $arch = $null
    switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
        'X64'   { $arch = 'x86_64' }
        'Arm64' { $arch = 'aarch64' }
        default { throw "unsupported test host architecture" }
    }
    if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
            [System.Runtime.InteropServices.OSPlatform]::OSX)) {
        return "$arch-apple-darwin"
    }
    # Linux libc, same ordering as install.ps1.
    $libc = 'gnu'
    if (Get-Command ldd -ErrorAction SilentlyContinue) {
        $lddOut = ''
        try { $lddOut = (& ldd --version 2>&1 | Out-String) } catch { $lddOut = '' }
        if ($lddOut -match 'musl') { $libc = 'musl' }
    }
    elseif (Get-ChildItem -Path '/lib/ld-musl-*.so.1' -ErrorAction SilentlyContinue) { $libc = 'musl' }
    elseif (Test-Path '/etc/alpine-release') { $libc = 'musl' }
    return "$arch-unknown-linux-$libc"
}

$script:Target = Resolve-FixtureTarget

function Get-FixtureTarget {
    return $script:Target
}

# Binary name in the release archive + at the canonical bin dir.
function Get-FixtureBinName {
    if (Test-FixtureIsWindows) { return 'ocx.exe' }
    return 'ocx'
}

# Archive extension for the host platform (.zip on Windows, .tar.xz on Unix).
function Get-FixtureArchiveExt {
    if (Test-FixtureIsWindows) { return 'zip' }
    return 'tar.xz'
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

# Write the stub `ocx`/`ocx.exe` into $BuildDir.
#   - default: answers `version` -> 0.0.0, `about`, and the `ocx self setup`
#     hand-off (records "$*" to $ArgvLog when set, exits 0).
#   - $FailSelfSetup: the `self setup` hand-off exits 9 (drives the exit-6 path).
# The stub is a `#!/bin/sh` script. On Unix it is named `ocx` and chmod +x so the
# extracted/copied binary runs; on Windows it is named `ocx.exe` but is not a PE,
# so suites that execute it self-skip there.
function New-OcxStub {
    param(
        [Parameter(Mandatory)][string]$BuildDir,
        [string]$ArgvLog,
        [string]$BinName,
        [switch]$FailSelfSetup
    )
    if (-not $BinName) { $BinName = Get-FixtureBinName }
    New-Item -ItemType Directory -Path $BuildDir -Force | Out-Null
    $stubPath = Join-Path $BuildDir $BinName

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
    if (-not (Test-FixtureIsWindows)) { & chmod +x $stubPath 2>$null }
    return $stubPath
}

# Build a FLAT release archive from the contents of $BuildDir (binary at the root)
# into $OutFile. .zip via Compress-Archive on Windows; .tar.xz via `tar -cJf` on
# Unix (libarchive xz). Mirrors the real cargo-dist layout per platform.
function New-OcxArchive {
    param(
        [Parameter(Mandatory)][string]$BuildDir,
        [Parameter(Mandatory)][string]$OutFile
    )
    if (Test-FixtureIsWindows) {
        Compress-Archive -Path (Join-Path $BuildDir '*') -DestinationPath $OutFile -Force
        return
    }
    # `-C $BuildDir .` => flat members (./ocx) extracting to the archive root.
    & tar -cJf $OutFile -C $BuildDir .
    if ($LASTEXITCODE -ne 0) { throw "tar -cJf failed building $OutFile (ensure tar + xz are installed)" }
}

# Build a standalone local test binary for the __OCX_TESTING_INSTALL_BINARY hatch
# and return its path. chmod +x on non-Windows so `& <bin> version` runs there.
function New-OcxTestBinary {
    param(
        [Parameter(Mandatory)][string]$Dir,
        [string]$Name,
        [string]$ArgvLog
    )
    if (-not $Name) { $Name = Get-FixtureBinName }
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    return (New-OcxStub -BuildDir $Dir -ArgvLog $ArgvLog -BinName $Name)
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

    $archive = "ocx-$target.$(Get-FixtureArchiveExt)"
    $archivePath = Join-Path $srvDir $archive
    New-OcxArchive -BuildDir $build -OutFile $archivePath

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

    # /redirect/<path> answers 302 -> http://127.0.0.1:<port>/<path>, mirroring
    # GitHub's release-asset redirect so the installer's redirect resolver is
    # exercised. The Location is an absolute (cross-"host") https-on-localhost URL.
    def do_GET(self):
        if self.path.startswith('/redirect/'):
            target = self.path[len('/redirect'):]
            port = self.server.server_address[1]
            self.send_response(302)
            self.send_header('Location', 'http://127.0.0.1:%d%s' % (port, target))
            self.end_headers()
            return
        return super().do_GET()

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
        # Same artifact, reached through a 302 hop (see the /redirect route above).
        RedirectMirrorUrl = "http://127.0.0.1:$port/redirect/releases/download"
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
    Get-FixtureTarget, Get-FixtureBinName, Get-FixtureArchiveExt, `
    New-OcxFixture, New-OcxStub, New-OcxArchive, New-OcxTestBinary, Write-OcxDist, `
    Start-FixtureServer, Stop-FixtureServer, Get-ExpectedBinDir, `
    Wait-FixturePort, Get-PythonExe, Test-FixtureIsWindows
