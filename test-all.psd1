# op9pro-kernel's tests, for dotfiles' bin\test-all.ps1 (run it from anywhere in this repo).
# 2026-10-30: the Docker-on-the-phone tooling (tools/docker-*.sh, tools/push-docker.ps1) is tested offline:
# Pester 5 with a fake adb, and the shell scripts under Git's bash with stubbed mount/unshare/dockerd.
@{ Tests = @(
    @{ Glob = 'tests/*.Tests.ps1'; Phase = 'loop'; Run = 'pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0; exit [int]((Invoke-Pester -Path {0} -Output Minimal -PassThru).Result -ne ''Passed'')"' }
) }
