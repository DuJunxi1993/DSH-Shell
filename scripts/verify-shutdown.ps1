<#
.SYNOPSIS
    Check that closing the dsh-shell window really released the dsh process.

.DESCRIPTION
    Read-only. This script never kills anything, by name or otherwise: it only
    inspects state and tells you what it found. See AGENTS.md rule 1 - a
    name-based kill (`taskkill /IM node.exe`) is what destroyed the previous
    agent's host process, and no verification helper has any business doing it.

    If a port is still held, the script prints the owning PID and its command
    line so you can decide what to do. Killing by that specific PID is safe;
    killing `node.exe` wholesale is not.

.EXAMPLE
    .\scripts\verify-shutdown.ps1
    .\scripts\verify-shutdown.ps1 -Port 3080
#>
param(
    [int]$Port = 3080,
    [int]$WaitSeconds = 10
)

$ErrorActionPreference = 'Continue'

Write-Host "[verify] waiting up to $WaitSeconds s for port $Port to be released..." -ForegroundColor Cyan

$deadline = (Get-Date).AddSeconds($WaitSeconds)
$listener = $null
while ((Get-Date) -lt $deadline) {
    $listener = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
    if (-not $listener) { break }
    Start-Sleep -Milliseconds 500
}

if ($listener) {
    $pid_ = $listener[0].OwningProcess
    Write-Host "[verify] FAIL: port $Port is still listening (PID $pid_)" -ForegroundColor Red

    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$pid_" -ErrorAction SilentlyContinue
    if ($proc) {
        Write-Host "[verify]   name        : $($proc.Name)" -ForegroundColor Yellow
        Write-Host "[verify]   parent PID  : $($proc.ParentProcessId)" -ForegroundColor Yellow
        Write-Host "[verify]   command line: $($proc.CommandLine)" -ForegroundColor Yellow
    }
    Write-Host "[verify] this is the contract dsh-shell promises to keep." -ForegroundColor Red
    Write-Host "[verify] If you must stop it, kill that one PID - never node.exe by name:" -ForegroundColor Red
    Write-Host "[verify]     Stop-Process -Id $pid_ -Force" -ForegroundColor DarkGray
    exit 1
}

Write-Host "[verify] OK: port $Port is free." -ForegroundColor Green

# Informational only. Listing processes is safe; the point is to notice whether
# anything dsh-shaped is still alive at all, not to act on it.
$dshLike = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -eq 'node.exe' -and $_.CommandLine -match '@deepseek-ai' }

if ($dshLike) {
    Write-Host "[verify] note: $($dshLike.Count) dsh process(es) still running (not necessarily ours):" -ForegroundColor Yellow
    $dshLike | ForEach-Object { Write-Host "[verify]   PID $($_.ProcessId)  $($_.CommandLine)" -ForegroundColor DarkGray }
} else {
    Write-Host "[verify] OK: no dsh process running." -ForegroundColor Green
}

exit 0
