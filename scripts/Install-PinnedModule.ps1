#Requires -Version 5.1
<#
Install-PinnedModule.ps1 -Name NAME -Version X.Y.Z
Install one PowerShell module at an exact version for the current user, and do nothing when that version is already present.
A floating install lets CI and a laptop run different analyzer or Pester majors. Exit 0 present or installed, 1 install failed.
ASCII only, 5.1 syntax.
#>
param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Version
)
$ErrorActionPreference = 'Stop'
try {
    $have = @(Get-Module -ListAvailable -Name $Name | Where-Object { $_.Version -eq [version]$Version })
    if ($have.Count -eq 0) {
        Install-Module -Name $Name -RequiredVersion $Version -Scope CurrentUser -Force -Repository PSGallery -SkipPublisherCheck
    }
} catch {
    [Console]::Error.WriteLine("install-pinned-module: $Name $Version : $($_.Exception.Message)")
    exit 1
}
exit 0
