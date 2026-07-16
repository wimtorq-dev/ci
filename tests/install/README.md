# Nimbus install tests

Test-driven coverage for `install.sh` / `install.ps1` / `install.cmd`.

## What's tested

- `tests/install/install-digest.bats` — bash-side OCI digest refresh
  (rewrites a stale `image: …/gateway:v1.0.0@sha256:OLD` pin in
  the extracted `compose.yaml` to the live digest from ghcr.io) +
  the `refresh_all_compose_pins` orchestrator that prints the
  user-visible "Refreshed X pin to sha256:…" log line.
- `tests/install/install-pwsh.bats` — `install.cmd` chooses `pwsh` over
  `powershell` when both are on PATH, falls back gracefully
- `tests/install/install-digest.Tests.ps1` — same digest-refresh
  contract on the PowerShell side (Pester 5, runs on Windows CI).
  Covers the boolean return contract (`$true` = rewrite happened,
  `$false` = file untouched) that the orchestrator uses to decide
  whether to log. Also covers the install-time Windows Defender
  contract: `Invoke-NimbusDefenderUnblock` is called after the
  `tar -xzf` block, `Add-NimbusDefenderExclusion` is gated on
  `Get-Command Add-MpPreference` and scoped to `$InstallDir` only
  (never `$env:USERPROFILE`, never `C:\`), and
  `Test-NimbusBinaryLaunch` matches the right
  Defender/SmartScreen exception patterns to surface a "click
  More info → Run anyway" hint on first-run block.

## Running

### Bats (macOS / Linux)

```bash
brew install bats-core    # one-time
bats tests/install/install-digest.bats tests/install/install-pwsh.bats
```

### Pester (Windows)

```powershell
Install-Module Pester -Force -SkipPublisherCheck   # one-time
Invoke-Pester -Path tests/install/install-digest.Tests.ps1
```

## Why these tests exist

Three real bugs shipped with v1.0.0:

1. The release tarball's `compose.yaml` carries an OCI digest
   pin that goes stale when v1.0.0 is re-pushed. `docker compose
   pull` 404s on the old digest and surfaces a misleading
   `no match for platform in manifest list entries` error.
2. `install.cmd` shells to `powershell -NoProfile` (Windows
   PowerShell 5.x) which has a 1.0 GB managed-heap cap. Pulling
   the multi-arch gateway + dashboard + qdrant + redis +
   postgres images through the parent's stdout pipe blows the
   cap and the install dies with `Maximum memory usage (1.0G)
   was exceeded` before the OCI error becomes visible.
3. The first real Windows user hit
   `Operation did not complete successfully because the file
   contains a virus or potentially unwanted software` on first
   `nimbus.exe` exec after `irm | iex`. The cause: Windows
   Defender real-time scan + Mark-of-the-Web on the freshly
   extracted binary. nimbus doesn't sign its Windows binary
   (no cert procurement), and a fresh unsigned binary has no
   SmartScreen reputation. The install-time fix is
   `Unblock-File` on the extracted files (clears the
   Zone.Identifier stream) + a per-install
   `Add-MpPreference -ExclusionPath $InstallDir` (so first
   `nimbus start` lands cleanly), with a
   `Test-NimbusBinaryLaunch` probe that surfaces a
   "click More info → Run anyway" hint if SmartScreen still
   blocks the exec. The exclusion is per-install
   (`$InstallDir` only) — never a parent path, never
   `%USERPROFILE%`, never `C:\`.

These tests pin the contract for the install-side fixes: every
install call (curl|bash on Mac/Linux, `irm|iex` on Windows) must
end with a `compose.yaml` whose gateway + dashboard pins match
the live v1.0.0 index, on Windows the install must run under
`pwsh` (PowerShell 7) when available, and the install-time
Defender handling must clear the Mark-of-the-Web + add a
per-install exclusion + surface a SmartScreen hint when
appropriate.

## Layout

The install tests live in `tests/install/` rather than `tests/`
so they don't collide with the Python pytest suite in the
parent `tests/` directory. CI gets a separate `install-tests`
job that runs bats + Pester and does NOT require Python deps.
