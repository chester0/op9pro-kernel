# op9pro-kernel's tests, for dotfiles' bin\test-all.ps1 (run it from anywhere in this repo).
# 2026-10-30: thin/tests/build.Tests.ps1 checks that thin/build.sh refuses a wrong pin. It drives WSL (offline fixture,
# no kernel, no container), so it is cheap; the real build is a manual run (thin/README.md), not a test.
@{ Tests = @(
    @{ Glob = 'thin/tests/*.Tests.ps1'; Phase = 'loop'; Run = 'pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0; exit [int]((Invoke-Pester -Path {0} -Output Minimal -PassThru).Result -ne ''Passed'')"' }
) }
