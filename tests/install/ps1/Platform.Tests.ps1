#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }
# Linux libc detection of src/install.ps1; mirrors the libc cases of
# ../env-knobs.bats and ../nu/install-nu.bats. The order is the ldd banner, musl
# loader files, glibc evidence, then exit 7. Get-LinuxLibc takes a root prefix
# (a function default, not a knob) so a fake tree stands in for the host. The
# whole-installer exit-7 path needs a host with no loader at all, which only
# tests/docker/ has, so these tests run the real functions cut out of the script.

BeforeAll {
    $installPs1 = Join-Path $PSScriptRoot '..\..\..\src\install.ps1'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($installPs1, [ref]$null, [ref]$null)
    $wanted = 'Say', 'Err', 'Get-LinuxLibc', 'Get-UnixTarget'
    $defs = $ast.FindAll({ param($n) ($n -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($n.Name -in $wanted) }, $true)
    foreach ($def in $defs) { . ([scriptblock]::Create($def.Extent.Text)) }

    $script:IsWin = $env:OS -eq 'Windows_NT'
    $script:SavedPath = $env:PATH

    # A PATH ldd that prints $Banner on stderr and exits 1, as musl's does (empty
    # $Banner = silent), ahead of whatever ldd the host has.
    function Use-FakeLdd {
        param([string]$Banner)
        $bin = Join-Path $TestDrive 'bin'
        New-Item -ItemType Directory -Path $bin -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $bin 'ldd.txt'), $Banner)
        if ($script:IsWin) {
            [System.IO.File]::WriteAllText((Join-Path $bin 'ldd.cmd'), "@type `"%~dp0ldd.txt`" 1>&2`r`n@exit /b 1`r`n")
        }
        else {
            $ldd = Join-Path $bin 'ldd'
            [System.IO.File]::WriteAllText($ldd, "#!/bin/sh`ncat `"`$(dirname `"`$0`")/ldd.txt`" >&2`nexit 1`n")
            [System.IO.File]::SetUnixFileMode($ldd, [System.IO.UnixFileMode]'UserRead,UserWrite,UserExecute')
        }
        $env:PATH = $bin + [System.IO.Path]::PathSeparator + $script:SavedPath
    }

    # A fake host tree holding the given relative files.
    function New-FakeRoot {
        param([string[]]$Files = @())
        $root = Join-Path $TestDrive "root-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        foreach ($f in $Files) {
            $path = Join-Path $root $f
            New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
            New-Item -ItemType File -Path $path -Force | Out-Null
        }
        return $root
    }
}

Describe 'install.ps1 Linux libc detection' {
    AfterEach {
        $env:PATH = $script:SavedPath
    }

    It 'a musl ldd banner selects musl' {
        Use-FakeLdd 'musl libc (x86_64)'
        Get-LinuxLibc -Root (New-FakeRoot) | Should -Be 'musl'
    }

    It 'a glibc ldd banner selects gnu even when a musl loader is present' -ForEach @(
        @{ Banner = 'ldd (Debian GLIBC 2.36-9+deb12u7) 2.36' }
        @{ Banner = 'ldd (GNU libc) 2.39' }
        @{ Banner = 'ldd (GNU C Library) 2.28' }
    ) {
        Use-FakeLdd $Banner
        Get-LinuxLibc -Root (New-FakeRoot @('lib/ld-musl-x86_64.so.1')) | Should -Be 'gnu'
    }

    It 'with no banner a musl loader file selects musl' {
        Use-FakeLdd ''
        Get-LinuxLibc -Root (New-FakeRoot @('lib/ld-musl-aarch64.so.1')) | Should -Be 'musl'
    }

    It 'with no banner /etc/alpine-release selects musl' {
        Use-FakeLdd ''
        Get-LinuxLibc -Root (New-FakeRoot @('etc/alpine-release')) | Should -Be 'musl'
    }

    It 'with no banner a glibc loader selects gnu' {
        Use-FakeLdd ''
        Get-LinuxLibc -Root (New-FakeRoot @('lib/x86_64-linux-gnu/ld-linux-x86-64.so.2')) | Should -Be 'gnu'
    }

    It 'no banner and no loader evidence is exit 7, not a guessed glibc' {
        Use-FakeLdd ''
        $root = New-FakeRoot
        $code = $null
        $libc = $null
        try { $libc = Get-LinuxLibc -Root $root } catch { $code = $_.Exception.Data['OcxExit'] }
        $libc | Should -BeNullOrEmpty
        $code | Should -Be 7
    }

    It 'Get-UnixTarget takes its libc from the ldd banner' -Skip:($env:OS -eq 'Windows_NT') {
        Use-FakeLdd 'musl libc (x86_64)'
        $onMac = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
            [System.Runtime.InteropServices.OSPlatform]::OSX)
        $expected = if ($onMac) { '-apple-darwin$' } else { '-unknown-linux-musl$' }
        Get-UnixTarget | Should -Match $expected
    }
}
