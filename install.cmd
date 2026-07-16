@echo off
REM install.cmd — Windows launcher for nimbus.
REM
REM Prefers `pwsh` (PowerShell 7+, default 4GB+ managed heap) over
REM `powershell` (Windows PowerShell 5.x, 1.0G managed-heap cap) because
REM `docker compose pull` of the multi-arch OCI images streams enough
REM layer-pull progress to blow the 1.0G cap, surfacing the error
REM `Maximum memory usage (1.0G) was exceeded` before the OCI error
REM underneath is visible. PowerShell 7 has no such cap.
REM
REM Falls back to `powershell` for users without pwsh installed (the
REM common case on Windows Server 2016/2019, pre-installed
REM PowerShell-5.x-only environments, etc.). If neither is on PATH,
REM prints a clear error and exits non-zero so the user knows what
REM to install instead of silently doing nothing.
REM
REM The 1.0.0 release shipped with the old `powershell` hardcode and
REM this is the install-side fix. See
REM tests/install/install-pwsh.bats for the contract.

echo Installing Nimbus for Windows...
where pwsh >nul 2>nul && (
    pwsh -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/Yoodule/nimbus/main/install.ps1 | iex"
    exit /b %ERRORLEVEL%
)
where powershell >nul 2>nul && (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/Yoodule/nimbus/main/install.ps1 | iex"
    exit /b %ERRORLEVEL%
)
echo Error: neither pwsh (PowerShell 7) nor powershell (Windows PowerShell 5.x) was found on PATH. 1>&2
echo Install PowerShell 7 from https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows and retry. 1>&2
exit /b 1
