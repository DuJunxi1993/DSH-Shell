<#
verify-shutdown.ps1
==================
Manual verification helper for dsh-shell.

After you close the Tauri window, run this script. It checks:
1. No `dsh` process is left running.
2. The configured port is free.

Usage:
    .\scripts\verify-shutdown.ps1 [-Port 34247]
#>

param(
    [int]$Port = 34247,
    [int]$WaitSeconds = 8
)

$ErrorActionPreference = "Stop"

Write-Host "[verify] waiting up to $WaitSeconds s for dsh to exit..." -ForegroundColor Cyan
$dsh = $null
for ($i = 0; $i -lt $WaitSeconds; $i++) {
    $dsh = Get-Process -Name "dsh", "node" -ErrorAction SilentlyContinue |
           Where-Object { $_.MainWindowTitle -eq "" -and $_.Path -like "*deepseek*" }
    if (-not $dsh) { break }
    Start-Sleep -Seconds 1
}

if ($dsh) {
    Write-Host "[verify] FAIL: dsh still running:" -ForegroundColor Red
    $dsh | Format-Table Id, ProcessName, Path -AutoSize
    exit 1
} else {
    Write-Host "[verify] OK: no dsh process found." -ForegroundColor Green
}

$listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($listener) {
    Write-Host "[verify] FAIL: port $Port is still listening (PID=$($listener.OwningProcess))" -ForegroundColor Red
    exit 1
} else {
    Write-Host "[verify] OK: port $Port is free." -ForegroundColor Green
    exit 0
}
