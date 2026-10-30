#requires -Version 7
<#
.SYNOPSIS
  Builds the two test-boot images (testboot-full.img, testboot-skipipvs.img) for the OnePlus 9 Pro from the
  phone's CURRENT boot partition and each thin build's Image.gz, and keeps a backup of the current image.
  Runs on the Evo; the phone is only read, and its temp files are removed.

.DESCRIPTION
  DRY RUN by default: checks the local inputs (zips, SHA256SUMS, Image.gz kernel banners), prints the plan,
  and does not call adb at all. -Execute does it:

    1. adb -s <Serial>: refuses anything that is not a lemonadep; reads the active slot (ro.boot.slot_suffix),
       the running kernel's /proc/version, and checks root (su).
    2. root dd reads /dev/block/by-name/boot<slot> into /data/local/tmp/testboot-make (a READ of the partition;
       nothing is ever written to it), adb pull, sha256 compared on both sides.
    3. magiskboot (the AnyKernel3 zip ships it) runs ON the phone: unpacks the dump, and the kernel inside must
       carry the same "Linux version ..." banner as the running kernel. If not, the dump is not today's kernel
       and the tool stops.
    4. For each build: unpack, swap in the build's Image.gz (decompressed; repack recompresses it the way the
       original was), repack, pull; unpack the result again and require that its kernel banner is the build's
       banner (and not today's).
    5. Writes everything under OutDir: the backup boot<slot>-backup-<sha8>.img (never deleted or overwritten),
       testboot-full.img, testboot-skipipvs.img and SHA256SUMS, then removes the phone's temp folder.

  Nothing here flashes or boots anything: the images are for `fastboot boot` (thin/TESTBOOT.md).
  Both thin builds carry the same kernel banner ("thin@op9pro-thin", -dirty); their images differ in the
  kernel bytes, so the sha256 is what tells them apart.

.PARAMETER Serial
  adb serial of the phone. The 9 Pro is 5d7a3c0.

.PARAMETER Execute
  Really talk to the phone and write the images. Without it: dry run.

.PARAMETER MagiskbootPath
  Use this magiskboot (an arm binary that runs on the phone) instead of the one in the full build's zip.

.EXAMPLE
  pwsh tools/testboot-make.ps1                 # dry run
  pwsh tools/testboot-make.ps1 -Execute        # pull, repack, verify
#>
[CmdletBinding()]
param(
    [string]$Serial = '5d7a3c0',
    [switch]$Execute,
    [string]$AdbPath = 'adb',
    [string]$BuildDir = (Join-Path (Split-Path $PSScriptRoot -Parent) 'output/thin-20261030'),
    [string]$FullZip = (Join-Path $BuildDir 'VanillaKernel-thin-e615f34-1fadf98.zip'),
    [string]$SkipIpvsZip = (Join-Path $BuildDir 'skip-ipvs/VanillaKernel-thin-skip-ipvs-e615f34-1fadf98.zip'),
    [string]$OutDir = (Join-Path $BuildDir 'testboot'),
    [string]$MagiskbootPath
)

$RemoteDir = '/data/local/tmp/testboot-make'
$AllowedDevices = '^(lemonadep|OnePlus9Pro|LE2123)$'
$BannerPattern = 'Linux version [0-9][ -~]*'
$AndroidMagic = 'ANDROID!'

function Write-Line {
    # Progress text on the information stream (shown by default here; PSScriptAnalyzer rejects Write-Host).
    param([string]$Text)
    Write-Information $Text -InformationAction Continue
}

function Get-FileSha256 {
    param([string]$Path)
    (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLower()
}

function Get-KernelBanner {
    # The "Linux version 5.4... (user@host) ..." line inside a kernel image (raw, or gzip-compressed).
    # The first "Linux version %s (%s)" in a kernel is a format string, hence the digit in the pattern.
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0x1f -and $bytes[1] -eq 0x8b) {
        $in = [IO.MemoryStream]::new($bytes)
        $gz = [IO.Compression.GZipStream]::new($in, [IO.Compression.CompressionMode]::Decompress)
        $out = [IO.MemoryStream]::new()
        $gz.CopyTo($out)
        $bytes = $out.ToArray()
    }
    $match = [regex]::Match([Text.Encoding]::Latin1.GetString($bytes), $BannerPattern)
    if ($match.Success) { $match.Value.Trim() } else { $null }
}

function Expand-ZipEntry {
    param([string]$Zip, [string]$Entry, [string]$Destination)
    $archive = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        $item = $archive.GetEntry($Entry)
        if (-not $item) { throw "$Zip has no entry $Entry" }
        [IO.Compression.ZipFileExtensions]::ExtractToFile($item, $Destination, $true)
    } finally { $archive.Dispose() }
}

function Read-ChecksumFile {
    # sha256sum-format file -> hashtable of leaf name -> sha256
    param([string]$Path)
    $sums = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^([0-9a-fA-F]{64})\s+\*?(.+)$') { $sums[(Split-Path $Matches[2] -Leaf)] = $Matches[1].ToLower() }
    }
    $sums
}

function Get-BuildInput {
    # Extracts Image.gz from a build's zip, checks it against the SHA256SUMS next to the zip, reads its banner.
    param([string]$Name, [string]$Zip, [string]$WorkDir)
    if (-not (Test-Path -LiteralPath $Zip)) { throw "build zip not found: $Zip" }
    $sumsFile = Join-Path (Split-Path $Zip -Parent) 'SHA256SUMS'
    if (-not (Test-Path -LiteralPath $sumsFile)) { throw "no SHA256SUMS next to ${Zip}: cannot check what is being repacked" }
    $sums = Read-ChecksumFile $sumsFile
    $zipSha = Get-FileSha256 $Zip
    $zipName = Split-Path $Zip -Leaf
    if ($sums[$zipName] -ne $zipSha) { throw "$zipName sha256 $zipSha is not the one in $sumsFile ($($sums[$zipName]))" }
    $image = Join-Path $WorkDir "$Name.Image.gz"
    Expand-ZipEntry -Zip $Zip -Entry 'Image.gz' -Destination $image
    $imageSha = Get-FileSha256 $image
    if ($sums['Image.gz'] -ne $imageSha) { throw "Image.gz inside $zipName is $imageSha, SHA256SUMS says $($sums['Image.gz'])" }
    $banner = Get-KernelBanner $image
    if (-not $banner) { throw "no kernel banner found in Image.gz of $zipName" }
    [pscustomobject]@{ Name = $Name; Zip = $Zip; ZipSha = $zipSha; ImageGz = $image; ImageGzSha = $imageSha; Banner = $banner }
}

function Invoke-Adb {
    # The one place that calls adb, always with -s <serial>. Returns the output lines.
    param([string]$AdbPath, [string]$Serial, [string[]]$Arguments)
    $out = & $AdbPath -s $Serial @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "adb -s $Serial $($Arguments -join ' ') failed (exit $LASTEXITCODE): $($out -join ' ')" }
    $out | ForEach-Object { "$_" }
}

function Invoke-AdbSu {
    # Runs one command line as root on the phone. The command must not contain a single quote.
    param([string]$AdbPath, [string]$Serial, [string]$Command)
    if ($Command.Contains("'")) { throw "internal error: single quote in a su command: $Command" }
    Invoke-Adb -AdbPath $AdbPath -Serial $Serial -Arguments @('shell', "su -c '$Command'")
}

function Get-RemoteSha256 {
    param([string]$AdbPath, [string]$Serial, [string]$RemotePath)
    $line = Invoke-AdbSu -AdbPath $AdbPath -Serial $Serial -Command "sha256sum $RemotePath" |
        Where-Object { $_ -match '^[0-9a-f]{64}\s' } | Select-Object -First 1
    if (-not $line) { throw "no sha256 for $RemotePath on the phone" }
    $line.Substring(0, 64)
}

function Test-AndroidBootImage {
    param([string]$Path)
    $head = [byte[]]::new($AndroidMagic.Length)
    $stream = [IO.File]::OpenRead($Path)
    try { [void]$stream.Read($head, 0, $head.Length) } finally { $stream.Dispose() }
    [Text.Encoding]::ASCII.GetString($head) -eq $AndroidMagic
}

function Assert-NinePro {
    # Refuses anything but a 9 Pro with root; returns the active slot suffix ("_a" or "_b").
    param([string]$AdbPath, [string]$Serial)
    $device = (Invoke-Adb -AdbPath $AdbPath -Serial $Serial -Arguments @('shell', 'getprop', 'ro.product.device') | Out-String).Trim()
    if ($device -notmatch $AllowedDevices) {
        throw "Serial $Serial reports device '$device': not a OnePlus 9 Pro (lemonadep). Refusing."
    }
    $slot = (Invoke-Adb -AdbPath $AdbPath -Serial $Serial -Arguments @('shell', 'getprop', 'ro.boot.slot_suffix') | Out-String).Trim()
    if ($slot -notmatch '^_[ab]$') { throw "ro.boot.slot_suffix is '$slot', expected _a or _b. Refusing." }
    $uid = (Invoke-AdbSu -AdbPath $AdbPath -Serial $Serial -Command 'id -u' | Out-String).Trim()
    if ($uid -ne '0') { throw "su -c 'id -u' answered '$uid', not 0: no root, cannot read the boot partition." }
    $slot
}

function Write-DryRunPlan {
    param($Builds, [string]$Serial, [string]$OutDir, [string]$MagiskSource)
    Write-Line "DRY RUN (add -Execute to do it). Nothing below was run; adb was not called."
    foreach ($b in $Builds) {
        Write-Line "  build $($b.Name): $($b.Zip)"
        Write-Line "    zip sha256 $($b.ZipSha)  (matches SHA256SUMS)"
        Write-Line "    Image.gz   $($b.ImageGzSha)  (matches SHA256SUMS)"
        Write-Line "    banner     $($b.Banner)"
    }
    Write-Line "  magiskboot from $MagiskSource"
    Write-Line "Plan, every call is 'adb -s $Serial ...':"
    Write-Line "  shell getprop ro.product.device (must be lemonadep), ro.boot.slot_suffix; shell cat /proc/version; shell su -c 'id -u' (must be 0)"
    Write-Line "  shell mkdir -p $RemoteDir/...; push magiskboot and the Image.gz files there"
    Write-Line "  shell su -c 'dd if=/dev/block/by-name/boot<slot> of=$RemoteDir/boot-cur.img bs=1M'   (reads the partition)"
    Write-Line "  pull boot-cur.img; sha256 equal on both sides; its kernel banner must equal /proc/version"
    Write-Line "  per build: su magiskboot unpack / decompress / repack, pull, unpack again, kernel banner must be the build's"
    Write-Line "  shell su -c 'rm -rf $RemoteDir'   (also on any failure)"
    Write-Line "Output in ${OutDir}: boot<slot>-backup-<sha8>.img, testboot-full.img, testboot-skipipvs.img, SHA256SUMS"
}

function Invoke-TestbootMake {
    param(
        [string]$Serial, [bool]$Execute, [string]$AdbPath, [string]$FullZip, [string]$SkipIpvsZip,
        [string]$OutDir, [string]$MagiskbootPath
    )
    $ErrorActionPreference = 'Stop'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $work = Join-Path ([IO.Path]::GetTempPath()) "testboot-make-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $work | Out-Null
    $remoteTouched = $false
    try {
        $builds = @(
            Get-BuildInput -Name 'full' -Zip $FullZip -WorkDir $work
            Get-BuildInput -Name 'skipipvs' -Zip $SkipIpvsZip -WorkDir $work
        )
        $magiskboot = Join-Path $work 'magiskboot'
        if ($MagiskbootPath) {
            Copy-Item -LiteralPath $MagiskbootPath -Destination $magiskboot
            $magiskSource = $MagiskbootPath
        } else {
            Expand-ZipEntry -Zip $FullZip -Entry 'tools/magiskboot' -Destination $magiskboot
            $magiskSource = "$FullZip!tools/magiskboot (sha256 $(Get-FileSha256 $magiskboot))"
        }

        if (-not $Execute) {
            Write-DryRunPlan -Builds $builds -Serial $Serial -OutDir $OutDir -MagiskSource $magiskSource
            return
        }

        $adb = @{ AdbPath = $AdbPath; Serial = $Serial }
        $slot = Assert-NinePro @adb
        $phoneBanner = ((Invoke-Adb @adb -Arguments @('shell', 'cat', '/proc/version')) -join '').Trim()
        if ($phoneBanner -notmatch $BannerPattern) { throw "/proc/version does not look like a kernel banner: $phoneBanner" }
        Write-Line "phone $Serial slot $slot, running: $phoneBanner"

        $remoteTouched = $true
        Invoke-AdbSu @adb -Command "rm -rf $RemoteDir" | Out-Null
        $dirs = @('cur') + ($builds | ForEach-Object { $_.Name; "chk-$($_.Name)" })
        Invoke-Adb @adb -Arguments @('shell', "mkdir -p $(($dirs | ForEach-Object { "$RemoteDir/$_" }) -join ' ')") | Out-Null
        Invoke-Adb @adb -Arguments @('push', $magiskboot, "$RemoteDir/magiskboot") | Out-Null
        Invoke-Adb @adb -Arguments @('shell', "chmod 755 $RemoteDir/magiskboot") | Out-Null
        foreach ($b in $builds) {
            Invoke-Adb @adb -Arguments @('push', $b.ImageGz, "$RemoteDir/$($b.Name).Image.gz") | Out-Null
        }
        $usage = (Invoke-AdbSu @adb -Command "$RemoteDir/magiskboot 2>&1 | head -n 1") -join ' '
        # case-sensitive with the dash: the shell's own error text also names "magiskboot"
        if ($usage -cnotmatch 'MagiskBoot - ') {
            throw "magiskboot does not run on the phone (it said: $usage). Pass -MagiskbootPath with one that does."
        }

        # The current boot partition, read only.
        $partition = "/dev/block/by-name/boot$slot"
        Invoke-AdbSu @adb -Command "dd if=$partition of=$RemoteDir/boot-cur.img bs=1M && chmod 644 $RemoteDir/boot-cur.img" | Out-Null
        $remoteSha = Get-RemoteSha256 @adb -RemotePath "$RemoteDir/boot-cur.img"
        $current = Join-Path $work 'boot-cur.img'
        Invoke-Adb @adb -Arguments @('pull', "$RemoteDir/boot-cur.img", $current) | Out-Null
        $currentSha = Get-FileSha256 $current
        if ($currentSha -ne $remoteSha) { throw "boot-cur.img sha256 differs after the pull: phone $remoteSha, host $currentSha" }
        if (-not (Test-AndroidBootImage $current)) { throw "boot$slot does not start with ${AndroidMagic}: not an Android boot image" }
        $currentSize = (Get-Item -LiteralPath $current).Length

        # Is it today's kernel? Unpack on the phone, read the banner of the kernel inside.
        Invoke-AdbSu @adb -Command "cd $RemoteDir/cur && $RemoteDir/magiskboot unpack $RemoteDir/boot-cur.img && chmod -R a+rX $RemoteDir" | Out-Null
        $curKernel = Join-Path $work 'kernel-cur'
        Invoke-Adb @adb -Arguments @('pull', "$RemoteDir/cur/kernel", $curKernel) | Out-Null
        $curBanner = Get-KernelBanner $curKernel
        if ($curBanner -ne $phoneBanner) {
            throw "boot$slot holds a different kernel than the one running.`n  image:   $curBanner`n  running: $phoneBanner`nRefusing to repack it."
        }
        Write-Line "boot$slot is today's kernel (banner equal to /proc/version), sha256 $currentSha"

        # One repack per build, each verified by unpacking the result again.
        $made = @()
        foreach ($b in $builds) {
            $n = $b.Name
            $remoteImg = "$RemoteDir/testboot-$n.img"
            $chain = @(
                "cd $RemoteDir/$n",
                "$RemoteDir/magiskboot unpack $RemoteDir/boot-cur.img",
                "$RemoteDir/magiskboot decompress $RemoteDir/$n.Image.gz kernel",
                "$RemoteDir/magiskboot repack $RemoteDir/boot-cur.img $remoteImg",
                "chmod -R a+rX $RemoteDir"
            ) -join ' && '
            Invoke-AdbSu @adb -Command $chain | Out-Null
            $remoteImgSha = Get-RemoteSha256 @adb -RemotePath $remoteImg
            $img = Join-Path $work "testboot-$n.img"
            Invoke-Adb @adb -Arguments @('pull', $remoteImg, $img) | Out-Null
            if ((Get-FileSha256 $img) -ne $remoteImgSha) { throw "testboot-$n.img sha256 differs after the pull" }
            if (-not (Test-AndroidBootImage $img)) { throw "testboot-$n.img does not start with $AndroidMagic" }
            $size = (Get-Item -LiteralPath $img).Length
            if ($size -gt $currentSize) { throw "testboot-$n.img is $size bytes, larger than the partition dump ($currentSize)" }

            Invoke-AdbSu @adb -Command "cd $RemoteDir/chk-$n && $RemoteDir/magiskboot unpack $remoteImg && chmod -R a+rX $RemoteDir" | Out-Null
            $chkKernel = Join-Path $work "kernel-chk-$n"
            Invoke-Adb @adb -Arguments @('pull', "$RemoteDir/chk-$n/kernel", $chkKernel) | Out-Null
            $chkBanner = Get-KernelBanner $chkKernel
            if ($chkBanner -ne $b.Banner) {
                throw "testboot-$n.img carries the wrong kernel.`n  image:    $chkBanner`n  expected: $($b.Banner)"
            }
            $made += [pscustomobject]@{ Name = $n; Path = $img; Sha = (Get-FileSha256 $img); Size = $size }
        }

        # Only now touch OutDir. The backup is never overwritten: its name carries its sha256.
        New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
        $backupName = "boot$slot-backup-$($currentSha.Substring(0, 8)).img"
        $backup = Join-Path $OutDir $backupName
        if (-not (Test-Path -LiteralPath $backup)) { Move-Item -LiteralPath $current -Destination $backup }
        foreach ($m in $made) { Move-Item -LiteralPath $m.Path -Destination (Join-Path $OutDir "testboot-$($m.Name).img") -Force }
        $sumLines = foreach ($f in Get-ChildItem -LiteralPath $OutDir -File | Where-Object { $_.Name -match '^(boot_[ab]-backup-.*|testboot-.*)\.img$' } | Sort-Object Name) {
            "$(Get-FileSha256 $f.FullName)  $($f.Name)"
        }
        [IO.File]::WriteAllText((Join-Path $OutDir 'SHA256SUMS'), (($sumLines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))

        Write-Line ''
        Write-Line "Done. Files in ${OutDir}:"
        $sumLines | ForEach-Object { Write-Line "  $_" }
        Write-Line "Backup of today's boot$slot (keep it, it is the rollback): $backup"
        Write-Line "Rollback:   fastboot flash boot$slot `"$backup`""
    } finally {
        if ($remoteTouched) {
            try {
                Invoke-AdbSu -AdbPath $AdbPath -Serial $Serial -Command "rm -rf $RemoteDir" | Out-Null
                Write-Line "phone: $RemoteDir removed"
            } catch { Write-Warning "could not remove $RemoteDir on the phone: $_" }
        }
        Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-TestbootMake -Serial $Serial -Execute $Execute.IsPresent -AdbPath $AdbPath -FullZip $FullZip `
        -SkipIpvsZip $SkipIpvsZip -OutDir $OutDir -MagiskbootPath $MagiskbootPath
}
