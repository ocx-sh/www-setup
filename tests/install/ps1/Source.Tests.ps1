#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }
# Static contract of src/install.ps1: the bytes `irm | iex` fetches and the
# header a reader (or a gate) looks at first.

BeforeAll {
    $script:InstallPs1 = Join-Path $PSScriptRoot '..\..\..\src\install.ps1'
}

Describe 'install.ps1 source' {
    It 'is pure ASCII with no BOM (served as text, read by Windows PowerShell 5.1)' {
        $bytes = [System.IO.File]::ReadAllBytes($InstallPs1)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }

    It 'declares its kind and exit table in the first eight lines' {
        $head = (Get-Content -LiteralPath $InstallPs1 -TotalCount 8) -join "`n"
        $head | Should -Match '(?m)^# Kind: INST'
        $head | Should -Match '(?m)^# Exit: 0 .*7'
    }

    It 'carries each embedded-config placeholder exactly once' {
        $text = [System.IO.File]::ReadAllText($InstallPs1)
        foreach ($t in 'OCX_INSTALL_DIST_URL', 'OCX_INSTALL_MIRROR_URL', 'OCX_INSTALL_CA_BUNDLE', 'OCX_MANAGED_CONFIG') {
            ([regex]::Matches($text, [regex]::Escape("@$t@"))).Count | Should -Be 1
        }
    }
}
