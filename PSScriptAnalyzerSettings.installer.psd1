@{
    # Installer kind: install.ps1 is a single-file script whose helpers are private, so the verb, noun and
    # ShouldProcess style rules do not apply. Write-Host is the installer's progress channel. Severity names
    # ParseError so an unparseable file fails (the gate wrapper exits 2 when it is omitted).
    Severity     = @('Error', 'Warning', 'ParseError')
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',
        'PSUseShouldProcessForStateChangingFunctions',
        'PSUseApprovedVerbs',
        'PSUseSingularNouns'
    )
    Rules        = @{
        PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1') }
    }
}
