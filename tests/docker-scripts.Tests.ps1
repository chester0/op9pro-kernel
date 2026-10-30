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
        param(
            [string]$IptablesRc = '0', [string]$OverlayRc = '0', [string]$Uid = '0',
            [string]$RootOverlayRc = '0',          # exit code of the root-view overlay mount (source name dockerroot)
            [switch]$RootOverlayFirstFails,        # the first root-view overlay attempt (tmpfs upper) is refused
            [switch]$LeakedCgroup, [switch]$LeakedOverlay, [switch]$SharedRoot, [switch]$FailBind
        )
        $base = Join-Path ([IO.Path]::GetTempPath()) "docker-up-test-$([guid]::NewGuid().ToString('N'))"
        $bin = Join-Path $base 'bin'
        New-Item -ItemType Directory -Path $bin, (Join-Path $base 'etc'), (Join-Path $base 'cg'),
            (Join-Path $base 'fs/apex/com.x'), (Join-Path $base 'fs/data'), (Join-Path $base 'fs/fail-me') | Out-Null
        Write-Stub $bin 'id' "echo $Uid"
        Write-Stub $bin 'getenforce' 'echo Enforcing'
        Write-Stub $bin 'iptables' "exit $IptablesRc"
        Write-Stub $bin 'ip' 'exit 0'
        Write-Stub $bin 'unshare' 'shift; exec "$@"'
        # mount stub: logs every call; the storage-driver probe (plain "overlay" source) fails with $OverlayRc,
        # the root-view overlay (source "dockerroot") with $RootOverlayRc, once only when asked to, and a
        # bind of a path called fail-me always fails.
        $firstFails = if ($RootOverlayFirstFails) { '1' } else { '0' }
        Write-Stub $bin 'mount' @"
echo "`$*" >> "`$DOCKER_BASE/mount.log"
case "`$*" in
    *fail-me*) exit 1;;
    *dockerroot*)
        if [ $firstFails = 1 ] && [ ! -e "`$DOCKER_BASE/.ov-tried" ]; then : > "`$DOCKER_BASE/.ov-tried"; exit 1; fi
        exit $RootOverlayRc;;
    *overlay*) exit $OverlayRc;;
esac
exit 0
"@
        Write-Stub $bin 'umount' 'echo "$*" >> "$DOCKER_BASE/mount.log"; exit 0'
        # no real chroot on the test host: log the new root and run the command in place
        Write-Stub $bin 'chroot' 'echo "$*" >> "$DOCKER_BASE/chroot.log"; shift; exec "$@"'
        # dockerd stub: records its flags, writes the pidfile and the socket, then idles
        Write-Stub $bin 'dockerd' @'
echo "$*" > "$DOCKER_BASE/dockerd.args"
echo "$SSL_CERT_DIR" > "$DOCKER_BASE/dockerd.certdir"
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
        if ($LeakedOverlay) { $lines += "98 45 0:98 / $(ToSh (Join-Path $base 'newroot')) rw,relatime shared:98 - overlay dockerroot rw,lowerdir=/" }
        [IO.File]::WriteAllText((Join-Path $base 'init-mountinfo'), (($lines -join "`n") + "`n"))
        # dockerd's own namespace after make_mounts_private: / private, unless the propagation call silently
        # did nothing (toybox's `-o rprivate / /` on the 9 Pro, 2026-10-30).
        $tag = if ($SharedRoot) { ' shared:1' } else { '' }
        # ...plus the submounts the root view must replicate: a stacked mount point (only the top one
        # counts), a child listed BEFORE its parent (mount ids get reused), and the new root itself and
        # /, which must never be bound into the new root.
        $fs = ToSh (Join-Path $base 'fs')
        $self = @(
            "41 40 253:2 / / ro,relatime$tag - ext4 /dev/block/dm-2 ro",
            "52 41 0:30 / $fs/apex/com.x rw - tmpfs tmpfs rw",
            "50 41 0:28 / $fs/apex rw - tmpfs tmpfs rw",
            "51 41 0:29 / $fs/apex rw - tmpfs tmpfs rw",
            "53 41 0:31 / $fs/data rw - f2fs /dev/block/dm-9 rw",
            "54 41 0:32 / $(ToSh (Join-Path $base 'newroot')) rw - overlay dockerroot rw",
            "55 41 0:33 / $(ToSh (Join-Path $base 'ov')) rw - tmpfs dockerov rw",
            # the same two for the probe, which uses its own dirs
            "57 41 0:35 / $(ToSh (Join-Path $base 'probe-root')) rw - overlay dockerroot rw",
            "58 41 0:36 / $(ToSh (Join-Path $base 'probe-ov')) rw - tmpfs dockerov rw"
        )
        if ($FailBind) { $self += "56 41 0:34 / $fs/fail-me rw - tmpfs tmpfs rw" }
        [IO.File]::WriteAllText((Join-Path $base 'self-mountinfo'), (($self -join "`n") + "`n"))
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
            # Android's CA roots, or every registry pull fails x509 (9 Pro, 2026-10-31)
            (Get-Content (Join-Path $base 'dockerd.certdir') -Raw) | Should -Match '^/apex/com\.android\.conscrypt/cacerts:/system/etc/security/cacerts'
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

    It 'aborts before dockerd when the root overlay shows in init''s namespace' {
        $base = New-FakePhone -LeakedOverlay
        try {
            $r = Invoke-Sh $base 'docker-up.sh'
            $r.Code | Should -Not -Be 0
            $r.Output | Should -Match 'leaked into the global namespace'
            Test-Path (Join-Path $base 'dockerd.args') | Should -BeFalse
        } finally { Stop-Fake $base }
    }

    It 'runs dockerd chrooted into an overlay of / with /run, /tmp and /var/run, never writing / itself' {
        $base = New-FakePhone
        try {
            $r = Invoke-Sh $base 'docker-up.sh'
            $r.Code | Should -Be 0 -Because $r.Output
            $newroot = ToSh (Join-Path $base 'newroot')
            $mounts = Get-Content (Join-Path $base 'mount.log')
            # tmpfs upper first, then the overlay: lower is /, upper+work are on that tmpfs
            $mounts | Should -Contain "-t tmpfs -o mode=755,size=128m,context=u:object_r:rootfs:s0 dockerov $(ToSh (Join-Path $base 'ov'))"
            $mounts | Should -Contain "-t overlay dockerroot -o lowerdir=/,upperdir=$(ToSh (Join-Path $base 'ov'))/upper,workdir=$(ToSh (Join-Path $base 'ov'))/work $newroot"
            $mounts -join "`n" | Should -Not -Match 'remount' -Because 'nothing may remount / writable'
            # dockerd was started through chroot into the overlay, with its flags unchanged
            (Get-Content (Join-Path $base 'chroot.log')) | Should -Match "^$([regex]::Escape($newroot)) \S*/bin/dockerd --config-file"
            # the places dockerd hardcodes exist in the new root
            Test-Path (Join-Path $base 'newroot/run') | Should -BeTrue
            Test-Path (Join-Path $base 'newroot/tmp') | Should -BeTrue
            Test-Path (Join-Path $base 'newroot/var') | Should -BeTrue
            # submounts are bound in parent-first, once each; / and our own mounts are not
            $fs = ToSh (Join-Path $base 'fs')
            $binds = @($mounts | Where-Object { $_ -like "--bind $fs/*" })
            $binds | Should -Be @(
                "--bind $fs/apex $newroot$fs/apex",
                "--bind $fs/apex/com.x $newroot$fs/apex/com.x",
                "--bind $fs/data $newroot$fs/data"
            )
            ($mounts | Where-Object { $_ -match '^--bind / ' }) | Should -BeNullOrEmpty
            ($mounts | Where-Object { $_ -match "^--bind \S*/(newroot|ov)( |$)" }) | Should -BeNullOrEmpty
        } finally { Stop-Fake $base }
    }

    It 'retries the root overlay with its upper on the data filesystem when the tmpfs upper is refused' {
        $base = New-FakePhone -RootOverlayFirstFails
        try {
            $r = Invoke-Sh $base 'docker-up.sh'
            $r.Code | Should -Be 0 -Because $r.Output
            $overlays = @(Get-Content (Join-Path $base 'mount.log') | Where-Object { $_ -like '-t overlay dockerroot*' })
            $overlays.Count | Should -Be 2
            Get-Content (Join-Path $base 'log/dockerd.log') -Raw | Should -Match 'retrying with the upper on'
            Test-Path (Join-Path $base 'dockerd.args') | Should -BeTrue
        } finally { Stop-Fake $base }
    }

    It 'aborts before dockerd, with a clear message, when the root overlay is refused both ways' {
        $base = New-FakePhone -RootOverlayRc '1'
        try {
            $r = Invoke-Sh $base 'docker-up.sh'
            $r.Code | Should -Not -Be 0
            $r.Output | Should -Match 'overlay root refused'
            Test-Path (Join-Path $base 'dockerd.args') | Should -BeFalse
            Test-Path (Join-Path $base 'chroot.log') | Should -BeFalse
        } finally { Stop-Fake $base }
    }

    It 'aborts when a required mount cannot be bound into the new root, but only warns for the others' {
        $base = New-FakePhone -FailBind
        try {
            $r = Invoke-Sh $base 'docker-up.sh'
            $r.Code | Should -Be 0 -Because 'fail-me is not in the required list'
            Get-Content (Join-Path $base 'log/dockerd.log') -Raw | Should -Match 'bind of .*fail-me failed'
        } finally { Stop-Fake $base }
        $base = New-FakePhone -FailBind
        try {
            $env:DOCKER_REQUIRED_MOUNTS = "$(ToSh (Join-Path $base 'fs'))/fail-me"
            $r = Invoke-Sh $base 'docker-up.sh'
            $r.Code | Should -Not -Be 0
            $r.Output | Should -Match 'required mount .*fail-me'
            Test-Path (Join-Path $base 'dockerd.args') | Should -BeFalse
        } finally { Remove-Item Env:DOCKER_REQUIRED_MOUNTS -ErrorAction SilentlyContinue; Stop-Fake $base }
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
            # On the phone the view's content lives in dockerd's namespace and the global mount-point dir
            # is empty; the stub mounts write into the dir, so empty it to match.
            Get-ChildItem (Join-Path $base 'newroot') | Remove-Item -Recurse -Force
            $down = Invoke-Sh $base 'docker-down.sh'
            $down.Code | Should -Be 0 -Because $down.Output
            $down.Output | Should -Match 'dockerd down'
            Test-Path (Join-Path $base 'run/docker.pid') | Should -BeFalse
            Test-Path (Join-Path $base 'run/docker.sock') | Should -BeFalse
            # nothing of the root view survives a stop: mountpoint dir and upper are gone
            Test-Path (Join-Path $base 'newroot') | Should -BeFalse
            Test-Path (Join-Path $base 'ov') | Should -BeFalse
            (& bash -c "kill -0 $dockerPid 2>/dev/null; echo `$?") | Should -Not -Be '0'
            $again = Invoke-Sh $base 'docker-down.sh'
            $again.Code | Should -Be 0
            $again.Output | Should -Match 'not running'
        } finally { Stop-Fake $base }
    }
}

Describe 'docker-probe-root.sh' {
    It 'builds the root view in a throwaway namespace, reports PASS and leaves nothing behind' {
        $base = New-FakePhone
        Remove-Item (Join-Path $base 'bin/dockerd')   # the stub would idle forever; the probe skips a missing binary
        $env:DOCKER_PROBE_PLUGIN_DIR = ToSh (Join-Path $base 'fs/plugins')   # the stub chroot keeps the host root
        $env:DOCKER_PROBE_PATHS = ToSh (Join-Path $base 'fs/data')
        # a real start's dirs exist (as mounts) in the fake mountinfo; the probe must not write into them
        New-Item -ItemType Directory -Path (Join-Path $base 'newroot'), (Join-Path $base 'ov') | Out-Null
        try {
            $r = Invoke-Sh $base 'docker-probe-root.sh'
            $r.Code | Should -Be 0 -Because $r.Output
            $r.Output | Should -Match 'PROBE RESULT: PASS'
            $r.Output | Should -Match 'overlay of / mounted'
            $r.Output | Should -Match 'mkdir /run/docker/plugins .*OK'
            # dockerd is never started and the real start's directories are untouched
            Test-Path (Join-Path $base 'dockerd.args') | Should -BeFalse
            @(Get-ChildItem (Join-Path $base 'newroot'), (Join-Path $base 'ov') -Force).Count | Should -Be 0
            Test-Path (Join-Path $base 'probe-ov') | Should -BeFalse
            # On the phone probe-root is an empty dir in the global view and is removed; the stub
            # keeps its mkdir results in it, but it must hold no files (only the dirs the stubs made).
            @(Get-ChildItem (Join-Path $base 'probe-root') -Recurse -File -ErrorAction SilentlyContinue).Count | Should -Be 0
        } finally {
            Remove-Item Env:DOCKER_PROBE_PLUGIN_DIR, Env:DOCKER_PROBE_PATHS -ErrorAction SilentlyContinue
            Stop-Fake $base
        }
    }

    It 'reports FAIL and exits non-zero when the overlay is refused' {
        $base = New-FakePhone -RootOverlayRc '1'
        try {
            $r = Invoke-Sh $base 'docker-probe-root.sh'
            $r.Code | Should -Not -Be 0
            $r.Output | Should -Match 'PROBE RESULT: FAIL'
            Test-Path (Join-Path $base 'probe-ov') | Should -BeFalse
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
