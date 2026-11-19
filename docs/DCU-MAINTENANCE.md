# Dell Command | Update in the Deep Freeze maintenance window

`scripts/Invoke-DFDcuMaintenance.ps1` runs Dell Command | Update (DCU) on Deep Freeze Cloud
managed Dell machines during the nightly maintenance window. It runs only while Deep Freeze
reports the machine **Thawed**, and it shares the window with Software Updater's Windows Updates
rather than fighting them. When DCU needs a restart, the script takes it inside the window, so
BIOS and driver installs finish while Deep Freeze is off and are kept.

It is one self-contained file. You push it once per machine from the Deep Freeze Cloud console.
It installs a scheduled task, and the task does the work every night after that.

> **Unlike the DFMaintenance module, this script changes machine state**: it installs drivers,
> firmware and BIOS updates and restarts machines. Pilot it on one machine first. Use the
> checklist at the end.

---

## What a night looks like

With the policy set up as below (Maintenance Period 22:00–06:00, Deep Freeze disabled,
Software Updater installing Windows Updates):

```
22:00  Maintenance Period starts: Deep Freeze and the other services are disabled, the machine
       restarts, and Software Updater begins installing Windows Updates
22:05  at-startup trigger: "first pass starts at 00:00" -- Windows Update has the window first
00:00  daily trigger -> pass 1: random 0-20 min wait, wait for Windows Update/MSI to be idle,
       dcu-cli /scan, /applyUpdates
       DCU wants a restart -> wait for Windows servicing to be idle, then restart
       (if Software Updater is still installing after 30 min: defer the restart to the next trigger)
~00:45 at-startup trigger -> pass 2: dcu-cli /scan -> up to date -> done for the night
01:00 ... 05:00   hourly re-checks: "already finished tonight", exit in seconds
04:30  install cutoff  -- no new pass starts after this
05:30  restart cutoff  -- no restart after this
06:00  Maintenance Period ends; Deep Freeze is re-enabled and the machine restarts Frozen
```

Every run checks for itself whether there is anything to do:

1. **Inside the window?** Outside it, the run exits in under a second, so a restart at 10:00 does nothing.
2. **Thawed?** It asks `DFC.exe get /ISFROZEN`. If the machine is Frozen, or the answer is unclear,
   nothing is installed. Work done while Frozen is discarded at the next restart, and DCU would
   then offer the same updates again every night.
3. **Past the start delay?** The first pass of a night waits until `WindowStart + StartDelayMinutes`
   (default 2 hours, i.e. 00:00), so Windows Update goes first.
4. **Already done tonight, or out of passes?** At most three install passes run per night. After
   that, one final scan reports whatever is still left.
5. **Windows Update or an MSI busy?** It waits up to 30 min rather than installing drivers on top of them.
6. **Scan, apply, and restart if needed.** The restart only happens inside the window and before
   the restart cutoff, and never on top of a running install. A restart someone else causes
   mid-pass, such as Software Updater rebooting after Windows Update, is expected: the next run
   notes the interrupted pass and carries on.

---

## 1. Deep Freeze Cloud policy

The script never thaws anything. It has no Deep Freeze password and wants none. The Deep Freeze
Cloud policy has to take Deep Freeze out of the way for the window.

### Your setup: a Maintenance Period with Deep Freeze disabled

In the policy: **General Settings > Maintenance Period**

| Setting | Value |
|---|---|
| Maintenance Period | Enable (Use below settings) |
| Services to disable | **Disable all services**, or at least **Deep Freeze** |
| Start / End | **22:00 / 06:00**, repeating every day |
| Perform Software Updater tasks | On, for Windows Updates and apps |
| Shutdown after maintenance period | Off |

Then the script's defaults fit as they are: window 22:00–06:00, first DCU pass at 00:00.

**In Software Updater > Windows Update tab, keep the `Drivers` category off.** DCU now owns
drivers. If Windows Update installs drivers too, the two replace each other's versions every
night: Windows Update puts on one Intel graphics driver, DCU puts back Dell's. The symptom is
the same driver showing up in `AppliedTonight` night after night.

> Faronics' Software Updater page notes that for policies with Deep Freeze enabled, Windows
> Updates "must be scheduled using the Windows Update Workstation Task" and Software Updater
> only reports. That note may predate the newer Software Updater you are using. Either way,
> confirm the machines really show recent Windows Update installs; the DFMaintenance compliance
> scan's WU005 finding checks exactly that.

### Other layouts that also work

- **A Thawed Period workstation task** (Deep Freeze > Workstation Tasks) covering the window. If
  nothing else installs Windows Updates in that window, you can install with
  `-StartDelayMinutes 10` to start DCU right away.
- **Not a Batch File task**: Deep Freeze restarts the machine Frozen as soon as the batch file
  finishes, so the restart DCU needs would always land on a Frozen boot.
- **Not a Windows Update workstation task set to "When Windows Update Completes"**: it can
  re-freeze the machine in the middle of a DCU pass.
- **Not DCU's own built-in scheduler**: it knows nothing about Deep Freeze, would install while
  Frozen at its own times, and shows pop-ups on patient-facing screens. The script switches it
  to manual.

### The DFMaintenance compliance scan

If you deployed it with `-ScanTime '03:00'`, move it to after the window, e.g. `06:30`. During
the window Deep Freeze is disabled by design, so a 03:00 scan reports DF001 every night. At 06:30
it does its real job: confirming the machine went back to Frozen.

---

## 2. Prerequisites on the machines

These must be in the **Frozen baseline**. Anything installed while Frozen disappears at restart.

- **Dell Command | Update 5.x** installed, with the *Dell Client Management Service* set to
  Automatic. The script finds `dcu-cli.exe` under `Program Files (x86)\Dell\CommandUpdate`
  (classic) or `Program Files\Dell\CommandUpdate` (Universal).
- **Network access to Dell** (`downloads.dell.com`, `dl.dell.com`) from these machines, or a DCU
  repository they can reach. Without it, every scan fails with 503, and the status file says so.
- **No BIOS admin password** (yours have none), so BIOS updates stay in the default set. If one
  is ever added, DCU can no longer flash the BIOS. This script will not store a BIOS password on
  a public-facing machine. Install with `-UpdateType firmware,driver` instead.
- **ThawSpace: optional with your layout.** Everything that matters is written during the
  maintenance window, while Deep Freeze is disabled, so it survives even on `C:\ProgramData`.
  Only the brief daytime no-op checks are lost, and those never touch the status file. With a
  ThawSpace, pass `-StatePath T:\DFMaintenance` to keep everything there.

---

## 3. Push it (once per machine, while Deep Freeze is off)

A scheduled task created on a **Frozen** machine is discarded at the next restart. The script
checks this and refuses with **exit 20** instead of reporting a success that disappears.

**Deep Freeze Cloud > Applications > Scripts (Windows) > Custom Script > Create Custom Script**

| Field | Value |
|---|---|
| URL | where you host `Invoke-DFDcuMaintenance.ps1` (`https://...` or a `\\UNC` path the machines can reach) |
| Type | PowerShell |
| Command line | empty for the defaults, or settings such as `-StatePath T:\DFMaintenance` |
| Run as | **System Account** |

To install, run it while Deep Freeze is disabled:

- **Test machine, during the day:** Live Action **Maintenance > Run Maintenance Period**, then
  **Run Once** the script, then **End Maintenance Period**. Note that this also lets Software
  Updater run its tasks on that machine.
- **The fleet:** **Run Once** during the nightly window, e.g. at 22:30.
- **New machines:** run it once in the image build, while Thawed, so it is in the baseline from day one.

Check the result: the script's exit code (0 = installed), or `dcu-install.json` in the state
folder. On the machine, `Get-ScheduledTask DFMaintenance-DellCommandUpdate` shows the task with
two triggers.

To change settings later, push again with the new command line, while Deep Freeze is off. Each
install replaces the previous task and config.

If Deep Freeze's PowerShell runner fails on execution policy, use the Batch Script type instead.
Have the batch file call
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<path to Invoke-DFDcuMaintenance.ps1>" <settings>`.

### Settings (all optional)

| Setting | Default | Meaning |
|---|---|---|
| `-WindowStart` / `-WindowEnd` | `22:00` / `06:00` | Must match the Maintenance Period. May cross midnight. |
| `-StartDelayMinutes` | `120` | First DCU pass no earlier than WindowStart + this, so Windows Update goes first. Unset, it is capped at a quarter of the window. |
| `-UpdateType` | `bios,firmware,driver` | Add `application` for Dell apps, `others` for the rest. |
| `-UpdateSeverity` | `security,critical,recommended` | Add `optional` for everything. |
| `-UpdateDeviceCategory` | all | e.g. `network,chipset,video` |
| `-StatePath` | ThawSpace by label, else ProgramData | e.g. `T:\DFMaintenance`. Removes any guessing. |
| `-MaxPassesPerNight` | `3` | Install passes per night (each may end in a restart). |
| `-InstallCutoffMinutes` | `90` | No new pass this close to the window end. |
| `-RebootCutoffMinutes` | `30` | No restart this close to the window end. |
| `-RebootDelaySeconds` | `120` | On-screen warning before a restart. |
| `-ServicingWaitMinutes` | `30` | How long to wait for Windows Update / MSI to go idle, before a pass and before a restart. |
| `-RandomDelayMinutes` | `20` | First pass of the night waits a random 0..N min to spread fleet downloads. |
| `-RetryIntervalMinutes` | `60` | How often the window is re-checked. |
| `-ScanTimeoutMinutes` / `-ApplyTimeoutMinutes` | `30` / `120` | A hung dcu-cli is stopped after this. |
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

**Files** (`<state>` is `T:\DFMaintenance\dcu` with a ThawSpace, else `C:\ProgramData\DFMaintenance\dcu`):

| File | What it is |
|---|---|
| `<state>\dcu-status.json` | The last real result. Status-only runs (outside the window, before the start delay, already finished) never overwrite it. **This is the one file a collector needs.** |
| `<state>\dcu-state.json` | Tonight's pass counter and any deferred restart. |
| `<state>\dcu-install.json` | Result of the last install, including refusals. |
| `<state>\logs\dfdcu-YYYYMM.jsonl` | Full history, one JSON object per line. |
| `<state>\dcu-logs\` | Copies of DCU's own logs and scan reports. |
| `%ProgramFiles%\DFMaintenance\DCU\` | The installed script and `config.json`. Admin-only. |
| `%ProgramData%\Dell\DFMaintenance\` | Where dcu-cli writes its logs. DCU only accepts certain folders for those. |
| Application event log, source `DFMaintenance-DCU` | Event ID = 1000 + the run's exit code (e.g. 1000, 1003, 4010); install = 2000/2020/2021. |

`dcu-status.json` fields worth watching: `Outcome`, `Message`, `AppliedTonight` (what went in
across all of tonight's passes), `Dcu.Updates` (what the last scan found), `LastSuccess` (when this
machine last finished cleanly, kept across bad nights).

### Outcomes

| Outcome | Exit | What it means / what to do |
|---|---|---|
| `UpToDate` | 0 | Nothing left to install. `AppliedTonight` lists what went in on earlier passes. |
| `Applied` | 0 | Updates installed, no restart needed. |
| `RebootScheduled` | 3010 | Restarting to finish installs; the next pass runs after the restart. |
| `RebootDeferredBusy` | 3 | DCU needs a restart, but Windows Update / an installer was still running after 30 min. The next trigger restarts once it is idle, or skips the restart if the machine has restarted since. |
| `SkippedServicingBusy` | 3 | Windows Update / MSI was busy for 30 min before a pass; retried at the next trigger. If this happens nightly, raise `-StartDelayMinutes`. |
| `SkippedFrozen` | 2 | **Deep Freeze was not disabled or thawed in the window.** Check the Maintenance Period. |
| `SkippedFreezeStateUnknown` | 2 | DFC.exe missing, or it returned an unexpected code. The status `FreezeDetail` shows the code; see the first check in section 5. |
| `MaxPassesReached` | 3 | Updates still applicable after all passes. If the same ones repeat nightly, read `dcu-logs`. |
| `RebootPendingAtWindowEnd` | 7 | Finished too late to restart. It finishes on a later night; if this is regular, widen the window or shorten the start delay. |
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

### Deep Freeze (do these first)

- [ ] **What DFC.exe says while the Maintenance Period has Deep Freeze disabled.** During the
      window, or after Live Action *Run Maintenance Period*, run the commands in
      [VALIDATION.md](VALIDATION.md) and note the exit code of `DFC.exe get /ISFROZEN`. **Expect 0.**
      This is the check everything depends on. The script installs only on 0, so if a disabled
      Deep Freeze answers anything else, every night ends `SkippedFreezeStateUnknown`. If you see
      that, report the exit code along with `Get-Service DFServ`, so the gate can learn that state.
- [ ] The same command returns **1** during the day, when the machine is Frozen.
- [ ] **A restart *inside* the Maintenance Period comes back with Deep Freeze still disabled.**
      Restart by hand during the period, then run `DFC.exe get /ISFROZEN` again; expect 0.
      Software Updater's own restarts suggest this works, but confirm it.
- [ ] At 06:00 the machine goes back to Frozen, and the next morning's compliance scan shows no DF001.

### Install

- [ ] Pushed while **Frozen**, the script exits **20** and `dcu-install.json` says `RefusedNotThawed`.
- [ ] Pushed during a Maintenance Period, it exits **0**. Task Scheduler shows
      `\DFMaintenance-DellCommandUpdate` running as SYSTEM, with a daily trigger at 00:00
      (repeating hourly) and an at-startup trigger.
- [ ] Files landed in `C:\Program Files\DFMaintenance\DCU` (**not** `Program Files (x86)`). If the
      Deep Freeze agent runs 32-bit PowerShell, the log shows "relaunching in 64-bit PowerShell".
- [ ] DCU's own settings now show its automatic updates as manual and notifications off.
- [ ] The next day, after a Frozen restart, the task is still there.

### A pass

- [ ] `-Mode Run -DryRun -IgnoreWindow` lists the applicable updates. This also proves DCU accepts
      the `-outputLog`/`-report` paths: no 106/107 in `dcu-status-dryrun.json`.
- [ ] During an on-demand Maintenance Period, `-Mode Run -IgnoreWindow` applies updates and
      restarts. Running it again after the restart reports `UpToDate`.
- [ ] Run the task by hand outside the window (Task Scheduler > Run). It exits **1** and changes nothing.

### A real night

- [ ] The next morning, `dcu-status.json` says `UpToDate` or `Applied`, and `AppliedTonight`
      lists what went in.
- [ ] The log shows the first pass waited for 00:00. If you see `SkippedServicingBusy` or
      `RebootDeferredBusy` most nights, Windows Update needs more of the window: raise
      `-StartDelayMinutes`.
- [ ] Over a week, the **same driver does not reappear** in `AppliedTonight` night after night.
      If it does, Windows Update and DCU are fighting; turn off Software Updater's `Drivers` category.
- [ ] **BitLocker machines with a BIOS update:** `manage-bde -status C:` shows Protection On afterwards.
- [ ] `dcu-status.json` begins with `{`: no BOM.
- [ ] Nothing popped up for users during the day.

---

## Uninstall

While Deep Freeze is off:

```powershell
& "$env:ProgramFiles\DFMaintenance\DCU\Invoke-DFDcuMaintenance.ps1" -Mode Uninstall
```

This removes the task, `%ProgramFiles%\DFMaintenance\DCU` and `%ProgramData%\Dell\DFMaintenance`.
Logs and status are kept. DCU's own scheduler stays on manual; to hand scheduling back to DCU,
run `dcu-cli.exe /configure -scheduleAuto`.

---

## Sources

- [Dell Command | Update 5.x Reference Guide (Rev. A14, Feb 2026)](https://www.dell.com/support/manuals/en-us/command-update/dcu_rg/dell-command-update-cli-commands?guid=guid-92619086-5f7c-4a05-bce2-0d560c15e8ed&lang=en-us): CLI options, restricted log folders, BitLocker behaviour
- [Dell Command | Update CLI error codes](https://www.dell.com/support/manuals/en-us/command-update/dcu_rg/command-line-interface-error-codes?guid=guid-fbb96b06-4603-423a-baec-cbf5963d8948&lang=en-us)
- [Deep Freeze Cloud: Maintenance Period](https://docs.faronics.com/deep-freeze-cloud/using-deep-freeze-cloud-console/general-settings/maintenance-period): services disabled for the period, Software Updater tasks
- [Deep Freeze Cloud: Software Updater, Windows Update tab](https://docs.faronics.com/deep-freeze-cloud/using-deep-freeze-cloud-console/software-updater-service-windows/windows-update-tab-for-ultimate-only): update categories (incl. Drivers), restart options
- [Deep Freeze Cloud: Live Actions](https://docs.faronics.com/deep-freeze-cloud/using-deep-freeze-cloud-console/computers/live-actions): Run / End Maintenance Period, Reboot Thawed / Frozen
- [Deep Freeze Cloud: Workstation Tasks](https://docs.faronics.com/deep-freeze-cloud/using-deep-freeze-cloud-console/deep-freeze-service/workstation-tasks-tab), [Thawed Period](https://docs.faronics.com/deep-freeze-cloud/using-deep-freeze-cloud-console/deep-freeze-service/workstation-tasks-tab/thawed-period), [Batch File](https://docs.faronics.com/deep-freeze-cloud/using-deep-freeze-cloud-console/deep-freeze-service/workstation-tasks-tab/batch-file)
- [Deep Freeze Cloud: Scripts (Windows)](https://docs.faronics.com/deep-freeze-cloud/using-deep-freeze-cloud-console/applications/scripts-windows)
- [Deep Freeze Command Line Syntax](https://docs.faronics.com/deep-freeze-cloud/using-deep-freeze-cloud-console/deep-freeze-service/advanced-settings-tab/deep-freeze-command-line-syntax): `DFC get /ISFROZEN`
