Lenovo AI Now Removal -- Intune Win32 Package
=============================================

Packages the repo-root `uninstall.ps1` as an Intune Win32 app (`.intunewin`)
instead of a platform script, so the removal gets Win32 features that platform
scripts lack: a detection rule, retry on failure, native reboot handling,
requirement rules, and reporting per device.

Contents
--------

| File | Purpose |
|------|---------|
| `Install-LenovoAINowRemoval.ps1` | Install wrapper. Runs `uninstall.ps1`, writes the detection marker, translates the result to Win32 exit codes. |
| `Uninstall-LenovoAINowRemoval.ps1` | Uninstall wrapper. Removes the detection marker only; nothing is reinstalled. |
| `Detect-LenovoAINowRemoval.ps1` | Optional custom detection script (marker + no live Lenovo AI Now traces). |
| `output/Install-LenovoAINowRemoval.intunewin` | Build output, ready to upload (not tracked in git). |

Building
--------

Stage the payload -- both wrappers plus the repo-root `uninstall.ps1` -- into a
folder, then package that folder. Staging keeps `uninstall.ps1` a single copy in
the repo root instead of duplicating it under `intune\`.

```powershell
$staging = Join-Path $env:TEMP 'LenovoAINowRemoval'
New-Item -ItemType Directory -Path $staging -Force | Out-Null
Copy-Item .\uninstall.ps1, .\intune\Install-LenovoAINowRemoval.ps1, .\intune\Uninstall-LenovoAINowRemoval.ps1 -Destination $staging -Force
& "$env:USERPROFILE\Downloads\IntuneWinAppUtil.exe" -c $staging -s (Join-Path $staging 'Install-LenovoAINowRemoval.ps1') -o .\intune\output -q
Remove-Item $staging -Recurse -Force
```

Run it from the repo root. `Detect-LenovoAINowRemoval.ps1` is deliberately left
out of the package -- Intune takes detection scripts as a separate upload in the
app config, not from the `.intunewin`. Get the packaging tool from
<https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool>.

Intune app configuration
------------------------

**Apps > Windows > Add > Windows app (Win32)**, upload
`output\Install-LenovoAINowRemoval.intunewin`.

App information

- Name: `Lenovo AI Now Removal`
- Publisher: your org
- App version: `1.0.0` (keep in step with `$PackageVersion` in the install wrapper)
- Category / description: your choice

Program

- Install command:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-LenovoAINowRemoval.ps1`
- Uninstall command:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-LenovoAINowRemoval.ps1`
- Install behavior: **System**
- Device restart behavior: **Determine behavior based on return codes**

Return codes (the defaults already cover these -- confirm they are present)

| Code | Mapping |
|------|---------|
| `0` | Success |
| `3010` | Soft reboot |
| `1603` | Failed |

Requirements

- Operating system architecture: x64
- Minimum operating system: Windows 10 1809 or later (match your fleet)
- Optional, to scope to Lenovo hardware only, add an additional requirement
  rule of type Script that exits `0` and outputs `True` when
  `(Get-CimInstance Win32_ComputerSystem).Manufacturer -like '*Lenovo*'`
  (data type Boolean, value equals `True`).

Detection rules -- pick one of the two:

*Registry rule (simple, recommended)*

- Rule type: Registry
- Key path: `HKEY_LOCAL_MACHINE\SOFTWARE\LenovoAINowRemoval`
- Value name: `Version`
- Detection method: String comparison, **Equals**, `1.0.0`
- Associated with a 32-bit app on 64-bit clients: **No**

*Custom script rule (stricter)*

- Rule type: Script, upload `Detect-LenovoAINowRemoval.ps1`
- Run script as 32-bit process on 64-bit clients: **No**
- Enforce script signature check: **No** (unless you sign it)

The script rule reports Installed only when the marker matches *and* no live
install directory, uninstall entry, or AppX package remains. That makes Intune
retry on devices where cleanup silently left residue, at the cost of a script
evaluation per detection cycle.

Assignment: **Required**, to a device group. Do not use Available -- there is no
user-facing app to install.

How the result is reported
--------------------------

`uninstall.ps1` reports Intune-platform-script-friendly codes: it collapses its
internal `3010` (reboot needed to finish deletion of locked shell-extension
DLLs) into process exit `0`. The install wrapper reconstructs the real state
after the run:

- Phase A sentinel at `HKLM\SOFTWARE\LenovoAINowRemediation\PhaseAComplete`
  present **and** a live Lenovo entry in `PendingFileRenameOperations`
  -> wrapper writes the marker and exits **3010**, so Intune reports success
  pending reboot and prompts per the restart behavior.
- Payload exit `0` with nothing queued -> marker written, wrapper exits **0**.
- Anything else -> wrapper exits **1603** and Intune retries.

The marker is written in the 3010 case as well: the cleanup work is done at
that point and SMSS finishes the file deletion on the next boot.

Re-running on already-processed devices
---------------------------------------

Detection keys on the version string, so a device that already ran stays
Installed. To force a fresh run after changing `uninstall.ps1`:

1. Bump `$PackageVersion` in `Install-LenovoAINowRemoval.ps1` (and
   `$expectedVersion` in `Detect-LenovoAINowRemoval.ps1` if you use it).
2. Rebuild, then update the app's version and detection rule value in Intune.

Logs
----

| Log | Written by |
|-----|-----------|
| `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\Lenovo_AI_Now_Win32.log` | Wrappers (result translation, marker) |
| `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\Lenovo_AI_Now_Remediate.log` | `uninstall.ps1` (full cleanup detail) |
| `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log` | IME (download, install, detection) |

Pilot validation
----------------

Run on one Lenovo device with AI Now present, from an elevated SYSTEM-context
shell (`psexec -s -i`, or assign to a pilot group):

1. Install command runs; expect exit `0` or `3010`.
2. `HKLM\SOFTWARE\LenovoAINowRemoval\Version` equals the package version.
3. On `3010`, reboot, then confirm the install directory is gone and detection
   still reports Installed.
4. Check `Lenovo_AI_Now_Remediate.log` for the internal result (`0` or `3010`;
   `1603` means residuals remain).
