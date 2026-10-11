# Test harness, not a product script: run an installer file against the fixture
# server, trusting its self-signed localhost certificate (see Trust-Fixture.ps1).
#
#   pwsh -NoProfile -File Run-Installer.ps1 <installer.ps1> [-Name value | -Switch]...
#
# Arguments are re-paired into a hashtable because a positional splat would hand
# '-Version' to the installer as a string, not as a parameter name.
. (Join-Path $PSScriptRoot 'Trust-Fixture.ps1')

$installer = [string]$args[0]
$named = @{}
$i = 1
while ($i -lt $args.Count) {
    $key = ([string]$args[$i]).TrimStart('-')
    if (($i + 1) -lt $args.Count -and -not ([string]$args[$i + 1]).StartsWith('-')) {
        $named[$key] = [string]$args[$i + 1]
        $i += 2
    }
    else {
        $named[$key] = $true
        $i += 1
    }
}
# Stop so a parameter-binding error (an unknown flag) ends this script with
# exit 1, exactly as `-File install.ps1 -BogusFlag` does.
$ErrorActionPreference = 'Stop'
$global:LASTEXITCODE = $null
& $installer @named
exit $LASTEXITCODE
