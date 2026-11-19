# Dell Command | Update in the Deep Freeze maintenance window

`scripts/Invoke-DFDcuMaintenance.ps1` runs Dell Command | Update (DCU) on Deep Freeze protected
Dell machines during the nightly maintenance window. It only runs while Deep Freeze has the
machine **Thawed**. When DCU needs a restart, the script takes it inside the window, so BIOS and
driver installs finish on a Thawed boot and are kept.

It is one self-contained file. You push it once per machine from the Deep Freeze Cloud console.
It installs a scheduled task, and the task does the work every night after that.

> **Unlike the DFMaintenance module, this script changes machine state**: it installs drivers,
> firmware and BIOS updates and restarts machines. Pilot it on one machine first. Use the
> checklist at the end.

---

## What a night looks like

```
22:00  Deep Freeze Thawed Period starts; Deep Freeze restarts the machine Thawed
22:05  at-startup trigger -> pass 1: random 0-20 min wait, DFC check, dcu-cli /scan, /applyUpdates
       DCU wants a restart -> the script restarts the machine (still inside the Thawed Period)
~22:45 at-startup trigger -> pass 2: dcu-cli /scan -> up to date -> done for the night
23:10, 00:10 ... 04:10   hourly re-checks: "already finished tonight", exit in seconds
04:30  install cutoff  -- no new pass starts after this
05:30  restart cutoff  -- no restart after this
06:00  Deep Freeze ends the Thawed Period and restarts the machine Frozen
```

Every run checks for itself whether there is anything to do:

1. **Inside the window?** Outside it, the run exits in under a second, so a restart at 10:00 does nothing.
2. **Thawed?** It asks `DFC.exe get /ISFROZEN`. If the machine is Frozen, or the answer is unclear,
   nothing is installed. Work done while Frozen is discarded at the next restart, and DCU would
   then offer the same updates again every night.
3. **Already done tonight, or out of passes?** At most three install passes run per night. After
   that, one final scan reports whatever is still left.
4. **Windows Update or an MSI busy?** It waits up to 30 min rather than installing drivers on top of them.
5. **Scan, apply, and restart if needed.** The restart only happens inside the window and before
   the restart cutoff.

---

## 1. Configure Deep Freeze Cloud first

The script never thaws anything. It has no Deep Freeze password and wants none. Deep Freeze Cloud
has to thaw the machines for the window.

In the policy for these machines, go to **Deep Freeze > Workstation Tasks**:

**If you do not use Deep Freeze's Windows Update task** — one task:

| Setting | Value |
|---|---|
| Task type | **Thawed Period** |
| Day | Every day (or Weekdays/Weekends) |
| Start / End | **22:00 / 06:00** |
| Attempt to wake up locally | On, if these machines ever sleep |
| Shut down after task | Off |

**If you also use Deep Freeze's Windows Update task**, split the night. Workstation tasks cannot
overlap and need a 5-minute gap:

| Task | Start | End |
|---|---|---|
| Windows Update | 22:00 | **01:55** — a fixed time, *not* "When Windows Update Completes" |
| Thawed Period (for DCU) | 02:00 | 06:00 |

Then install the script with `-WindowStart 02:00 -WindowEnd 06:00`.

Why not the other task types:

- **Windows Update task set to end "When Windows Update Completes"**: Deep Freeze restarts Frozen
  as soon as Windows Update finishes. That can be in the middle of a DCU pass.
- **Batch File task**: Deep Freeze restarts the machine Frozen as soon as the batch file finishes.
  The restart DCU needs would then always land on a Frozen boot.
- **DCU's own built-in scheduler**: it knows nothing about Deep Freeze. It would install while
  Frozen, at its own times, with pop-ups on patient-facing screens. The script switches it to manual.

Two more things to check:

- **The DFMaintenance compliance scan.** If you deployed it with the README's `-ScanTime '03:00'`,
  move it after the window, e.g. `06:30`. At 03:00 the machine is Thawed by design, so the scan
  reports DF001 Critical every night. At 06:30 it does its real job and confirms the machine
  refroze.
- **Time zone.** The window is local machine time. Deep Freeze Cloud task times should be the same
  wall-clock times on the machines.

---

## 2. Prerequisites on the machines

These must be in the **Frozen baseline**. Anything installed while Frozen disappears at restart.

- **Dell Command | Update 5.x** installed, with the *Dell Client Management Service* set to
  Automatic. The script finds `dcu-cli.exe` under `Program Files (x86)\Dell\CommandUpdate` (classic)
  or `Program Files\Dell\CommandUpdate` (Universal).
- **Network access to Dell** (`downloads.dell.com`, `dl.dell.com`) from these machines, or a DCU
  repository they can reach. Without it, every scan fails with 503 and the status file says so.
- **A ThawSpace volume is strongly recommended** for logs and status, so you can still read them
  after the Frozen restart. Without one, the script falls back to `C:\ProgramData`. That still
  works, but only records written while Thawed survive.
- **BIOS admin password:** if these machines have one, DCU cannot flash the BIOS without it. This
  script deliberately never stores a BIOS password on a public-facing machine. Either install with
  `-UpdateType firmware,driver` and update BIOS another way, or expect `MaxPassesReached` with the
  BIOS listed every night.

---

## 3. Push it (once per machine, while Thawed)

A scheduled task created on a **Frozen** machine is discarded at the next restart. The script
checks this and refuses with **exit 20** instead of reporting a success that disappears.

**Deep Freeze Cloud > Applications > Scripts (Windows) > Custom Script > Create Custom Script**

| Field | Value |
|---|---|
| URL | where you host `Invoke-DFDcuMaintenance.ps1` (`https://...` or a `\\UNC` path the machines can reach) |
| Type | PowerShell |
| Command line | empty for the defaults, or settings such as `-WindowStart 02:00 -WindowEnd 06:00 -StatePath T:\DFMaintenance` |
| Run as | **System Account** |

Then:

1. **Make the target Thawed**: Live Action **Deep Freeze > Reboot Thawed**, or push during the
   nightly Thawed Period.
2. **Run Once** on the target.
3. **Check the result**: the script's exit code (0 = installed), or `dcu-install.json` in the
   state folder. On the machine, `Get-ScheduledTask DFMaintenance-DellCommandUpdate` should show
   the task with two triggers.
4. **Refreeze**: Live Action **Reboot Frozen**, or let the Thawed Period end. The task is now part
   of the Frozen baseline.

To change settings later, push again with the new command line, while Thawed. Each install
replaces the previous task and config.

If Deep Freeze's PowerShell runner fails on execution policy, use the Batch Script type instead.
Have the batch file call
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<path to Invoke-DFDcuMaintenance.ps1>" <settings>`.

### Settings (all optional)

| Setting | Default | Meaning |
|---|---|---|
| `-WindowStart` / `-WindowEnd` | `22:00` / `06:00` | Must match the Deep Freeze Thawed Period. May cross midnight. |
| `-UpdateType` | `bios,firmware,driver` | Add `application` for Dell apps, `others` for the rest. |
| `-UpdateSeverity` | `security,critical,recommended` | Add `optional` for everything. |
| `-UpdateDeviceCategory` | all | e.g. `network,chipset,video` |
| `-StatePath` | ThawSpace by label, else ProgramData | e.g. `T:\DFMaintenance`. **Recommended:** removes any guessing. |
| `-MaxPassesPerNight` | `3` | Install passes per night (each may end in a restart). |
| `-InstallCutoffMinutes` | `90` | No new pass this close to the window end. |
| `-RebootCutoffMinutes` | `30` | No restart this close to the window end. |
| `-RebootDelaySeconds` | `120` | On-screen warning before a restart. |
| `-RandomDelayMinutes` | `20` | First pass of the night waits a random 0..N min to spread fleet downloads. |
| `-RetryIntervalMinutes` | `60` | How often the window is re-checked. |
| `-ScanTimeoutMinutes` / `-ApplyTimeoutMinutes` | `30` / `120` | A hung dcu-cli is stopped after this. |
| `-ServicingWaitMinutes` | `30` | How long to wait for Windows Update / MSI to go idle. |
| `-MinFreeSpaceGB` | `2` | Skip the night below this much free space on C:. |
| `-LogRetentionDays` | `60` | Old logs are pruned. |
| `-NoReboot` | off | Never restart. **Not recommended:** the next restart is then Deep Freeze's Frozen one. |
| `-LeaveDcuSettings` | off | Never run `dcu-cli /configure` (DCU managed by ADMX/Intune). |
| `-RunWithoutDeepFreeze` | off | Run even where Deep Freeze is not installed at all. |
| `-WakeToRun` | off | Wake the machine for the scheduled trigger. |
| `-DFCPath` | auto | Explicit `DFC.exe`, honoured only under Program Files or Windows. |
| `-SkipFreezeCheck` | off | Install/uninstall even when Frozen. Lab use only. |

You can also change the defaults at the top of the script (`$script:DcuDefaults`) and push it
with an empty command line.

---

## 4. Read the results

**On a machine:**

```powershell
& "$env:ProgramFiles\DFMaintenance\DCU\Invoke-DFDcuMaintenance.ps1" -Mode Status
```

**Files** (`<state>` is the ThawSpace path, e.g. `T:\DFMaintenance\dcu`):

| File | What it is |
|---|---|
| `<state>\dcu-status.json` | The last real result. Status-only runs (outside the window, already finished) never overwrite it. **This is the one file a collector needs.** |
| `<state>\dcu-state.json` | Tonight's pass counter. |
| `<state>\dcu-install.json` | Result of the last install, including refusals. |
| `<state>\logs\dfdcu-YYYYMM.jsonl` | Full history, one JSON object per line. |
| `<state>\dcu-logs\` | Copies of DCU's own logs and scan reports. |
| `%ProgramFiles%\DFMaintenance\DCU\` | The installed script and `config.json`. Admin-only. |
| `%ProgramData%\Dell\DFMaintenance\` | Where dcu-cli writes its logs. DCU only accepts certain folders for those. |
| Application event log, source `DFMaintenance-DCU` | Event ID = 1000 + the run's exit code (e.g. 1000, 1002, 4010); install = 2000/2020/2021. |

`dcu-status.json` fields worth watching: `Outcome`, `Message`, `AppliedTonight` (what went in
across all of tonight's passes), `Dcu.Updates` (what the last scan found), `LastSuccess` (when this
machine last finished cleanly, kept across bad nights), `StateIsPersistent`.

### Outcomes

| Outcome | Exit | What it means / what to do |
|---|---|---|
| `UpToDate` | 0 | Nothing left to install. `AppliedTonight` lists what went in on earlier passes. |
| `Applied` | 0 | Updates installed, no restart needed. |
| `RebootScheduled` | 3010 | Restarting to finish installs; the next pass runs after the restart. |
| `SkippedFrozen` | 2 | **Deep Freeze is not thawing this machine in the window.** Check the Thawed Period. |
| `SkippedFreezeStateUnknown` | 2 | DFC.exe missing or unreadable. Check the Deep Freeze client, or pass `-DFCPath`. |
| `MaxPassesReached` | 3 | Updates still applicable after all passes. If the same ones repeat nightly, read `dcu-logs`. Common cause: a BIOS password. |
| `SkippedServicingBusy` | 3 | Windows Update / MSI was busy for 30 min; retried at the next trigger. |
| `RebootPendingAtWindowEnd` | 7 | Finished too late to restart. It finishes on a later night; if this is regular, widen the window. |
| `DcuNotInstalled` / `DcuTooOld` / `DcuServiceDisabled` / `DcuServiceMissing` / `DcuUntrusted` | 4 | Fix DCU in the baseline. |
| `DcuUnsupported` | 4 | Not a Dell, or a model DCU does not support. |
| `ScanFailed` / `ApplyFailed` / `*TimedOut` | 5 | Usually network (503/1002). Retried at the next trigger. |
| `LowDiskSpace` / `RebootFailed` / `StateWriteFailed` | 5 | As named. |
| `DcuUsageError` | 6 | DCU rejected the command line (100-113). Retrying will not help. Check the DCU version and the log. |

Full exit-code lists for every mode are in the script's help:
`Get-Help .\Invoke-DFDcuMaintenance.ps1 -Full`.

---

## 5. Validate on one machine first

Nothing that touches Windows was testable where this was written: Task Scheduler, DCU, DFC.exe, ACLs,
the registry. The logic around them is covered by `tests/DFDcuMaintenance.Tests.ps1` (Pester).
Work through this list on one test machine before any wider push.

### Deep Freeze

- [ ] `DFC.exe get /ISFROZEN` returns **1** when Frozen and **0** when Thawed. See the commands in
      [VALIDATION.md](VALIDATION.md). If it differs, stop: the freeze gate depends on it.
- [ ] **A restart *inside* the Thawed Period comes back Thawed.** This is the most important
      check. During the Thawed Period, restart the machine by hand, then run `DFC.exe get /ISFROZEN`
      again and expect 0. If it comes back Frozen, the in-window restart cannot keep BIOS/driver
      work. Report back before rolling out; the design would need to change.
- [ ] At the end of the window, Deep Freeze restarts the machine Frozen, and the next morning's
      compliance scan shows no DF001.

### Install

- [ ] Pushed while **Frozen**, the script exits **20** and `dcu-install.json` says `RefusedNotThawed`.
- [ ] Pushed while **Thawed**, the script exits **0**. Task Scheduler shows
      `\DFMaintenance-DellCommandUpdate` running as SYSTEM, with a daily trigger (repeating
      hourly) and an at-startup trigger.
- [ ] Files landed in `C:\Program Files\DFMaintenance\DCU` (**not** `Program Files (x86)`). If the
      Deep Freeze agent runs 32-bit PowerShell, the log shows "relaunching in 64-bit PowerShell".
- [ ] DCU's own settings now show its automatic updates as manual and notifications off.
- [ ] After a Frozen restart, the task is still there. That only holds if it was installed while Thawed.

### A pass

- [ ] `-Mode Run -DryRun -IgnoreWindow` lists the applicable updates. This also proves DCU accepts
      the `-outputLog`/`-report` paths: no 106/107 in `dcu-status-dryrun.json`.
- [ ] On a **Thawed** test machine, `-Mode Run -IgnoreWindow` applies updates and restarts.
      Running it again after the restart reports `UpToDate`.
- [ ] Run the task by hand outside the window (Task Scheduler > Run). It exits **1** and changes nothing.

### A real night

- [ ] The next morning, `dcu-status.json` says `UpToDate` or `Applied`, `AppliedTonight` lists
      what went in, and `StateIsPersistent` is true.
- [ ] **BitLocker machines with a BIOS update:** `manage-bde -status C:` shows Protection On
      afterwards.
- [ ] `dcu-status.json` begins with `{`: no BOM.
- [ ] Nothing popped up for users during the day.

---

## Uninstall

While Thawed:

```powershell
& "$env:ProgramFiles\DFMaintenance\DCU\Invoke-DFDcuMaintenance.ps1" -Mode Uninstall
```

This removes the task, `%ProgramFiles%\DFMaintenance\DCU` and `%ProgramData%\Dell\DFMaintenance`.
Logs and status on the state volume are kept. DCU's own scheduler stays on manual; to hand
scheduling back to DCU, run `dcu-cli.exe /configure -scheduleAuto`.

---

## Sources

- [Dell Command | Update 5.x Reference Guide (Rev. A14, Feb 2026)](https://www.dell.com/support/manuals/en-us/command-update/dcu_rg/dell-command-update-cli-commands?guid=guid-92619086-5f7c-4a05-bce2-0d560c15e8ed&lang=en-us): CLI options, restricted log folders, BitLocker behaviour
- [Dell Command | Update CLI error codes](https://www.dell.com/support/manuals/en-us/command-update/dcu_rg/command-line-interface-error-codes?guid=guid-fbb96b06-4603-423a-baec-cbf5963d8948&lang=en-us)
- [Deep Freeze Cloud: Workstation Tasks](https://docs.faronics.com/deep-freeze-cloud/using-deep-freeze-cloud-console/deep-freeze-service/workstation-tasks-tab): no overlaps, triggers only when Frozen
- [Deep Freeze Cloud: Thawed Period](https://docs.faronics.com/deep-freeze-cloud/using-deep-freeze-cloud-console/deep-freeze-service/workstation-tasks-tab/thawed-period)
- [Deep Freeze Cloud: Batch File task](https://docs.faronics.com/deep-freeze-cloud/using-deep-freeze-cloud-console/deep-freeze-service/workstation-tasks-tab/batch-file): "Computers will reboot Frozen after the batch file has been executed"
- [Deep Freeze Cloud: Windows Update task](https://docs.faronics.com/deep-freeze-cloud/using-deep-freeze-cloud-console/deep-freeze-service/workstation-tasks-tab/windows-update)
- [Deep Freeze Cloud: Scripts (Windows)](https://docs.faronics.com/deep-freeze-cloud/using-deep-freeze-cloud-console/applications/scripts-windows)
- [Deep Freeze Cloud: Live Actions](https://docs.faronics.com/deep-freeze-cloud/using-deep-freeze-cloud-console/computers/live-actions): Reboot Thawed / Reboot Frozen
- [Deep Freeze Command Line Syntax](https://docs.faronics.com/deep-freeze-cloud/using-deep-freeze-cloud-console/deep-freeze-service/advanced-settings-tab/deep-freeze-command-line-syntax): `DFC get /ISFROZEN`
