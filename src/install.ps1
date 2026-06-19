# install.ps1 - OCX installer for Windows
# https://ocx.sh
#
# Windows-only. This installer targets Windows PowerShell 5.1+ and PowerShell 7+
# ON WINDOWS (the release targets are *-pc-windows-msvc and the binary is
# ocx.exe). On Linux/macOS use the POSIX installer (src/install.sh); this script
# intentionally does NOT support pwsh-on-Linux for real installs.
#
# This is a THIN BOOTSTRAP. It detects the architecture, resolves the release
# from the self-hosted distribution manifest (dist.json), downloads + verifies
# the archive against the manifest's inline sha256, then hands off to the
# downloaded binary's `ocx self setup`. `ocx self setup` owns everything that
# touches the machine - the package-store self-install, the per-shell env shims
# under $OcxHome, and the managed PowerShell-profile activation block.
#
# Usage:
#   irm https://setup.ocx.sh/pwsh | iex
#   $env:OCX_NO_MODIFY_PATH = '1'; irm https://setup.ocx.sh/pwsh | iex
#   & ([scriptblock]::Create((irm https://setup.ocx.sh/pwsh))) -Version 0.5.0
#   $env:OCX_INSTALL_VERSION = '0.5.0'; irm https://setup.ocx.sh/pwsh | iex
#
# Latest-version resolution + the per-target checksum/URL come from the
# self-hosted distribution manifest (OCX_INSTALL_DIST_URL, default
# https://setup.ocx.sh/dist.json) - NOT the GitHub API. No GITHUB_TOKEN is
# consulted; the manifest and release assets are public.
#
# Stdout/stderr contract (load-bearing):
#   - All informational/warning/error messages go to STDERR.
#   - STDOUT is silent on success unless OCX_INSTALL_PRINT_PATH is truthy (or
#     -PrintPath), in which case the FINAL stdout line is the absolute path to
#     the OCX bin dir.
#
# Exit codes:
#   0  success
#   1  generic / legacy
#   2  argument or environment validation
#   3  network / download / manifest failure
#   4  checksum mismatch
#   5  archive extraction failure
#   6  'ocx self setup' failure
#   7  unsupported platform / architecture

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$Version = '',
    [switch]$NoModifyPath,
    [switch]$Quiet,
    [switch]$Force,
    [switch]$PrintPath,
    [switch]$NoSetup,
    [switch]$NoSmoketest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Truthy helper ---

function Test-Truthy {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return $false }
    # Case-SENSITIVE match over exactly the 7 forms sh's is_truthy accepts:
    #   1 | true | yes | TRUE | YES | True | Yes
    return $Value -cmatch '^(1|true|yes|TRUE|YES|True|Yes)$'
}

# --- Configuration (env-driven) ---
#
# Tier 1 - shared OCX env: OCX_HOME, OCX_NO_MODIFY_PATH. Plus NO_COLOR, TMPDIR.
# Tier 2 - installer-only knobs, all OCX_INSTALL_*:
#   values:    OCX_INSTALL_VERSION (empty = latest), OCX_INSTALL_REPO
#   endpoints: OCX_INSTALL_DIST_URL, OCX_INSTALL_MIRROR_URL
#   opt-outs:  OCX_INSTALL_NO_SETUP, OCX_INSTALL_NO_SMOKETEST
#   opt-ins:   OCX_INSTALL_FORCE, OCX_INSTALL_QUIET, OCX_INSTALL_PRINT_PATH
# (OCX_INSTALL_DOWNLOADER is sh-only; install.ps1 always uses Invoke-WebRequest.)

$OcxInstallRepo      = if ($env:OCX_INSTALL_REPO)        { $env:OCX_INSTALL_REPO }        else { 'ocx-sh/ocx' }
$OcxInstallDistUrl   = if ($env:OCX_INSTALL_DIST_URL)    { $env:OCX_INSTALL_DIST_URL }    else { 'https://setup.ocx.sh/dist.json' }
$OcxInstallMirrorUrl = if ($env:OCX_INSTALL_MIRROR_URL)  { $env:OCX_INSTALL_MIRROR_URL }  else { '' }

# Behavioral knobs. Environment wins over switches.
$OcxInstallNoSetup    = if (Test-Truthy $env:OCX_INSTALL_NO_SETUP)    { $true } else { [bool]$NoSetup }
$OcxInstallPrintPath  = if (Test-Truthy $env:OCX_INSTALL_PRINT_PATH)  { $true } else { [bool]$PrintPath }
$OcxInstallForce      = if (Test-Truthy $env:OCX_INSTALL_FORCE)       { $true } else { [bool]$Force }
$OcxInstallQuiet      = if (Test-Truthy $env:OCX_INSTALL_QUIET)       { $true } else { [bool]$Quiet }
$OcxInstallNoSmoketest = if (Test-Truthy $env:OCX_INSTALL_NO_SMOKETEST) { $true } else { [bool]$NoSmoketest }
$OcxNoModifyPath      = if (Test-Truthy $env:OCX_NO_MODIFY_PATH)      { $true } else { [bool]$NoModifyPath }

# Canonical CLI bin dir relative to OCX_HOME (real on-disk store layout).
$OcxBinSubPath = 'symlinks\ocx.sh\ocx\cli\current\content\bin'

# --- Output helpers (all go to STDERR) ---

function Say {
    param([string]$Message)
    if ($OcxInstallQuiet) { return }
    [Console]::Error.WriteLine("ocx-install: $Message")
}

function Err {
    param([string]$Message, [int]$Code = 1)
    [Console]::Error.WriteLine("ocx-install: error: $Message")
    exit $Code
}

function Warn {
    param([string]$Message)
    [Console]::Error.WriteLine("ocx-install: warning: $Message")
}

# --- Platform detection ---

function Detect-Architecture {
    try {
        $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
        switch ($arch) {
            'X64'   { return 'x86_64-pc-windows-msvc' }
            'Arm64' { return 'aarch64-pc-windows-msvc' }
            'X86'   { Err '32-bit Windows is not supported. OCX requires a 64-bit system.' 7 }
            'Arm'   { Err '32-bit ARM Windows is not supported. OCX requires a 64-bit system.' 7 }
            default { Err "Unsupported architecture: $arch" 7 }
        }
    }
    catch {
        Write-Verbose "OSArchitecture probe failed, falling back to PROCESSOR_ARCHITECTURE: $($_.Exception.Message)"
    }

    $procArch = $env:PROCESSOR_ARCHITECTURE
    switch ($procArch) {
        'AMD64' { return 'x86_64-pc-windows-msvc' }
        'ARM64' { return 'aarch64-pc-windows-msvc' }
        'x86'   { Err '32-bit Windows is not supported. OCX requires a 64-bit system.' 7 }
        default { Err "Unsupported architecture: $procArch" 7 }
    }
}

# --- Download utilities ---

# TLS fail-closed gate. OCX_INSTALL_DIST_URL / OCX_INSTALL_MIRROR_URL are
# CI-injectable, so reject any non-https URL with exit 3 before a request leaves
# the machine. Loopback (127.0.0.1 / [::1] / localhost) is exempt so the
# Pester/Bats fixture servers can run on loopback; no credential is ever
# attached, so the public network stays https-only.
function Assert-HttpsUrl {
    param([string]$Url)
    if ($Url -match '^https://') { return }
    if ($Url -match '^https?://(?:127\.0\.0\.1|\[::1\]|localhost)(?::\d+)?(?:/|$)') { return }
    Err "refusing insecure (non-https) URL: $Url" 3
}

# Extract the redirect Location from a thrown Invoke-WebRequest error, across
# PowerShell editions (PS 5.1 WebException vs PS 7 HttpResponseException).
function Get-RedirectLocation {
    param($ErrorRecord)
    $resp = $ErrorRecord.Exception.Response
    if ($null -eq $resp) { return $null }
    try { $code = [int]$resp.StatusCode } catch { return $null }
    if ($code -lt 300 -or $code -ge 400) { return $null }
    if ($resp.PSObject.Properties.Match('Headers').Count -gt 0 -and
        $resp.Headers.PSObject.Properties.Match('Location').Count -gt 0 -and
        $resp.Headers.Location) {
        return [string]$resp.Headers.Location
    }
    try { return [string]$resp.Headers['Location'] } catch { return $null }
}

function Download-File {
    param([string]$Url, [string]$Destination)

    Assert-HttpsUrl $Url
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

    # Follow at most ONE redirect hop manually, re-validating the scheme on the
    # hop target. -MaximumRedirection 0 means a https->http redirect can NOT
    # silently downgrade the transport. GitHub release assets answer 302 to a
    # signed S3 URL, so one explicit, scheme-checked hop is required.
    $current = $Url
    for ($hop = 0; $hop -lt 2; $hop++) {
        try {
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $current -OutFile $Destination -MaximumRedirection 0 -UseBasicParsing -ErrorAction Stop
            return $true
        }
        catch {
            $next = Get-RedirectLocation $_
            if (-not $next) { return $false }
            Assert-HttpsUrl $next
            $current = $next
        }
    }
    return $false
}

function Download-String {
    param([string]$Url)
    Assert-HttpsUrl $Url
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
    $ProgressPreference = 'SilentlyContinue'
    (Invoke-WebRequest -Uri $Url -MaximumRedirection 0 -UseBasicParsing).Content
}

# --- Checksum verification ---

# Verify-Checksum <file_path> <expected_sha256>. The expected hash comes inline
# from dist.json - no separate sha256.sum fetch.
function Verify-Checksum {
    param([string]$FilePath, [string]$Expected)

    if ([string]::IsNullOrWhiteSpace($Expected)) {
        Warn 'No inline checksum in the manifest - skipping verification.'
        return
    }
    $expectedLower = $Expected.ToLower()
    $actual = (Get-FileHash -Path $FilePath -Algorithm SHA256).Hash.ToLower()
    if ($expectedLower -ne $actual) {
        Err "Checksum mismatch for $(Split-Path $FilePath -Leaf)`n  expected: $expectedLower`n  got:      $actual" 4
    }
    Say 'Checksum verified.'
}

# --- Archive extraction ---

# Extract a .zip with zip-slip protection on PowerShell 5.1+. Expand-Archive only
# validates entry paths from PS 7.4 onwards, so we use the .NET API directly and
# reject any entry that escapes the destination directory.
function Expand-ZipSafely {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Destination
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    [System.IO.Directory]::CreateDirectory($Destination) | Out-Null
    $destRoot = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\', '/')
    $sep = [System.IO.Path]::DirectorySeparatorChar

    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName
            $rel = $name -replace '/', '\'
            $segments = $rel.Split('\')
            if ($rel.StartsWith('\') -or $rel -match '^[A-Za-z]:' -or ($segments -contains '..')) {
                throw "Archive contains unsafe entry: $name"
            }
            $target = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($destRoot, $rel))
            if ($target -ne $destRoot -and
                -not $target.StartsWith($destRoot + $sep, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Archive entry escapes destination: $name"
            }
            if ($name.EndsWith('/') -or $name.EndsWith('\')) {
                [System.IO.Directory]::CreateDirectory($target) | Out-Null
                continue
            }
            $parent = [System.IO.Path]::GetDirectoryName($target)
            if ($parent) { [System.IO.Directory]::CreateDirectory($parent) | Out-Null }
            $in = $entry.Open()
            try {
                $out = [System.IO.File]::Create($target)
                try { $in.CopyTo($out) } finally { $out.Dispose() }
            }
            finally { $in.Dispose() }
        }
    }
    finally { $zip.Dispose() }
}

# --- OCX_HOME validation ---

# Defence-in-depth: $OcxHome is embedded literally into the env shim + profile
# block written by `ocx self setup`. Reject a path that is not absolute, contains
# '..' components, or carries characters that could break out of that quoting.
function Assert-SafeOcxHome {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { Err 'OCX_HOME must not be empty' 2 }
    if (-not [System.IO.Path]::IsPathRooted($Path)) { Err "OCX_HOME must be an absolute path: $Path" 2 }
    if ($Path -match '\.\.[\\/]' -or $Path -match '[\\/]\.\.$' -or $Path -eq '..') {
        Err "OCX_HOME must not contain '..' components: $Path" 2
    }
    if ($Path -match '["`$;\r\n\[\]()]') {
        Err "OCX_HOME contains characters unsafe for shell embedding: $Path" 2
    }
}

# --- Distribution manifest (dist.json) ---

# Parse dist.json via native ConvertFrom-Json. Returns the parsed object.
function Get-DistManifest {
    $body = $null
    try { $body = Download-String $OcxInstallDistUrl }
    catch { Err "Failed to fetch the latest version from the manifest ($OcxInstallDistUrl): $($_.Exception.Message)" 3 }

    if ([string]::IsNullOrWhiteSpace([string]$body)) {
        Err "Failed to determine the latest version: the manifest ($OcxInstallDistUrl) was empty." 3
    }
    try { return ConvertFrom-Json -InputObject ([string]$body) }
    catch { Err "Failed to parse the latest version from the manifest ($OcxInstallDistUrl): $($_.Exception.Message)" 3 }
}

# Resolve the latest STABLE version: the first releases[] entry whose channel is
# 'stable' (newest-first ordering makes that the latest stable).
function Get-LatestVersion {
    param($Dist)
    $releases = @()
    if ($Dist.PSObject.Properties.Match('releases').Count -gt 0 -and $Dist.releases) {
        $releases = @($Dist.releases)
    }
    foreach ($entry in $releases) {
        if ($null -eq $entry) { continue }
        $channel = $null; $version = $null
        if ($entry.PSObject.Properties.Match('channel').Count -gt 0) { $channel = [string]$entry.channel }
        if ($entry.PSObject.Properties.Match('version').Count -gt 0) { $version = [string]$entry.version }
        if ($channel -eq 'stable' -and -not [string]::IsNullOrWhiteSpace($version)) {
            return ($version -replace '^v', '')
        }
    }
    Err "Could not determine the latest version: no stable release found in the manifest ($OcxInstallDistUrl)." 3
}

# Find the releases[] row matching (version,target). Returns the row or $null.
function Resolve-DistRow {
    param($Dist, [string]$Ver, [string]$Target)
    $releases = @()
    if ($Dist.PSObject.Properties.Match('releases').Count -gt 0 -and $Dist.releases) {
        $releases = @($Dist.releases)
    }
    foreach ($entry in $releases) {
        if ($null -eq $entry) { continue }
        $v = $null; $t = $null
        if ($entry.PSObject.Properties.Match('version').Count -gt 0) { $v = [string]$entry.version }
        if ($entry.PSObject.Properties.Match('target').Count -gt 0) { $t = [string]$entry.target }
        if ($v -eq $Ver -and $t -eq $Target) { return $entry }
    }
    return $null
}

# --- Hand off to `ocx self setup` ---

# Run the downloaded binary's `ocx self setup`. Global pre-flags (e.g. --offline)
# precede the subcommand; subcommand args (the version positional,
# --no-modify-path) follow it.
function Invoke-SelfSetup {
    param([string]$Bin, [string[]]$PreArgs = @(), [string[]]$PostArgs = @())
    Say 'Running ocx self setup...'
    $argList = @($PreArgs) + @('self', 'setup') + @($PostArgs)
    & $Bin @argList
    if ($LASTEXITCODE -ne 0) {
        Err "'ocx self setup' failed - see the output above for details" 6
    }
}

# --- Place binary (NO_SETUP path) ---

# Place the extracted binary at the canonical bin dir (no `ocx self setup`).
# Binary-on-PATH only: 'ocx self update' will NOT manage such an install.
function Install-PlaceBinary {
    param([string]$Bin, [string]$OcxHome)
    $binDir = Join-Path $OcxHome $OcxBinSubPath
    New-Item -ItemType Directory -Path $binDir -Force | Out-Null
    Copy-Item -Path $Bin -Destination (Join-Path $binDir 'ocx.exe') -Force
    Say "Installed to $binDir\ocx.exe"
}

# --- Test-mode install (internal, test-only) ---

# Install a pre-built ocx.exe as the candidate, bypassing download + checksum +
# extract. Driven by $env:__OCX_TESTING_INSTALL_BINARY (double-underscore =
# test-only, undocumented). Validates the source is a file (exit 2).
function Install-LocalTestBinary {
    param([string]$Source, [string]$OcxHome)
    if (-not (Test-Path $Source -PathType Leaf)) {
        Err "__OCX_TESTING_INSTALL_BINARY does not point to a file: $Source" 2
    }
    $binDir = Join-Path $OcxHome $OcxBinSubPath
    Say 'Test mode: installing local binary as the candidate (no download).'
    New-Item -ItemType Directory -Path $binDir -Force | Out-Null
    Copy-Item -Path $Source -Destination (Join-Path $binDir 'ocx.exe') -Force
    Say "Installed to $binDir\ocx.exe"
}

# --- Success message ---

function Print-Success {
    param([string]$InstalledVersion)
    if ($OcxInstallQuiet) { return }
    $ocxHome = if ($env:OCX_HOME) { $env:OCX_HOME } else { Join-Path $env:USERPROFILE '.ocx' }
    [Console]::Error.WriteLine('')
    [Console]::Error.WriteLine("  ocx $InstalledVersion installed successfully!")
    [Console]::Error.WriteLine(@"

  Restart your shell, then verify with:

    ocx about

  To uninstall, remove the OCX home directory:

    Remove-Item -Recurse -Force "$ocxHome"

"@)
}

# --- CI PATH export ---

function Export-GithubPath {
    param([string]$OcxHome)
    if ($env:GITHUB_PATH) {
        $ghBinPath = Join-Path $OcxHome $OcxBinSubPath
        try { Add-Content -Path $env:GITHUB_PATH -Value $ghBinPath }
        catch { Warn 'Failed to write to $GITHUB_PATH.' }
    }
}

# --- Main ---

function Main {
    param([string]$RequestedVersion = '')

    if ($PSVersionTable.PSVersion -lt [Version]'5.1') {
        [Console]::Error.WriteLine('ocx-install: error: PowerShell 5.1+ required.')
        [Console]::Error.WriteLine('Upgrade: https://aka.ms/install-powershell')
        exit 2
    }

    # Version precedence: -Version flag > OCX_INSTALL_VERSION env > caller-scope
    # $Version idiom > latest lookup.
    $requestedVersion = $RequestedVersion
    if (-not $requestedVersion -and $env:OCX_INSTALL_VERSION) { $requestedVersion = $env:OCX_INSTALL_VERSION }
    if (-not $requestedVersion) {
        $callerVersion = Get-Variable -Name 'Version' -Scope 1 -ErrorAction SilentlyContinue
        if ($callerVersion -and $callerVersion.Value) { $requestedVersion = $callerVersion.Value }
    }

    $ocxHome = if ($env:OCX_HOME) { $env:OCX_HOME } else { Join-Path $env:USERPROFILE '.ocx' }
    Assert-SafeOcxHome -Path $ocxHome
    $installBinDir = Join-Path $ocxHome $OcxBinSubPath

    # `ocx self setup` subcommand flags (--no-modify-path keyed off
    # OCX_NO_MODIFY_PATH or -NoModifyPath). No-op in NO_SETUP mode.
    $postFlags = @()
    if ($OcxNoModifyPath) { $postFlags += '--no-modify-path' }

    # --- Internal test-mode hatch (UNDOCUMENTED) ---
    if ($env:__OCX_TESTING_INSTALL_BINARY) {
        Install-LocalTestBinary -Source $env:__OCX_TESTING_INSTALL_BINARY -OcxHome $ocxHome
        $candBin = Join-Path $installBinDir 'ocx.exe'
        if ($OcxInstallNoSetup) {
            Say 'Skipping ocx self setup (OCX_INSTALL_NO_SETUP).'
        }
        else {
            # Candidate present, no registry reachable -> --offline. No version
            # positional (the candidate is 'local', not a published version).
            Invoke-SelfSetup -Bin $candBin -PreArgs @('--offline') -PostArgs $postFlags
        }
        Export-GithubPath -OcxHome $ocxHome
        if ($OcxInstallPrintPath) { Write-Output $installBinDir }
        return
    }

    $target = Detect-Architecture
    Say "Detected platform: $target"

    # Fetch + parse the manifest once; reuse for latest- AND row-resolution.
    $dist = Get-DistManifest

    if (-not $requestedVersion) {
        Say 'Resolving latest version...'
        $requestedVersion = Get-LatestVersion -Dist $dist
    }

    if ($requestedVersion -match '[^0-9A-Za-z.+-]') {
        Err "Invalid version format: $requestedVersion (expected semver like 1.2.3 or 1.0.0-rc.1)" 2
    }
    if ($requestedVersion -notmatch '^\d+\.\d+\.\d+') {
        Err "Invalid version format: $requestedVersion (expected semver like 1.2.3)" 2
    }

    # Idempotent fast-path.
    $oldVersion = ''
    $existingBin = Join-Path $installBinDir 'ocx.exe'
    if (Test-Path $existingBin) {
        try { $oldVersion = & $existingBin version 2>$null } catch { Write-Verbose "version probe failed: $($_.Exception.Message)" }
    }
    if ($oldVersion -and ($oldVersion -eq $requestedVersion) -and -not $OcxInstallForce) {
        Say "ocx v$requestedVersion already installed at $installBinDir\ocx.exe (set OCX_INSTALL_FORCE=1 to reinstall)"
        if ($OcxInstallPrintPath) { Write-Output $installBinDir }
        Export-GithubPath -OcxHome $ocxHome
        return
    }

    # Resolve the (version,target) row -> inline sha256 + download URL.
    $row = Resolve-DistRow -Dist $dist -Ver $requestedVersion -Target $target
    if (-not $row) {
        Err "No published artifact for ocx v$requestedVersion on $target in the manifest ($OcxInstallDistUrl)." 3
    }
    $sha = if ($row.PSObject.Properties.Match('sha256').Count -gt 0) { [string]$row.sha256 } else { '' }
    $url = if ($row.PSObject.Properties.Match('url').Count -gt 0) { [string]$row.url } else { '' }
    $filename = if ($row.PSObject.Properties.Match('filename').Count -gt 0) { [string]$row.filename } else { '' }
    $tag = if ($row.PSObject.Properties.Match('tag').Count -gt 0) { [string]$row.tag } else { '' }
    if (-not $url -or -not $filename) {
        Err "Manifest row for v$requestedVersion/$target is missing url/filename." 3
    }

    # Artifact host override (mirror): rewrite the host, keep <tag>/<filename>.
    if ($OcxInstallMirrorUrl) {
        $url = ($OcxInstallMirrorUrl.TrimEnd('/')) + "/$tag/$filename"
    }

    Say "Installing ocx v$requestedVersion..."

    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "ocx-install-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

    try {
        $archivePath = Join-Path $tmpDir $filename
        Say "Downloading $filename..."
        $downloaded = Download-File -Url $url -Destination $archivePath
        if (-not $downloaded) {
            Err "Failed to download $url`nEnsure v$requestedVersion is a valid release with a binary for $target.`nAvailable releases: https://github.com/$OcxInstallRepo/releases" 3
        }

        Verify-Checksum -FilePath $archivePath -Expected $sha

        $extractDir = Join-Path $tmpDir 'extracted'
        try { Expand-ZipSafely -Path $archivePath -Destination $extractDir }
        catch { Err "Failed to extract $filename - $($_.Exception.Message)" 5 }

        $bin = $null
        $candidatePaths = @(
            (Join-Path $extractDir "ocx-$target\ocx.exe"),
            (Join-Path $extractDir 'ocx.exe')
        )
        foreach ($candidate in $candidatePaths) {
            if (Test-Path $candidate) { $bin = $candidate; break }
        }
        if (-not $bin) { Err 'Could not find ocx.exe binary in archive.' 5 }

        if (-not $OcxInstallNoSmoketest) {
            try { $null = & $bin version 2>$null }
            catch { Warn 'Binary failed to execute - it may be blocked by antivirus or execution policy.' }
        }

        # PATH shadowing warning (OrdinalIgnoreCase; trailing-sep anchored).
        $existingOcx = Get-Command ocx -ErrorAction SilentlyContinue
        $ocxHomePrefix = $ocxHome.TrimEnd('\') + '\'
        if ($existingOcx -and -not $existingOcx.Source.StartsWith($ocxHomePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            Warn "An existing ocx was found at $($existingOcx.Source)"
            Warn 'The new install may be shadowed - check your PATH order.'
        }

        if (-not (Test-Path $ocxHome)) { New-Item -ItemType Directory -Path $ocxHome -Force | Out-Null }

        if ($OcxInstallNoSetup) {
            # Binary-on-PATH only: place the binary, skip `ocx self setup`.
            Install-PlaceBinary -Bin $bin -OcxHome $ocxHome
        }
        else {
            # Hand off: `ocx self setup <version>` installs that version from the
            # registry into the package store and writes the env shim + profile
            # block. The version is a positional to `self setup`.
            Invoke-SelfSetup -Bin $bin -PostArgs (@($requestedVersion) + $postFlags)
            Print-Success -InstalledVersion $requestedVersion
        }

        Export-GithubPath -OcxHome $ocxHome
        if ($OcxInstallPrintPath) { Write-Output $installBinDir }
    }
    finally {
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
    }
}

Main -RequestedVersion $Version
