#requires -Version 7
#requires -Modules @{ModuleName='Pester';ModuleVersion='5.0'}
# Pester 5 tests for tools/testboot-make.ps1 with a fake adb. No phone, no network, no real magiskboot:
# the fake answers getprop/su/sha256sum and "pulls" prepared fixture files, so these tests prove the
# tool's decisions (what it refuses, what it writes, that it only reads the partition and cleans up).

BeforeAll {
    $script:Repo = Split-Path $PSScriptRoot -Parent
    $script:Script = Join-Path $Repo 'tools/testboot-make.ps1'
    . $script:Script

    $script:Banners = @{
        phone    = 'Linux version 5.4.302-qgki-unknown-e615f34c7 (runner@runnervmwhx2h) #1 SMP PREEMPT Tue Oct 27 20:08:50 UTC 2026'
        full     = 'Linux version 5.4.302-qgki-unknown-e615f34c7-dirty (thin@op9pro-thin) #1 SMP PREEMPT full'
        skipipvs = 'Linux version 5.4.302-qgki-unknown-e615f34c7-dirty (thin@op9pro-thin) #1 SMP PREEMPT skip'
    }

    $script:Work = Join-Path ([IO.Path]::GetTempPath()) "testboot-make-test-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $script:Work | Out-Null
    $script:AdbLog = Join-Path $script:Work 'adb.log'

    function script:Get-Sha256Hex([string]$Path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLower() }

    function script:New-KernelFile([string]$Path, [string]$Banner, [switch]$Gzip) {
        # leading junk with the printk format string, as in a real kernel, then the banner
        $bytes = [Text.Encoding]::Latin1.GetBytes("junk Linux version %s (%s) junk`0$Banner`n`0tail")
        if ($Gzip) {
            $ms = [IO.MemoryStream]::new()
            $gz = [IO.Compression.GZipStream]::new($ms, [IO.Compression.CompressionMode]::Compress, $true)
            $gz.Write($bytes, 0, $bytes.Length); $gz.Dispose()
            $bytes = $ms.ToArray()
        }
        [IO.File]::WriteAllBytes($Path, $bytes)
    }

    function script:New-BootFile([string]$Path, [int]$Size, [byte]$Fill) {
        $bytes = [byte[]]::new($Size)
        [Array]::Fill($bytes, $Fill)
        [Text.Encoding]::ASCII.GetBytes('ANDROID!').CopyTo($bytes, 0)
        [IO.File]::WriteAllBytes($Path, $bytes)
    }

    # A build directory shaped like output\thin-20261030 (full zip beside SHA256SUMS, skip-ipvs in a subfolder).
    function script:New-BuildTree([string]$Root) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        foreach ($spec in @(@{ Dir = $Root; Name = 'full'; Zip = 'VanillaKernel-thin-e615f34-1fadf98.zip' },
                @{ Dir = (Join-Path $Root 'skip-ipvs'); Name = 'skipipvs'; Zip = 'VanillaKernel-thin-skip-ipvs-e615f34-1fadf98.zip' })) {
            New-Item -ItemType Directory -Force -Path $spec.Dir | Out-Null
            $stage = Join-Path $spec.Dir 'stage'
            New-Item -ItemType Directory -Force -Path (Join-Path $stage 'tools') | Out-Null
            New-KernelFile (Join-Path $stage 'Image.gz') $script:Banners[$spec.Name] -Gzip
            [IO.File]::WriteAllText((Join-Path $stage 'tools/magiskboot'), 'fake magiskboot')
            $zip = Join-Path $spec.Dir $spec.Zip
            [IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip)
            $imageSha = Get-Sha256Hex (Join-Path $stage 'Image.gz')
            Remove-Item -Recurse -Force -LiteralPath $stage
            [IO.File]::WriteAllText((Join-Path $spec.Dir 'SHA256SUMS'),
                "$imageSha  Image.gz`n$(Get-Sha256Hex $zip)  ./$($spec.Zip)`n")
        }
    }

    # The files the fake adb "pulls": the phone's boot image, the kernels inside, the two repacked images.
    function script:New-Fixtures([string]$Dir) {
        New-Item -ItemType Directory -Force -Path $Dir | Out-Null
        New-BootFile (Join-Path $Dir 'boot-cur.img') 4000 1
        New-KernelFile (Join-Path $Dir 'kernel-cur') $script:Banners.phone
        New-BootFile (Join-Path $Dir 'testboot-full.img') 3900 2
        New-BootFile (Join-Path $Dir 'testboot-skipipvs.img') 3900 3
        New-KernelFile (Join-Path $Dir 'kernel-chk-full') $script:Banners.full
        New-KernelFile (Join-Path $Dir 'kernel-chk-skipipvs') $script:Banners.skipipvs
    }

    # Fake adb: logs its arguments (minus -s <serial>, which it checks), answers like a 9 Pro.
    $script:FakeAdb = Join-Path $script:Work 'adb.ps1'
    Set-Content -Path $script:FakeAdb -Value @'
$a = @($args)
if ($a.Count -lt 3 -or $a[0] -ne '-s' -or $a[1] -ne $env:FAKE_ADB_SERIAL) {
    Add-Content -Path $env:FAKE_ADB_LOG -Value "BAD-CALL: $($a -join ' ')"
    exit 9
}
$rest = $a[2..($a.Count - 1)]
Add-Content -Path $env:FAKE_ADB_LOG -Value ($rest -join ' ')
$fix = $env:FAKE_ADB_FIX
function Sha($p) { (Get-FileHash -Algorithm SHA256 -LiteralPath $p).Hash.ToLower() }
if ($rest[0] -eq 'pull') {
    $remote = $rest[1]
    $leaf = $remote.Split('/')[-1]
    $name = if ($leaf -eq 'kernel') { 'kernel-' + $remote.Split('/')[-2] } else { $leaf }
    $src = Join-Path $fix $name
    if ($env:FAKE_ADB_CORRUPT_PULL -eq $leaf) {
        $bytes = [IO.File]::ReadAllBytes($src); $bytes[100] = $bytes[100] -bxor 255
        [IO.File]::WriteAllBytes($rest[2], $bytes)
    } else { Copy-Item -LiteralPath $src -Destination $rest[2] }
    exit 0
}
if ($rest[0] -eq 'shell') {
    $cmd = ($rest[1..($rest.Count - 1)]) -join ' '
    switch -Regex ($cmd) {
        '^getprop ro\.product\.device$' { $env:FAKE_ADB_DEVICE; exit 0 }
        '^getprop ro\.boot\.slot_suffix$' { $env:FAKE_ADB_SLOT; exit 0 }
        '^cat /proc/version$' { $env:FAKE_ADB_VERSION; exit 0 }
        "^su -c 'id -u'$" { $env:FAKE_ADB_UID; exit 0 }
        '^su -c .*magiskboot 2>&1 \| head' { $env:FAKE_ADB_MAGISK; exit 0 }
        '^su -c .sha256sum (\S+)' {
            $p = $Matches[1].TrimEnd("'")
            "$(Sha (Join-Path $fix $p.Split('/')[-1]))  $p"; exit 0
        }
    }
}
exit 0
'@

    function script:Reset-Fake {
        $env:FAKE_ADB_LOG = $script:AdbLog
        $env:FAKE_ADB_SERIAL = '5d7a3c0'
        $env:FAKE_ADB_DEVICE = 'lemonadep'
        $env:FAKE_ADB_SLOT = '_a'
        $env:FAKE_ADB_UID = '0'
        $env:FAKE_ADB_VERSION = $script:Banners.phone
        $env:FAKE_ADB_MAGISK = 'MagiskBoot - Boot Image Modification Tool'
        $env:FAKE_ADB_CORRUPT_PULL = ''
        $env:FAKE_ADB_FIX = $script:Fix
        Remove-Item -Force -LiteralPath $script:AdbLog -ErrorAction SilentlyContinue
    }

    # Runs the tool; returns output text and the error (if any).
    function script:Invoke-Make {
        param([bool]$Execute = $true, [string]$Zip = $script:Full)
        $err = $null
        $out = try {
            Invoke-TestbootMake -Serial '5d7a3c0' -Execute $Execute -AdbPath $script:FakeAdb -FullZip $Zip `
                -SkipIpvsZip $script:Skip -OutDir $script:Out -MagiskbootPath $null 6>&1 | Out-String
        } catch { $err = $_.Exception.Message; '' }
        [pscustomobject]@{ Output = $out; Error = $err }
    }

    function script:Get-AdbLog { if (Test-Path $script:AdbLog) { Get-Content $script:AdbLog } else { @() } }
}

AfterAll {
    foreach ($v in 'FAKE_ADB_LOG', 'FAKE_ADB_SERIAL', 'FAKE_ADB_DEVICE', 'FAKE_ADB_SLOT', 'FAKE_ADB_UID', 'FAKE_ADB_VERSION',
        'FAKE_ADB_MAGISK', 'FAKE_ADB_CORRUPT_PULL', 'FAKE_ADB_FIX') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
    Remove-Item -Recurse -Force -LiteralPath $script:Work -ErrorAction SilentlyContinue
}

Describe 'testboot-make.ps1' {
    BeforeEach {
        $script:Case = Join-Path $script:Work "case-$([guid]::NewGuid().ToString('N'))"
        $script:Build = Join-Path $script:Case 'thin'
        $script:Fix = Join-Path $script:Case 'fix'
        $script:Out = Join-Path $script:Build 'testboot'
        $script:Full = Join-Path $script:Build 'VanillaKernel-thin-e615f34-1fadf98.zip'
        $script:Skip = Join-Path $script:Build 'skip-ipvs/VanillaKernel-thin-skip-ipvs-e615f34-1fadf98.zip'
        New-BuildTree $script:Build
        New-Fixtures $script:Fix
        Reset-Fake
    }

    Context 'dry run (the default)' {
        It 'checks the local inputs, prints the plan, and calls neither adb nor writes anything' {
            $r = Invoke-Make -Execute $false
            $r.Error | Should -BeNullOrEmpty
            $r.Output | Should -Match 'DRY RUN'
            $r.Output | Should -Match 'build full'
            $r.Output | Should -Match 'build skipipvs'
            $r.Output | Should -Match 'thin@op9pro-thin'
            Get-AdbLog | Should -BeNullOrEmpty
            Test-Path $script:Out | Should -BeFalse
        }

        It 'refuses a zip whose sha256 is not in the SHA256SUMS beside it' {
            [IO.File]::AppendAllText($script:Full, 'tamper')
            $r = Invoke-Make -Execute $false
            $r.Error | Should -Match 'is not the one in'
        }

        It 'refuses when the SHA256SUMS file is missing' {
            Remove-Item (Join-Path $script:Build 'SHA256SUMS')
            (Invoke-Make -Execute $false).Error | Should -Match 'no SHA256SUMS'
        }
    }

    Context 'execute' {
        It 'writes the backup, both images and SHA256SUMS, with matching hashes' {
            $r = Invoke-Make
            $r.Error | Should -BeNullOrEmpty
            $curSha = Get-Sha256Hex (Join-Path $script:Fix 'boot-cur.img')
            $backup = Join-Path $script:Out "boot_a-backup-$($curSha.Substring(0, 8)).img"
            Test-Path $backup | Should -BeTrue
            Get-Sha256Hex $backup | Should -Be $curSha
            foreach ($n in 'full', 'skipipvs') {
                Get-Sha256Hex (Join-Path $script:Out "testboot-$n.img") | Should -Be (Get-Sha256Hex (Join-Path $script:Fix "testboot-$n.img"))
            }
            $sums = Get-Content (Join-Path $script:Out 'SHA256SUMS')
            $sums.Count | Should -Be 3
            foreach ($line in $sums) {
                $line -match '^([0-9a-f]{64})  (\S+)$' | Should -BeTrue
                Get-Sha256Hex (Join-Path $script:Out $Matches[2]) | Should -Be $Matches[1]
            }
            $r.Output | Should -Match 'fastboot flash boot_a'
        }

        It 'talks to the phone only with -s <serial>, never writes a partition, and removes its temp folder last' {
            (Invoke-Make).Error | Should -BeNullOrEmpty
            $log = Get-AdbLog
            $log.Count | Should -BeGreaterThan 10
            ($log -join "`n") | Should -Not -Match 'BAD-CALL'
            ($log -join "`n") | Should -Not -Match 'of=/dev'
            ($log -join "`n") | Should -Not -Match 'fastboot|flash|reboot'
            ($log | Where-Object { $_ -match 'dd if=' }) | Should -Match 'if=/dev/block/by-name/boot_a of=/data/local/tmp/testboot-make/boot-cur\.img'
            $log[-1] | Should -Be "shell su -c 'rm -rf /data/local/tmp/testboot-make'"
        }

        It 'reads the slot from the phone (boot_b when b is active)' {
            $env:FAKE_ADB_SLOT = '_b'
            (Invoke-Make).Error | Should -BeNullOrEmpty
            (Get-AdbLog | Where-Object { $_ -match 'dd if=' }) | Should -Match 'by-name/boot_b'
            @(Get-ChildItem $script:Out -Filter 'boot_b-backup-*.img').Count | Should -Be 1
        }

        It 'keeps an existing backup and succeeds a second time' {
            (Invoke-Make).Error | Should -BeNullOrEmpty
            $backup = Get-ChildItem $script:Out -Filter 'boot_a-backup-*.img'
            $stamp = $backup.LastWriteTimeUtc
            Start-Sleep -Milliseconds 50
            (Invoke-Make).Error | Should -BeNullOrEmpty
            @(Get-ChildItem $script:Out -Filter 'boot_a-backup-*.img').Count | Should -Be 1
            (Get-Item $backup.FullName).LastWriteTimeUtc | Should -Be $stamp
        }

        It 'refuses a OnePlus 8T before reading anything' {
            $env:FAKE_ADB_DEVICE = 'kebab'
            (Invoke-Make).Error | Should -Match 'not a OnePlus 9 Pro'
            ((Get-AdbLog) -join "`n") | Should -Not -Match 'dd if='
            Test-Path $script:Out | Should -BeFalse
        }

        It 'refuses without root' {
            $env:FAKE_ADB_UID = '2000'
            (Invoke-Make).Error | Should -Match 'no root'
            ((Get-AdbLog) -join "`n") | Should -Not -Match 'dd if='
        }

        It 'refuses an unknown slot' {
            $env:FAKE_ADB_SLOT = ''
            (Invoke-Make).Error | Should -Match 'slot_suffix'
        }

        It 'refuses when the dumped kernel is not the running one, and cleans up' {
            New-KernelFile (Join-Path $script:Fix 'kernel-cur') 'Linux version 5.4.1-someone-else (x@y) #1'
            (Invoke-Make).Error | Should -Match 'different kernel than the one running'
            Test-Path $script:Out | Should -BeFalse
            (Get-AdbLog)[-1] | Should -Be "shell su -c 'rm -rf /data/local/tmp/testboot-make'"
        }

        It 'accepts a gzip-compressed kernel inside the dump' {
            New-KernelFile (Join-Path $script:Fix 'kernel-cur') $script:Banners.phone -Gzip
            (Invoke-Make).Error | Should -BeNullOrEmpty
        }

        It 'refuses a repack whose kernel is not the build''s' {
            New-KernelFile (Join-Path $script:Fix 'kernel-chk-full') $script:Banners.phone
            (Invoke-Make).Error | Should -Match 'testboot-full.img carries the wrong kernel'
            Test-Path $script:Out | Should -BeFalse
        }

        It 'refuses a dump that is not an Android boot image' {
            [IO.File]::WriteAllBytes((Join-Path $script:Fix 'boot-cur.img'), [byte[]](1..64))
            (Invoke-Make).Error | Should -Match 'not an Android boot image'
        }

        It 'refuses a pull that differs from what the phone hashed' {
            $env:FAKE_ADB_CORRUPT_PULL = 'boot-cur.img'
            (Invoke-Make).Error | Should -Match 'differs after the pull'
            Test-Path $script:Out | Should -BeFalse
        }

        It 'refuses a repacked image larger than the partition dump' {
            New-BootFile (Join-Path $script:Fix 'testboot-full.img') 5000 2
            (Invoke-Make).Error | Should -Match 'larger than the partition dump'
        }

        It 'stops with a clear message when magiskboot does not run on the phone, and cleans up' {
            $env:FAKE_ADB_MAGISK = '/data/local/tmp/testboot-make/magiskboot: Exec format error'
            (Invoke-Make).Error | Should -Match 'magiskboot does not run on the phone'
            (Get-AdbLog) | Should -Not -Match 'dd if='
            (Get-AdbLog)[-1] | Should -Be "shell su -c 'rm -rf /data/local/tmp/testboot-make'"
        }
    }

    Context 'the script file itself' {
        It 'has no PSScriptAnalyzer findings' -Skip:(-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
            @(Invoke-ScriptAnalyzer -Path $script:Script -Severity Warning, Error) | Should -BeNullOrEmpty
        }
    }
}
