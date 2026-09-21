# Validation checklist

## What has actually been tested

This module was developed in a Linux container with no Windows, no Deep Freeze,
and no Windows Update Agent. Be clear-eyed about what that means.

**Verified:**

- All 16 PowerShell files parse cleanly (`[Parser]::ParseFile`, 0 errors).
- 23 logic assertions pass against the platform-independent code:
  config merge and malformed-JSON fallback, JSON Lines log format and its
  failure-tolerance, state path resolution, HTML rendering including
  markup-injection encoding and the no-external-URL requirement, and
  manifest-to-disk export consistency.
- Severity rollup produces the correct verdict for empty / Info / Warning /
  Critical finding sets.

**Not verified — requires a real Windows endpoint:**

- Everything touching Deep Freeze, WMI/CIM, the registry, the Windows Update
  Agent COM API, and Task Scheduler.

The highest-risk unverified item is called out below.

---

## Verify this first: the DFC.exe exit code

`Get-DFFreezeState` maps `DFC.exe /ISFROZEN` exit codes as:

```
exit code 1  ->  FROZEN
exit code 0  ->  THAWED
```

This mapping comes from Faronics documentation, **not from a test on your
hardware.** It is inverted from the usual "0 means success" convention, and if it
is wrong on your Deep Freeze build the tool will confidently report the exact
opposite of reality — reporting healthy Frozen machines as a critical Thawed
finding, or worse, reporting a genuinely Thawed public-facing machine as fine.

Confirm it on one machine before trusting any report:

```powershell
# With the machine FROZEN:
& 'C:\Program Files\Faronics\Deep Freeze\DFC.exe' /ISFROZEN
Write-Host "Frozen machine returned: $LASTEXITCODE"    # expect 1

# Thaw via the Cloud console, reboot, then:
& 'C:\Program Files\Faronics\Deep Freeze\DFC.exe' /ISFROZEN
Write-Host "Thawed machine returned: $LASTEXITCODE"    # expect 0
```

If your build returns something different, correct the `switch` block in
`src/DFMaintenance/Public/Get-DFFreezeState.ps1`. The mapping is deliberately
written as an explicit switch rather than a boolean cast so it is a one-line fix.

---

## Full checklist

Work through this on a single test machine before any wider deployment.

### 1. Module loads

- [ ] `Import-Module .\src\DFMaintenance\DFMaintenance.psd1 -Force` succeeds on Windows PowerShell 5.1
- [ ] `Get-Command -Module DFMaintenance` lists all 8 exported functions
- [ ] Module import does not throw when no ThawSpace volume exists

### 2. State persistence — the foundation

- [ ] `Resolve-DFStatePath` finds a ThawSpace volume and reports `IsPersistent = $true`
- [ ] With no ThawSpace, a scan produces finding **`DF004` at Critical** (not merely a
      warning nobody sees) and exits 2
- [ ] With no ThawSpace, it falls back to ProgramData and reports `IsPersistent = $false`
- [ ] **A report written to ThawSpace survives a Frozen reboot.** Write a report,
      reboot Frozen, confirm the file is still there. If this fails, nothing else
      in the module matters.
- [ ] Adjust `ThawSpaceLabelPattern` if your volume label differs from `ThawSpace*`

### 3. Freeze state

- [ ] The DFC.exe exit code check above
- [ ] `Get-DFCPath` locates DFC.exe on your build (check the candidate paths — the
      install location varies by Deep Freeze version)
- [ ] With DFC.exe absent/renamed, `Get-DFFreezeState` returns `Unknown`, not a guess
- [ ] Thawed machine produces finding `DF001` at Critical
- [ ] **DFC.exe stderr does not break the read.** If your DFC.exe writes any banner or
      notice to stderr, confirm `Get-DFFreezeState` still returns Frozen/Thawed rather
      than `Unknown`. On 5.1, native stderr under `$ErrorActionPreference='Stop'` becomes
      a terminating error; the code neutralises the preference around the call
      specifically to prevent a Thawed machine being downgraded to `DF002` Warning.

### 4. Windows Update

- [ ] `Get-DFWindowsUpdateStatus -SkipOnlineSearch` returns OS build and history quickly
- [ ] Online search completes on the isolated VLAN — **confirm these machines can
      reach Windows Update at all.** If they are pulling from WSUS or via Deep
      Freeze Cloud only, the direct COM search may return nothing or fail, and
      `WU004`/`WU006` will fire constantly and train you to ignore them.
- [ ] `Test-DFRebootPending` returns `$true` after an update that needs a reboot
- [ ] **`PendingDriver` is meaningful.** The search criteria returns software updates; WUA
      generally needs the Microsoft Update service and an explicit `Type='Driver'` search to
      return drivers. Confirm on an endpoint with a known-pending driver update whether
      `PendingDriver` is ever non-zero. If it is always 0, treat the field as unimplemented
      rather than as "no driver updates pending".
- [ ] **`RebootNeeded` is not universally true.** Windows 10/11 cumulative updates are
      bundles, whose `InstallationBehavior` can be a null pointer; the code now reports
      `$null` (unknown) rather than guessing `$true`.
- [ ] `WU001` fires on a Frozen machine with a pending reboot

### 5. Inventory

- [ ] `Get-DFDriverInventory` returns sensible driver counts and ages
- [ ] `ProblemDevices` correctly lists a device in error state (test by disabling one)
- [ ] `Get-DFSoftwareInventory` finds your tracked apps; tune `TrackedSoftware`
- [ ] `UserHivesRead` is reported. Under SYSTEM at 03:00 with nobody logged on this will
      usually be 0 — that is expected, not a bug. Machine-wide installs are still complete.
      If you need per-user coverage, run a scan while a profile is loaded and confirm the
      count rises.
- [ ] Confirm the inventory does **not** trigger MSI reconfigure dialogs
      (the reason `Win32_Product` is avoided — verify this holds in practice)

### 6. Reporting

- [ ] `Export-DFComplianceReport -IncludeHtml` writes JSON and HTML to ThawSpace
- [ ] `latest.json` is updated each run
- [ ] HTML renders correctly **with no network connectivity**
- [ ] Old reports are pruned past `LogRetentionDays`; ThawSpace does not fill up
      over months of unattended running
- [ ] **No byte-order mark.** Confirm the first byte of `latest.json` is `{` (0x7B), not
      0xEF. This is the single most likely 5.1-vs-7.x divergence in the codebase:
      ```powershell
      ([System.IO.File]::ReadAllBytes('T:\DFMaintenance\reports\latest.json'))[0..2]
      # expect 123 34 ... (i.e. '{'), NOT 239 187 191
      ```
      Then confirm a non-PowerShell parser can read it, since that is the actual consumer.
- [ ] Logs land under the **same** state path as the reports (not `C:\ProgramData`) when
      `-StatePath` is passed or `StatePath` is set in config
- [ ] A write failure still reports: fill the volume, run a scan, confirm the findings are
      printed and `WriteError` is set rather than the scan dying with exit 3

### 7. Scheduled execution

- [ ] Task registers and runs as SYSTEM
- [ ] It completes unattended with no logged-on user
- [ ] Exit codes map correctly (0/1/2/3). In particular force a scan failure and confirm
      it exits **3**, not 1 — `Write-Error` inside the catch under `$ErrorActionPreference='Stop'`
      previously escalated to terminating and killed the script with exit 1, which this
      script's own contract defines as "Warning-level findings".
- [ ] **The task survives a Frozen reboot** — it must be registered during the
      same Thawed window that becomes the frozen baseline
- [ ] The 2-hour execution limit is sufficient for an online search on your slowest machine

### 7b. Security (do not skip — these are privilege-escalation checks)

The scan runs as SYSTEM and executes the `DFCPath` from a config file on the state volume.

- [ ] **Hostile DFCPath is rejected.** Put `{"DFCPath":"C:\\Users\\Public\\calc.exe"}` in
      `dfmaintenance.json`, run a scan, and confirm it is logged and ignored — not executed.
      Confirm `Get-DFFreezeState` falls through to the real DFC.exe.
- [ ] **State directory is not user-writable.** As a standard (non-admin) kiosk account,
      confirm you cannot write to the state directory or modify `dfmaintenance.json`:
      ```powershell
      (Get-Acl 'T:\DFMaintenance').Access | Format-Table IdentityReference, FileSystemRights
      # expect SYSTEM and Administrators FullControl, Users ReadAndExecute only
      ```
      `Initialize-DFMaintenance` returns `DirectorySecured`; if it is `$false`, fix it by hand.
- [ ] **Reports carry no hardware serials.** Confirm `HardwareId` values in `latest.json`
      look like `USB\VID_046D&PID_C52B` with no trailing instance/serial segment.
- [ ] **HTML report has no interpolated colours** — severity is carried by CSS class.

### 8. Unit tests

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force
Invoke-Pester .\tests\DFMaintenance.Tests.ps1 -Output Detailed
```

Note: `tests/DFMaintenance.Tests.ps1` uses Windows path separators and is
intended to run on Windows.

---

## Deployment sequence

Once the checklist passes on one machine:

1. Pilot on **one** classroom machine. Let it run a full week including at least
   one Deep Freeze maintenance window.
2. Read the reports. This is the point of Phase 1 — find out whether DF Cloud's
   native updating is actually working on these machines. The answer determines
   whether Phase 2 and 3 are worth building.
3. Expand to the rest of the classroom only after the pilot data makes sense.
4. Bake into the image so new machines get it from the baseline.
