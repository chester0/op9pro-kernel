#requires -Version 7
#requires -Modules @{ModuleName='Pester';ModuleVersion='5.0'}
# Pester 5 tests for tools/docker-*.sh: shellcheck (-s sh) on every script, and the start/stop logic
# under Git's bash with stubbed mount/unshare/dockerd/docker/iptables (no phone, no real Docker).

BeforeDiscovery {
    $repo = Split-Path $PSScriptRoot -Parent
    $script:ShellScripts = @(Get-ChildItem (Join-Path $repo 'tools') -Filter '*.sh') +
        @(Get-ChildItem (Join-Path $repo 'compose') -Filter '*.sh' -Recurse) |
        ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
    $script:ComposeFiles = Get-ChildItem (Join-Path $repo 'compose') -Filter 'compose.yaml' -Recurse |
        ForEach-Object { @{ Name = $_.Directory.Name; Path = $_.FullName } }
}

BeforeAll {
    $script:Tools = Join-Path (Split-Path $PSScriptRoot -Parent) 'tools'

    # Git-bash path: C:\x\y -> /c/x/y (a "C:/x" would be split at the colon inside PATH).
    function script:ToSh([string]$p) {
        ($p -replace '\\', '/') -replace '^([A-Za-z]):', { '/' + $_.Groups[1].Value.ToLower() }
    }

    function script:Write-Stub {
        param([string]$Dir, [string]$Name, [string]$Body)
        $text = "#!/bin/sh`n$Body`n" -replace "`r`n", "`n"
        [IO.File]::WriteAllText((Join-Path $Dir $Name), $text)
    }

    # A fresh fake /data/docker with stub binaries; returns the base dir.
    function script:New-FakePhone {
        param([string]$IptablesRc = '0', [string]$OverlayRc = '0', [string]$Uid = '0', [switch]$LeakedCgroup, [switch]$SharedRoot)
        $base = Join-Path ([IO.Path]::GetTempPath()) "docker-up-test-$([guid]::NewGuid().ToString('N'))"
        $bin = Join-Path $base 'bin'
        New-Item -ItemType Directory -Path $bin, (Join-Path $base 'etc'), (Join-Path $base 'cg') | Out-Null
        Write-Stub $bin 'id' "echo $Uid"
        Write-Stub $bin 'getenforce' 'echo Enforcing'
        Write-Stub $bin 'iptables' "exit $IptablesRc"
        Write-Stub $bin 'ip' 'exit 0'
        Write-Stub $bin 'unshare' 'shift; exec "$@"'
        # mount stub: fails only for the overlay probe when asked to
        Write-Stub $bin 'mount' "case `"`$*`" in *overlay*) exit $OverlayRc;; esac; exit 0"
        Write-Stub $bin 'umount' 'exit 0'
        # dockerd stub: records its flags, writes the pidfile and the socket, then idles
        Write-Stub $bin 'dockerd' @'
echo "$*" > "$DOCKER_BASE/dockerd.args"
while [ $# -gt 0 ]; do case "$1" in --pidfile) pf="$2";; --host) sock="${2#unix://}";; esac; shift; done
echo $$ > "$pf"; : > "$sock"
trap 'exit 0' TERM
while :; do sleep 1; done
'@
        Write-Stub $bin 'docker' 'exit 0'
        # init's mount view as on the real 9 Pro: Android's own cgroup2 sits at the same mount point
        # the daemon covers with its private tmpfs (the 2026-10-30 false "leaked" abort).
        $cgPoint = ToSh (Join-Path $base 'cg')
        $lines = @("63 45 0:27 / $cgPoint rw,nosuid,nodev,noexec,relatime shared:18 - cgroup2 none rw")
        if ($LeakedCgroup) { $lines += "99 45 0:99 / $cgPoint rw,nosuid,nodev,noexec,relatime shared:99 - tmpfs dockercg rw,mode=755" }
        [IO.File]::WriteAllText((Join-Path $base 'init-mountinfo'), (($lines -join "`n") + "`n"))
        # dockerd's own namespace after make_mounts_private: / private, unless the propagation call silently
        # did nothing (toybox's `-o rprivate / /` on the 9 Pro, 2026-10-30).
        $tag = if ($SharedRoot) { ' shared:1' } else { '' }
        [IO.File]::WriteAllText((Join-Path $base 'self-mountinfo'), "41 40 253:2 / / ro,relatime$tag - ext4 /dev/block/dm-2 ro`n")
        $base
    }

    function script:Invoke-Sh {
        param([string]$Base, [string]$Script, [string[]]$Arguments = @())
        $env:DOCKER_BASE = ToSh $Base
        $env:DOCKER_ETC_DIR = ToSh (Join-Path $Base 'etc')
        $env:DOCKER_CGROUP_DIR = ToSh (Join-Path $Base 'cg')
        $env:DOCKER_INIT_MOUNTINFO = ToSh (Join-Path $Base 'init-mountinfo')
        $env:DOCKER_SELF_MOUNTINFO = ToSh (Join-Path $Base 'self-mountinfo')
        $out = & bash (ToSh (Join-Path $script:Tools $Script)) @Arguments 2>&1 | Out-String
        [pscustomobject]@{ Output = $out; Code = $LASTEXITCODE }
    }

    function script:Stop-Fake {
        param([string]$Base)
        if ($null -ne (Invoke-Sh $Base 'docker-down.sh')) { }
        Remove-Item -Recurse -Force -LiteralPath $Base -ErrorAction SilentlyContinue
    }
}

Describe 'shellcheck' {
    It '<Name> passes shellcheck -s sh' -ForEach $script:ShellScripts {
        $result = & shellcheck -s sh $Path 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $result
    }
}

Describe 'compose files' {
    It '<Name>/compose.yaml parses and defines a service with a restart policy' -ForEach $script:ComposeFiles {
        $json = & python -I -c "import sys, json, yaml; print(json.dumps(yaml.safe_load(open(sys.argv[1]))))" $Path
        $LASTEXITCODE | Should -Be 0
        $doc = $json | ConvertFrom-Json
        $services = @($doc.services.PSObject.Properties)
        $services.Count | Should -BeGreaterThan 0
        $services | ForEach-Object { $_.Value.restart | Should -Be 'unless-stopped' }
    }
}

Describe 'docker-up.sh / docker-down.sh' {
    It 'starts dockerd in bridge mode with overlay2, then refuses a second start' {
        $base = New-FakePhone
        try {
            $first = Invoke-Sh $base 'docker-up.sh'
            $first.Code | Should -Be 0 -Because $first.Output
            $first.Output | Should -Match 'dockerd up, pid \d+, network mode bridge'
            (Get-Content (Join-Path $base 'run/mode')) | Should -Be 'bridge'
            (Get-Content (Join-Path $base 'daemon.json') -Raw) | Should -Match '"storage-driver": "overlay2"'
            (Get-Content (Join-Path $base 'dockerd.args') -Raw) | Should -Match '--data-root \S*/root'
            $pid1 = (Get-Content (Join-Path $base 'run/docker.pid'))

            $second = Invoke-Sh $base 'docker-up.sh'
            $second.Code | Should -Be 0
            $second.Output | Should -Match 'already running'
            (Get-Content (Join-Path $base 'run/docker.pid')) | Should -Be $pid1
        } finally { Stop-Fake $base }
    }

    It 'aborts before dockerd when its cgroup tmpfs shows in init''s namespace' {
        $base = New-FakePhone -LeakedCgroup
        try {
            $r = Invoke-Sh $base 'docker-up.sh'
            $r.Code | Should -Not -Be 0
            $r.Output | Should -Match 'leaked into the global namespace'
            Test-Path (Join-Path $base 'dockerd.args') | Should -BeFalse
        } finally { Stop-Fake $base }
    }

    It 'aborts before any mount when / stays shared after the propagation call' {
        $base = New-FakePhone -SharedRoot
        try {
            $r = Invoke-Sh $base 'docker-up.sh'
            $r.Code | Should -Not -Be 0
            $r.Output | Should -Match 'could not make / private'
            Test-Path (Join-Path $base 'dockerd.args') | Should -BeFalse
        } finally { Stop-Fake $base }
    }

    It 'falls back to host-only networking when iptables nat is unusable' {
        $base = New-FakePhone -IptablesRc '1'
        try {
            $r = Invoke-Sh $base 'docker-up.sh'
            $r.Code | Should -Be 0 -Because $r.Output
            (Get-Content (Join-Path $base 'run/mode')) | Should -Be 'host-only'
            (Get-Content (Join-Path $base 'dockerd.args') -Raw) | Should -Match '--iptables=false --bridge=none'
        } finally { Stop-Fake $base }
    }

    It 'falls back to the vfs storage driver when overlay cannot mount' {
        $base = New-FakePhone -OverlayRc '1'
        try {
            $r = Invoke-Sh $base 'docker-up.sh'
            $r.Code | Should -Be 0 -Because $r.Output
            (Get-Content (Join-Path $base 'daemon.json') -Raw) | Should -Match '"storage-driver": "vfs"'
        } finally { Stop-Fake $base }
    }

    It 'refuses to run unless root' {
        $base = New-FakePhone -Uid '2000'
        try {
            $r = Invoke-Sh $base 'docker-up.sh'
            $r.Code | Should -Not -Be 0
            $r.Output | Should -Match 'must run as root'
            Test-Path (Join-Path $base 'run/docker.pid') | Should -BeFalse
        } finally { Stop-Fake $base }
    }

    It 'down stops dockerd, removes pid and socket, and is idempotent' {
        $base = New-FakePhone
        try {
            (Invoke-Sh $base 'docker-up.sh').Code | Should -Be 0
            $dockerPid = Get-Content (Join-Path $base 'run/docker.pid')
            $down = Invoke-Sh $base 'docker-down.sh'
            $down.Code | Should -Be 0 -Because $down.Output
            $down.Output | Should -Match 'dockerd down'
            Test-Path (Join-Path $base 'run/docker.pid') | Should -BeFalse
            Test-Path (Join-Path $base 'run/docker.sock') | Should -BeFalse
            (& bash -c "kill -0 $dockerPid 2>/dev/null; echo `$?") | Should -Not -Be '0'
            $again = Invoke-Sh $base 'docker-down.sh'
            $again.Code | Should -Be 0
            $again.Output | Should -Match 'not running'
        } finally { Stop-Fake $base }
    }
}

Describe 'docker-boot-service.sh' {
    It 'installs, reports and removes the opt-in service.d script' {
        $base = New-FakePhone
        try {
            $env:KSU_SERVICE_DIR = ToSh (Join-Path $base 'service.d')
            (Invoke-Sh $base 'docker-boot-service.sh' @('status')).Output | Should -Match 'not installed'
            (Invoke-Sh $base 'docker-boot-service.sh' @('install')).Code | Should -Be 0
            $svc = Join-Path $base 'service.d/99-docker-up.sh'
            Get-Content $svc -Raw | Should -Match 'docker-up\.sh'
            Get-Content $svc -Raw | Should -Match 'sys\.boot_completed'
            (Invoke-Sh $base 'docker-boot-service.sh' @('remove')).Code | Should -Be 0
            Test-Path $svc | Should -BeFalse
        } finally {
            Remove-Item Env:KSU_SERVICE_DIR
            Remove-Item -Recurse -Force -LiteralPath $base -ErrorAction SilentlyContinue
        }
    }
}

Describe 'docker-install.sh' {
    BeforeEach {
        $script:Base = New-FakePhone
        $script:Stage = Join-Path $script:Base 'stage'
        New-Item -ItemType Directory -Path (Join-Path $script:Stage 'docker-src/docker') | Out-Null
        Write-Stub (Join-Path $script:Stage 'docker-src/docker') 'dockerd' 'echo "Docker version stub"'
        $stageSh = ToSh $script:Stage
        & bash -c "cd '$stageSh/docker-src' && tar -czf ../docker-1.tgz docker"
        [IO.File]::WriteAllText((Join-Path $script:Stage 'compose-bin'), "#!/bin/sh`necho compose stub`n")
        Copy-Item (Join-Path $script:Tools 'docker-*.sh') $script:Stage
        $script:TgzSha = (Get-FileHash -Algorithm SHA256 (Join-Path $script:Stage 'docker-1.tgz')).Hash.ToLower()
        $script:ComposeSha = (Get-FileHash -Algorithm SHA256 (Join-Path $script:Stage 'compose-bin')).Hash.ToLower()
    }
    AfterEach { Remove-Item -Recurse -Force -LiteralPath $script:Base -ErrorAction SilentlyContinue }

    It 'verifies checksums, unpacks into bin and copies the scripts' {
        $r = Invoke-Sh $script:Base 'docker-install.sh' @((ToSh $script:Stage), 'docker-1.tgz', $script:TgzSha, 'compose-bin', $script:ComposeSha)
        $r.Code | Should -Be 0 -Because $r.Output
        Test-Path (Join-Path $script:Base 'bin/dockerd') | Should -BeTrue
        Test-Path (Join-Path $script:Base 'bin/docker-compose') | Should -BeTrue
        Test-Path (Join-Path $script:Base 'tools/docker-up.sh') | Should -BeTrue
    }

    It 'refuses a bundle whose sha256 does not match' {
        $r = Invoke-Sh $script:Base 'docker-install.sh' @((ToSh $script:Stage), 'docker-1.tgz', ('0' * 64), 'compose-bin', $script:ComposeSha)
        $r.Code | Should -Not -Be 0
        $r.Output | Should -Match 'sha256 mismatch'
        Test-Path (Join-Path $script:Base 'bin/docker-compose') | Should -BeFalse
    }
}
