# Optional custom detection script for the Win32 app.
#
# Use this instead of the simple registry detection rule when you want the app
# to report Installed only if the marker is present AND no live Lenovo AI Now
# traces remain (install directories, uninstall entry, or AppX package).
#
# Intune contract: write anything to stdout and exit 0 to mean "detected";
# write nothing and exit 0 to mean "not detected".
#
# Configure in Intune with:
#   Run script as 32-bit process on 64-bit clients: No
#   Enforce script signature check: No (unless signed)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'

$expectedVersion = '1.0.0'
$markerKey       = 'HKLM:\SOFTWARE\LenovoAINowRemoval'

# Strict-mode safe: read through Get-ItemPropertyValue in a try block rather
# than dotting into a possibly-null Get-ItemProperty result.
$version = $null
try { $version = Get-ItemPropertyValue -Path $markerKey -Name 'Version' -ErrorAction Stop } catch { }
if ($version -ne $expectedVersion) { exit 0 }

# Live traces that survive a completed run mean cleanup did not finish, so keep
# reporting Not installed and let Intune retry. Files renamed to
# *.tobedeleted are already queued for boot-time deletion and are ignored.
$installDirs = @(
    "$env:ProgramFiles\Lenovo\Lenovo AI Now",
    "${env:ProgramFiles(x86)}\Lenovo\Lenovo AI Now",
    "$env:ProgramData\Lenovo\Lenovo AI Now"
)
foreach ($dir in $installDirs) {
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    $live = @(Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '\.tobedeleted$' })
    if ($live.Count -gt 0) { exit 0 }
}

$uninstallRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)
foreach ($root in $uninstallRoots) {
    if (-not (Test-Path -Path $root)) { continue }
    foreach ($child in Get-ChildItem -Path $root -ErrorAction SilentlyContinue) {
        $displayName = $null
        try { $displayName = Get-ItemPropertyValue -Path $child.PSPath -Name 'DisplayName' -ErrorAction Stop } catch { continue }
        if ($displayName -like '*Lenovo AI Now*') { exit 0 }
    }
}

$appx = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like '*AINow*' -or $_.Name -like '*AiNow*' }
if ($appx) { exit 0 }

Write-Output "Lenovo AI Now removal $expectedVersion applied"
exit 0
