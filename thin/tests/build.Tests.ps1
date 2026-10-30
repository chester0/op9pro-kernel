#requires -Modules @{ModuleName='Pester';ModuleVersion='5.0'}
<#
.SYNOPSIS
    Pester tests for thin/build.sh: it must refuse any input whose pin (sha256 or commit) is wrong.
.DESCRIPTION
    Runs build.sh inside WSL Ubuntu against an offline fixture (thin/tests/make-fixture.sh): a tiny
    clang-like tarball and a one-commit git repo. No network, no kernel, no container.
    Run:  Invoke-Pester -Path thin/tests/build.Tests.ps1
#>

BeforeDiscovery {
    $script:WslAvailable = [bool](Get-Command wsl -ErrorAction SilentlyContinue)
}

BeforeAll {
    function ConvertTo-WslPath([string]$Path) {
        # wslpath eats backslashes passed through wsl.exe, so hand it forward slashes.
        $full = [System.IO.Path]::GetFullPath($Path) -replace '\\', '/'
        (& wsl -d Ubuntu -- wslpath -a $full).Trim()
    }

    # Runs build.sh <subcommand> in WSL with the named pins file; returns exit code and merged output.
    function Invoke-Build([string]$Pins, [string]$Command) {
        $out = & wsl -d Ubuntu -- env "PINS_FILE=$script:Fx/$Pins.pins" "THIN_HOME=$script:Fx/home" `
            bash $script:BuildSh $Command 2>&1
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out | Out-String) }
    }

    $script:BuildSh = ConvertTo-WslPath (Join-Path $PSScriptRoot '..\build.sh')
    $fixtureScript = ConvertTo-WslPath (Join-Path $PSScriptRoot 'make-fixture.sh')
    $script:Fx = "/tmp/thin-build-test-$PID"
    & wsl -d Ubuntu -- bash $fixtureScript $script:Fx
    if ($LASTEXITCODE -ne 0) { throw 'fixture creation failed' }
}

AfterAll {
    # One literal fixture folder under /tmp, created by this test run.
    & wsl -d Ubuntu -- rm -rf "/tmp/thin-build-test-$PID"
}

Describe 'thin/build.sh pin checks' -Skip:(-not $script:WslAvailable) {
    It 'accepts a download whose sha256 matches the pin (positive control)' {
        $r = Invoke-Build 'good' 'fetch-clang'
        $r.ExitCode | Should -Be 0 -Because $r.Output
    }

    It 'refuses a toolchain whose tree digest is not the pin, and keeps nothing' {
        $r = Invoke-Build 'bad-clang' 'fetch-clang'
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -Match 'sha256 mismatch'
        $left = & wsl -d Ubuntu -- find "$script:Fx/home/cache" -name '*000000000000*'
        $left | Should -BeNullOrEmpty
    }

    It 'refuses a downloaded file whose sha256 is not the pin, and keeps nothing' {
        $r = Invoke-Build 'bad-file' 'fetch-checkconfig'
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -Match 'sha256 mismatch'
        $left = & wsl -d Ubuntu -- find "$script:Fx/home/cache" -name 'check-config.sh*'
        $left | Should -BeNullOrEmpty
    }

    It 'refuses a kernel commit pin that does not exist' {
        $r = Invoke-Build 'bad-kernel' 'fetch-kernel'
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -Match 'cannot fetch pinned commit'
    }

    It 'refuses a VanillaSU pin that differs from the gitlink the kernel records' {
        $r = Invoke-Build 'bad-gitlink' 'fetch-kernel'
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -Match 'records VanillaSU'
    }
}
