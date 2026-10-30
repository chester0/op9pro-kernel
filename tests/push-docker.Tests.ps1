#requires -Version 7
#requires -Modules @{ModuleName='Pester';ModuleVersion='5.0'}
# Pester 5 tests for tools/push-docker.ps1 with a fake adb. No network, no phone.

BeforeAll {
    $script:Repo = Split-Path $PSScriptRoot -Parent
    $script:Script = Join-Path $Repo 'tools/push-docker.ps1'
    . $script:Script

    $script:Work = Join-Path ([IO.Path]::GetTempPath()) "push-docker-test-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $script:Work | Out-Null
    $script:AdbLog = Join-Path $script:Work 'adb.log'

    # Fake adb: logs its arguments, answers getprop from $env:FAKE_ADB_DEVICE.
    $script:FakeAdb = Join-Path $script:Work 'adb.ps1'
    Set-Content -Path $script:FakeAdb -Value @'
Add-Content -Path $env:FAKE_ADB_LOG -Value ($args -join ' ')
if ($args -contains 'getprop') { $env:FAKE_ADB_DEVICE }
exit 0
'@

    function script:New-Pin {
        param([string]$DockerSha, [string]$Path)
        $pin = @{
            docker  = @{ version = '1.2.3'; url = 'https://example.invalid/docker-1.2.3.tgz'; sha256 = $DockerSha }
            compose = @{ version = 'v9'; url = 'https://example.invalid/docker-compose-linux-aarch64'; sha256 = (Get-Sha256Text 'compose-bytes') }
        }
        $pin | ConvertTo-Json -Depth 4 | Set-Content -Path $Path
    }
    function script:Get-Sha256Text {
        param([string]$Text)
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        ([BitConverter]::ToString([Security.Cryptography.SHA256]::HashData($bytes)) -replace '-', '').ToLower()
    }
}

AfterAll {
    Remove-Item -Recurse -Force -LiteralPath $script:Work -ErrorAction SilentlyContinue
}

Describe 'push-docker.ps1' {
    BeforeEach {
        $env:FAKE_ADB_LOG = $script:AdbLog
        $env:FAKE_ADB_DEVICE = 'lemonadep'
        Remove-Item -Force -LiteralPath $script:AdbLog -ErrorAction SilentlyContinue
        $script:Pin = Join-Path $script:Work 'pin.json'
        $script:Cache = Join-Path $script:Work 'cache'
        Remove-Item -Recurse -Force -LiteralPath $script:Cache -ErrorAction SilentlyContinue
        New-Pin -DockerSha (Get-Sha256Text 'docker-bytes') -Path $script:Pin
        # Fake download: writes the bytes whose hash the pin expects (or wrong ones when asked).
        # (env vars, because a Mock body does not see this file's $script: scope)
        $env:FAKE_DL_DOCKER = 'docker-bytes'
        $env:FAKE_DL_COMPOSE = 'compose-bytes'
        Mock Invoke-WebRequest {
            $text = if ($Uri -like '*compose*') { $env:FAKE_DL_COMPOSE } else { $env:FAKE_DL_DOCKER }
            [IO.File]::WriteAllText($OutFile, $text)
        }
    }

    It 'dry run (the default) calls neither adb nor the network' {
        $out = & $script:Script -Serial 5d7a3c0 -AdbPath $script:FakeAdb -PinFile $script:Pin -CacheDir $script:Cache 6>&1 | Out-String
        $out | Should -Match 'DRY RUN'
        $out | Should -Match '5d7a3c0'
        Test-Path $script:AdbLog | Should -BeFalse
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'requires a serial' {
        { & $script:Script -AdbPath $script:FakeAdb -PinFile $script:Pin -CacheDir $script:Cache } | Should -Throw '*Serial*'
    }

    It 'refuses when the pin has no sha256 for the docker bundle' {
        New-Pin -DockerSha '' -Path $script:Pin
        { & $script:Script -Serial 5d7a3c0 -Execute -AdbPath $script:FakeAdb -PinFile $script:Pin -CacheDir $script:Cache } | Should -Throw '*RecordHash*'
        Test-Path $script:AdbLog | Should -BeFalse
    }

    It 'refuses a download whose sha256 does not match the pin' {
        $env:FAKE_DL_DOCKER = 'tampered'
        { & $script:Script -Serial 5d7a3c0 -Execute -AdbPath $script:FakeAdb -PinFile $script:Pin -CacheDir $script:Cache } | Should -Throw '*sha256*'
        Test-Path $script:AdbLog | Should -BeFalse
    }

    It 'refuses the OnePlus 8T (kebab) before pushing anything' {
        $env:FAKE_ADB_DEVICE = 'kebab'
        { & $script:Script -Serial 5d7a3c0 -Execute -AdbPath $script:FakeAdb -PinFile $script:Pin -CacheDir $script:Cache } | Should -Throw '*not a OnePlus 9 Pro*'
        (Get-Content $script:AdbLog) -join "`n" | Should -Not -Match ' push '
    }

    It 'pushes bundle, compose and scripts with adb -s <serial> only, then installs as root' {
        & $script:Script -Serial 5d7a3c0 -Execute -AdbPath $script:FakeAdb -PinFile $script:Pin -CacheDir $script:Cache 6>&1 | Out-Null
        $calls = Get-Content $script:AdbLog
        $calls | ForEach-Object { $_ | Should -Match '^-s 5d7a3c0 ' }
        ($calls | Where-Object { $_ -match ' push ' }).Count | Should -BeGreaterOrEqual 9   # tgz + compose + 7 scripts
        ($calls -join "`n") | Should -Match 'docker-1\.2\.3\.tgz'
        $calls[-1] | Should -Match "su -c 'sh /data/local/tmp/docker-push/docker-install\.sh"
        $calls[-1] | Should -Match (Get-Sha256Text 'docker-bytes')
    }

    It '-RecordHash downloads the bundle, writes its sha256 into the pin and does not touch adb' {
        New-Pin -DockerSha '' -Path $script:Pin
        & $script:Script -RecordHash -PinFile $script:Pin -CacheDir $script:Cache 6>&1 | Out-Null
        (Get-Content $script:Pin -Raw | ConvertFrom-Json).docker.sha256 | Should -Be (Get-Sha256Text 'docker-bytes')
        Test-Path $script:AdbLog | Should -BeFalse
    }
}
