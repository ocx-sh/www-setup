@{
    # Test kind: Pester files hold fixtures that assign without reading and build plain-text secrets on purpose.
    # Severity names ParseError so an unparseable file fails.
    Severity     = @('Error', 'Warning', 'ParseError')
    ExcludeRules = @(
        'PSUseShouldProcessForStateChangingFunctions',
        'PSUseApprovedVerbs',
        'PSUseSingularNouns',
        'PSUseBOMForUnicodeEncodedFile',
        'PSUseDeclaredVarsMoreThanAssignments',
        'PSAvoidUsingConvertToSecureStringWithPlainText'
    )
}
