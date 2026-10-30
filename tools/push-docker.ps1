#requires -Version 7
<#
.SYNOPSIS
  Pushes the static Docker arm64 binaries, docker compose and the docker-*.sh scripts to the
  OnePlus 9 Pro and installs them under /data/docker (runs on the Evo).

.DESCRIPTION
  DRY RUN by default: prints the plan, touches neither the network nor the phone. -Execute does it.
  Pinned versions and checksums live in docker-pin.json next to this script. Docker publishes no
  checksum file for the static bundle, so the pin's sha256 is recorded once with -RecordHash
  (downloads the bundle, writes its sha256 into the pin; review the diff, commit it). From then on
  every download is checked against it, and again on the phone before unpacking.
  Every adb call is `adb -s <Serial> ...`. The device is checked first: a OnePlus 8T (kebab) or
  anything that is not a 9 Pro (lemonadep / OnePlus9Pro) is refused.

.PARAMETER Serial
  adb serial of the phone. The 9 Pro is 5d7a3c0. Required except with -RecordHash.

.PARAMETER Execute
  Really download, push and install. Without it: dry run.

.PARAMETER RecordHash
  Download the Docker bundle and write its sha256 into the pin file. No adb.

.EXAMPLE
  pwsh tools/push-docker.ps1 -Serial 5d7a3c0              # dry run
  pwsh tools/push-docker.ps1 -Serial 5d7a3c0 -Execute     # push + install
#>
[CmdletBinding()]
param(
    [string]$Serial,
    [switch]$Execute,
    [switch]$RecordHash,
    [string]$AdbPath = 'adb',
    [string]$PinFile = (Join-Path $PSScriptRoot 'docker-pin.json'),
    [string]$CacheDir = (Join-Path ($env:LOCALAPPDATA ?? [IO.Path]::GetTempPath()) 'op9pro-docker')
)

$StageDir = '/data/local/tmp/docker-push'
$AllowedDevices = '^(lemonadep|OnePlus9Pro|LE2123)$'
$RefusedDevices = '^(kebab|OnePlus8T|KB2003)$'

function Get-FileSha256 {
    param([string]$Path)
    (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLower()
}

function Get-Pin {
    param([string]$Path)
    Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
}

function Save-Download {
    # Downloads $Entry.url into the cache and returns the local path.
    param($Entry, [string]$Dir)
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    $target = Join-Path $Dir ([IO.Path]::GetFileName(([uri]$Entry.url).AbsolutePath))
    Invoke-WebRequest -Uri $Entry.url -OutFile $target
    $target
}

function Assert-Sha256 {
    param([string]$Path, [string]$Expected)
    $actual = Get-FileSha256 $Path
    if ($actual -ne $Expected.ToLower()) {
        throw "sha256 mismatch for ${Path}: got $actual, pin says $Expected. Not pushing."
    }
}

function Invoke-Adb {
    # The one place that calls adb, always with -s <serial>.
    param([string]$AdbPath, [string]$Serial, [string[]]$Arguments)
    & $AdbPath -s $Serial @Arguments
    if ($LASTEXITCODE -ne 0) { throw "adb -s $Serial $($Arguments -join ' ') failed (exit $LASTEXITCODE)" }
}

function Assert-NinePro {
    param([string]$AdbPath, [string]$Serial)
    $device = (Invoke-Adb -AdbPath $AdbPath -Serial $Serial -Arguments @('shell', 'getprop', 'ro.product.device') | Out-String).Trim()
    if ($device -match $RefusedDevices -or $device -notmatch $AllowedDevices) {
        throw "Serial $Serial reports device '$device': not a OnePlus 9 Pro (lemonadep). Refusing."
    }
}

function Invoke-PushDocker {
    param([string]$Serial, [bool]$Execute, [bool]$RecordHash, [string]$AdbPath, [string]$PinFile, [string]$CacheDir)

    $pin = Get-Pin $PinFile
    $scripts = Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'docker-*.sh' | Sort-Object Name

    if ($RecordHash) {
        $path = Save-Download -Entry $pin.docker -Dir $CacheDir
        $pin.docker.sha256 = Get-FileSha256 $path
        $pin | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $PinFile
        Write-Host "docker $($pin.docker.version) sha256 = $($pin.docker.sha256) written to $PinFile - review and commit it."
        return
    }

    if (-not $Serial) { throw 'Serial is required (the 9 Pro is 5d7a3c0).' }

    $dockerName = [IO.Path]::GetFileName(([uri]$pin.docker.url).AbsolutePath)
    $composeName = [IO.Path]::GetFileName(([uri]$pin.compose.url).AbsolutePath)

    if (-not $Execute) {
        Write-Host "DRY RUN (add -Execute to do it). Target: adb -s $Serial"
        Write-Host "  download $($pin.docker.url)  (sha256 pin: $(if ($pin.docker.sha256) { $pin.docker.sha256 } else { 'EMPTY - run -RecordHash first' }))"
        Write-Host "  download $($pin.compose.url)  (sha256 pin: $($pin.compose.sha256))"
        Write-Host "  adb -s $Serial shell getprop ro.product.device   (must be lemonadep)"
        Write-Host "  adb -s $Serial push $dockerName, $composeName and $($scripts.Count) scripts -> $StageDir"
        Write-Host "  adb -s $Serial shell su -c 'sh $StageDir/docker-install.sh ...'  (verifies sha256 again, installs to /data/docker)"
        return
    }

    if (-not $pin.docker.sha256) {
        throw "docker-pin.json has no sha256 for the Docker bundle. Run: pwsh tools/push-docker.ps1 -RecordHash, review, commit."
    }

    $dockerFile = Save-Download -Entry $pin.docker -Dir $CacheDir
    Assert-Sha256 -Path $dockerFile -Expected $pin.docker.sha256
    $composeFile = Save-Download -Entry $pin.compose -Dir $CacheDir
    Assert-Sha256 -Path $composeFile -Expected $pin.compose.sha256

    Assert-NinePro -AdbPath $AdbPath -Serial $Serial

    Invoke-Adb -AdbPath $AdbPath -Serial $Serial -Arguments @('shell', "rm -rf $StageDir; mkdir -p $StageDir")
    foreach ($file in @($dockerFile, $composeFile) + $scripts.FullName) {
        Invoke-Adb -AdbPath $AdbPath -Serial $Serial -Arguments @('push', $file, "$StageDir/")
    }
    $install = "sh $StageDir/docker-install.sh $StageDir $dockerName $($pin.docker.sha256) $composeName $($pin.compose.sha256)"
    Invoke-Adb -AdbPath $AdbPath -Serial $Serial -Arguments @('shell', "su -c '$install'")
    Write-Host "Installed. Next: adb -s $Serial shell `"su -c 'sh /data/docker/tools/docker-up.sh'`""
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-PushDocker -Serial $Serial -Execute $Execute.IsPresent -RecordHash $RecordHash.IsPresent `
        -AdbPath $AdbPath -PinFile $PinFile -CacheDir $CacheDir
}
