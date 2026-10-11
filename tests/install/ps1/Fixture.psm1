# Shared Pester fixtures for src/install.ps1.
# Imported via `Import-Module $PSScriptRoot/Fixture.psm1 -Force` from each suite.
#
# PowerShell analogue of tests/install/helpers/server.bash: it builds a fake
# release tree (a platform-appropriate archive + a dist.json manifest with an
# INLINE sha256) and spins a python HTTPS server against it (the vendored
# localhost certificate in ../helpers) so install.ps1 runs end-to-end without
# network access. install.ps1 refuses plain http, so Run-Installer.ps1 makes the
# child accept that certificate; `Start-FixtureServer -Plain` serves http for the
# refusal scenarios.
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
# the root; on Unix it builds a FLAT .tar.gz with an executable `ocx` at the root
# (so the full download -> extract -> `self setup` hand-off path EXECUTES on the
# POSIX hosts - ubuntu + macos). The stub is a `#!/bin/sh` script; on Windows it is
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
    # The installer exits 7 when none of these decide, so 'gnu' below is only
    # reached on a host the installer itself would refuse.
    $lddOut = ''
    if (Get-Command ldd -CommandType Application -ErrorAction SilentlyContinue) {
        try { $lddOut = (& ldd --version 2>&1 | Out-String) } catch { $lddOut = '' }
    }
    $libc = 'gnu'
    if ($lddOut -cmatch 'musl') { $libc = 'musl' }
    elseif ($lddOut -cmatch 'GLIBC|GNU libc|GNU C Library') { $libc = 'gnu' }
    elseif ((Get-ChildItem -Path '/lib/ld-musl-*.so.1' -ErrorAction SilentlyContinue) -or
        (Test-Path '/etc/alpine-release')) { $libc = 'musl' }
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

# Archive extension for the host platform (.zip on Windows, .tar.gz on Unix).
function Get-FixtureArchiveExt {
    if (Test-FixtureIsWindows) { return 'zip' }
    return 'tar.gz'
}

function Wait-FixturePort {
    param(
        [Parameter(Mandatory)][string]$OutLog,
        [Parameter(Mandatory)][string]$ErrLog
    )
    # 30s: a cold python spawn on a windows-latest runner has exceeded 10s (nightly flake).
    for ($i = 0; $i -lt 300; $i++) {
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
#     hand-off (records "$*" to $ArgvLog when set, prints the marker line
#     `ocx-stub: self setup result` on STDOUT like the real result table, exits 0).
#   - $FailSelfSetup: the `self setup` hand-off exits 9 (drives the exit-6 path).
# The stub is a `#!/bin/sh` script. On Unix it is named `ocx` and chmod +x so the
# extracted/copied binary runs; on Windows it is named `ocx.exe` but is not a PE,
# so suites that execute it self-skip there.
function New-OcxStub {
    param(
        [Parameter(Mandatory)][string]$BuildDir,
        [string]$ArgvLog,
        [string]$BinName,
        [switch]$FailSelfSetup,
        [switch]$StderrOnVersion
    )
    if (-not $BinName) { $BinName = Get-FixtureBinName }
    New-Item -ItemType Directory -Path $BuildDir -Force | Out-Null
    $stubPath = Join-Path $BuildDir $BinName

    $record = ''
    if ($ArgvLog) {
        $record = "if [ -n `"`$OCX_STUB_ARGV`" ]; then printf '%s\n' `"`$*`" >> `"`$OCX_STUB_ARGV`"; fi`n" +
            "if [ -n `"`$OCX_STUB_ENV`" ]; then printf 'SSL_CERT_FILE=%s\n' `"`$SSL_CERT_FILE`" >> `"`$OCX_STUB_ENV`"; fi`n" +
            "if [ -n `"`$OCX_STUB_ENV`" ]; then printf 'OCX_EXTRA_CA_CERTS=%s\n' `"`$OCX_EXTRA_CA_CERTS`" >> `"`$OCX_STUB_ENV`"; fi`n" +
            "if [ -n `"`$OCX_STUB_ENV`" ] && [ -f `"`$SSL_CERT_FILE`" ]; then printf 'SSL_CERT_BODY=%s\n' `"`$(grep -m1 BEGIN `"`$SSL_CERT_FILE`")`" >> `"`$OCX_STUB_ENV`"; fi`n"
    }
    $setupExit = if ($FailSelfSetup) { '9' } else { '0' }
    $versionBody = if ($StderrOnVersion) { 'echo 0.0.0; echo noisy >&2' } else { 'echo 0.0.0' }
    $body = "#!/bin/sh`n" +
            $record +
            "case `"`$1`" in`n" +
            "  version) $versionBody ;;`n" +
            "  about) echo 'ocx 0.0.0 (fixture stub)' ;;`n" +
            "  --offline) shift; [ `"`$1`" = self ] && [ `"`$2`" = setup ] && { echo 'ocx-stub: self setup result'; exit $setupExit; }; echo 'stub ocx' ;;`n" +
            "  self) [ `"`$2`" = setup ] && { echo 'ocx-stub: self setup result'; exit $setupExit; }; echo 'stub ocx' ;;`n" +
            "  *) echo 'stub ocx' ;;`n" +
            "esac`n"
    [System.IO.File]::WriteAllText($stubPath, $body)
    if (-not (Test-FixtureIsWindows)) { & chmod +x $stubPath 2>$null }
    return $stubPath
}

# Build a FLAT release archive from the contents of $BuildDir (binary at the root)
# into $OutFile. .zip via Compress-Archive on Windows; .tar.gz via `tar -czf` on
# Unix (gzip in-box on modern tar). Mirrors the real cargo-dist layout per platform.
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
    & tar -czf $OutFile -C $BuildDir .
    if ($LASTEXITCODE -ne 0) { throw "tar -czf failed building $OutFile (ensure tar is installed)" }
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
        [Parameter(Mandatory)][AllowEmptyString()][string]$Sha,
        [Parameter(Mandatory)][string]$Filename,
        [switch]$OmitSha
    )
    $shaField = if ($OmitSha) { '' } else { ",`"sha256`":`"$Sha`"" }
    $json = @"
{
  "schema": 1,
  "latest": {"version":"0.0.0","channel":"stable"},
  "latest_next": null,
  "releases": [
    {"version":"0.0.0","channel":"stable","tag":"v0.0.0","target":"$Target","filename":"$Filename"$shaField,"url":"https://example.invalid/ocx/releases/download/v0.0.0/$Filename"}
  ]
}
"@
    Set-Content -LiteralPath (Join-Path $SrvRoot 'dist.json') -Value $json -Encoding ASCII -NoNewline
}

# Write dist-decoy.json beside dist.json: a manifest whose newest stable release
# (9.9.9) has no row for this host's target, then the real 0.0.0 row. Latest
# resolution lands on the decoy (exit 3); pinning 0.0.0 must still install.
# Mirror of server_write_decoy_dist in ../helpers/server.bash.
function Write-OcxDecoyDist {
    param([Parameter(Mandatory)][string]$SrvRoot)
    $real = Get-Content -LiteralPath (Join-Path $SrvRoot 'dist.json') -Raw | ConvertFrom-Json
    $row = $real.releases[0]
    $json = @"
{
  "schema": 1,
  "latest": {"version":"9.9.9","channel":"stable"},
  "latest_next": null,
  "releases": [
    {"version":"9.9.9","channel":"stable","tag":"v9.9.9","target":"decoy-unknown-none","filename":"ocx-decoy.tar.gz","sha256":"$('0' * 64)","url":"https://example.invalid/ocx/releases/download/v9.9.9/ocx-decoy.tar.gz"},
    {"version":"0.0.0","channel":"stable","tag":"v0.0.0","target":"$($row.target)","filename":"$($row.filename)","sha256":"$($row.sha256)","url":"$($row.url)"}
  ]
}
"@
    Set-Content -LiteralPath (Join-Path $SrvRoot 'dist-decoy.json') -Value $json -Encoding ASCII -NoNewline
}

# Serve an arbitrary prepared archive as the v0.0.0 release for this host. The
# manifest carries the archive's real sha256 unless $Sha overrides it. Returns
# the same shape as New-OcxFixture.
function New-ArchiveFixture {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Archive,
        [Parameter(Mandatory)][string]$Filename,
        [string]$Sha,
        [switch]$OmitSha
    )
    $srvRoot = Join-Path $Root 'srv'
    $srvDir = Join-Path $srvRoot 'releases/download/v0.0.0'
    New-Item -ItemType Directory -Path $srvDir -Force | Out-Null
    Copy-Item -LiteralPath $Archive -Destination (Join-Path $srvDir $Filename) -Force
    if (-not $PSBoundParameters.ContainsKey('Sha')) {
        $Sha = (Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash.ToLower()
    }
    Write-OcxDist -SrvRoot $srvRoot -Target $script:Target -Sha $Sha -Filename $Filename -OmitSha:$OmitSha
    return @{ Root = $Root; SrvRoot = $srvRoot; Target = $script:Target; Archive = $Filename }
}

# A .zip holding one tiny file per name in $EntryNames, names taken verbatim
# (so '..\x', '/x' and 'C:x' reach the installer's containment checks).
function New-HostileZip {
    param(
        [Parameter(Mandatory)][string]$OutFile,
        [Parameter(Mandatory)][string[]]$EntryNames
    )
    Add-Type -AssemblyName System.IO.Compression
    Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
    $fs = [System.IO.File]::Open($OutFile, [System.IO.FileMode]::Create)
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in $EntryNames) {
            $w = New-Object System.IO.StreamWriter($zip.CreateEntry($name).Open())
            try { $w.Write('evil') } finally { $w.Dispose() }
        }
    }
    finally { $zip.Dispose(); $fs.Dispose() }
}

# A .tar.gz with one hostile member: Kind is dotdot ('../x'), abs ('/x') or
# symlink (a link to '../..'). Built by python's tarfile, which writes names as given.
function New-HostileTar {
    param(
        [Parameter(Mandatory)][string]$OutFile,
        [Parameter(Mandatory)][ValidateSet('dotdot', 'abs', 'symlink')][string]$Kind,
        [string]$EvilName = 'ocx-evil.txt'
    )
    $py = Join-Path (Split-Path $OutFile -Parent) 'hostile-tar.py'
    [System.IO.File]::WriteAllText($py, @'
import io, sys, tarfile
out, kind, evil = sys.argv[1:4]
t = tarfile.open(out, 'w:gz')
if kind == 'symlink':
    i = tarfile.TarInfo('link')
    i.type = tarfile.SYMTYPE
    i.linkname = '../..'
    t.addfile(i)
else:
    i = tarfile.TarInfo(('../' if kind == 'dotdot' else '/tmp/') + evil)
    i.size = 4
    t.addfile(i, io.BytesIO(b'evil'))
t.close()
'@)
    & (Get-PythonExe) -I $py $OutFile $Kind $EvilName
    if ($LASTEXITCODE -ne 0) { throw "python failed building $OutFile" }
}

# Build the fake release tree under $Root and return a hashtable describing it.
function New-OcxFixture {
    param(
        [Parameter(Mandatory)][string]$Root,
        [switch]$TamperChecksum,
        [string]$ArgvLog,
        [switch]$FailSelfSetup,
        [switch]$StderrOnVersion
    )

    $target = $script:Target
    $build = Join-Path $Root 'build'
    New-OcxStub -BuildDir $build -ArgvLog $ArgvLog -FailSelfSetup:$FailSelfSetup -StderrOnVersion:$StderrOnVersion | Out-Null

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
        $hash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLower()
    }
    Write-OcxDist -SrvRoot $srvRoot -Target $target -Sha $hash -Filename $archive

    return @{
        Root    = $Root
        SrvRoot = $srvRoot
        Target  = $target
        Archive = $archive
    }
}

# Spin a python server against $SrvRoot: HTTPS with the vendored localhost
# certificate, or plain http with -Plain (to prove the installer refuses it and
# never sends a request). Returns @{ Process; Port; DistUrl; MirrorUrl; ... }.
# dist.json is served as application/json so ConvertFrom-Json is happy.
function Start-FixtureServer {
    param(
        [Parameter(Mandatory)][string]$SrvRoot,
        [switch]$Plain
    )

    $python = Get-PythonExe
    $parent = Split-Path $SrvRoot -Parent
    $tag = if ($Plain) { '-plain' } else { '' }
    $outLog = Join-Path $parent "srv$tag.out.log"
    $errLog = Join-Path $parent "srv$tag.err.log"
    $scheme = if ($Plain) { 'http' } else { 'https' }
    $cert = if ($Plain) { 'plain' } else { (Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'helpers') 'localhost-combined.pem') }

    $serverPy = Join-Path $parent "fixture-server$tag.py"
    $pyBody = @'
import http.server, socketserver, ssl, sys

CERT = sys.argv[1]
SCHEME = 'http' if CERT == 'plain' else 'https'

class Handler(http.server.SimpleHTTPRequestHandler):
    def guess_type(self, path):
        if path.endswith('dist.json') or path.endswith('/dist'):
            return 'application/json'
        return super().guess_type(path)

    # /redirect/<path> answers 302 -> <scheme>://127.0.0.1:<port>/<path>, mirroring
    # GitHub's release-asset redirect so the installer's redirect resolver is
    # exercised. /downgrade/<path> answers 302 -> http://... (a TLS downgrade the
    # installer must refuse).
    # /flaky/<n>/<path> answers 500 for the first <n> hits of that exact URL,
    # then serves <path> normally - the retry path. Counter is a CLASS attribute
    # because a new Handler instance is built per request.
    hits = {}

    def do_GET(self):
        port = self.server.server_address[1]
        for prefix, scheme in (('/redirect', SCHEME), ('/downgrade', 'http')):
            if self.path.startswith(prefix + '/'):
                self.send_response(302)
                self.send_header('Location', '%s://127.0.0.1:%d%s' % (scheme, port, self.path[len(prefix):]))
                self.end_headers()
                return
        if self.path.startswith('/flaky/'):
            rest = self.path[len('/flaky/'):]
            count, _, target = rest.partition('/')
            try:
                limit = int(count)
            except ValueError:
                self.send_error(400, 'bad flaky count')
                return
            seen = Handler.hits.get(self.path, 0)
            Handler.hits[self.path] = seen + 1
            if seen < limit:
                self.send_error(500, 'flaky fixture failure')
                return
            self.path = '/' + target
        return super().do_GET()

with socketserver.TCPServer(('127.0.0.1', 0), Handler) as httpd:
    if SCHEME == 'https':
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(CERT)
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    print('Serving %s on 127.0.0.1 port %d' % (SCHEME.upper(), httpd.server_address[1]), flush=True)
    httpd.serve_forever()
'@
    [System.IO.File]::WriteAllText($serverPy, $pyBody)

    $proc = Start-Process -FilePath $python `
        -ArgumentList '-u', "`"$serverPy`"", "`"$cert`"" `
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
        DistUrl   = "${scheme}://127.0.0.1:$port/dist.json"
        MirrorUrl = "${scheme}://127.0.0.1:$port/releases/download"
        # Same artifact, reached through a 302 hop (see the /redirect route above).
        RedirectMirrorUrl = "${scheme}://127.0.0.1:$port/redirect/releases/download"
        # A 302 to plain http (see the /downgrade route above).
        DowngradeMirrorUrl = "${scheme}://127.0.0.1:$port/downgrade/releases/download"
        # The python access log - one line per request, so a retry test can
        # count attempts (see the /flaky route above).
        ErrLog    = $errLog
    }
}

function Stop-FixtureServer {
    param($Server)
    if ($Server -and $Server.Process -and -not $Server.Process.HasExited) {
        Stop-Process -Id $Server.Process.Id -Force -ErrorAction SilentlyContinue
    }
}

# Publish the fixture's dist.json as a content-addressed snapshot at
# dist/<sha256>.json - the layout scripts/publish-dist.sh and `ocx-mirror dist
# sync` both emit - and return the digest.
#
# Pointing OCX_INSTALL_DIST_URL at the snapshot PINS the manifest: install.ps1
# recognises the 64-hex basename and verifies the served body against it, so a
# mirror that altered the manifest is caught (exit 4) instead of trusted.
function Publish-DistSnapshot {
    param([Parameter(Mandatory)][string]$SrvRoot)
    $dist = Join-Path $SrvRoot 'dist.json'
    $sha = (Get-FileHash -LiteralPath $dist -Algorithm SHA256).Hash.ToLower()
    $dir = Join-Path $SrvRoot 'dist'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Copy-Item -Path $dist -Destination (Join-Path $dir "$sha.json") -Force
    return $sha
}

# Canonical OCX bin dir under $OcxHome (the real on-disk store layout).
function Get-ExpectedBinDir {
    param([Parameter(Mandatory)][string]$OcxHome)
    return (Join-Path $OcxHome 'symlinks/ocx.sh/ocx/cli/current/content/bin')
}

<#
.SYNOPSIS
Copy install.ps1 and substitute its embedded-configuration placeholders.

.DESCRIPTION
The PowerShell mirror of server_embed_config in ../helpers/server.bash. Tokens
are the bare environment-variable names (e.g. OCX_INSTALL_DIST_URL); the @...@
wrapper is added here. The substitution is a plain literal replace over the whole
file - the point of the token contract is that ONE such command works on every
dialect, so no per-shell special-casing belongs here. A value may contain
newlines (an inline PEM block).
#>
function New-EmbeddedInstaller {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][hashtable]$Tokens
    )
    $text = [System.IO.File]::ReadAllText($Source)
    foreach ($key in $Tokens.Keys) {
        $token = "@$key@"
        if ($text -notlike "*$token*") { throw "placeholder $token not found in $Source" }
        $text = $text.Replace($token, [string]$Tokens[$key])
    }
    [System.IO.File]::WriteAllText($Destination, $text)
    return $Destination
}

Export-ModuleMember -Function `
    Get-FixtureTarget, Get-FixtureBinName, Get-FixtureArchiveExt, `
    New-OcxFixture, New-OcxStub, New-OcxArchive, New-OcxTestBinary, Write-OcxDist, Write-OcxDecoyDist, `
    New-ArchiveFixture, New-HostileZip, New-HostileTar, `
    New-EmbeddedInstaller, `
    Publish-DistSnapshot, `
    Start-FixtureServer, Stop-FixtureServer, Get-ExpectedBinDir, `
    Wait-FixturePort, Get-PythonExe, Test-FixtureIsWindows
