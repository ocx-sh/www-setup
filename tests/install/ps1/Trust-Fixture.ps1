# Test harness, not a product script: dot-source to make this PowerShell process
# accept the fixture server's self-signed localhost certificate (install.ps1
# refuses plain http, so the fixture speaks TLS). Only the certificate check is
# relaxed; the installer's own code is untouched.
Add-Type -TypeDefinition @'
public static class OcxFixtureTrust {
    public static bool Any(object sender, System.Security.Cryptography.X509Certificates.X509Certificate cert,
        System.Security.Cryptography.X509Certificates.X509Chain chain, System.Net.Security.SslPolicyErrors errors) {
        return true;
    }
}
'@
[Net.ServicePointManager]::ServerCertificateValidationCallback = [Delegate]::CreateDelegate(
    [Net.Security.RemoteCertificateValidationCallback], [OcxFixtureTrust].GetMethod('Any'))

# PowerShell 7 Invoke-WebRequest ignores ServicePointManager; it has its own switch.
if ($PSVersionTable.PSEdition -eq 'Core') {
    function Invoke-WebRequest {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Test harness: adds only the fixture certificate switch.')]
        param()
        Microsoft.PowerShell.Utility\Invoke-WebRequest @args -SkipCertificateCheck
    }
}
