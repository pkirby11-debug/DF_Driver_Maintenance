# DF_Driver_Maintenance

Compliance, inventory and freeze-state verification for Deep Freeze protected
endpoints — built for public-facing classroom machines on an isolated VLAN.

---

## Why this exists (and what it deliberately does not do)

The starting question was whether to build a PowerShell program to manage
Windows Updates on Deep Freeze protected machines. After scoping, the answer is
**partly** — and the useful half is not the half you would expect.

### What Deep Freeze Cloud already covers

These endpoints run **Deep Freeze Cloud**, which already includes patch
management that handles the hard part of updating a frozen machine:

- Caches update payloads while the machine is still Frozen
- Thaws on schedule, installs, handles the reboot chain, refreezes when done
- Ends the maintenance window on **"when Windows Update completes"** rather than
  a fixed clock window — the old failure mode where a 2:00–4:00 window closed
  mid-install
- Ships pre-built packages for 85+ third-party products via Software Updater

**Writing a PowerShell replacement for any of that would be rebuilding a feature
you already own.** Before extending this project past its current scope, confirm
whether Patch Management / Software Updater are licensed in your Cloud
subscription tier — they are separate line items in the Ultimate Bundle, not
automatically present.

### What nothing covers

1. **Drivers.** Deep Freeze's Windows Update integration does not meaningfully
   manage driver currency. There is no other source of truth on this VLAN.
2. **Independent verification.** Nothing proactively tells you a machine failed
   to refreeze after maintenance. On a public-facing hospital device, a machine
   silently stuck Thawed is the highest-severity condition in the environment,
   and the tooling that is supposed to refreeze it is not a credible reporter of
   its own failure.
3. **Per-device visibility.** No answer to "what patch level is CLASSROOM-07 at,
   and when did it last successfully install anything?"
4. **Silent device failures.** A touchscreen that has been in a driver error
   state for a month on a machine nobody uses interactively.

**This module fills those four gaps.** It is a read-only reporter. It does not
thaw, freeze, install, or reboot anything.

### Why the scan is read-only

The **scan** path — `Get-DFComplianceSnapshot`, `Export-DFComplianceReport` and everything
they call — changes no machine state. That matters because:

- It can run nightly on production classroom machines with no change-control risk.
- It produces the data needed to decide whether Phase 2 and 3 are justified at
  all — rather than assuming DF Cloud's native updating is failing.
- It never needs the Deep Freeze password, so no credential is stored on a
  public-facing endpoint.

That last point is a hard design constraint, not a convenience. See
[Security notes](#security-notes).

### The one state-changing entry point

`Initialize-DFMaintenance` is **not** read-only, and the distinction is worth stating
plainly rather than describing the module as a whole as incapable of changing state. It:

- creates the state directory and its `reports`/`logs` children
- applies an explicit DACL restricting them to SYSTEM and Administrators, with read-only
  access for users
- writes `dfmaintenance.json`
- with `-RegisterScheduledTask`, registers a **daily task running as SYSTEM at Highest
  privilege**, which `-Force` will replace if one already exists

It is a setup-time operation run deliberately by an administrator on a Thawed machine, not
part of the nightly job.

`dfmaintenance.json` carries `DFCPath`, and the scan **executes** that path as SYSTEM.
`Get-DFCPath` therefore accepts it only if it is a `DFC.exe` under `%ProgramFiles%`,
`%ProgramFiles(x86)%` or `%SystemRoot%`; anything else is logged and ignored. Together with
the DACL, that closes a config-file-to-SYSTEM-code-execution path on a machine students
physically use. If `DirectorySecured` comes back `$false`, secure the directory by hand
before relying on the deployment.

---

## Design constraints

These machines are unusual, and the constraints drive most of the code:

| Constraint | Consequence in the code |
|---|---|
| Frozen volume discards all writes on reboot | All state lives on a **ThawSpace** volume. `Resolve-DFStatePath` refuses to silently pretend `C:` is durable. |
| No module can be installed at runtime (it would be discarded) | **Zero external dependencies.** Windows Update is queried via the built-in `Microsoft.Update.Session` COM API, not PSWindowsUpdate. |
| Isolated VLAN, no route to the Carle network | No file-share reporting. The endpoint's ThawSpace is the system of record; a collector picks reports up out-of-band. HTML reports are fully self-contained — no CDN references, since they would render broken. |
| No SCCM client | No ConfigMgr inventory to lean on; the module collects its own. |
| Windows PowerShell 5.1 is what is on the box | Targets 5.1. No PS7-only syntax. All files written via `Write-DFTextFile`, because `Set-Content -Encoding UTF8` emits a BOM on 5.1 but not on 7.x, and a BOM makes `latest.json` unreadable to the collector. |
| Scan runs as SYSTEM | Per-user software is read from the loaded hives under `HKEY_USERS`, never `HKCU` — under SYSTEM, `HKCU` is SYSTEM's own profile and would silently report nothing. Profiles not loaded at scan time are not visible; machine-wide coverage is complete. |
| Public-facing, unattended, hospital setting | Scans run as SYSTEM, never prompt, never throw out of the top level, and log to a durable JSON Lines file. |

---

## Installation

Run **while the machine is Thawed.** Anything installed while Frozen is
discarded on the next reboot — `Initialize-DFMaintenance` warns if you do this,
but it cannot save you from it.

```powershell
# 1. Thaw the machine via the Deep Freeze Cloud console, then:
Import-Module .\src\DFMaintenance\DFMaintenance.psd1

# 2. Set up state directory, config and the daily scan task
Initialize-DFMaintenance -StatePath 'T:\DFMaintenance' `
                         -RegisterScheduledTask `
                         -ScanTime '03:00' -Verbose

# 3. Confirm it works before you refreeze
.\scripts\Invoke-DFComplianceScan.ps1 -StatePath 'T:\DFMaintenance' -IncludeHtml

# 4. Refreeze via the console. The task is now part of the frozen baseline.
```

`T:` above assumes a ThawSpace volume labelled `ThawSpace*`. If you have not
configured one, `Resolve-DFStatePath` falls back to `ProgramData` and flags the
result as **non-persistent** — reports will be discarded on the next reboot.
Configure ThawSpace first; it is the foundation everything else rests on.

---

## Usage

```powershell
# Fast local snapshot, no network round trip
Get-DFComplianceSnapshot -SkipOnlineSearch

# Just the critical findings
(Get-DFComplianceSnapshot).Findings | Where-Object Severity -eq 'Critical'

# Is this machine actually protected right now?
Get-DFFreezeState

# Drivers older than two years, oldest first
(Get-DFDriverInventory -StaleAfterDays 730).Drivers | Where-Object IsStale

# Devices silently sitting in an error state
(Get-DFDriverInventory).ProblemDevices

# Full scan to disk, with HTML summary
Get-DFComplianceSnapshot | Export-DFComplianceReport -IncludeHtml
```

### Exit codes

`Invoke-DFComplianceScan.ps1` returns meaningful codes so a collector can triage
without parsing the report:

| Code | Meaning |
|---|---|
| 0 | Healthy, or informational findings only |
| 1 | Warning-level findings |
| 2 | **Critical** findings (includes THAWED state) |
| 3 | The scan itself failed |

### Finding codes

| Code | Severity | Meaning |
|---|---|---|
| `DF001` | Critical | Machine is **Thawed** — protection not active |
| `DF002` | Warning | Freeze state could not be determined |
| `DF003` | Critical | Deep Freeze client not detected |
| `DF004` | Critical | State path is not persistent — this report dies on the next Frozen reboot |
| `WU001` | Warning | Reboot pending while Frozen — the work will be discarded, not applied |
| `WU002` | Critical | Critical/important updates pending |
| `WU003` | Info | Non-critical updates pending |
| `WU004` | Warning | Windows Update query failed |
| `WU005` | Critical | No successful install in the overdue window — maintenance is not working |
| `WU006` | Warning | No successful install in recorded history |
| `DRV001` | Warning | Device(s) in an error state |
| `DRV002` | Info | Third-party driver(s) past the staleness threshold |
| `DRV003` | Warning | Driver inventory itself failed (e.g. WMI repository corruption) |
| `SW001` | Warning | Software inventory itself failed |

`DF004`, `DRV003` and `SW001` exist because a collector cannot tell "nothing was wrong"
from "the check never ran". Without them a machine with no ThawSpace, or one whose WMI
repository is corrupt, scans clean and reports `Healthy` — while its report is discarded
on the next reboot or its driver inventory is silently empty.

`WU001` and `WU005` are the two worth watching. Together they catch the specific
silent failure this project exists for: a machine that appears to be patching on
schedule but whose work is discarded by every Frozen reboot, forever, with no
error surfaced anywhere.

---

## Security notes

- **No Deep Freeze password anywhere.** `DFC.exe /ISFROZEN` is a read-only query
  and does not require one. Deliberately, no function in this module performs a
  state change, so no credential ever needs to be stored on a public-facing
  endpoint. Preserve this property if you extend the module — drive state changes
  from the Cloud console, not from a secret baked into an endpoint script.
- **Do not put secrets in `dfmaintenance.json`.** It sits on a kiosk volume.
- **Report contents** are inventory data (hostname, OS build, driver and software
  versions). No PHI, no user data. Device identifiers are truncated to the hardware-class
  prefix (`USB\VID_046D&PID_C52B`) because the instance id that follows is, for many
  devices, the hardware **serial number** — a stable per-unit identifier. Confirm this
  still holds if you extend it.
- **`DFCPath` is executed as SYSTEM.** It is validated against a closed set of
  administrator-controlled directories. Do not loosen that check, and do not reinstate a
  bare `PATH` search — any user-writable directory on `PATH` would become a SYSTEM
  execution source whenever Deep Freeze is absent or renamed.
- **The state directory is ACL'd** to SYSTEM and Administrators at setup. It holds the
  config that steers a SYSTEM-executed path, so a user-writable state directory is a
  privilege-escalation vector, not just untidy.
- Changes to public-facing hospital endpoints should go through your normal
  change-control process, even read-only ones.

---

## Project layout

```
src/DFMaintenance/
  Public/           # Exported functions
  Private/          # Internal helpers
  DFMaintenance.psd1
  DFMaintenance.psm1
scripts/
  Invoke-DFComplianceScan.ps1   # Scheduled-task entry point
config/
  dfmaintenance.example.json
tests/
  DFMaintenance.Tests.ps1       # Pester 5
docs/
  VALIDATION.md                 # On-Windows validation checklist
```

---

## Roadmap

**Phase 1 — compliance reporting (this release).** Read-only. Zero state change.

**Phase 2 — refreeze watchdog + alerting.** An independent check that a machine
returned to Frozen after a maintenance window, with a route for the alert to
actually reach somebody given the VLAN isolation. Needs a decision on transport.

**Phase 3 — driver maintenance orchestration.** Only if Phase 1 data shows it is
needed. Highest risk: driver installs are multi-reboot, can roll back, and on a
frozen machine a failed driver is self-healing on reboot — which is a genuinely
useful property to design around rather than fight.

Phase 1 is useful on its own even if 2 and 3 are never built.

---

## Sources

- [Deep Freeze and Windows Updates — Faronics](https://faronics.kayako.com/article/278-deep-freeze-and-windows-updates)
- [Behavior of Windows Update on machines running Deep Freeze Enterprise](https://support.faronics.com/help/en-ca/29-deep-freeze-windows/226-behavior-of-windows-update-on-machines-running-deep-freeze-enterprise)
- [Smarter Windows Updates with Deep Freeze 8.23](https://www.faronics.com/news/blog/welcome-to-the-smarter-windows-updates-with-deep-freeze)
- [Deep Freeze Cloud — Windows Updates documentation](https://docs.faronics.com/deep-freeze-cloud/using-deep-freeze-cloud-console/windows-updates)
- [Deep Freeze Cloud — Patch Management / Software Updater](https://www.faronics.com/deep-freeze-cloud-patch-mangement-automatic-software-update)
- [Deep Freeze Command Line Syntax (DFC.exe)](https://docs.faronics.com/deep-freeze-cloud/using-deep-freeze-cloud-console/deep-freeze-service/advanced-settings-tab/deep-freeze-command-line-syntax)
