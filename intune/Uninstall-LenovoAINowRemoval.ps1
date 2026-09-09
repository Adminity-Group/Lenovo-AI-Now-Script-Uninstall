# Win32 app uninstall wrapper.
#
# Intune requires an uninstall command for every Win32 app. Lenovo AI Now is
# not reinstalled here -- "uninstalling" this app only drops the detection
# marker, so the app reports Not installed and a later assignment can run the
# cleanup again.
#
# Uninstall command:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-LenovoAINowRemoval.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$logFolder = 'C:\ProgramData\Microsoft\IntuneManagementExtension\Logs'
$logFile   = Join-Path $logFolder 'Lenovo_AI_Now_Win32.log'
$markerKey = 'HKLM:\SOFTWARE\LenovoAINowRemoval'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $entry = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $entry
    try { Add-Content -Path $logFile -Value $entry -ErrorAction Stop } catch { }
}

if (-not (Test-Path $logFolder)) { New-Item -ItemType Directory -Path $logFolder -Force | Out-Null }

Write-Log '=== Lenovo AI Now removal, Win32 wrapper uninstall ==='

try {
    if (Test-Path -Path $markerKey) {
        Remove-Item -Path $markerKey -Recurse -Force -ErrorAction Stop
        Write-Log "Detection marker removed: $markerKey"
    } else {
        Write-Log 'Detection marker already absent.'
    }
    exit 0
} catch {
    Write-Log "Failed to remove detection marker: $($_.Exception.Message)" 'ERROR'
    exit 1603
}
