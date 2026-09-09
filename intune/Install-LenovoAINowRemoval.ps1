# Win32 app install wrapper for the Lenovo AI Now removal script.
#
# Intune Win32 apps need three things the raw uninstall.ps1 does not provide:
#   1. A detection signal, so the app reports Installed once cleanup is done.
#   2. A real 3010 exit when cleanup is queued for the next boot, instead of
#      uninstall.ps1's Intune-platform-script behaviour of collapsing 3010
#      into 0 (Win32 apps understand 3010 natively as "soft reboot").
#   3. A non-zero failure code Intune can surface (1603).
#
# uninstall.ps1 is shipped alongside this wrapper inside the .intunewin and is
# not modified; this wrapper only runs it and translates the result.
#
# Install command:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-LenovoAINowRemoval.ps1

[CmdletBinding()]
param(
    # Stamped into the detection key. Bump it to force a re-run on devices
    # that already ran an earlier package version.
    [string]$PackageVersion = '1.0.0'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$payload      = Join-Path $scriptRoot 'uninstall.ps1'
$logFolder    = 'C:\ProgramData\Microsoft\IntuneManagementExtension\Logs'
$logFile      = Join-Path $logFolder 'Lenovo_AI_Now_Win32.log'
$markerKey    = 'HKLM:\SOFTWARE\LenovoAINowRemoval'
$sentinelKey  = 'HKLM:\SOFTWARE\LenovoAINowRemediation'
$sessionMgr   = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'

function Write-Log {
    param(
        [Parameter(Position = 0)][string]$Message,
        [Parameter(Position = 1)][ValidateSet('INFO', 'WARNING', 'ERROR')][string]$Level = 'INFO'
    )
    $entry = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $entry
    try { Add-Content -Path $logFile -Value $entry -ErrorAction Stop } catch { }
}

function Test-RebootQueued {
    # uninstall.ps1 writes the Phase A sentinel only when it queued files via
    # PendingFileRenameOperations. Requiring a live Lenovo PFRO entry as well
    # keeps a stale sentinel from being read as "reboot pending" forever.
    if (-not (Test-Path -Path $sentinelKey)) { return $false }
    try {
        $null = Get-ItemPropertyValue -Path $sentinelKey -Name 'PhaseAComplete' -ErrorAction Stop
    } catch {
        return $false
    }
    try {
        $pfro = @(Get-ItemPropertyValue -Path $sessionMgr -Name 'PendingFileRenameOperations' -ErrorAction Stop)
    } catch {
        return $false
    }
    return [bool]($pfro | Where-Object { $_ -match '(?i)lenovo' })
}

function Set-DetectionMarker {
    param([Parameter(Mandatory = $true)][int]$Result)
    try {
        if (-not (Test-Path -Path $markerKey)) { New-Item -Path $markerKey -Force -ErrorAction Stop | Out-Null }
        New-ItemProperty -Path $markerKey -Name 'Version'   -Value $PackageVersion -PropertyType String -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -Path $markerKey -Name 'RemovedOn' -Value ((Get-Date).ToUniversalTime().ToString('o')) -PropertyType String -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -Path $markerKey -Name 'Result'    -Value $Result -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        Write-Log "Detection marker written: $markerKey Version=$PackageVersion Result=$Result"
        return $true
    } catch {
        Write-Log "Failed to write detection marker: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

if (-not (Test-Path $logFolder)) { New-Item -ItemType Directory -Path $logFolder -Force | Out-Null }

Write-Log "=== Lenovo AI Now removal, Win32 wrapper $PackageVersion ==="

if (-not (Test-Path -Path $payload)) {
    Write-Log "Payload not found next to wrapper: $payload" 'ERROR'
    exit 1603
}

# Prefer the native 64-bit host explicitly. uninstall.ps1 has its own SysNative
# relaunch guard, but calling the 64-bit host directly avoids the extra hop.
$psHost = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
if ($env:PROCESSOR_ARCHITECTURE -eq 'x86' -and (Test-Path "$env:WINDIR\SysNative\WindowsPowerShell\v1.0\powershell.exe")) {
    $psHost = "$env:WINDIR\SysNative\WindowsPowerShell\v1.0\powershell.exe"
}

Write-Log "Running payload: $payload"
$proc = Start-Process -FilePath $psHost `
    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$payload`"") `
    -Wait -PassThru -WindowStyle Hidden
$payloadExit = $proc.ExitCode
Write-Log "Payload exit code: $payloadExit"

# The payload reports 0 for both "clean" and "reboot required"; the sentinel plus
# a live Lenovo PFRO entry is what distinguishes the two.
if (Test-RebootQueued) {
    Write-Log 'Cleanup queued for next boot; reporting 3010 (soft reboot).'
    if (-not (Set-DetectionMarker -Result 3010)) { exit 1603 }
    exit 3010
}

if ($payloadExit -eq 0) {
    Write-Log 'Removal complete; reporting 0.'
    if (-not (Set-DetectionMarker -Result 0)) { exit 1603 }
    exit 0
}

Write-Log "Removal failed (payload exit $payloadExit); reporting 1603. See Lenovo_AI_Now_Remediate.log for detail." 'ERROR'
exit 1603
