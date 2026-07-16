<#
.SYNOPSIS
Nimbus Installer - Windows Edition
Usage: irm https://raw.githubusercontent.com/Yoodule/nimbus/main/install.ps1 | iex
#>

$ErrorActionPreference = "Stop"
$Repo = "Yoodule/nimbus"
$InstallDir = if ($env:NIMBUS_HOME) { $env:NIMBUS_HOME } else { Join-Path $env:USERPROFILE ".nimbus" }

# Print the Nimbus brand mark as a **pre-baked stacked layout**:
# 26-line block-shading icon on top, 1 blank separator, 3-line
# text-block (wordmark / value prop / URL) centered within the
# 65-cell icon width, divider beneath — 31 rows total. Pre-baked
# by `nimbus-cli/build.rs` (writes `logo.banner`, copied to
# `release/banner.txt` by `scripts/release.sh`) and inlined into
# the literal-string heredoc below at release-build time (see
# the heredoc comment for the placeholder name). The runtime
# CLI's `print_banner` uses `banner::build_banner_lines` instead
# so it can pick layout by terminal width; the install banner is
# the brand's "best foot forward" — 65 cells, fixed, always
# renders the same shape.
#
# TTY gating: PowerShell doesn't have a portable equivalent to bash's
# `test -t 1`, and the `irm | iex` path means `$Host` here is the
# IEX pipeline host, not a real TTY. We just print the banner
# unconditionally — block-shading characters are valid output even
# when piped into a file (modern terminals and log scrapers preserve
# UTF-8 glyphs).
#
# The 2-space indent on each body line is baked into the file by
# build.rs (writes `logo.banner`) so the icon column-aligns with
# the 2-space-indented install text below (`  Preparing your
# environment...`).
$Banner = @'
  █████████████████████████████████████████████████████████████████
  █████████████████████████████████████████████████████████████████
  █████████████████████████████████████████████████████████████████
  █████████████████████████████████████████████████████████████████
  █████████████████████████████████████████████████████████████████
  █████████████████████████████████████████████████████████████████
  █████████████████████▒░▓█████████████████████████████████████████
  █████████████████████  ░███████████████████▓ ░███████████████████
  ████████████████▒░░░     ░░░▓███████████▓░░    ░▒████████████████
  ████████████████▓▓▒░     ░▒▓██████▓▓█████▓▒   ▒▓▓████████████████
  █████████████████████  ░█████████   ███████▓░▒███████████████████
  █████████████████████▒░▓████████▒   ▒████████████████████████████
  ███████████████████████████████░     ░███████████████████████████
  ███████████████████████████▓▒           ▒▓███████████████████████
  ██████████████████████░                       ░██████████████████
  █████████████████████████▓▒░             ░▒▓█████████████████████
  ██████████████████████████████▒       ▒██████████████████████████
  ████████████████████████████████░   ▒████████████████████████████
  █████████████████████████████████   █████████████████████████████
  █████████████████████████████████▓░▒█████████████████████████████
  █████████████████████████████████████████████████████████████████
  █████████████████████████████████████████████████████████████████
  █████████████████████████████████████████████████████████████████
  █████████████████████████████████████████████████████████████████
  █████████████████████████████████████████████████████████████████
  █████████████████████████████████████████████████████████████████
                                                                   
                     NIMBUS — Your 24/7 Employee
   One command. No sign-up. The unified semantic gateway for MCP.
                     https://nimbus.yoodule.com
  ─────────────────────────────────────────────────────────────────
'@
Write-Host ""
Write-Host $Banner

# --- OCI digest refresh helpers --------------------------------
# Used after `Expand-Archive` / `tar -xzf` to fix the stale
# `@sha256:…` pin in the extracted compose.yaml. The release
# tarball bakes the pin at release-build time, so any re-push
# of the same tag (e.g. a hotfix) makes the pin dangle. We HEAD
# the live index digest and rewrite the @sha256 suffix in-place.
#
# Mirrors install.sh's resolve_ghcr_digest + refresh_compose_pin
# pair. Functions are defined BEFORE the install pipeline so
# the Pester tests can dot-source install.ps1 and call them in
# isolation. Real installs reach them after the tarball is on
# disk (see call site after the extract).

# Resolve-NimbusImageDigest <repo-name> <tag>
#   Prints `sha256:<64hex>` of the live ghcr.io OCI image index
#   for `ghcr.io/yoodule/nimbus/<repo>:<tag>`. Returns 0 on
#   success, throws on network/HTTP failure.
#
# The Accept header `application/vnd.oci.image.index.v1+json`
# is REQUIRED: without it, ghcr returns 401 (it uses the Accept
# header to decide between a manifest, an index, and a manifest
# list — and treats the absence of the index Accept on the
# anonymous endpoint as unauthorized). This is a real bug we
# hit in v1.0.0 recut9 (project-release-v100-recut9.md).
#
# Test-override: when NIMBUS_TESTS_GHCR_DIGEST_CMD is set, the
# function runs the named command (via cmd.exe) and prints its
# stdout. The Pester tests use this to inject a canned digest
# without touching the network. Real installs never set this —
# only the Pester source-only path does.
function Resolve-NimbusImageDigest {
    param(
        [Parameter(Mandatory)][string]$RepoName,
        [Parameter(Mandatory)][string]$Tag
    )

    if ($env:NIMBUS_TESTS_GHCR_DIGEST_CMD) {
        $output = & cmd.exe /c $env:NIMBUS_TESTS_GHCR_DIGEST_CMD
        return $output
    }

    $url = "https://ghcr.io/v2/yoodule/nimbus/${RepoName}/manifests/${Tag}"
    $headers = @{
        Accept = "application/vnd.oci.image.index.v1+json"
    }

    try {
        # Use -Method Head + -Headers; -DisableKeepAlive is a
        # no-op for HEAD but matches install.sh's --no-keepalive
        # pattern; -PassThru lets us read .Headers from the
        # response object. -ErrorAction Stop forces a try/catch
        # on any 4xx/5xx (default would let it slide past the
        # try block).
        $response = Invoke-WebRequest -Uri $url -Method Head -Headers $headers -UseBasicParsing -ErrorAction Stop
        $digest = $response.Headers["Docker-Content-Digest"]
        if (-not $digest) {
            throw "no Docker-Content-Digest header in response"
        }
        return $digest
    } catch {
        Write-Host "Note: could not resolve live digest for ${RepoName}:${Tag} (offline?)" -ForegroundColor Yellow
        throw
    }
}

# Refresh-NimbusComposePin <compose.yaml-path> <image-ref>
#   Rewrites a `image: <image-ref>@sha256:OLD` line in the given
#   compose.yaml to `image: <image-ref>@sha256:NEW`, where NEW is
#   the current ghcr.io index digest for <image-ref>. Leaves
#   bare `image: <image-ref>` lines (no pin) untouched. Leaves
#   other services' image lines alone.
#
#   Returns:
#     $true  if a stale pin was found and rewritten (or the pin
#            was already current and the file was rewritten to
#            normalize it — the caller's "did the hex change?"
#            check is what actually decides whether to log);
#     $false if the file was untouched (no pin to refresh, or
#            the digest lookup failed and we left the file
#            alone offline-safely).
#
#   This function does NOT print to the host — the caller
#   (Invoke-NimbusInstallPostExtract) formats the user-visible
#   log line. Keeping the function quiet makes the Pester unit
#   tests trivial: they assert on file content, not stdout.
function Refresh-NimbusComposePin {
    param(
        [Parameter(Mandatory)][string]$ComposePath,
        [Parameter(Mandatory)][string]$ImageRef
    )

    if (-not (Test-Path $ComposePath)) {
        return $false
    }

    # Pull the repo name and tag out of <image-ref> for the
    # ghcr.io lookup. We accept both `repo:tag` and the full
    # `ghcr.io/org/repo:tag` form.
    $refTail = $ImageRef.Split('/')[-1]
    $repo = $refTail.Split(':')[0]
    $tag = $refTail.Split(':')[1]

    try {
        $newDigest = Resolve-NimbusImageDigest -RepoName $repo -Tag $tag
    } catch {
        # Offline / registry hiccup: leave the pin as-is.
        return $false
    }

    # Normalize: tolerate callers (and the live registry) that
    # hand us a digest with or without the `sha256:` prefix.
    if ($newDigest.StartsWith("sha256:")) {
        $newHex = $newDigest.Substring(7)
    } else {
        $newHex = $newDigest
    }

    # Build the matching pattern: `image: <ImageRef>@sha256:<64hex>`.
    # Escape regex metacharacters in $ImageRef (slashes, colons,
    # dots). The pattern matches a whole line beginning with
    # optional leading whitespace.
    $escapedRef = [regex]::Escape($ImageRef)
    $pattern = "^(?<indent>\s*)image:\s+${escapedRef}@sha256:[0-9a-f]{64}"
    $replacement = '${indent}image: ' + $ImageRef + '@sha256:' + $newHex

    $content = Get-Content -Raw -Path $ComposePath
    $newContent = [regex]::Replace($content, $pattern, $replacement, 'Multiline')
    if ($newContent -eq $content) {
        # No match — the file's image line was bare or didn't
        # have a pin to refresh. Nothing to do.
        return $false
    }
    Set-Content -Path $ComposePath -Value $newContent -NoNewline
    return $true
}

# Invoke-NimbusInstallPostExtract
#   Orchestrates the post-extract digest refresh. Iterates the
#   known pinned repos (gateway, dashboard) and refreshes each
#   pin in $InstallDir\compose.yaml against the live
#   ghcr.io index. Safe to call when the compose.yaml or $Version
#   is missing (no-op). Mirrors the install.sh call site below
#   the `tar -xzf` step.
#
#   Prints a visible "Refreshed X pin to sha256:..." line on
#   success so the user can see the post-install digest refresh
#   actually ran. The line is conditional on the hex having
#   changed (a current install with a current pin stays quiet).
function Invoke-NimbusInstallPostExtract {
    if (-not $Version) { return }
    $tag = $Version.TrimStart('v')
    $composePath = Join-Path $InstallDir "compose.yaml"
    if (-not (Test-Path $composePath)) { return }

    foreach ($repoName in @("gateway", "dashboard")) {
        $imageRef = "ghcr.io/yoodule/nimbus/${repoName}:${tag}"

        # Snapshot the hex in the file BEFORE the refresh, so we
        # can show "Refreshed X pin from OLD to NEW" (and stay
        # silent when the pin was already current).
        $oldHex = $null
        $content = Get-Content -Raw -Path $composePath
        $matchPattern = "image:\s+${imageRef}@sha256:([0-9a-f]{64})"
        $m = [regex]::Match($content, $matchPattern)
        if ($m.Success) { $oldHex = $m.Groups[1].Value }

        $rewritten = Refresh-NimbusComposePin -ComposePath $composePath -ImageRef $imageRef
        if ($rewritten) {
            $newContent = Get-Content -Raw -Path $composePath
            $m2 = [regex]::Match($newContent, $matchPattern)
            if ($m2.Success) {
                $newHex = $m2.Groups[1].Value
                if ($oldHex -and ($oldHex -ne $newHex)) {
                    Write-Host "  Refreshed ${repoName} pin to sha256:$($newHex.Substring(0,12))… (was stale $($oldHex.Substring(0,12))…)" -ForegroundColor Blue
                }
            }
        }
    }
}

# --- Windows Defender handling helpers -------------------------
# A real Windows user hit this immediately after `irm | iex`:
#
#   Program 'nimbus.exe' failed to run: Operation did not complete
#   successfully because the file contains a virus or potentially
#   unwanted software.
#
# The fix is install-time, not signing. The release binary is
# unsigned (no cert procurement) and fresh binaries have no
# SmartScreen reputation. Windows Defender real-time scan trips
# on the freshly extracted `nimbus.exe` until we (a) clear the
# Mark-of-the-Web that Invoke-WebRequest set on the tarball, and
# (b) add a per-install Defender exclusion so first-run lands
# cleanly. Mirrors the install.sh side which has no Defender
# surface to handle.
#
# All three helpers are quiet on success — the caller formats
# the user-visible log line. This keeps the Pester unit tests
# trivial: they assert on file content / return value, not on
# stdout. Mirrors the Resolve-NimbusImageDigest / Refresh-NimbusComposePin
# pattern above.

# Invoke-NimbusDefenderUnblock <install-dir>
#   Clears the Mark-of-the-Web (Zone.Identifier alternate data
#   stream = 3, "downloaded from the internet") that
#   Invoke-WebRequest set on every file under $InstallDir. The
#   tar -xzf step preserves the stream from the tarball, so
#   the .exe lands on disk with the "internet zone" tag and
#   Defender's "downloaded from the internet" PUA branch fires
#   on first exec. Unblock-File silences that branch.
#
#   SmartScreen still warns on a fresh binary with no
#   reputation — this only neutralizes the Defender scan, not
#   the SmartScreen reputation dialog. For the latter, the
#   Test-NimbusBinaryLaunch helper below prints a "click More
#   info → Run anyway" hint when the dialog actually appears.
#
#   Returns:
#     $true  on success (or when there were no files to unblock);
#     $false on hard failure.
#
#   Test-override: NIMBUS_TESTS_DEFENDER_UNBLOCK_CMD, if set,
#   replaces the Unblock-File loop with a no-op. The Pester
#   tests use this to exercise the caller without touching the
#   filesystem. Real installs never set this.
function Invoke-NimbusDefenderUnblock {
    param(
        [Parameter(Mandatory)][string]$InstallDir
    )

    if ($env:NIMBUS_TESTS_DEFENDER_UNBLOCK_CMD) {
        # Tests have stubbed the unblock step out. Run the
        # named command and report $true to keep the caller
        # quiet.
        & cmd.exe /c $env:NIMBUS_TESTS_DEFENDER_UNBLOCK_CMD | Out-Null
        return $true
    }

    if (-not (Test-Path $InstallDir)) {
        return $false
    }

    try {
        Get-ChildItem -Path $InstallDir -Recurse -File -Force |
            ForEach-Object { Unblock-File -Path $_.FullName -ErrorAction SilentlyContinue }
        return $true
    } catch {
        return $false
    }
}

# Add-NimbusDefenderExclusion <install-dir>
#   Adds a Windows Defender real-time-scan exclusion scoped to
#   $InstallDir only. Never to a parent path, never to
#   %USERPROFILE%, never to C:\. The exclusion is the difference
#   between "user clicks through SmartScreen and it works" and
#   "user clicks through SmartScreen and Defender still kills
#   the .exe on the next launch."
#
#   Guarded by Get-Command Add-MpPreference so PS5.1 hosts
#   (which don't ship the Defender module) skip silently
#   instead of throwing on a missing cmdlet. On hosts that
#   have the cmdlet but lack elevation, the try/catch swallows
#   the failure and the caller logs a one-line yellow note.
#
#   Returns:
#     $true  if the exclusion was added;
#     $false if the cmdlet is unavailable, the user isn't
#            elevated, or $InstallDir doesn't exist.
#
#   Test-override: NIMBUS_TESTS_DEFENDER_EXCLUSION_CMD, if
#   set, replaces the Add-MpPreference call with a no-op (or
#   a deliberate failure for the offline-safety test). The
#   Pester tests use this to inject outcomes without needing
#   an elevated shell. Real installs never set this.
function Add-NimbusDefenderExclusion {
    param(
        [Parameter(Mandatory)][string]$InstallDir
    )

    if ($env:NIMBUS_TESTS_DEFENDER_EXCLUSION_CMD) {
        # Tests have stubbed the exclusion step. The named
        # command is expected to set %ERRORLEVEL%: 0 = success,
        # non-zero = simulated failure. PowerShell's `cmd.exe
        # /c` translates that into $LASTEXITCODE.
        & cmd.exe /c $env:NIMBUS_TESTS_DEFENDER_EXCLUSION_CMD | Out-Null
        return ($LASTEXITCODE -eq 0)
    }

    if (-not (Get-Command Add-MpPreference -ErrorAction SilentlyContinue)) {
        # PS5.1 + no Defender module — the cmdlet isn't there.
        return $false
    }

    if (-not (Test-Path $InstallDir)) {
        return $false
    }

    try {
        Add-MpPreference -ExclusionPath $InstallDir -ErrorAction Stop
        return $true
    } catch {
        # Non-elevated PowerShell → "Requested registry access
        # is not allowed." Swallow and let the caller log.
        return $false
    }
}

# Test-NimbusBinaryLaunch <binary-path>
#   Probes the freshly installed binary with `--version` to
#   catch the case where Windows Defender or SmartScreen
#   actually blocks the exec at runtime. Without this probe,
#   a user who hit the SmartScreen dialog would still see
#   `nimbus start` crash with the cryptic "file contains a
#   virus" message; with it, we surface a one-line hint
#   pointing them at the "More info → Run anyway" click.
#
#   Returns:
#     $null     if the binary launched cleanly (no hint needed);
#     a string  with the user-visible hint, if the exception
#               message matches the Defender/SmartScreen
#               pattern. The caller prints it in yellow.
#
#   Throws on any OTHER failure (binary missing, bad exit
#   code, etc.) — we don't want to silence unrelated errors.
#
#   Test-override: NIMBUS_TESTS_BINARY_LAUNCH_CMD, if set,
#   runs the named command instead of `& $BinaryPath --version`
#   and returns $null on exit-code 0 / hint string on
#   non-zero. Lets the Pester tests cover both branches
#   without an actual Defender dialog. Real installs never
#   set this.
function Test-NimbusBinaryLaunch {
    param(
        [Parameter(Mandatory)][string]$BinaryPath
    )

    if ($env:NIMBUS_TESTS_BINARY_LAUNCH_CMD) {
        & cmd.exe /c $env:NIMBUS_TESTS_BINARY_LAUNCH_CMD | Out-Null
        if ($LASTEXITCODE -eq 0) { return $null }
        return "Windows blocked nimbus.exe on first run. Click 'More info' -> 'Run anyway' in the dialog, then re-run this installer or invoke 'nimbus start' directly."
    }

    try {
        & $BinaryPath --version | Out-Null
        return $null
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match 'virus|potentially unwanted|SmartScreen|protected your PC') {
            return "Windows blocked nimbus.exe on first run. Click 'More info' -> 'Run anyway' in the dialog, then re-run this installer or invoke 'nimbus start' directly."
        }
        throw
    }
}

Write-Host "  Preparing your environment..."

# 1. System Check
# Note: Windows 11 ARM64 natively emulates x86_64 binaries. Since we do not
# currently build a native windows-arm64 target in release.sh, we fall back
# to windows-amd64 on ARM64 systems.
$Arch = "amd64"
$DetectArch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "amd64" }
$OsName = "windows"

if ($DetectArch -eq "arm64") {
    Write-Host "  Detecting system... Done ($OsName-$DetectArch -> falling back to amd64 emulation)" -ForegroundColor Blue
} else {
    Write-Host "  Detecting system... Done ($OsName-$Arch)" -ForegroundColor Blue
}

$IsSource = $false

# 2. Local-repo dev install: build the Rust CLI + sync gateway source
# into $InstallDir. Only works when run from a clone of the gateway
# repo (i.e. the dev's own machine), never from `irm | iex`.
if ((Test-Path "nimbus-cli/Cargo.toml") -and (Test-Path "src")) {
    Write-Host "  Local repository detected. Building CLI + installing from source..."
    if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }

    Write-Host "  Compiling nimbus (cargo build --release)... " -NoNewline
    Push-Location nimbus-cli
    try {
        cargo build --release | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "cargo build failed" }
    } finally {
        Pop-Location
    }
    Copy-Item "nimbus-cli/target/release/nimbus.exe" -Destination (Join-Path $InstallDir "nimbus.exe") -Force
    Write-Host "Done" -ForegroundColor Blue

    # Sync gateway source + servers + mcp.json so the CLI's
    # `start` can mount them into the container via compose.yaml's
    # dev bind mounts. The release compose.yaml doesn't need these
    # because the gateway image is self-contained.
    Write-Host "  Syncing gateway source... " -NoNewline
    $Items = @("src", "servers", "mcp.json", "pyproject.toml", "uv.lock", "docker", "compose.yaml")
    foreach ($i in $Items) {
        if (Test-Path $i) {
            Copy-Item $i -Destination $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host "Done" -ForegroundColor Blue

    $BinaryName = "nimbus.exe"
    $IsSource = $true
} else {
    # 2. Fetching Release
    Write-Host "  Fetching latest release... " -NoNewline
    $ReleaseUrl = "https://api.github.com/repos/$Repo/releases/latest"
    try {
        # Force TLS 1.2
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $ReleaseData = Invoke-RestMethod -Uri $ReleaseUrl -UseBasicParsing
    } catch {
        Write-Host "`n  Error: Failed to fetch release data from GitHub." -ForegroundColor Red
        exit 1
    }

    $Version = $ReleaseData.tag_name
    $Asset = $ReleaseData.assets | Where-Object { $_.name -match "$OsName-$Arch" -and $_.name -match "\.(tar\.gz|zip)$" } | Select-Object -First 1

    if (-not $Asset) {
        Write-Host "`n  Error: Platform not supported ($OsName-$Arch) in release $Version." -ForegroundColor Red
        Write-Host "  Please build from source: https://github.com/Yoodule/nimbus"
        exit 1
    }

    Write-Host $Version -ForegroundColor Blue

    # 3. Downloading
    Write-Host "  Downloading assets..."
    if (-not (Test-Path $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    }

    $TmpFile = Join-Path $env:TEMP $Asset.name
    Invoke-WebRequest -Uri $Asset.browser_download_url -OutFile $TmpFile -UseBasicParsing

    # 4. Extracting
    Write-Host "  Installing Nimbus... " -NoNewline
    if ($TmpFile -match "\.tar\.gz$") {
        # Windows 10+ natively supports tar
        tar -xzf $TmpFile -C $InstallDir
    } elseif ($TmpFile -match "\.zip$") {
        Expand-Archive -Path $TmpFile -DestinationPath $InstallDir -Force
    }
    Remove-Item $TmpFile -Force
    Write-Host "Success" -ForegroundColor Blue

    # 4.1 Refresh the OCI digest pin in the extracted compose.yaml.
    # Same rationale as the install.sh call site: the release
    # tarball's compose.yaml carries
    # `image: ghcr.io/yoodule/nimbus/gateway:vX.Y.Z@sha256:OLD`
    # (and the dashboard line beside it). If vX.Y.Z has been
    # re-pushed, the live index digest is NEW but the tarball
    # still bakes the OLD pin, and `docker compose pull` 404s
    # on the old digest. The fix is one HTTP HEAD against
    # ghcr.io per image and a sed-equivalent rewrite of the
    # @sha256:… suffix. Offline-safe: if the network call
    # fails, we log a warning and leave the pin as-is.
    Invoke-NimbusInstallPostExtract

    # 4.2 Clear the Mark-of-the-Web (Zone.Identifier = 3) that
    # Invoke-WebRequest set on every file in the extracted
    # tarball. Without this, Defender's "downloaded from the
    # internet" PUA branch fires on first nimbus.exe exec and
    # the user sees `Operation did not complete successfully
    # because the file contains a virus or potentially
    # unwanted software`. Unblock-File is a no-op on files
    # without the stream, so the dev path (which doesn't have
    # the stream at all because it uses Copy-Item) is safe to
    # call this on too.
    $Unblocked = Invoke-NimbusDefenderUnblock -InstallDir $InstallDir
    # Quiet on success — unblocking ~5 files is invisible to
    # the user. A future change could log the count, but the
    # current install is already busy with extraction lines.

    # 4.3 Add a per-install Defender real-time-scan exclusion.
    # Scoped to $InstallDir only — never a parent path, never
    # %USERPROFILE%, never C:\. On non-elevated PowerShell the
    # Add-MpPreference call throws ("Requested registry access
    # is not allowed") and the helper returns $false; we log a
    # one-line note and continue. On PS5.1 hosts (no Defender
    # module) the helper also returns $false. Either way the
    # user is no worse off than before this change — the
    # Test-NimbusBinaryLaunch probe below will print the
    # SmartScreen hint if needed.
    $Excluded = Add-NimbusDefenderExclusion -InstallDir $InstallDir
    if ($Excluded) {
        Write-Host "  Added Defender exclusion for $InstallDir" -ForegroundColor Blue
    } else {
        Write-Host "  Note: Defender exclusion skipped (run as admin? Or PS5.1 host?). Defender may scan on first run." -ForegroundColor Yellow
    }

    $IsSource = $false
}

# 4.5 First-run .env stub. Same logic as install.sh — write a stub
# $NIMBUS_HOME\.env on first install so `nimbus start` doesn't crash
# on a missing env file. Skip if the file already exists.
#
# We do NOT generate real values for any secret. Only structural
# defaults get non-empty values — the rest are empty placeholders
# the user can populate. Four keys (BETTER_AUTH_SECRET,
# QDRANT_API_KEY, NIMBUS_SERVICE_KEY, OPENROUTER_API_KEY) are
# intentionally OMITTED from this stub: the first three are
# auto-generated by `nimbus start` (or `nimbus env-init`) so the
# Better Auth dashboard sees a real, crypto-strong secret from
# first boot and the gateway↔dashboard service-key handshake has
# a value, and OPENROUTER_API_KEY is prompted for interactively
# on first start. Writing `KEY=` for any of them would
# short-circuit those paths because the lookup would find the
# key (with an empty value) and skip generation.
# The file is restricted to the current user (Windows equivalent
# of chmod 0600) because it WILL hold real secrets once populated.
$EnvFile = Join-Path $InstallDir ".env"
if (-not (Test-Path $EnvFile)) {
    $Stub = @'
# Nimbus runtime config — generated by install.ps1 on first install.
# Paste your real values into the empty fields, then run `nimbus start`.
# See https://nimbus.yoodule.com for the full list of integrations.

# --- Secrets (paste your real values) ---
# BETTER_AUTH_SECRET, QDRANT_API_KEY, and NIMBUS_SERVICE_KEY are
# auto-generated by `nimbus start` / `nimbus env-init` on first run.
# OPENROUTER_API_KEY is prompted for interactively on first start.
UPWORK_REDIRECT_URI=
UPWORK_CLIENT_ID=
NIMBUS_APPROVED=
EXA_API_KEY=
POLYGON_RPC_URL=
NIMBUS_USER_EMAIL=
NIMBUS_USER_NAME=
NIMBUS_API_KEY=
GITHUB_TOKEN=
CLOUDFLARE_API_TOKEN=
CLOUDFLARE_ZONE_ID=
NIMBUS_ADMIN_PASSWORD=
POLYMARKET_PRIVATE_KEY=
NIMBUS_RUN_MODE=
UPWORK_API_KEY_NAME=
UPWORK_ACCOUNT_TYPE=
UPWORK_CLIENT_SECRET=
NIMBUS_OPENROUTER_KEY=
UPWORK_PERMISSIONS=
MINISIGN_SECRET_KEY_FILE=
NOTION_TOKEN=

# --- Structural defaults (runtime needs these) ---
GATEWAY_PORT=8088
QDRANT_URL=http://qdrant:6333
EMBEDDING_MODEL=nvidia/llama-nemotron-embed-vl-1b-v2:free
NIMBUS_DOMAIN=localhost
NIMBUS_GATEWAY_URL=http://localhost:8088/mcp
'@
    # -NoNewline matters: without it PowerShell appends a trailing
    # CRLF that breaks the KEY=VALUE parser in
    # nimbus-cli/src/main.rs:load_env_file.
    Set-Content -Path $EnvFile -Value $Stub -Encoding UTF8 -NoNewline
    # Restrict to current user — same pattern as project-cli-config-file.md
    $Acl = Get-Acl $EnvFile
    $Acl.SetAccessRuleProtection($true, $false)
    $Rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $env:USERNAME, "FullControl", "Allow")
    $Acl.AddAccessRule($Rule)
    Set-Acl $EnvFile $Acl
    Write-Host "  Created $EnvFile — paste your API keys before first start"
}

# 5. Shell Setup
# (no-op wrapper needed: the dev branch above already dropped a real
# nimbus.exe at $InstallDir\nimbus.exe, so we use it as-is. The
# $IsSource flag is kept for any future code that branches on it.)
$FinalBinary = "nimbus.exe"

# Update User PATH if needed
$UserPath = [Environment]::GetEnvironmentVariable("PATH", "User")
if ($UserPath -notmatch [regex]::Escape($InstallDir)) {
    $NewPath = "$InstallDir;$UserPath"
    [Environment]::SetEnvironmentVariable("PATH", $NewPath, "User")
    # Also update current process so it works immediately
    $env:PATH = "$InstallDir;$env:PATH"
    Write-Host "  Added Nimbus to your User PATH"
}

# Add NIMBUS_HOME
if (-not [Environment]::GetEnvironmentVariable("NIMBUS_HOME", "User")) {
    [Environment]::SetEnvironmentVariable("NIMBUS_HOME", $InstallDir, "User")
    $env:NIMBUS_HOME = $InstallDir
}

Write-Host "`n  Nimbus is ready to go." -ForegroundColor Cyan
Write-Host "  Note: You may need to restart your terminal for PATH changes to take full effect.`n" -ForegroundColor DarkCyan

# 5.5 SmartScreen probe (release-install path only). Run the
# freshly-installed nimbus.exe with `--version` to catch the
# case where SmartScreen reputation / Defender runtime block
# the exec. If the binary actually fails to start with a
# Defender- or SmartScreen-pattern error message, print a
# one-line "click More info -> Run anyway" hint so the user
# knows what's blocking them and how to clear it. The dev
# branch is skipped — the just-built binary is known-good and
# the user's machine is the maintainer's own.
if (-not $IsSource) {
    $FinalBinaryPath = Join-Path $InstallDir "nimbus.exe"
    $Hint = Test-NimbusBinaryLaunch -BinaryPath $FinalBinaryPath
    if ($Hint) {
        Write-Host ""
        Write-Host "  $Hint" -ForegroundColor Yellow
        Write-Host ""
    }
}

# 6. Auto-start option
$Response = Read-Host "  Would you like to start Nimbus now? (y/N)"
if ($Response -match "^[Yy]$") {
    Write-Host "  Starting Nimbus..."
    Set-Location $InstallDir
    & ".\nimbus.exe" start
} else {
    Write-Host "  To start later, open a new PowerShell and type:"
    Write-Host "  nimbus start`n"
}
