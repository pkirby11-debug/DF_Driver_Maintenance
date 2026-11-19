#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
    Tests for scripts/Invoke-DFDcuMaintenance.ps1.

    The script is dot-sourced (its entry point does not run when dot-sourced), so every function
    can be exercised directly. Windows-only pieces -- Task Scheduler, the registry, CIM, ACLs,
    Get-Service -- are mocked or skipped.

    On Linux/macOS, tiny shell scripts stand in for DFC.exe and dcu-cli.exe. That tests the real
    process handling: exit codes, argument passing (including the literal 'get' in
    "DFC get /ISFROZEN"), timeouts and stderr noise. Those tests are skipped on Windows, where the
    on-device checklist in docs/DCU-MAINTENANCE.md covers the real binaries.

    Note: a Linux process exit code is 8 bits, so DCU codes above 255 (500, 1002, 3003...) are
    exercised through the mocked Invoke-DcuCli, not through the fake executable.
#>

BeforeDiscovery {
    # -Skip is evaluated during discovery, before BeforeAll runs, so this has to be set here.
    $CanFakeExe = ($PSVersionTable.PSEdition -eq 'Core') -and ($IsLinux -or $IsMacOS)
}

BeforeAll {
    $script:ScriptUnderTest = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\Invoke-DFDcuMaintenance.ps1')).Path
    $script:CanFakeExe = ($PSVersionTable.PSEdition -eq 'Core') -and ($IsLinux -or $IsMacOS)

    # Fake Windows layout. Everything the script trusts is resolved from these variables.
    $script:Root = Join-Path ([System.IO.Path]::GetTempPath()) ("dfdcu-" + [guid]::NewGuid().ToString('N'))
    $script:SavedEnv = @{}
    foreach ($name in 'ProgramFiles', 'ProgramFiles(x86)', 'ProgramW6432', 'SystemRoot', 'ProgramData', 'SystemDrive', 'COMPUTERNAME') {
        $script:SavedEnv[$name] = [Environment]::GetEnvironmentVariable($name)
    }
    $script:Pf = Join-Path $script:Root 'pf'
    $script:Pf86 = Join-Path $script:Root 'pf86'
    $script:Win = Join-Path $script:Root 'win'
    $script:Pd = Join-Path $script:Root 'pd'
    foreach ($dir in $script:Pf, $script:Pf86, $script:Win, $script:Pd) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [Environment]::SetEnvironmentVariable('ProgramFiles', $script:Pf)
    [Environment]::SetEnvironmentVariable('ProgramFiles(x86)', $script:Pf86)
    [Environment]::SetEnvironmentVariable('ProgramW6432', $script:Pf)
    [Environment]::SetEnvironmentVariable('SystemRoot', $script:Win)
    [Environment]::SetEnvironmentVariable('ProgramData', $script:Pd)
    [Environment]::SetEnvironmentVariable('SystemDrive', $null)
    [Environment]::SetEnvironmentVariable('COMPUTERNAME', 'TESTPC')

    . $script:ScriptUnderTest

    # Never sleep in tests.
    $script:DcuBusyDelaySeconds = 0
    $script:DcuServicingPollSeconds = 0

    function script:New-TestDir {
        param([string] $Name = 'case')
        $dir = Join-Path $script:Root ("{0}-{1}" -f $Name, [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        return $dir
    }

    function script:New-FakeExe {
        # A shell script under a fake trusted root, named like the Windows binary it replaces.
        param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Body)
        New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
        [System.IO.File]::WriteAllText($Path, "#!/usr/bin/env bash`n$Body`n")
        & chmod +x $Path
        return $Path
    }

    function script:New-TestConfig {
        param([hashtable] $Overrides = @{})
        $raw = @{ RandomDelayMinutes = 0 }
        foreach ($k in $Overrides.Keys) { $raw[$k] = $Overrides[$k] }
        $built = ConvertTo-DcuConfig -Raw $raw
        if (@($built.Problems).Count) { throw "Test config problems: $($built.Problems -join ' | ')" }
        return $built.Config
    }

    function script:New-TestState {
        param([string] $Path)
        return [pscustomobject]@{ Path = $Path; Source = 'test'; IsPersistent = $true; VolumeSerial = $null; Warning = $null }
    }

    function script:Read-Json {
        param([string] $Path)
        return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
    }

    $script:SampleReport = @'
<?xml version="1.0" encoding="utf-8"?>
<updates>
  <update>
    <release>ABC12</release>
    <name>Dell OptiPlex 7010 System BIOS</name>
    <version>1.22.0</version>
    <date>2026-10-01</date>
    <urgency>Urgent</urgency>
    <type>BIOS</type>
    <category>BIOS</category>
  </update>
  <update>
    <release>DEF34</release>
    <name>Intel Chipset Device Software</name>
    <version>10.1.19222.8341</version>
    <date>2026-09-14</date>
    <urgency>Recommended</urgency>
    <type>Driver</type>
    <category>Chipset</category>
  </update>
</updates>
'@

    # Windows-only cmdlets the script calls behind try/catch; define stubs so they can be mocked.
    foreach ($name in 'Get-ScheduledTask', 'Unregister-ScheduledTask', 'Get-Service') {
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
            Set-Item -Path "function:global:$name" -Value { param([Parameter(ValueFromRemainingArguments)] $Rest) }
            $script:DefinedStubs += @($name)
        }
    }
}

AfterAll {
    foreach ($name in $script:SavedEnv.Keys) { [Environment]::SetEnvironmentVariable($name, $script:SavedEnv[$name]) }
    foreach ($name in @($script:DefinedStubs)) { if ($name) { Remove-Item -Path "function:global:$name" -ErrorAction SilentlyContinue } }
    if ($script:Root -and (Test-Path $script:Root)) { Remove-Item $script:Root -Recurse -Force -ErrorAction SilentlyContinue }
}

# =================================================================================================
Describe 'Source hygiene (Windows PowerShell 5.1 safety)' {
    BeforeAll {
        $script:Tokens = $null
        $script:Errors = $null
        $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptUnderTest, [ref]$script:Tokens, [ref]$script:Errors)
        $script:Commands = $script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
    }

    It 'parses with no errors' {
        @($script:Errors).Count | Should -Be 0
    }

    It 'is pure ASCII (5.1 reads a BOM-less file as ANSI, mangling anything else)' {
        $bytes = [System.IO.File]::ReadAllBytes($script:ScriptUnderTest)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }

    It 'uses no PowerShell 7-only operators' {
        $bad = $script:Ast.FindAll({
            param($n)
            $n.GetType().Name -in 'TernaryExpressionAst', 'PipelineChainAst' -or
            ($n -is [System.Management.Automation.Language.BinaryExpressionAst] -and "$($n.Operator)" -eq 'QuestionQuestion')
        }, $true)
        @($bad).Count | Should -Be 0
    }

    It 'never uses Set-Content, Add-Content or Out-File (5.1 would write a BOM)' {
        @($script:Commands | Where-Object { $_.GetCommandName() -in 'Set-Content', 'Add-Content', 'Out-File' }).Count | Should -Be 0
    }

    It 'discards New-Item and Register-ScheduledTask output, so no function returns stray objects' {
        $leaks = foreach ($command in $script:Commands) {
            if ($command.GetCommandName() -notin 'New-Item', 'Register-ScheduledTask') { continue }
            $pipeline = $command.Parent
            $piped = ($pipeline -is [System.Management.Automation.Language.PipelineAst]) -and $pipeline.PipelineElements.Count -gt 1
            $assigned = $pipeline.Parent -is [System.Management.Automation.Language.AssignmentStatementAst]
            if (-not $piped -and -not $assigned) { "line $($command.Extent.StartLineNumber): $($command.Extent.Text)" }
        }
        @($leaks) | Should -BeNullOrEmpty
    }

    It 'uses "return , `$x" only in Get-DcuValue (callers wrap results in @(), which would nest it)' {
        # Regression guard. With "return , `$list", @(f) yields a ONE-element array holding the
        # list, so an empty result has Count 1. That made Wait-DcuServicingIdle see Windows
        # servicing as permanently busy -- every night would have waited 30 min and skipped.
        $returns = $script:Ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.ReturnStatementAst] -and $n.Pipeline -and
            $n.Pipeline.Extent.Text -match '^,'
        }, $true)
        foreach ($r in $returns) {
            $function = $r.Parent
            while ($function -and $function -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $function = $function.Parent }
            $function.Name | Should -Be 'Get-DcuValue'
        }
    }

    It 'never passes -userConsent, which DCU 5.x removed (an unknown option fails the whole command with 106)' {
        (Get-Content -LiteralPath $script:ScriptUnderTest -Raw) | Should -Not -Match '-userConsent='
    }

    It 'calls DFC.exe with the documented "get /ISFROZEN" form' {
        $calls = @($script:Commands | Where-Object { $_.Extent.Text -match "'/ISFROZEN'" })
        $calls.Count | Should -BeGreaterThan 0
        foreach ($call in $calls) { $call.Extent.Text | Should -Match "'get'\s+'/ISFROZEN'" }
    }

    It 'uses the same documented form in the DFMaintenance module' {
        $moduleFile = Join-Path $PSScriptRoot '..\src\DFMaintenance\Public\Get-DFFreezeState.ps1'
        $text = Get-Content -LiteralPath $moduleFile -Raw
        $text | Should -Match "& \`$dfc 'get' '/ISFROZEN'"
        $text | Should -Not -Match "& \`$dfc '/ISFROZEN'"
    }
}

# =================================================================================================
Describe 'ConvertTo-DcuConfig' {
    It 'returns the defaults with no problems for empty input' {
        $built = ConvertTo-DcuConfig -Raw @{}
        @($built.Problems).Count | Should -Be 0
        $built.Config.WindowStart | Should -Be '22:00'
        $built.Config.WindowEnd | Should -Be '06:00'
        $built.Config.UpdateType | Should -Be @('bios', 'firmware', 'driver')
        $built.Config.MaxPassesPerNight | Should -Be 3
        $built.Config.NoReboot | Should -BeFalse
    }

    It 'accepts a $null raw object (no config.json yet)' {
        $built = ConvertTo-DcuConfig -Raw $null
        @($built.Problems).Count | Should -Be 0
        $built.Config.WindowStart | Should -Be '22:00'
    }

    It 'splits a comma-joined list the way a -File command line delivers it' {
        $config = (ConvertTo-DcuConfig -Raw @{ UpdateType = @('BIOS; Driver'); UpdateSeverity = 'security,critical' }).Config
        $config.UpdateType | Should -Be @('bios', 'driver')
        $config.UpdateSeverity | Should -Be @('security', 'critical')
    }

    It 'reads switch parameters' {
        $config = (ConvertTo-DcuConfig -Raw @{ NoReboot = [switch]$true; WakeToRun = [switch]$false }).Config
        $config.NoReboot | Should -BeTrue
        $config.WakeToRun | Should -BeFalse
    }

    It 'rejects bad values with a reason and keeps the default' {
        $built = ConvertTo-DcuConfig -Raw @{
            WindowStart = '25:00'; MaxPassesPerNight = 0; UpdateType = 'drivers'; MinimumDcuVersion = 'five'; NoReboot = 'yes'
        }
        @($built.Problems).Count | Should -Be 5
        $built.Config.WindowStart | Should -Be '22:00'
        $built.Config.MaxPassesPerNight | Should -Be 3
        $built.Config.UpdateType | Should -Be @('bios', 'firmware', 'driver')
        $built.Config.MinimumDcuVersion | Should -Be '5.0'
        $built.Config.NoReboot | Should -BeFalse
    }

    It 'drops unsupported list entries but keeps the valid ones' {
        $built = ConvertTo-DcuConfig -Raw @{ UpdateType = 'bios,driver,rm -rf' }
        $built.Config.UpdateType | Should -Be @('bios', 'driver')
        @($built.Problems).Count | Should -Be 1
    }

    It 'allows an empty device-category filter (meaning all categories)' {
        $built = ConvertTo-DcuConfig -Raw @{ UpdateDeviceCategory = '' }
        @($built.Problems).Count | Should -Be 0
        @($built.Config.UpdateDeviceCategory).Count | Should -Be 0
    }

    It 'refuses a zero-length window' {
        $built = ConvertTo-DcuConfig -Raw @{ WindowStart = '03:00'; WindowEnd = '03:00' }
        @($built.Problems).Count | Should -BeGreaterThan 0
        $built.Config.WindowStart | Should -Be '22:00'
    }

    It 'refuses a window too short for a scan, an install and a restart' {
        $built = ConvertTo-DcuConfig -Raw @{ WindowStart = '05:00'; WindowEnd = '05:30' }
        @($built.Problems).Count | Should -BeGreaterThan 0
        $built.Config.WindowEnd | Should -Be '06:00'
    }

    It 'clamps cutoffs that would leave no time to work' {
        $built = ConvertTo-DcuConfig -Raw @{ WindowStart = '02:00'; WindowEnd = '04:00'; InstallCutoffMinutes = 200; RebootCutoffMinutes = 500 }
        $built.Config.InstallCutoffMinutes | Should -Be 90      # 120-min window - 30
        $built.Config.RebootCutoffMinutes | Should -Be 90       # never later than the install cutoff
    }

    It 'treats string or out-of-range numbers from a hand-edited config.json as problems' {
        $raw = '{ "MaxPassesPerNight": "99", "RebootDelaySeconds": -5, "LogRetentionDays": 1.5 }' | ConvertFrom-Json
        $built = ConvertTo-DcuConfig -Raw $raw
        $built.Config.MaxPassesPerNight | Should -Be 3
        $built.Config.RebootDelaySeconds | Should -Be 120
        $built.Config.LogRetentionDays | Should -Be 60
        @($built.Problems).Count | Should -Be 3
    }

    It 'requires StatePath to be absolute' {
        $built = ConvertTo-DcuConfig -Raw @{ StatePath = 'relative\path' }
        @($built.Problems).Count | Should -Be 1
        $built.Config.StatePath | Should -BeNullOrEmpty
    }
}

# =================================================================================================
Describe 'Read-DcuInstalledConfig and Write-DcuJsonFile' {
    It 'round-trips a config through BOM-less JSON with no problems' {
        $dir = New-TestDir 'cfg'
        $path = Join-Path $dir 'config.json'
        $config = New-TestConfig @{ WindowStart = '02:05'; UpdateType = 'bios,driver'; NoReboot = $true }
        $config.PinnedStatePath = (Join-Path $dir 'state')
        Write-DcuJsonFile -Path $path -InputObject $config

        [System.IO.File]::ReadAllBytes($path)[0] | Should -Be ([byte][char]'{')
        $loaded = Read-DcuInstalledConfig -Path $path
        $loaded.Found | Should -BeTrue
        @($loaded.Problems).Count | Should -Be 0
        $loaded.Config.WindowStart | Should -Be '02:05'
        $loaded.Config.UpdateType | Should -Be @('bios', 'driver')
        $loaded.Config.NoReboot | Should -BeTrue
        $loaded.Config.PinnedStatePath | Should -Be $config.PinnedStatePath
        Test-Path -LiteralPath ($path + '.tmp') | Should -BeFalse
    }

    It 'keeps a single-entry list as a list across the round trip' {
        $dir = New-TestDir 'cfg1'
        $path = Join-Path $dir 'config.json'
        Write-DcuJsonFile -Path $path -InputObject (New-TestConfig @{ UpdateType = 'driver' })
        (Read-DcuInstalledConfig -Path $path).Config.UpdateType | Should -Be @('driver')
    }

    It 'falls back to defaults, with a note, when config.json is missing' {
        $loaded = Read-DcuInstalledConfig -Path (Join-Path (New-TestDir 'nocfg') 'config.json')
        $loaded.Found | Should -BeFalse
        $loaded.Config.WindowStart | Should -Be '22:00'
        $loaded.Problems[0] | Should -Match 'No config.json'
    }

    It 'falls back to defaults, with a note, when config.json is corrupt' {
        $path = Join-Path (New-TestDir 'badcfg') 'config.json'
        [System.IO.File]::WriteAllText($path, '{ not json')
        $loaded = Read-DcuInstalledConfig -Path $path
        $loaded.Found | Should -BeFalse
        $loaded.Problems[0] | Should -Match 'unreadable'
    }
}

# =================================================================================================
Describe 'Get-DcuWindowState (22:00-06:00, cutoffs 90/30)' {
    BeforeAll { $script:WinCfg = New-TestConfig }

    It 'is in the window at 23:30, and the night is that date' {
        $w = Get-DcuWindowState -Now ([datetime]'2026-11-19T23:30:00') -Config $script:WinCfg
        $w.InWindow | Should -BeTrue
        $w.NightId | Should -Be '2026-11-19'
        $w.MinutesUntilClose | Should -Be 390
        $w.CanStartInstall | Should -BeTrue
    }

    It 'gives 03:30 the night the window opened (the previous date)' {
        $w = Get-DcuWindowState -Now ([datetime]'2026-11-20T03:30:00') -Config $script:WinCfg
        $w.InWindow | Should -BeTrue
        $w.NightId | Should -Be '2026-11-19'
    }

    It 'counts midnight as inside the window' {
        $w = Get-DcuWindowState -Now ([datetime]'2026-11-20T00:00:00') -Config $script:WinCfg
        $w.InWindow | Should -BeTrue
        $w.NightId | Should -Be '2026-11-19'
    }

    It 'opens at exactly 22:00 and closes at exactly 06:00' {
        (Get-DcuWindowState -Now ([datetime]'2026-11-19T22:00:00') -Config $script:WinCfg).InWindow | Should -BeTrue
        (Get-DcuWindowState -Now ([datetime]'2026-11-19T21:59:00') -Config $script:WinCfg).InWindow | Should -BeFalse
        (Get-DcuWindowState -Now ([datetime]'2026-11-20T06:00:00') -Config $script:WinCfg).InWindow | Should -BeFalse
        (Get-DcuWindowState -Now ([datetime]'2026-11-20T14:00:00') -Config $script:WinCfg).InWindow | Should -BeFalse
    }

    It 'stops starting passes 90 minutes before the end' {
        (Get-DcuWindowState -Now ([datetime]'2026-11-20T04:29:00') -Config $script:WinCfg).CanStartInstall | Should -BeTrue
        (Get-DcuWindowState -Now ([datetime]'2026-11-20T04:31:00') -Config $script:WinCfg).CanStartInstall | Should -BeFalse
    }

    It 'stops restarting 30 minutes before the end' {
        (Get-DcuWindowState -Now ([datetime]'2026-11-20T05:29:00') -Config $script:WinCfg).CanReboot | Should -BeTrue
        (Get-DcuWindowState -Now ([datetime]'2026-11-20T05:31:00') -Config $script:WinCfg).CanReboot | Should -BeFalse
    }

    It 'handles a window that does not cross midnight' {
        $cfg = New-TestConfig @{ WindowStart = '01:00'; WindowEnd = '05:00' }
        (Get-DcuWindowState -Now ([datetime]'2026-11-20T00:30:00') -Config $cfg).InWindow | Should -BeFalse
        $w = Get-DcuWindowState -Now ([datetime]'2026-11-20T01:00:00') -Config $cfg
        $w.InWindow | Should -BeTrue
        $w.NightId | Should -Be '2026-11-20'
        $w.MinutesUntilClose | Should -Be 240
    }
}

# =================================================================================================
Describe 'Get-DcuSchedulePlan' {
    It 'derives the default triggers from the window' {
        $plan = Get-DcuSchedulePlan -Config (New-TestConfig)
        $plan.FirstStart | Should -Be '22:10'
        $plan.RepeatEveryMinutes | Should -Be 60
        $plan.RepeatForMinutes | Should -Be 380   # 22:10 -> 04:30
        $plan.InstallCutoff | Should -Be '04:30'
        $plan.RebootCutoff | Should -Be '05:30'
        $plan.WindowMinutes | Should -Be 480
    }

    It 'registers no repetition when RetryIntervalMinutes is 0' {
        $plan = Get-DcuSchedulePlan -Config (New-TestConfig @{ RetryIntervalMinutes = 0 })
        $plan.RepeatEveryMinutes | Should -Be 0
        $plan.RepeatForMinutes | Should -Be 0
    }

    It 'wraps a first start past midnight' {
        $plan = Get-DcuSchedulePlan -Config (New-TestConfig @{ WindowStart = '23:50'; StartDelayMinutes = 15 })
        $plan.FirstStart | Should -Be '00:05'
        $plan.FirstStartSpan.TotalMinutes | Should -Be 5
    }
}

# =================================================================================================
Describe 'Get-DcuExitInfo' {
    It 'classifies <Code> as <Category>' -ForEach @(
        @{ Code = 0; Category = 'Success' }
        @{ Code = 1; Category = 'RebootRequired' }
        @{ Code = 5; Category = 'RebootRequired' }
        @{ Code = 500; Category = 'UpToDate' }
        @{ Code = 3; Category = 'Unavailable' }
        @{ Code = 7; Category = 'Unavailable' }
        @{ Code = 106; Category = 'UsageError' }
        @{ Code = 6; Category = 'Busy' }
        @{ Code = 3003; Category = 'Busy' }
        @{ Code = 3000; Category = 'ServiceStopped' }
        @{ Code = 3002; Category = 'Unavailable' }
        @{ Code = 1002; Category = 'Transient' }
        @{ Code = 503; Category = 'Transient' }
        @{ Code = 9999; Category = 'Unknown' }
    ) {
        (Get-DcuExitInfo -Code $Code).Category | Should -Be $Category
    }

    It 'maps every documented code to a category the run knows how to handle' {
        $known = 'Success', 'RebootRequired', 'UpToDate', 'Unavailable', 'UsageError', 'Busy', 'ServiceStopped', 'Transient'
        foreach ($code in $script:DcuExitCodes.Keys) { (Get-DcuExitInfo -Code $code).Category | Should -BeIn $known }
    }
}

# =================================================================================================
Describe 'DCU argument building' {
    It 'quotes an option value only when it contains a space' {
        New-DcuOption -Name 'outputLog' -Value 'C:\ProgramData\Dell\x.log' | Should -Be '-outputLog=C:\ProgramData\Dell\x.log'
        New-DcuOption -Name 'outputLog' -Value 'C:\Path With Space\x.log' | Should -Be '-outputLog="C:\Path With Space\x.log"'
    }

    It 'passes the update filters explicitly' {
        $options = Get-DcuFilterOptions -Config (New-TestConfig)
        $options | Should -Be @('-updateType=bios,firmware,driver', '-updateSeverity=security,critical,recommended')
        $withCategory = Get-DcuFilterOptions -Config (New-TestConfig @{ UpdateDeviceCategory = 'network,chipset' })
        $withCategory[-1] | Should -Be '-updateDeviceCategory=network,chipset'
    }

    It 'rebuilds -File arguments for the 64-bit relaunch' {
        $bound = [ordered]@{ Mode = 'Install'; UpdateType = @('bios', 'driver'); NoReboot = [switch]$true; WakeToRun = [switch]$false; StatePath = ''; MaxPassesPerNight = 2 }
        ConvertTo-DcuRelaunchArguments -Bound $bound | Should -Be @('-Mode', 'Install', '-UpdateType', 'bios,driver', '-NoReboot', '-MaxPassesPerNight', '2')
    }
}

# =================================================================================================
Describe 'Test-DcuTrustedPath (everything run as SYSTEM must pass this)' {
    It 'accepts the expected binary under a trusted root' {
        Test-DcuTrustedPath -Path (Join-Path $script:Pf86 'Dell/CommandUpdate/dcu-cli.exe') -ExpectedLeaf 'dcu-cli.exe' | Should -BeTrue
        Test-DcuTrustedPath -Path (Join-Path $script:Win 'SysWOW64/DFC.exe') -ExpectedLeaf 'DFC.exe' | Should -BeTrue
    }

    It 'rejects a sibling directory that merely shares the prefix' {
        Test-DcuTrustedPath -Path ($script:Pf + 'Evil/DFC.exe') -ExpectedLeaf 'DFC.exe' | Should -BeFalse
    }

    It 'rejects traversal back out of a trusted root' {
        Test-DcuTrustedPath -Path (Join-Path $script:Pf '../outside/DFC.exe') -ExpectedLeaf 'DFC.exe' | Should -BeFalse
    }

    It 'rejects the wrong file name and empty input' {
        Test-DcuTrustedPath -Path (Join-Path $script:Pf 'Faronics/Deep Freeze/calc.exe') -ExpectedLeaf 'DFC.exe' | Should -BeFalse
        Test-DcuTrustedPath -Path '' | Should -BeFalse
    }
}

# =================================================================================================
Describe 'Deep Freeze state via a fake DFC.exe' -Skip:(-not $CanFakeExe) {
    BeforeAll {
        $script:FakeDfc = New-FakeExe -Path (Join-Path $script:Win 'SysWOW64/DFC.exe') -Body @'
echo "$@" >> "${DFC_FAKE_ARGLOG:-/dev/null}"
if [ -n "$DFC_FAKE_STDERR" ]; then echo "$DFC_FAKE_STDERR" >&2; fi
if [ "$#" -eq 2 ] && [ "$1" = "get" ] && [ "$2" = "/ISFROZEN" ]; then exit "${DFC_FAKE_EXIT:-1}"; fi
exit 42
'@
    }
    AfterEach {
        Remove-Item Env:\DFC_FAKE_EXIT, Env:\DFC_FAKE_STDERR, Env:\DFC_FAKE_ARGLOG -ErrorAction SilentlyContinue
    }

    It 'reads exit code 1 as Frozen' {
        $env:DFC_FAKE_EXIT = '1'
        $state = Get-DcuFreezeState
        $state.State | Should -Be 'Frozen'
        $state.Method | Should -Be 'DFC.exe get /ISFROZEN'
    }

    It 'reads exit code 0 as Thawed' {
        $env:DFC_FAKE_EXIT = '0'
        (Get-DcuFreezeState).State | Should -Be 'Thawed'
    }

    It 'reports anything else as Unknown, never as a guess' {
        $env:DFC_FAKE_EXIT = '7'
        $state = Get-DcuFreezeState
        $state.State | Should -Be 'Unknown'
        $state.Detail | Should -Match "exit code '7'"
    }

    It 'passes exactly "get /ISFROZEN" (the fake answers 42 to anything else)' {
        $log = Join-Path (New-TestDir 'dfcargs') 'args.txt'
        $env:DFC_FAKE_ARGLOG = $log
        $env:DFC_FAKE_EXIT = '0'
        [void](Get-DcuFreezeState)
        (Get-Content -LiteralPath $log -Raw).Trim() | Should -Be 'get /ISFROZEN'
    }

    It 'still reads the exit code when DFC.exe writes to stderr' {
        $env:DFC_FAKE_EXIT = '0'
        $env:DFC_FAKE_STDERR = 'Deep Freeze banner on stderr'
        (Get-DcuFreezeState).State | Should -Be 'Thawed'
    }

    It 'ignores a DFCPath outside the trusted roots and uses the real one' {
        $evil = New-FakeExe -Path (Join-Path $script:Root 'users/public/DFC.exe') -Body 'exit 0'
        $env:DFC_FAKE_EXIT = '1'
        Mock Write-Host { }
        $state = Get-DcuFreezeState -DfcPath $evil
        $state.DfcPath | Should -Be $script:FakeDfc
        $state.State | Should -Be 'Frozen'
    }
}

Describe 'Deep Freeze state without DFC.exe' {
    BeforeAll {
        $script:HiddenDfc = $null
        $real = Join-Path $script:Win 'SysWOW64/DFC.exe'
        if (Test-Path $real) { $script:HiddenDfc = "$real.hidden"; Move-Item $real $script:HiddenDfc }
    }
    AfterAll {
        if ($script:HiddenDfc) { Move-Item $script:HiddenDfc ($script:HiddenDfc -replace '\.hidden$', '') }
    }

    It 'is NotInstalled when there is neither a service nor DFC.exe' {
        Mock Get-Service { }
        (Get-DcuFreezeState).State | Should -Be 'NotInstalled'
    }

    It 'is Unknown when the Deep Freeze service exists but DFC.exe does not' {
        Mock Get-Service { [pscustomobject]@{ Name = 'DFServ'; Status = 'Running' } }
        $state = Get-DcuFreezeState
        $state.State | Should -Be 'Unknown'
        $state.ServiceFound | Should -BeTrue
    }
}

# =================================================================================================
Describe 'Invoke-DcuCli via a fake dcu-cli.exe' -Skip:(-not $CanFakeExe) {
    BeforeAll {
        $script:FakeDcu = New-FakeExe -Path (Join-Path $script:Pf86 'Dell/CommandUpdate/dcu-cli.exe') -Body @'
printf '%s\n' "$@" > "${DCU_FAKE_ARGFILE:-/dev/null}"
if [ -n "$DCU_FAKE_SLEEP" ]; then sleep "$DCU_FAKE_SLEEP"; fi
echo "fake dcu stdout"
echo "fake dcu stderr" >&2
exit "${DCU_FAKE_EXIT:-0}"
'@
        Mock Write-Host { }
    }
    AfterEach {
        Remove-Item Env:\DCU_FAKE_EXIT, Env:\DCU_FAKE_SLEEP, Env:\DCU_FAKE_ARGFILE -ErrorAction SilentlyContinue
    }

    It 'returns the exit code <Code>' -ForEach @(@{ Code = 0 }, @{ Code = 1 }, @{ Code = 5 }, @{ Code = 42 }) {
        $env:DCU_FAKE_EXIT = [string]$Code
        $r = Invoke-DcuCli -DcuPath $script:FakeDcu -Arguments @('/scan', '-silent') -TimeoutMinutes 1 -Tag 'exit'
        $r.ExitCode | Should -Be $Code
        $r.TimedOut | Should -BeFalse
    }

    It 'keeps a quoted value with spaces as one argument' {
        $argFile = Join-Path (New-TestDir 'dcuargs') 'args.txt'
        $env:DCU_FAKE_ARGFILE = $argFile
        $options = @('/applyUpdates', '-silent', (New-DcuOption -Name 'outputLog' -Value '/tmp/a b/x.log'), '-reboot=disable')
        [void](Invoke-DcuCli -DcuPath $script:FakeDcu -Arguments $options -TimeoutMinutes 1 -Tag 'args')
        Get-Content -LiteralPath $argFile | Should -Be @('/applyUpdates', '-silent', '-outputLog=/tmp/a b/x.log', '-reboot=disable')
    }

    It 'captures the tail of stdout and stderr' {
        $r = Invoke-DcuCli -DcuPath $script:FakeDcu -Arguments @('/version') -TimeoutMinutes 1 -Tag 'tail'
        $r.OutputTail | Should -Match 'fake dcu stdout'
        $r.OutputTail | Should -Match 'fake dcu stderr'
    }

    It 'stops a hung dcu-cli at the timeout' {
        $env:DCU_FAKE_SLEEP = '20'
        $r = Invoke-DcuCli -DcuPath $script:FakeDcu -Arguments @('/scan') -TimeoutMinutes 0.03 -Tag 'hang'
        $r.TimedOut | Should -BeTrue
        $r.ExitCode | Should -BeNullOrEmpty
        $r.DurationSeconds | Should -BeLessThan 10
    }

    It 'reports a start failure instead of throwing' {
        $r = Invoke-DcuCli -DcuPath (Join-Path $script:Root 'missing/dcu-cli.exe') -Arguments @('/scan') -TimeoutMinutes 1 -Tag 'missing'
        $r.ExitCode | Should -BeNullOrEmpty
        $r.StartError | Should -Not -BeNullOrEmpty
    }

    It 'classifies a timeout as TimedOut' {
        $env:DCU_FAKE_SLEEP = '20'
        $r = Invoke-DcuCliWithRetry -DcuPath $script:FakeDcu -Arguments @('/scan') -TimeoutMinutes 0.03 -Tag 'hang2'
        $r.Category | Should -Be 'TimedOut'
    }

    It 'finds dcu-cli.exe under Program Files (x86)' {
        $found = Find-DcuCli
        $found.Path | Should -Be $script:FakeDcu
    }
}

# =================================================================================================
Describe 'List-returning helpers stay flat under @()' {
    It 'ConvertTo-DcuList' {
        @(ConvertTo-DcuList 'a,b').Count | Should -Be 2
        @(ConvertTo-DcuList 'a').Count | Should -Be 1
        @(ConvertTo-DcuList '').Count | Should -Be 0
    }

    It 'Get-DcuFilterOptions' {
        @(Get-DcuFilterOptions -Config (New-TestConfig)).Count | Should -Be 2
    }

    It 'ConvertTo-DcuRelaunchArguments' {
        @(ConvertTo-DcuRelaunchArguments -Bound @{}).Count | Should -Be 0
        @(ConvertTo-DcuRelaunchArguments -Bound @{ Mode = 'Run' }).Count | Should -Be 2
    }

    It 'Test-DcuServicingBusy and Wait-DcuServicingIdle report idle when nothing is installing (unmocked)' {
        Mock Write-Host { }
        @(Test-DcuServicingBusy).Count | Should -Be 0
        $idle = Wait-DcuServicingIdle -MaxMinutes 0
        $idle.Idle | Should -BeTrue
        $idle.WaitedSeconds | Should -Be 0
    }

    It 'Get-DcuPendingReboot is empty when nothing is pending (unmocked)' -Skip:(-not $CanFakeExe) {
        # Off Windows there is no HKLM: drive, so this checks the empty case cleanly.
        @(Get-DcuPendingReboot).Count | Should -Be 0
    }
}

# =================================================================================================
Describe 'Read-DcuScanReport' {
    BeforeAll { Mock Write-Host { } }

    It 'flattens each update to an object' {
        $path = Join-Path (New-TestDir 'report') 'r.xml'
        [System.IO.File]::WriteAllText($path, $script:SampleReport)
        $updates = @(Read-DcuScanReport -Path $path)
        $updates.Count | Should -Be 2
        $updates[0].name | Should -Be 'Dell OptiPlex 7010 System BIOS'
        $updates[1].type | Should -Be 'Driver'
    }

    It 'returns nothing, without throwing, for a missing or corrupt report' {
        @(Read-DcuScanReport -Path (Join-Path $script:Root 'nope.xml')).Count | Should -Be 0
        $bad = Join-Path (New-TestDir 'badreport') 'r.xml'
        [System.IO.File]::WriteAllText($bad, '<updates><update>')
        @(Read-DcuScanReport -Path $bad).Count | Should -Be 0
    }

    It 'refuses a report that carries a DTD' {
        $path = Join-Path (New-TestDir 'dtd') 'r.xml'
        [System.IO.File]::WriteAllText($path, '<?xml version="1.0"?><!DOCTYPE x [<!ENTITY a "aaaa">]><updates><update><name>&a;</name></update></updates>')
        @(Read-DcuScanReport -Path $path).Count | Should -Be 0
    }
}

# =================================================================================================
Describe 'Night state (the pass counter)' {
    BeforeAll { Mock Write-Host { } }

    It 'starts fresh when there is no file' {
        $state = Read-DcuNightState -Path (Join-Path (New-TestDir 'ns') 'dcu-state.json') -NightId '2026-11-19'
        $state.Passes | Should -Be 0
        $state.Completed | Should -BeFalse
    }

    It 'round-trips within the same night' {
        $path = Join-Path (New-TestDir 'ns') 'dcu-state.json'
        $state = New-DcuNightState -NightId '2026-11-19'
        $state.Passes = 2; $state.InProgress = $true; $state.LastOutcome = 'RebootScheduled'
        Save-DcuNightState -Path $path -State $state | Should -BeTrue
        $read = Read-DcuNightState -Path $path -NightId '2026-11-19'
        $read.Passes | Should -Be 2
        $read.InProgress | Should -BeTrue
        $read.LastOutcome | Should -Be 'RebootScheduled'
    }

    It 'starts fresh on a new night' {
        $path = Join-Path (New-TestDir 'ns') 'dcu-state.json'
        $state = New-DcuNightState -NightId '2026-11-18'
        $state.Passes = 3; $state.Completed = $true
        [void](Save-DcuNightState -Path $path -State $state)
        $read = Read-DcuNightState -Path $path -NightId '2026-11-19'
        $read.Passes | Should -Be 0
        $read.Completed | Should -BeFalse
    }

    It 'treats a tampered file as a fresh night: <Json>' -ForEach @(
        @{ Json = '{"NightId":"2026-11-19","Passes":-1}' }
        @{ Json = '{"NightId":"2026-11-19","Passes":999}' }
        @{ Json = '{"NightId":"2026-11-19","Passes":"lots"}' }
        @{ Json = 'not json at all' }
    ) {
        $path = Join-Path (New-TestDir 'ns') 'dcu-state.json'
        [System.IO.File]::WriteAllText($path, $Json)
        (Read-DcuNightState -Path $path -NightId '2026-11-19').Passes | Should -Be 0
    }

    It 'keeps only short strings in AppliedTonight' {
        $path = Join-Path (New-TestDir 'ns') 'dcu-state.json'
        $long = 'x' * 500
        [System.IO.File]::WriteAllText($path, ('{{"NightId":"2026-11-19","Passes":1,"AppliedTonight":["BIOS 1.2", 7, {{"a":1}}, "{0}"]}}' -f $long))
        (Read-DcuNightState -Path $path -NightId '2026-11-19').AppliedTonight | Should -Be @('BIOS 1.2')
    }

    It 'accepts only real booleans for the flags' {
        $path = Join-Path (New-TestDir 'ns') 'dcu-state.json'
        [System.IO.File]::WriteAllText($path, '{"NightId":"2026-11-19","Passes":1,"Completed":"true","InProgress":1}')
        $read = Read-DcuNightState -Path $path -NightId '2026-11-19'
        $read.Completed | Should -BeFalse
        $read.InProgress | Should -BeFalse
    }
}

# =================================================================================================
Describe 'Write-DcuStatusFile' {
    It 'records LastSuccess on success and carries it through a later failure' {
        $dir = New-TestDir 'status'
        $run = New-DcuRunRecord -Config (New-TestConfig) -StateInfo (New-TestState $dir) -DryRun $false
        $run.Outcome = 'Applied'; $run.NightId = '2026-11-18'; $run.FinishedAt = '2026-11-18T23:40:00'
        Write-DcuStatusFile -Run $run -StateDir $dir
        $run2 = New-DcuRunRecord -Config (New-TestConfig) -StateInfo (New-TestState $dir) -DryRun $false
        $run2.Outcome = 'SkippedFrozen'; $run2.NightId = '2026-11-19'
        Write-DcuStatusFile -Run $run2 -StateDir $dir

        $status = Read-Json (Join-Path $dir 'dcu-status.json')
        $status.Outcome | Should -Be 'SkippedFrozen'
        $status.LastSuccess.NightId | Should -Be '2026-11-18'
        $status.LastSuccess.Outcome | Should -Be 'Applied'
        [System.IO.File]::ReadAllBytes((Join-Path $dir 'dcu-status.json'))[0] | Should -Be ([byte][char]'{')
    }

    It 'writes a dry run to its own file' {
        $dir = New-TestDir 'status'
        $run = New-DcuRunRecord -Config (New-TestConfig) -StateInfo (New-TestState $dir) -DryRun $true
        $run.Outcome = 'DryRun'
        Write-DcuStatusFile -Run $run -StateDir $dir
        Test-Path (Join-Path $dir 'dcu-status-dryrun.json') | Should -BeTrue
        Test-Path (Join-Path $dir 'dcu-status.json') | Should -BeFalse
    }
}

# =================================================================================================
Describe 'Invoke-DcuRetention' {
    It 'removes old log files and keeps recent ones and status files' {
        $dir = New-TestDir 'ret'
        $old = Join-Path $dir 'old.log'; $recent = Join-Path $dir 'new.log'; $status = Join-Path $dir 'dcu-status.json'
        foreach ($f in $old, $recent, $status) { [System.IO.File]::WriteAllText($f, 'x') }
        (Get-Item $old).LastWriteTime = (Get-Date).AddDays(-90)
        (Get-Item $status).LastWriteTime = (Get-Date).AddDays(-90)
        Invoke-DcuRetention -Directories @($dir) -Days 60 | Should -Be 1
        Test-Path $old | Should -BeFalse
        Test-Path $recent | Should -BeTrue
        Test-Path $status | Should -BeTrue
    }
}

# =================================================================================================
Describe 'Resolve-DcuStatePath' {
    BeforeAll { Mock Write-Host { } }

    It 'uses an explicit StatePath and puts files in its dcu subfolder' {
        $base = New-TestDir 'explicit'
        $state = Resolve-DcuStatePath -Config (New-TestConfig @{ StatePath = $base }) -ForInstall
        $state.Path | Should -Be (Join-Path $base 'dcu')
        Test-Path $state.Path | Should -BeTrue
    }

    It 'falls back to ProgramData, flagged non-persistent, when nothing better exists' {
        $env:SystemDrive = '/'
        try {
            $state = Resolve-DcuStatePath -Config (New-TestConfig) -ForInstall
            $state.Path | Should -Be (Join-Path $script:Pd 'DFMaintenance/dcu')
            $state.IsPersistent | Should -BeFalse
        } finally {
            $env:SystemDrive = $null
        }
    }

    It 'uses the path pinned at install' {
        $pinned = Join-Path (New-TestDir 'pinned') 'dcu'
        $config = New-TestConfig
        $config.PinnedStatePath = $pinned
        (Resolve-DcuStatePath -Config $config).Path | Should -Be $pinned
    }

    It 'creates nothing with -NoCreate' {
        $config = New-TestConfig
        $config.PinnedStatePath = Join-Path $script:Root ('never-' + [guid]::NewGuid().ToString('N'))
        $state = Resolve-DcuStatePath -Config $config -NoCreate
        Test-Path $state.Path | Should -BeFalse
    }
}

# =================================================================================================
Describe 'Invoke-DcuRunCore (orchestration)' {
    BeforeAll {
        Mock Write-Host { }
        Mock Start-Sleep { }
        Mock Write-DcuEvent { }
        Mock Get-DcuNow { $script:FakeNow }
        Mock Get-DcuFreezeState { [pscustomobject]@{ State = $script:FakeFreeze; Method = 'test'; Detail = 'test'; DfcPath = $null; ExitCode = $null; ServiceFound = $true } }
        Mock Find-DcuCli { $script:FakeDcuCli }
        Mock Get-DcuServiceState { $script:FakeService }
        Mock Start-DcuService { $true }
        Mock Get-DcuFreeSpaceGB { $script:FakeFreeGB }
        Mock Wait-DcuServicingIdle { $script:FakeIdle }
        Mock Get-DcuPendingReboot { @() }
        Mock Invoke-DcuReboot {
            $script:RebootCalls++
            # What a collector would see if the machine went down this instant.
            $statusPath = Join-Path $script:StateDir 'dcu-status.json'
            $script:StatusAtReboot = $null
            if (Test-Path $statusPath) { $script:StatusAtReboot = (Read-Json $statusPath).Outcome }
            $script:FakeRebootResult
        }
        Mock Invoke-DcuCli {
            $command = $Arguments[0].TrimStart('/')
            $script:DcuCalls.Add([pscustomobject]@{ Command = $command; Arguments = $Arguments })
            $queue = $script:DcuQueue[$command]
            $code = 0
            if ($queue -and $queue.Count -gt 0) { $code = $queue.Dequeue() }
            elseif ($script:DcuDefault.ContainsKey($command)) { $code = $script:DcuDefault[$command] }
            if ($command -eq 'scan' -and $code -eq 0) {
                $reportArg = @($Arguments | Where-Object { $_ -like '-report=*' }) | Select-Object -First 1
                if ($reportArg) { [System.IO.File]::WriteAllText($reportArg.Substring(8).Trim('"'), $script:SampleReport) }
            }
            if ($script:OnDcuCall) { & $script:OnDcuCall $command }
            [pscustomobject]@{ Tag = $Tag; CommandLine = "fake $($Arguments -join ' ')"; ExitCode = $code; TimedOut = $false; StartError = $null; DurationSeconds = 1; OutputTail = $null }
        }

        function script:Reset-Fakes {
            $script:FakeNow = [datetime]'2026-11-19T23:00:00'
            $script:FakeFreeze = 'Thawed'
            $script:FakeDcuCli = [pscustomobject]@{ Path = '/fake/dcu-cli.exe'; Version = [version]'5.7.1.27'; Signature = 'Valid'; SignatureProblem = $null }
            $script:FakeService = [pscustomobject]@{ Installed = $true; Status = 'Running'; StartType = 'Automatic' }
            $script:FakeFreeGB = 50
            $script:FakeIdle = [pscustomobject]@{ Idle = $true; WaitedSeconds = 0; Reasons = @() }
            $script:FakeRebootResult = [pscustomobject]@{ Scheduled = $true; ExitCode = 0; Detail = 'ok' }
            $script:RebootCalls = 0
            $script:DcuCalls = New-Object System.Collections.Generic.List[object]
            $script:DcuQueue = @{ scan = New-Object 'System.Collections.Generic.Queue[int]'; applyUpdates = New-Object 'System.Collections.Generic.Queue[int]'; configure = New-Object 'System.Collections.Generic.Queue[int]' }
            $script:DcuDefault = @{ configure = 0; scan = 500; applyUpdates = 0 }
            $script:OnDcuCall = $null
            $script:StateDir = New-TestDir 'run'
            Initialize-DcuLog -StateDir $script:StateDir
        }

        function script:Invoke-TestRun {
            param([hashtable] $Overrides = @{}, [switch] $DryRun, [switch] $IgnoreWindow)
            $code = Invoke-DcuRunCore -Config (New-TestConfig $Overrides) -StateInfo (New-TestState $script:StateDir) -DryRun:$DryRun -IgnoreWindow:$IgnoreWindow
            @($code).Count | Should -Be 1 -Because 'a function that leaks pipeline output returns an array instead of an exit code'
            return $code
        }

        function script:Get-Status { Read-Json (Join-Path $script:StateDir 'dcu-status.json') }
        function script:Get-NightState { Read-Json (Join-Path $script:StateDir 'dcu-state.json') }
        function script:Enqueue {
            param([string] $Command, [int[]] $Codes)
            foreach ($c in $Codes) { $script:DcuQueue[$Command].Enqueue($c) }
        }
    }
    BeforeEach { Reset-Fakes }

    Context 'gates' {
        It 'does nothing outside the window and leaves the last status alone' {
            $script:FakeNow = [datetime]'2026-11-20T14:00:00'
            Invoke-TestRun | Should -Be 1
            $script:DcuCalls.Count | Should -Be 0
            Test-Path (Join-Path $script:StateDir 'dcu-status.json') | Should -BeFalse
        }

        It 'does not start a pass inside the install cutoff' {
            $script:FakeNow = [datetime]'2026-11-20T05:00:00'
            Invoke-TestRun | Should -Be 1
            $script:DcuCalls.Count | Should -Be 0
        }

        It 'refuses to run on a Frozen machine and says why' {
            $script:FakeFreeze = 'Frozen'
            Invoke-TestRun | Should -Be 2
            $script:DcuCalls.Count | Should -Be 0
            $status = Get-Status
            $status.Outcome | Should -Be 'SkippedFrozen'
            $status.Message | Should -Match 'Thawed Period'
        }

        It 'refuses when the freeze state is unknown' {
            $script:FakeFreeze = 'Unknown'
            Invoke-TestRun | Should -Be 2
            (Get-Status).Outcome | Should -Be 'SkippedFreezeStateUnknown'
        }

        It 'refuses without Deep Freeze unless RunWithoutDeepFreeze is set' {
            $script:FakeFreeze = 'NotInstalled'
            Invoke-TestRun | Should -Be 2
            Reset-Fakes
            $script:FakeFreeze = 'NotInstalled'
            Invoke-TestRun -Overrides @{ RunWithoutDeepFreeze = $true } | Should -Be 0
        }

        It 'reports DCU missing, too old, untrusted, or with an unusable service as exit 4' {
            $script:FakeDcuCli = $null
            Invoke-TestRun | Should -Be 4
            (Get-Status).Outcome | Should -Be 'DcuNotInstalled'

            Reset-Fakes; $script:FakeDcuCli.Version = [version]'4.9.0'
            Invoke-TestRun | Should -Be 4
            (Get-Status).Outcome | Should -Be 'DcuTooOld'

            Reset-Fakes; $script:FakeDcuCli.SignatureProblem = 'not Dell'
            Invoke-TestRun | Should -Be 4
            (Get-Status).Outcome | Should -Be 'DcuUntrusted'

            Reset-Fakes; $script:FakeService = [pscustomobject]@{ Installed = $true; Status = 'Stopped'; StartType = 'Disabled' }
            Invoke-TestRun | Should -Be 4
            (Get-Status).Outcome | Should -Be 'DcuServiceDisabled'

            Reset-Fakes; $script:FakeService = [pscustomobject]@{ Installed = $false; Status = $null; StartType = $null }
            Invoke-TestRun | Should -Be 4
            (Get-Status).Outcome | Should -Be 'DcuServiceMissing'
        }

        It 'starts a stopped (not disabled) DCU service' {
            $script:FakeService = [pscustomobject]@{ Installed = $true; Status = 'Stopped'; StartType = 'Automatic' }
            Invoke-TestRun | Should -Be 0
            Should -Invoke Start-DcuService -Times 1 -Exactly
        }

        It 'skips on low disk space' {
            $script:FakeFreeGB = 0.5
            Invoke-TestRun | Should -Be 5
            (Get-Status).Outcome | Should -Be 'LowDiskSpace'
        }

        It 'does not start on top of Windows servicing, and does not use up a pass' {
            $script:FakeIdle = [pscustomobject]@{ Idle = $false; WaitedSeconds = 1800; Reasons = @('TiWorker') }
            Invoke-TestRun | Should -Be 3
            (Get-Status).Outcome | Should -Be 'SkippedServicingBusy'
            $script:DcuCalls.Count | Should -Be 0
            Test-Path (Join-Path $script:StateDir 'dcu-state.json') | Should -BeFalse
        }

        It 'does not run DCU when the pass counter cannot be saved' {
            Mock Save-DcuNightState { $false }
            Invoke-TestRun | Should -Be 5
            (Get-Status).Outcome | Should -Be 'StateWriteFailed'
            $script:DcuCalls.Count | Should -Be 0
        }
    }

    Context 'a night' {
        It 'finishes UpToDate when the scan finds nothing, then does nothing for the rest of the night' {
            Invoke-TestRun | Should -Be 0
            (Get-Status).Outcome | Should -Be 'UpToDate'
            (Get-NightState).Completed | Should -BeTrue
            (Get-NightState).Passes | Should -Be 1

            $calls = $script:DcuCalls.Count
            $script:FakeNow = [datetime]'2026-11-20T01:00:00'
            Invoke-TestRun | Should -Be 0
            $script:DcuCalls.Count | Should -Be $calls
            (Get-Status).Outcome | Should -Be 'UpToDate'
        }

        It 'applies updates that need no restart' {
            Enqueue scan 0
            Invoke-TestRun | Should -Be 0
            $status = Get-Status
            $status.Outcome | Should -Be 'Applied'
            @($status.Dcu.Updates).Count | Should -Be 2
            $status.LastSuccess.Outcome | Should -Be 'Applied'
            $script:RebootCalls | Should -Be 0
        }

        It 'passes the filters, -reboot=disable and BitLocker suspend to /applyUpdates' {
            Enqueue scan 0
            [void](Invoke-TestRun)
            $apply = @($script:DcuCalls | Where-Object { $_.Command -eq 'applyUpdates' })[0].Arguments
            $apply | Should -Contain '-silent'
            $apply | Should -Contain '-reboot=disable'
            $apply | Should -Contain '-autoSuspendBitLocker=enable'
            $apply | Should -Contain '-updateType=bios,firmware,driver'
            $apply | Should -Contain '-updateSeverity=security,critical,recommended'
            @($apply | Where-Object { $_ -like '-outputLog=*' }).Count | Should -Be 1
        }

        It 'restarts inside the window when DCU needs it, then continues after the restart' {
            Enqueue scan 0
            Enqueue applyUpdates 1
            Invoke-TestRun | Should -Be 3010
            $script:RebootCalls | Should -Be 1
            $script:StatusAtReboot | Should -Be 'RebootScheduled' -Because 'the result must be on disk before the restart is requested'
            $night = Get-NightState
            $night.Passes | Should -Be 1
            $night.InProgress | Should -BeFalse
            $night.LastOutcome | Should -Be 'RebootScheduled'

            # After the restart (at-startup trigger):
            $script:FakeNow = [datetime]'2026-11-19T23:40:00'
            Invoke-TestRun | Should -Be 0
            $status = Get-Status
            $status.Outcome | Should -Be 'UpToDate'
            (Get-NightState).Passes | Should -Be 2
            # The final status still says what went in on pass 1.
            $status.AppliedTonight | Should -Be @('Dell OptiPlex 7010 System BIOS 1.22.0', 'Intel Chipset Device Software 10.1.19222.8341')
            $status.Message | Should -Match 'Applied tonight: Dell OptiPlex 7010 System BIOS 1.22.0'
        }

        It 'configures DCU once a night, on the first pass only' {
            Enqueue scan 0
            Enqueue applyUpdates 1
            [void](Invoke-TestRun)
            $script:FakeNow = [datetime]'2026-11-19T23:40:00'
            [void](Invoke-TestRun)
            @($script:DcuCalls | Where-Object { $_.Command -eq 'configure' }).Count | Should -Be 1
            $configure = @($script:DcuCalls | Where-Object { $_.Command -eq 'configure' })[0].Arguments
            $configure | Should -Contain '-scheduleManual'
            $configure | Should -Contain '-updatesNotification=disable'
        }

        It 'never runs /configure with LeaveDcuSettings' {
            [void](Invoke-TestRun -Overrides @{ LeaveDcuSettings = $true })
            @($script:DcuCalls | Where-Object { $_.Command -eq 'configure' }).Count | Should -Be 0
        }

        It 'caps a restart loop at MaxPassesPerNight, then reports what is left without restarting again' {
            $script:DcuDefault = @{ configure = 0; scan = 0; applyUpdates = 1 }   # every apply wants a restart
            $codes = foreach ($minute in 0, 20, 40, 59) {
                $script:FakeNow = ([datetime]'2026-11-19T23:00:00').AddMinutes($minute)
                Invoke-TestRun
            }
            $codes | Should -Be @(3010, 3010, 3010, 3)
            $script:RebootCalls | Should -Be 3
            @($script:DcuCalls | Where-Object { $_.Command -eq 'applyUpdates' }).Count | Should -Be 3
            (Get-Status).Outcome | Should -Be 'MaxPassesReached'
            (Get-NightState).Completed | Should -BeTrue
        }

        It 'leaves the restart pending when the reboot cutoff passed during the install' {
            $script:FakeNow = [datetime]'2026-11-20T04:20:00'
            Enqueue scan 0
            Enqueue applyUpdates 1
            $script:OnDcuCall = { param($command) if ($command -eq 'applyUpdates') { $script:FakeNow = [datetime]'2026-11-20T05:40:00' } }
            Invoke-TestRun | Should -Be 7
            (Get-Status).Outcome | Should -Be 'RebootPendingAtWindowEnd'
            $script:RebootCalls | Should -Be 0
        }

        It 'never restarts with NoReboot' {
            Enqueue scan 0
            Enqueue applyUpdates 1
            Invoke-TestRun -Overrides @{ NoReboot = $true } | Should -Be 7
            (Get-Status).Outcome | Should -Be 'RebootRequiredNoReboot'
            $script:RebootCalls | Should -Be 0
        }

        It 'reports a restart that could not be scheduled' {
            Enqueue scan 0
            Enqueue applyUpdates 1
            $script:FakeRebootResult = [pscustomobject]@{ Scheduled = $false; ExitCode = 5; Detail = 'access denied' }
            Invoke-TestRun | Should -Be 5
            (Get-Status).Outcome | Should -Be 'RebootFailed'
        }

        It 'restarts when the scan reports a restart already pending' {
            Enqueue scan 5
            Invoke-TestRun | Should -Be 3010
            $script:RebootCalls | Should -Be 1
        }

        It 'counts a pass that was killed mid-run (e.g. DCU restarting for a BIOS update)' {
            $night = New-DcuNightState -NightId '2026-11-19'
            $night.Passes = 1; $night.InProgress = $true
            [void](Save-DcuNightState -Path (Join-Path $script:StateDir 'dcu-state.json') -State $night)
            Invoke-TestRun | Should -Be 0
            $after = Get-NightState
            $after.InterruptedPasses | Should -Be 1
            $after.Passes | Should -Be 2
        }
    }

    Context 'DCU failures' {
        It 'retries a download failure at the next trigger, using another pass' {
            Enqueue scan 0
            Enqueue applyUpdates 1002
            Invoke-TestRun | Should -Be 5
            (Get-Status).Outcome | Should -Be 'ApplyFailed'
            (Get-NightState).Completed | Should -BeFalse
            (Get-NightState).InProgress | Should -BeFalse

            $script:FakeNow = [datetime]'2026-11-20T00:00:00'
            Invoke-TestRun | Should -Be 0
            (Get-NightState).Passes | Should -Be 2
        }

        It 'stops for the night on a command-line error (retrying cannot fix it)' {
            Enqueue scan 106
            Invoke-TestRun | Should -Be 6
            (Get-Status).Outcome | Should -Be 'DcuUsageError'
            (Get-NightState).Completed | Should -BeTrue
        }

        It 'stops for the night on an unsupported system' {
            Enqueue scan 3
            Invoke-TestRun | Should -Be 4
            (Get-Status).Outcome | Should -Be 'DcuUnsupported'
            (Get-NightState).Completed | Should -BeTrue
        }

        It 'waits out a busy DCU service and carries on' {
            Enqueue scan 3003, 3005, 500
            Invoke-TestRun | Should -Be 0
            $status = Get-Status
            $status.Outcome | Should -Be 'UpToDate'
            $status.Dcu.Scan.Attempts | Should -Be 3
        }

        It 'starts the service once when DCU reports it stopped' {
            Enqueue scan 3000, 500
            Invoke-TestRun | Should -Be 0
            Should -Invoke Start-DcuService -Times 1 -Exactly
        }

        It 'gives up on a service that stays busy and retries at the next trigger' {
            Enqueue scan 3003, 3003, 3003, 3003
            Invoke-TestRun | Should -Be 5
            (Get-Status).Outcome | Should -Be 'ScanFailed'
            (Get-NightState).Completed | Should -BeFalse
        }
    }

    Context 'testing aids' {
        It 'DryRun scans a Frozen machine during the day and changes nothing' {
            $script:FakeNow = [datetime]'2026-11-20T14:00:00'
            $script:FakeFreeze = 'Frozen'
            Enqueue scan 0
            Invoke-TestRun -DryRun -IgnoreWindow | Should -Be 0
            $dry = Read-Json (Join-Path $script:StateDir 'dcu-status-dryrun.json')
            $dry.Outcome | Should -Be 'DryRun'
            @($dry.Dcu.Updates).Count | Should -Be 2
            @($script:DcuCalls | Where-Object { $_.Command -ne 'scan' }).Count | Should -Be 0
            Test-Path (Join-Path $script:StateDir 'dcu-state.json') | Should -BeFalse
            Test-Path (Join-Path $script:StateDir 'dcu-status.json') | Should -BeFalse
            $script:RebootCalls | Should -Be 0
        }

        It 'IgnoreWindow uses its own pass counter, so a daytime test cannot mark tonight done' {
            $script:FakeNow = [datetime]'2026-11-19T14:00:00'
            Invoke-TestRun -IgnoreWindow | Should -Be 0
            (Get-NightState).NightId | Should -Match '^adhoc-'

            $script:FakeNow = [datetime]'2026-11-19T23:00:00'
            Invoke-TestRun | Should -Be 0
            $night = Get-NightState
            $night.NightId | Should -Be '2026-11-19'
            $night.Passes | Should -Be 1
        }

        It 'writes one JSON Lines record per event, BOM-free' {
            [void](Invoke-TestRun)
            $log = Get-ChildItem (Join-Path $script:StateDir 'logs') -Filter '*.jsonl' | Select-Object -First 1
            [System.IO.File]::ReadAllBytes($log.FullName)[0] | Should -Be ([byte][char]'{')
            foreach ($line in (Get-Content -LiteralPath $log.FullName)) { { $line | ConvertFrom-Json } | Should -Not -Throw }
        }
    }
}

# =================================================================================================
Describe 'Run mode wrapper' {
    BeforeAll { Mock Write-Host { } }

    It 'exits 3 when another run holds the lock' {
        Mock Enter-DcuMutex { @{ Mutex = $null; Acquired = $false } }
        $config = New-TestConfig
        $config.PinnedStatePath = Join-Path (New-TestDir 'mutex') 'dcu'
        $path = Join-Path (New-TestDir 'mutexcfg') 'config.json'
        Write-DcuJsonFile -Path $path -InputObject $config
        Invoke-DcuRunMode -ConfigPath $path | Should -Be 3
    }

    It 'turns an unexpected exception into exit 9 rather than a crash' {
        Mock Invoke-DcuRunMode { throw 'boom' }
        Invoke-DcuMain -Mode 'Run' -Bound @{} | Should -Be 9
    }
}

# =================================================================================================
Describe 'Install-DcuMaintenance' {
    BeforeAll {
        Mock Write-Host { }
        Mock Write-DcuEvent { }
        Mock Set-DcuDirectorySecurity { $true }
        Mock Register-DcuEventSource { }
    }

    It 'refuses bad parameters before touching anything (24)' {
        Install-DcuMaintenance -Bound @{ WindowStart = '7pm' } | Should -Be 24
    }

    It 'refuses when not elevated (22)' {
        Mock Test-DcuElevated { $false }
        Install-DcuMaintenance -Bound @{} | Should -Be 22
    }

    Context 'elevated' {
        BeforeAll {
            Mock Test-DcuElevated { $true }
            Mock Find-DcuCli { [pscustomobject]@{ Path = '/fake/dcu-cli.exe'; Version = [version]'5.7.1.27'; Signature = 'Valid'; SignatureProblem = $null } }
            Mock Get-DcuServiceState { [pscustomobject]@{ Installed = $true; Status = 'Running'; StartType = 'Automatic' } }
            Mock Set-DcuQuietSettings { [pscustomobject]@{ Category = 'Success'; ExitCode = 0; Meaning = 'ok' } }
            Mock Register-DcuTask { [pscustomobject]@{ Name = 'DFMaintenance-DellCommandUpdate'; Triggers = 2; Plan = (Get-DcuSchedulePlan -Config $Config); Limit = '03:45:00' } }
        }

        It 'refuses on a Frozen machine and records why on the state volume (20)' {
            Mock Get-DcuFreezeState { [pscustomobject]@{ State = 'Frozen'; Method = 'test'; Detail = $null } }
            $base = New-TestDir 'inst-frozen'
            Install-DcuMaintenance -Bound @{ StatePath = $base } | Should -Be 20
            (Read-Json (Join-Path $base 'dcu/dcu-install.json')).Outcome | Should -Be 'RefusedNotThawed'
            Should -Invoke Register-DcuTask -Times 0 -Exactly
        }

        It 'refuses when DCU is missing (21)' {
            Mock Get-DcuFreezeState { [pscustomobject]@{ State = 'Thawed'; Method = 'test'; Detail = $null } }
            Mock Find-DcuCli { $null }
            Install-DcuMaintenance -Bound @{ StatePath = (New-TestDir 'inst-nodcu') } | Should -Be 21
        }

        It 'installs on a Thawed machine: copies itself, pins the state path, registers the task (0)' {
            Mock Get-DcuFreezeState { [pscustomobject]@{ State = 'Thawed'; Method = 'test'; Detail = $null } }
            $base = New-TestDir 'inst-ok'
            Install-DcuMaintenance -Bound @{ StatePath = $base; WindowStart = '02:05' } | Should -Be 0

            $installed = Join-Path $script:Pf 'DFMaintenance/DCU/Invoke-DFDcuMaintenance.ps1'
            (Get-FileHash $installed).Hash | Should -Be (Get-FileHash $script:ScriptUnderTest).Hash
            $config = Read-Json (Join-Path $script:Pf 'DFMaintenance/DCU/config.json')
            $config.PinnedStatePath | Should -Be (Join-Path $base 'dcu')
            $config.WindowStart | Should -Be '02:05'
            $config.InstalledVersion | Should -Be $script:DcuScriptVersion
            (Read-Json (Join-Path $base 'dcu/dcu-install.json')).Outcome | Should -Be 'Installed'
            Should -Invoke Register-DcuTask -Times 1 -Exactly
            Should -Invoke Set-DcuQuietSettings -Times 1 -Exactly
        }
    }
}

# =================================================================================================
Describe 'Uninstall-DcuMaintenance' {
    BeforeAll {
        Mock Write-Host { }
        Mock Test-DcuElevated { $true }
    }

    It 'refuses on a Frozen machine (20)' {
        Mock Get-DcuFreezeState { [pscustomobject]@{ State = 'Frozen'; Method = 'test'; Detail = $null } }
        Uninstall-DcuMaintenance -ConfigPath (Join-Path (New-TestDir 'un') 'config.json') | Should -Be 20
    }

    It 'removes the task and the installed files on a Thawed machine (0)' {
        Mock Get-DcuFreezeState { [pscustomobject]@{ State = 'Thawed'; Method = 'test'; Detail = $null } }
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'DFMaintenance-DellCommandUpdate' } }
        Mock Unregister-ScheduledTask { }
        $installDir = Get-DcuInstallDir
        New-Item -ItemType Directory -Path $installDir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $installDir 'marker.txt'), 'x')

        Uninstall-DcuMaintenance -ConfigPath (Join-Path (New-TestDir 'un2') 'config.json') | Should -Be 0
        Should -Invoke Unregister-ScheduledTask -Times 1 -Exactly
        Test-Path $installDir | Should -BeFalse
    }
}

# =================================================================================================
Describe 'Entry point (separate process)' -Skip:(-not $CanFakeExe) {
    BeforeAll {
        $script:Pwsh = (Get-Process -Id $PID).Path
        New-FakeExe -Path (Join-Path $script:Win 'SysWOW64/DFC.exe') -Body 'if [ "$1" = "get" ] && [ "$2" = "/ISFROZEN" ]; then exit "${DFC_FAKE_EXIT:-1}"; fi; exit 42' | Out-Null

        function script:New-WindowAroundNow {
            # A config whose window contains the current time, so the real clock passes the gate.
            param([string] $StateBase)
            $now = Get-Date
            $config = New-TestConfig @{ WindowStart = $now.AddMinutes(-60).ToString('HH:mm'); WindowEnd = $now.AddMinutes(240).ToString('HH:mm') }
            $config.PinnedStatePath = Join-Path $StateBase 'dcu'
            $path = Join-Path $StateBase 'config.json'
            Write-DcuJsonFile -Path $path -InputObject $config
            return $path
        }

        function script:Invoke-Script {
            param([string[]] $Arguments)
            & $script:Pwsh -NoProfile -NonInteractive -File $script:ScriptUnderTest @Arguments *> $null
            return $LASTEXITCODE
        }
    }
    AfterEach { Remove-Item Env:\DFC_FAKE_EXIT -ErrorAction SilentlyContinue }

    It 'exits 24 for an invalid setting' {
        Invoke-Script @('-Mode', 'Install', '-WindowStart', '25:00') | Should -Be 24
    }

    It 'exits 22 when not elevated' {
        Invoke-Script @('-Mode', 'Install') | Should -Be 22
    }

    It 'exits 2 on a Frozen machine inside the window, recording SkippedFrozen' {
        $base = New-TestDir 'proc-frozen'
        $config = New-WindowAroundNow -StateBase $base
        $env:DFC_FAKE_EXIT = '1'
        Invoke-Script @('-Mode', 'Run', '-ConfigPath', $config) | Should -Be 2
        (Read-Json (Join-Path $base 'dcu/dcu-status.json')).Outcome | Should -Be 'SkippedFrozen'
    }

    It 'exits 4 on a Thawed machine with no DCU installed' {
        $base = New-TestDir 'proc-nodcu'
        $config = New-WindowAroundNow -StateBase $base
        $env:DFC_FAKE_EXIT = '0'
        $hidden = $null
        $fakeDcu = Join-Path $script:Pf86 'Dell/CommandUpdate/dcu-cli.exe'
        if (Test-Path $fakeDcu) { $hidden = "$fakeDcu.hidden"; Move-Item $fakeDcu $hidden }
        try {
            Invoke-Script @('-Mode', 'Run', '-ConfigPath', $config) | Should -Be 4
            (Read-Json (Join-Path $base 'dcu/dcu-status.json')).Outcome | Should -Be 'DcuNotInstalled'
        } finally {
            if ($hidden) { Move-Item $hidden $fakeDcu }
        }
    }

    It 'exits 0 for Status' {
        $base = New-TestDir 'proc-status'
        Invoke-Script @('-Mode', 'Status', '-ConfigPath', (New-WindowAroundNow -StateBase $base)) | Should -Be 0
    }
}
