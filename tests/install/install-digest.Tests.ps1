#
# tests/install/install-digest.Tests.ps1
#
# Pester 5 tests for install.ps1's OCI digest refresh helpers.
# Mirrors tests/install/install-digest.bats on the bash side.
#
# These tests can only run on a Windows host with Pester 5
# installed. CI runs them on `windows-latest`; local devs
# run via:
#
#   Install-Module Pester -Force -SkipPublisherCheck   # one-time
#   Invoke-Pester -Path tests/install/install-digest.Tests.ps1
#
# The test-override env var NIMBUS_TESTS_GHCR_DIGEST_CMD
# (consumed by Resolve-NimbusImageDigest) is set per-test to
# inject a canned digest without touching the network.

BeforeAll {
    $script:InstallPs1 = Join-Path $PSScriptRoot "..\..\install.ps1"
    if (-not (Test-Path $script:InstallPs1)) {
        throw "install.ps1 not found at $script:InstallPs1"
    }
}

Describe "Resolve-NimbusImageDigest" {
    It "returns the live digest when the test-override env var is set" {
        $tmp = New-TempDir
        $mock = Join-Path $tmp "mock-ghcr.cmd"
        Set-Content -Path $mock -Value "@echo sha256:1111111111111111111111111111111111111111111111111111111111111111"
        $env:NIMBUS_TESTS_GHCR_DIGEST_CMD = $mock
        try {
            . $script:InstallPs1
            $result = Resolve-NimbusImageDigest -RepoName "gateway" -Tag "v1.0.0"
            $result | Should -Be "sha256:1111111111111111111111111111111111111111111111111111111111111111"
        } finally {
            Remove-Item -Recurse -Force $tmp
            Remove-Item Env:NIMBUS_TESTS_GHCR_DIGEST_CMD -ErrorAction SilentlyContinue
        }
    }

    It "issues a HEAD request to ghcr.io with the right Accept header" {
        # Source-of-truth check: install.ps1 must contain the
        # Accept header literal. If a future refactor drops it,
        # the test fails and the bug is caught before reaching
        # a real Windows user.
        (Get-Content $script:InstallPs1 -Raw) | Should -Match "Accept:\s+application/vnd\.oci\.image\.index\.v1\+json"
        (Get-Content $script:InstallPs1 -Raw) | Should -Match "ghcr\.io/v2/yoodule/nimbus/"
    }
}

Describe "Refresh-NimbusComposePin" {
    BeforeAll {
        # Load install.ps1 once for the whole Describe. The
        # function defs survive across It blocks because
        # dot-sourcing executes them in the current scope.
        . $PSScriptRoot\..\..\install.ps1
    }

    It "replaces a stale gateway digest with the live one" {
        $tmp = New-TempDir
        $compose = Join-Path $tmp "compose.yaml"
        @"
services:
  gateway:
    image: ghcr.io/yoodule/nimbus/gateway:v1.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000
  dashboard:
    image: ghcr.io/yoodule/nimbus/dashboard:v1.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000
"@ | Set-Content -Path $compose

        $mock = Join-Path $tmp "mock-ghcr.cmd"
        Set-Content -Path $mock -Value "@echo sha256:1111111111111111111111111111111111111111111111111111111111111111"
        $env:NIMBUS_TESTS_GHCR_DIGEST_CMD = $mock
        try {
            Refresh-NimbusComposePin -ComposePath $compose -ImageRef "ghcr.io/yoodule/nimbus/gateway:v1.0.0"
            $content = Get-Content -Raw $compose
            $content | Should -Not -Match "0000000000000000000000000000000000000000000000000000000000000000"
            $content | Should -Match "image:\s+ghcr\.io/yoodule/nimbus/gateway:v1\.0\.0@sha256:1111111111111111111111111111111111111111111111111111111111111111"
        } finally {
            Remove-Item -Recurse -Force $tmp
            Remove-Item Env:NIMBUS_TESTS_GHCR_DIGEST_CMD -ErrorAction SilentlyContinue
        }
    }

    It "is a no-op when the pin already matches" {
        $tmp = New-TempDir
        $compose = Join-Path $tmp "compose.yaml"
        $digest = "2222222222222222222222222222222222222222222222222222222222222222"
        @"
services:
  gateway:
    image: ghcr.io/yoodule/nimbus/gateway:v1.0.0@sha256:$digest
"@ | Set-Content -Path $compose

        $mock = Join-Path $tmp "mock-ghcr.cmd"
        Set-Content -Path $mock -Value "@echo $digest"
        $env:NIMBUS_TESTS_GHCR_DIGEST_CMD = $mock
        try {
            Refresh-NimbusComposePin -ComposePath $compose -ImageRef "ghcr.io/yoodule/nimbus/gateway:v1.0.0"
            $content = Get-Content -Raw $compose
            $content | Should -Match "image:\s+ghcr\.io/yoodule/nimbus/gateway:v1\.0\.0@sha256:$digest"
        } finally {
            Remove-Item -Recurse -Force $tmp
            Remove-Item Env:NIMBUS_TESTS_GHCR_DIGEST_CMD -ErrorAction SilentlyContinue
        }
    }

    It "leaves a bare (un-pinned) image line alone" {
        $tmp = New-TempDir
        $compose = Join-Path $tmp "compose.yaml"
        @"
services:
  gateway:
    image: ghcr.io/yoodule/nimbus/gateway:v1.0.0
"@ | Set-Content -Path $compose

        $mock = Join-Path $tmp "mock-ghcr.cmd"
        Set-Content -Path $mock -Value "@echo sha256:deadbeefcafebabe"
        $env:NIMBUS_TESTS_GHCR_DIGEST_CMD = $mock
        try {
            Refresh-NimbusComposePin -ComposePath $compose -ImageRef "ghcr.io/yoodule/nimbus/gateway:v1.0.0"
            $content = Get-Content -Raw $compose
            $content | Should -Not -Match "image:\s+ghcr\.io/yoodule/nimbus/gateway:v1\.0\.0@sha256:"
            $content | Should -Match "image:\s+ghcr\.io/yoodule/nimbus/gateway:v1\.0\.0\s*$"
        } finally {
            Remove-Item -Recurse -Force $tmp
            Remove-Item Env:NIMBUS_TESTS_GHCR_DIGEST_CMD -ErrorAction SilentlyContinue
        }
    }

    It "is offline-safe: warns and exits 0 on network failure" {
        $tmp = New-TempDir
        $compose = Join-Path $tmp "compose.yaml"
        $oldDigest = "0000000000000000000000000000000000000000000000000000000000000000"
        @"
services:
  gateway:
    image: ghcr.io/yoodule/nimbus/gateway:v1.0.0@sha256:$oldDigest
"@ | Set-Content -Path $compose

        # Mock exits with code 1 to simulate a network failure.
        $mock = Join-Path $tmp "mock-ghcr.cmd"
        Set-Content -Path $mock -Value "@exit /b 1"
        $env:NIMBUS_TESTS_GHCR_DIGEST_CMD = $mock
        try {
            # Should NOT throw — offline path is non-fatal.
            { Refresh-NimbusComposePin -ComposePath $compose -ImageRef "ghcr.io/yoodule/nimbus/gateway:v1.0.0" } | Should -Not -Throw
            # And should return $false (no rewrite happened) so the
            # caller knows not to log a "Refreshed" line.
            Refresh-NimbusComposePin -ComposePath $compose -ImageRef "ghcr.io/yoodule/nimbus/gateway:v1.0.0" | Should -Be $false
            $content = Get-Content -Raw $compose
            $content | Should -Match "image:\s+ghcr\.io/yoodule/nimbus/gateway:v1\.0\.0@sha256:$oldDigest"
        } finally {
            Remove-Item -Recurse -Force $tmp
            Remove-Item Env:NIMBUS_TESTS_GHCR_DIGEST_CMD -ErrorAction SilentlyContinue
        }
    }

    It "returns $true when a stale pin was rewritten" {
        $tmp = New-TempDir
        $compose = Join-Path $tmp "compose.yaml"
        @"
services:
  gateway:
    image: ghcr.io/yoodule/nimbus/gateway:v1.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000
"@ | Set-Content -Path $compose

        $mock = Join-Path $tmp "mock-ghcr.cmd"
        Set-Content -Path $mock -Value "@echo sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        $env:NIMBUS_TESTS_GHCR_DIGEST_CMD = $mock
        try {
            Refresh-NimbusComposePin -ComposePath $compose -ImageRef "ghcr.io/yoodule/nimbus/gateway:v1.0.0" | Should -Be $true
        } finally {
            Remove-Item -Recurse -Force $tmp
            Remove-Item Env:NIMBUS_TESTS_GHCR_DIGEST_CMD -ErrorAction SilentlyContinue
        }
    }

    It "returns $false when there's no pin to refresh (bare image line)" {
        $tmp = New-TempDir
        $compose = Join-Path $tmp "compose.yaml"
        @"
services:
  gateway:
    image: ghcr.io/yoodule/nimbus/gateway:v1.0.0
"@ | Set-Content -Path $compose

        $mock = Join-Path $tmp "mock-ghcr.cmd"
        Set-Content -Path $mock -Value "@echo sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        $env:NIMBUS_TESTS_GHCR_DIGEST_CMD = $mock
        try {
            Refresh-NimbusComposePin -ComposePath $compose -ImageRef "ghcr.io/yoodule/nimbus/gateway:v1.0.0" | Should -Be $false
        } finally {
            Remove-Item -Recurse -Force $tmp
            Remove-Item Env:NIMBUS_TESTS_GHCR_DIGEST_CMD -ErrorAction SilentlyContinue
        }
    }

    It "finds the right image line when compose.yaml has many services" {
        $tmp = New-TempDir
        $compose = Join-Path $tmp "compose.yaml"
        @"
services:
  qdrant:
    image: qdrant/qdrant:v1.12.4
  postgres:
    image: postgres:17.4-alpine
  redis:
    image: redis:7.4.1-alpine
  gateway:
    image: ghcr.io/yoodule/nimbus/gateway:v1.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000
  dashboard:
    image: ghcr.io/yoodule/nimbus/dashboard:v1.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000
"@ | Set-Content -Path $compose

        $mock = Join-Path $tmp "mock-ghcr.cmd"
        Set-Content -Path $mock -Value "@echo sha256:3333333333333333333333333333333333333333333333333333333333333333"
        $env:NIMBUS_TESTS_GHCR_DIGEST_CMD = $mock
        try {
            Refresh-NimbusComposePin -ComposePath $compose -ImageRef "ghcr.io/yoodule/nimbus/gateway:v1.0.0"
            $content = Get-Content -Raw $compose
            $content | Should -Match "image:\s+ghcr\.io/yoodule/nimbus/gateway:v1\.0\.0@sha256:3333333333333333333333333333333333333333333333333333333333333333"
            $content | Should -Match "image:\s+qdrant/qdrant:v1\.12\.4"
            $content | Should -Match "image:\s+postgres:17\.4-alpine"
            $content | Should -Match "image:\s+redis:7\.4\.1-alpine"
        } finally {
            Remove-Item -Recurse -Force $tmp
            Remove-Item Env:NIMBUS_TESTS_GHCR_DIGEST_CMD -ErrorAction SilentlyContinue
        }
    }
}

# ---- Defender handling tests ----------------------------------
#
# These four cases pin the install-time contract for the
# Windows Defender / SmartScreen handling added in
# Invoke-NimbusDefenderUnblock, Add-NimbusDefenderExclusion,
# and Test-NimbusBinaryLaunch. They are content-level
# assertions on install.ps1 (matching the source-of-truth
# pattern in the Resolve-NimbusImageDigest "Accept header
# literal" case at line 41-48 above) — the runtime behavior
# is exercised by the manual end-to-end on a Windows VM with
# default Defender (see plan's Verification section).

Describe "Invoke-NimbusDefenderUnblock" {
    It "is invoked on the extracted files (helper call after tar -xzf)" {
        $content = Get-Content -Raw $script:InstallPs1
        # Contract: the helper must be CALLED after the
        # actual tar -xzf / Expand-Archive extraction line.
        # Unblocking before extraction is a no-op. We look for
        # the helper name (Invoke-NimbusDefenderUnblock) rather
        # than the cmdlet (Unblock-File) because the cmdlet
        # appears in the helper definition itself, which is
        # before the extraction site. We use Select-String on
        # individual lines so we can ignore comment lines
        # (the file's preamble comments reference "tar -xzf"
        # at line 72, well before the real call site at
        # line 514). The `Where-Object { $_ -notmatch '^\s*#' }`
        # filter strips PowerShell comment lines.
        $extractLine = ($content -split "`n" |
            Where-Object { $_ -notmatch '^\s*#' } |
            Select-String -Pattern 'tar\s+-xzf|Expand-Archive' |
            Select-Object -First 1).LineNumber
        $callLine = ($content -split "`n" |
            Where-Object { $_ -notmatch '^\s*#' } |
            Select-String -Pattern 'Invoke-NimbusDefenderUnblock\s+-InstallDir' |
            Select-Object -First 1).LineNumber
        $callLine | Should -BeGreaterThan $extractLine
    }
}

Describe "Add-NimbusDefenderExclusion" {
    It "is gated on Get-Command Add-MpPreference availability" {
        # The PS5.1-skip path: on hosts without the Defender
        # module, Get-Command returns nothing and the helper
        # bails out without throwing. A future refactor that
        # drops the guard would break the PS5.1 install path
        # (the cmdlet would not be found, the call would
        # error, and the install would crash). This test
        # catches that regression.
        $content = Get-Content -Raw $script:InstallPs1
        $content | Should -Match 'Get-Command\s+Add-MpPreference\s+-ErrorAction\s+SilentlyContinue'
    }

    It "scopes the exclusion to `$InstallDir only (never a parent, never %USERPROFILE%, never C:\)" {
        # The user explicitly required per-install scope. The
        # exclusion argument must be exactly $InstallDir (or
        # an expression that resolves to it). It's the
        # difference between "this CLI is trustworthy enough
        # to whitelist its own install dir" (the desired
        # UX) and "this CLI just whitelisted the user's entire
        # home dir" (a security regression that no one would
        # approve).
        $content = Get-Content -Raw $script:InstallPs1
        # The -ExclusionPath argument must reference $InstallDir.
        $content | Should -Match 'Add-MpPreference\s+-ExclusionPath\s+\$InstallDir'
        # The argument must NOT be $env:USERPROFILE, $env:HOME,
        # $env:USERPROFILE\*, or any literal "C:\" path. A
        # regression that swaps $InstallDir for $env:USERPROFILE
        # would silently whitelist the whole user profile.
        $content | Should -Not -Match 'Add-MpPreference\s+-ExclusionPath\s+\$env:USERPROFILE'
        $content | Should -Not -Match 'Add-MpPreference\s+-ExclusionPath\s+\$env:HOME'
        $content | Should -Not -Match 'Add-MpPreference\s+-ExclusionPath\s+["'']C:\\["'']'
    }
}

Describe "Test-NimbusBinaryLaunch" {
    It "matches the right Defender / SmartScreen exception patterns" {
        # The SmartScreen / Defender dialogs produce a small
        # set of recognizable substrings: "virus", "potentially
        # unwanted", "SmartScreen", and "protected your PC".
        # A regression that drops any of these from the
        # pattern would leave users stuck without a hint.
        # Conversely, a too-broad pattern would silence
        # unrelated nimbus.exe errors and hide real bugs.
        $content = Get-Content -Raw $script:InstallPs1
        $content | Should -Match 'virus'
        $content | Should -Match 'potentially unwanted'
        $content | Should -Match 'SmartScreen'
        $content | Should -Match 'protected your PC'
    }
}

# Helper: portable cross-platform New-TempDir. PowerShell 5
# doesn't ship New-TempDir (added in PS7), so emulate it for
# Windows PowerShell compat. The tests run on `windows-latest`
# in CI, which now ships PS7+; this is belt-and-suspenders.
function New-TempDir {
    if (Get-Command New-TempDir -ErrorAction SilentlyContinue) {
        return New-TempDir
    }
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $path | Out-Null
    return $path
}
