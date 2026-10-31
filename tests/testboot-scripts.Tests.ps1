#requires -Version 7
#requires -Modules @{ModuleName='Pester';ModuleVersion='5.0'}
# Pester 5 tests for tools/testboot-{lib,baseline,check}.sh: shellcheck (-s sh) on each, and their logic
# under Git's bash with stubbed lsmod/dmesg/ip/ps/zcat/getprop (no phone).

BeforeDiscovery {
    $repo = Split-Path $PSScriptRoot -Parent
    $script:ShellScripts = Get-ChildItem (Join-Path $repo 'tools') -Filter 'testboot-*.sh' |
        ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
}

BeforeAll {
    $script:Tools = Join-Path (Split-Path $PSScriptRoot -Parent) 'tools'
    $script:OursBanner = 'Linux version 5.4.302-qgki-unknown-e615f34c7-ge615f34c7dcb-dirty (thin@op9pro-thin) #1 SMP'
    $script:TheirBanner = 'Linux version 5.4.302-qgki-unknown-e615f34c7-ge615f34c7dcb (runner@runnervmwhx2h) #1 SMP'
    $script:Modules = @('cfg80211', 'wlan', 'snd_soc_core')
    # `ps -A -o NAME` output: process names only (the USER column of a full ps would also say audioserver)
    $script:DefaultPs = @('init', 'audioserver', 'android.hardware.audio.service_64')
    $script:NoAudioPs = @('init', 'zygote64')

    # Git-bash path: C:\x\y -> /c/x/y (a "C:/x" would be split at the colon inside PATH).
    function script:ToSh([string]$p) {
        ($p -replace '\\', '/') -replace '^([A-Za-z]):', { '/' + $_.Groups[1].Value.ToLower() }
    }
    function script:Write-Lf([string]$Path, [string]$Text) {
        # a trailing newline, like every real command output (wc -l counts newlines)
        $body = ($Text -replace "`r`n", "`n")
        if ($body -and -not $body.EndsWith("`n")) { $body += "`n" }
        [IO.File]::WriteAllText($Path, $body)
    }
    function script:Write-Stub([string]$Dir, [string]$Name, [string]$Body) {
        Write-Lf (Join-Path $Dir $Name) "#!/bin/sh`n$Body`n"
    }

    # The option list the script checks, read from the script itself.
    function script:Get-RequiredOptions {
        $lib = ToSh (Join-Path $script:Tools 'testboot-lib.sh')
        (& bash -c ". $lib; echo `$DOCKER_REQUIRED_OPTIONS") -split '\s+' | Where-Object { $_ }
    }
    function script:New-ConfigText([string[]]$Without = @(), [switch]$IpVs) {
        $lines = Get-RequiredOptions | Where-Object { $_ -notin $Without } | ForEach-Object { "CONFIG_$_=y" }
        if ($IpVs) { $lines += 'CONFIG_IP_VS=y'; $lines += 'CONFIG_NETFILTER_XT_MATCH_IPVS=y' }
        $lines -join "`n"
    }

    # A fake phone: stub binaries plus the state files they print. Returns the directory.
    function script:New-FakePhone {
        param(
            [string]$Banner = $script:OursBanner, [string[]]$Modules = $script:Modules,
            [string[]]$Dmesg = @(), [bool]$Wifi = $true, [string[]]$Ps = $script:DefaultPs,
            [string]$Config = (New-ConfigText), [bool]$Ksud = $true, [string]$Release = '5.4.302-qgki'
        )
        $dir = Join-Path ([IO.Path]::GetTempPath()) "testboot-sh-$([guid]::NewGuid().ToString('N'))"
        $bin = Join-Path $dir 'bin'
        New-Item -ItemType Directory -Path $bin | Out-Null
        Write-Stub $bin 'id' 'echo "${FAKE_UID:-0}"'
        Write-Stub $bin 'uname' 'echo "$FAKE_RELEASE"'
        Write-Stub $bin 'getprop' 'echo 1'
        Write-Stub $bin 'sleep' 'exit 0'
        Write-Stub $bin 'lsmod' 'echo "Module Size Used by"; cat "$FAKE_DIR/lsmod"'
        Write-Stub $bin 'dmesg' 'cat "$FAKE_DIR/dmesg"'
        Write-Stub $bin 'ps' 'cat "$FAKE_DIR/ps"'
        Write-Stub $bin 'ip' '[ "$FAKE_WIFI" = 1 ] && echo "    inet 192.0.2.7/24 brd 192.0.2.255 scope global wlan0"; exit 0'
        Write-Stub $bin 'cmd' '[ "$FAKE_WIFI" = 1 ] && echo "Wifi is connected to \"home\""; exit 0'
        Write-Stub $bin 'dumpsys' 'exit 0'
        Write-Stub $bin 'zcat' '[ -r "$1" ] && cat "$1"'
        Write-Lf (Join-Path $dir 'lsmod') (($Modules | ForEach-Object { "$_ 1000 0" }) -join "`n")
        Write-Lf (Join-Path $dir 'dmesg') ($Dmesg -join "`n")
        Write-Lf (Join-Path $dir 'ps') ($Ps -join "`n")
        Write-Lf (Join-Path $dir 'version') $Banner
        if ($Config) { Write-Lf (Join-Path $dir 'config') $Config }
        Write-Stub $dir 'ksud' 'exit 0'
        if (-not $Ksud) { Remove-Item -LiteralPath (Join-Path $dir 'ksud') }
        $env:FAKE_RELEASE = $Release
        $env:FAKE_WIFI = if ($Wifi) { '1' } else { '0' }
        $dir
    }

    # Runs a script under bash with the stubs first on PATH.
    function script:Invoke-Phone {
        param([string]$Dir, [string]$Script, [string[]]$Arguments = @(), [string]$Uid = '0', [string]$ExpectIpVs = '')
        $d = ToSh $Dir
        $env:FAKE_DIR = $d
        $env:FAKE_UID = $Uid
        $env:PROC_VERSION = "$d/version"
        $env:PROC_CONFIG = "$d/config"
        $env:KSUD_PATH = "$d/ksud"
        $env:TMPDIR = $d
        $env:BOOT_WAIT = '0'
        $env:WIFI_WAIT = '0'
        if ($ExpectIpVs) { $env:EXPECT_IPVS = $ExpectIpVs } else { Remove-Item Env:EXPECT_IPVS -ErrorAction SilentlyContinue }
        $path = ToSh (Join-Path $script:Tools $Script)
        $out = & bash -c "PATH='$d/bin':`"`$PATH`" exec bash '$path' `"`$@`"" -- @Arguments 2>&1 | Out-String
        [pscustomobject]@{ Output = $out; Code = $LASTEXITCODE }
    }

    # Baseline from a healthy phone (the installed kernel: not ours, ordinary modules) into a fresh folder;
    # returns the folder. /data survives the test boot, so the same folder serves the later check.
    function script:New-Baseline {
        $dir = New-FakePhone -Banner $script:TheirBanner
        $base = Join-Path ([IO.Path]::GetTempPath()) "testboot-base-$([guid]::NewGuid().ToString('N'))"
        $result = Invoke-Phone $dir 'testboot-baseline.sh' @((ToSh $base))
        $result.Code | Should -Be 0 -Because $result.Output
        Remove-Item -Recurse -Force -LiteralPath $dir
        $base
    }

    # The check on a phone built from $Phone (New-FakePhone parameters) against the baseline folder.
    function script:Invoke-Check {
        param([string]$Base, [hashtable]$Phone = @{}, [string]$ExpectIpVs = '')
        $dir = New-FakePhone @Phone
        try { Invoke-Phone $dir 'testboot-check.sh' @((ToSh $Base)) -ExpectIpVs $ExpectIpVs }
        finally { Remove-Item -Recurse -Force -LiteralPath $dir }
    }
}

AfterAll {
    foreach ($v in 'FAKE_DIR', 'FAKE_UID', 'FAKE_RELEASE', 'FAKE_WIFI', 'PROC_VERSION', 'PROC_CONFIG', 'KSUD_PATH',
        'TMPDIR', 'BOOT_WAIT', 'WIFI_WAIT', 'EXPECT_IPVS') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
}

Describe 'shellcheck' {
    It '<Name> passes shellcheck -s sh' -ForEach $script:ShellScripts {
        $result = & shellcheck -s sh $Path 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $result
    }
}

Describe 'testboot-baseline.sh' {
    AfterEach { Remove-Item -Recurse -Force -LiteralPath $script:Base -ErrorAction SilentlyContinue }

    It 'writes the facts, the module list and the dmesg lines, and changes nothing else' {
        $script:Base = New-Baseline
        $facts = Get-Content -Raw (Join-Path $script:Base 'baseline.txt')
        $facts | Should -Match 'kernel_release=5.4.302-qgki'
        $facts | Should -Match 'lsmod_count=3'
        $facts | Should -Match 'modload_errors=0'
        $facts | Should -Match 'wifi=associated'
        $facts | Should -Match 'audioserver_procs=1'
        $facts | Should -Match 'audio_hal_procs=1'
        $facts | Should -Match 'root_uid=0'
        $facts | Should -Match 'ksud=present'
        $facts | Should -Match 'ip_vs=no'
        (Get-Content (Join-Path $script:Base 'lsmod.txt')) | Should -Be @('cfg80211', 'snd_soc_core', 'wlan')
    }

    It 'counts the module-refusal lines in dmesg' {
        $dir = New-FakePhone -Dmesg @('wlan: disagrees about version of symbol __alloc_skb', 'x: Unknown symbol foo (err -22)', 'ordinary line')
        $script:Base = Join-Path ([IO.Path]::GetTempPath()) "testboot-base-$([guid]::NewGuid().ToString('N'))"
        try { $r = Invoke-Phone $dir 'testboot-baseline.sh' @((ToSh $script:Base)) } finally { Remove-Item -Recurse -Force -LiteralPath $dir }
        $r.Code | Should -Be 0 -Because $r.Output
        (Get-Content -Raw (Join-Path $script:Base 'baseline.txt')) | Should -Match 'modload_errors=2'
    }

    It 'warns when no audio HAL process matched, and refuses without root' {
        $dir = New-FakePhone -Ps $script:NoAudioPs
        $script:Base = Join-Path ([IO.Path]::GetTempPath()) "testboot-base-$([guid]::NewGuid().ToString('N'))"
        try {
            $r = Invoke-Phone $dir 'testboot-baseline.sh' @((ToSh $script:Base))
            $r.Output | Should -Match 'WARNING: no audio HAL'
            $nonroot = Invoke-Phone $dir 'testboot-baseline.sh' @((ToSh $script:Base)) -Uid '2000'
            $nonroot.Code | Should -Not -Be 0
            $nonroot.Output | Should -Match 'must run as root'
        } finally { Remove-Item -Recurse -Force -LiteralPath $dir }
    }
}

Describe 'testboot-check.sh' {
    BeforeAll { $script:Base = New-Baseline }
    AfterAll { Remove-Item -Recurse -Force -LiteralPath $script:Base -ErrorAction SilentlyContinue }

    It 'passes every line when the new kernel is ours and nothing regressed' {
        $r = Invoke-Check $script:Base
        $r.Code | Should -Be 0 -Because $r.Output
        $r.Output | Should -Match 'RESULT: PASS'
        $r.Output | Should -Not -Match 'FAIL:'
        foreach ($name in 'kernel banner is ours', 'lsmod count', 'module-load errors', 'Wi-Fi associated',
            'audio HAL running', 'KernelSU root', 'Docker check-config') {
            $r.Output | Should -Match "PASS: $name"
        }
    }

    It 'fails when the banner is still the maintainer''s build' {
        $r = Invoke-Check $script:Base @{ Banner = $script:TheirBanner }
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'FAIL: kernel banner is ours'
    }

    It 'fails when the banner has the marker but equals the baseline''s (nothing was swapped)' {
        $same = New-Baseline
        try {
            Set-Content -NoNewline (Join-Path $same 'baseline.txt') -Value ("kernel_banner=$script:OursBanner`nlsmod_count=3`n")
            $r = Invoke-Check $same
            $r.Output | Should -Match 'FAIL: kernel banner is ours'
        } finally { Remove-Item -Recurse -Force -LiteralPath $same }
    }

    It 'fails and names the modules that did not load when lsmod shrinks' {
        $r = Invoke-Check $script:Base @{ Modules = @('cfg80211', 'snd_soc_core') }
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'FAIL: lsmod count: 2 loaded, baseline 3'
        $r.Output | Should -Match 'INFO: modules in the baseline but not loaded now: wlan'
    }

    It 'fails on a MODVERSIONS refusal in dmesg and shows the line' {
        $r = Invoke-Check $script:Base @{ Dmesg = @('wlan: disagrees about version of symbol __alloc_skb') }
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'FAIL: module-load errors: 1'
        $r.Output | Should -Match 'INFO: dmesg: wlan: disagrees about version'
    }

    It 'fails on an Unknown symbol line (case-insensitive)' {
        $r = Invoke-Check $script:Base @{ Dmesg = @('snd: unknown symbol cfg80211_foo (err -2)') }
        $r.Output | Should -Match 'FAIL: module-load errors: 1'
    }

    It 'fails when Wi-Fi is not associated' {
        $r = Invoke-Check $script:Base @{ Wifi = $false }
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'FAIL: Wi-Fi associated'
    }

    It 'fails when the audio HAL is gone' {
        $r = Invoke-Check $script:Base @{ Ps = $script:NoAudioPs }
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'FAIL: audio HAL running'
    }

    It 'fails without ksud (root manager missing) although the baseline had it' {
        $r = Invoke-Check $script:Base @{ Ksud = $false }
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'FAIL: KernelSU root'
    }

    It 'fails and names the Docker option the kernel lacks' {
        $r = Invoke-Check $script:Base @{ Config = (New-ConfigText -Without 'IP6_NF_NAT', 'BRIDGE_NETFILTER') }
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'FAIL: Docker check-config: .*IP6_NF_NAT.*BRIDGE_NETFILTER.* missing|FAIL: Docker check-config: .*BRIDGE_NETFILTER.*IP6_NF_NAT.* missing'
    }

    It 'fails when the kernel config cannot be read' {
        $r = Invoke-Check $script:Base @{ Config = '' }
        $r.Output | Should -Match 'FAIL: Docker check-config: .* unreadable'
    }

    It 'requires CONFIG_IP_VS for the full build and forbids it for skip-ipvs' {
        (Invoke-Check $script:Base @{} -ExpectIpVs 'yes').Output | Should -Match 'FAIL: IP_VS matches the build under test: expected yes, found no'
        (Invoke-Check $script:Base @{ Config = (New-ConfigText -IpVs) } -ExpectIpVs 'yes').Output | Should -Match 'PASS: IP_VS matches'
        (Invoke-Check $script:Base @{ Config = (New-ConfigText -IpVs) } -ExpectIpVs 'no').Output | Should -Match 'FAIL: IP_VS matches the build under test: expected no, found yes'
        (Invoke-Check $script:Base @{} -ExpectIpVs 'no').Output | Should -Match 'PASS: IP_VS matches'
    }

    It 'only reports IP_VS when no expectation is given' {
        $r = Invoke-Check $script:Base @{ Config = (New-ConfigText -IpVs) }
        $r.Code | Should -Be 0 -Because $r.Output
        $r.Output | Should -Match 'INFO: CONFIG_IP_VS=yes'
    }

    It 'fails when there is no baseline, instead of passing against nothing' {
        $r = Invoke-Check (Join-Path ([IO.Path]::GetTempPath()) 'testboot-no-such-baseline') @{}
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'FAIL: baseline'
    }

    It 'refuses to run without root' {
        $dir = New-FakePhone
        try { $r = Invoke-Phone $dir 'testboot-check.sh' @((ToSh $script:Base)) -Uid '2000' } finally { Remove-Item -Recurse -Force -LiteralPath $dir }
        $r.Code | Should -Not -Be 0
        $r.Output | Should -Match 'must run as root'
    }
}
