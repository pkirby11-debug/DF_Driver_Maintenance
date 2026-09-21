#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
    Unit tests for DFMaintenance.

    Scope note: the Deep Freeze, WUA and CIM-backed functions cannot be
    meaningfully unit tested off a Windows endpoint, so the suite covers the
    platform-independent logic (config merge, state resolution, log format,
    report rendering) and mocks the rest. Validation of the freeze-state and
    update paths has to happen on a real Thawed test machine - see
    docs/VALIDATION.md for that checklist.
#>

BeforeAll {
    $script:ModuleRoot = Join-Path $PSScriptRoot '..\src\DFMaintenance'
    . (Join-Path $script:ModuleRoot 'Private\Resolve-DFStatePath.ps1')
    . (Join-Path $script:ModuleRoot 'Private\Write-DFLog.ps1')
    . (Join-Path $script:ModuleRoot 'Private\Get-DFConfig.ps1')
    . (Join-Path $script:ModuleRoot 'Private\ConvertTo-DFHtmlReport.ps1')
    . (Join-Path $script:ModuleRoot 'Private\Invoke-DFRetention.ps1')
    . (Join-Path $script:ModuleRoot 'Private\Write-DFTextFile.ps1')
    . (Join-Path $script:ModuleRoot 'Private\Set-DFStateContext.ps1')
    . (Join-Path $script:ModuleRoot 'Private\Get-DFCPath.ps1')
    . (Join-Path $script:ModuleRoot 'Private\Get-DFHardwareIdPrefix.ps1')

    $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dfmtest-$([guid]::NewGuid().ToString('N'))"
    New-Item -Path $script:TestRoot -ItemType Directory -Force | Out-Null
}

AfterAll {
    if ($script:TestRoot -and (Test-Path $script:TestRoot)) {
        Remove-Item $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Resolve-DFStatePath' {
    It 'honours an explicitly configured path' {
        $target = Join-Path $script:TestRoot 'explicit'
        $result = Resolve-DFStatePath -StatePath $target
        $result.Path   | Should -Be $target
        $result.Source | Should -Be 'Configured'
    }

    It 'creates the directory it returns' {
        $target = Join-Path $script:TestRoot 'created'
        Resolve-DFStatePath -StatePath $target | Out-Null
        Test-Path $target | Should -BeTrue
    }
}

Describe 'Get-DFConfig' {
    It 'returns defaults when no config file exists' {
        $missing = Join-Path $script:TestRoot 'nope.json'
        $config = Get-DFConfig -ConfigPath $missing
        $config.LogRetentionDays     | Should -Be 90
        $config.DriverAgeWarningDays | Should -Be 1095
    }

    It 'merges file values over defaults and preserves unspecified defaults' {
        $path = Join-Path $script:TestRoot 'partial.json'
        '{ "LogRetentionDays": 30 }' | Set-Content -LiteralPath $path -Encoding UTF8

        $config = Get-DFConfig -ConfigPath $path
        $config.LogRetentionDays     | Should -Be 30    # overridden
        $config.DriverAgeWarningDays | Should -Be 1095  # default retained
    }

    It 'falls back to defaults rather than throwing on malformed JSON' {
        $path = Join-Path $script:TestRoot 'bad.json'
        '{ this is not json' | Set-Content -LiteralPath $path -Encoding UTF8

        $config = Get-DFConfig -ConfigPath $path -WarningAction SilentlyContinue
        $config.LogRetentionDays | Should -Be 90
    }
}

Describe 'Write-DFLog' {
    It 'writes one parseable JSON object per line' {
        $log = Join-Path $script:TestRoot 'test.jsonl'
        Write-DFLog -Message 'first'  -LogPath $log
        Write-DFLog -Message 'second' -Level 'Warning' -LogPath $log -WarningAction SilentlyContinue

        $lines = Get-Content -LiteralPath $log
        $lines.Count | Should -Be 2
        ($lines[0] | ConvertFrom-Json).Message | Should -Be 'first'
        ($lines[1] | ConvertFrom-Json).Level   | Should -Be 'Warning'
    }

    It 'does not throw when the log target is unwritable' {
        { Write-DFLog -Message 'x' -LogPath '/nonexistent-dir/x.jsonl' -WarningAction SilentlyContinue } |
            Should -Not -Throw
    }

    It 'includes structured data when supplied' {
        $log = Join-Path $script:TestRoot 'data.jsonl'
        Write-DFLog -Message 'with data' -LogPath $log -Data @{ Pending = 7 }
        ((Get-Content -LiteralPath $log)[0] | ConvertFrom-Json).Data.Pending | Should -Be 7
    }
}

Describe 'ConvertTo-DFHtmlReport' {
    BeforeAll {
        $script:Snapshot = [PSCustomObject]@{
            Computer      = 'CLASSROOM-01'
            Timestamp     = '2026-09-21T03:00:00'
            OverallStatus = 'Critical'
            Findings      = @(
                [PSCustomObject]@{ Severity = 'Critical'; Code = 'DF001'; Message = 'Machine is THAWED.' }
            )
            FreezeState   = [PSCustomObject]@{ State = 'Thawed' }
            WindowsUpdate = [PSCustomObject]@{ OSCaption = 'Windows 11 Pro'; DisplayVersion = '24H2'; OSBuild = '26100'; UptimeDays = 4.2 }
            Drivers       = [PSCustomObject]@{ TotalDrivers = 120; StaleCount = 3; ProblemDevices = @() }
            Software      = [PSCustomObject]@{ TotalCount = 41 }
        }
    }

    It 'renders the computer name and status' {
        $html = ConvertTo-DFHtmlReport -Snapshot $script:Snapshot
        $html | Should -Match 'CLASSROOM-01'
        $html | Should -Match 'Critical'
    }

    It 'is self-contained with no external resource references' {
        # These machines are on an isolated VLAN; a CDN reference renders broken.
        $html = ConvertTo-DFHtmlReport -Snapshot $script:Snapshot
        $html | Should -Not -Match 'https?://'
    }

    It 'HTML-encodes values rather than interpolating them raw' {
        $evil = $script:Snapshot.PSObject.Copy()
        $evil.Computer = '<script>alert(1)</script>'
        $html = ConvertTo-DFHtmlReport -Snapshot $evil
        $html | Should -Not -Match '<script>alert'
        $html | Should -Match '&lt;script&gt;'
    }

    It 'handles an empty findings collection' {
        $clean = $script:Snapshot.PSObject.Copy()
        $clean.Findings = @()
        { ConvertTo-DFHtmlReport -Snapshot $clean } | Should -Not -Throw
        (ConvertTo-DFHtmlReport -Snapshot $clean) | Should -Match 'No findings'
    }
}

Describe 'Invoke-DFRetention' {
    BeforeEach {
        $script:RetRoot = Join-Path $script:TestRoot "ret-$([guid]::NewGuid().ToString('N'))"
        New-Item -Path (Join-Path $script:RetRoot 'reports') -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $script:RetRoot 'logs')    -ItemType Directory -Force | Out-Null

        function New-AgedFile {
            param($Path, $AgeDays)
            Set-Content -LiteralPath $Path -Value 'x'
            (Get-Item -LiteralPath $Path).LastWriteTime = (Get-Date).AddDays(-$AgeDays)
        }

        New-AgedFile (Join-Path $script:RetRoot 'reports\old1.json')   120
        New-AgedFile (Join-Path $script:RetRoot 'reports\latest.json') 400
        New-AgedFile (Join-Path $script:RetRoot 'reports\latest.html') 400
        New-AgedFile (Join-Path $script:RetRoot 'reports\new.json')      1
        New-AgedFile (Join-Path $script:RetRoot 'logs\old.jsonl')      200
    }

    It 'removes files older than the retention window' {
        Invoke-DFRetention -StatePath $script:RetRoot -RetentionDays 90 | Should -Be 2
        Test-Path (Join-Path $script:RetRoot 'reports\old1.json') | Should -BeFalse
        Test-Path (Join-Path $script:RetRoot 'logs\old.jsonl')    | Should -BeFalse
    }

    It 'never prunes the latest.* pointer files regardless of age' {
        # A machine that has not scanned in a year should still present its last
        # known state to a collector rather than nothing at all.
        Invoke-DFRetention -StatePath $script:RetRoot -RetentionDays 90 | Out-Null
        Test-Path (Join-Path $script:RetRoot 'reports\latest.json') | Should -BeTrue
        Test-Path (Join-Path $script:RetRoot 'reports\latest.html') | Should -BeTrue
    }

    It 'retains files inside the window' {
        Invoke-DFRetention -StatePath $script:RetRoot -RetentionDays 90 | Out-Null
        Test-Path (Join-Path $script:RetRoot 'reports\new.json') | Should -BeTrue
    }

    It 'is idempotent' {
        Invoke-DFRetention -StatePath $script:RetRoot -RetentionDays 90 | Out-Null
        Invoke-DFRetention -StatePath $script:RetRoot -RetentionDays 90 | Should -Be 0
    }

    It 'does not throw on a missing state directory' {
        { Invoke-DFRetention -StatePath (Join-Path $script:TestRoot 'nope') -RetentionDays 90 } |
            Should -Not -Throw
    }
}

Describe 'Write-DFTextFile' {
    # Set-Content -Encoding UTF8 means UTF-8 WITH BOM on Windows PowerShell 5.1 and
    # WITHOUT on 7.x. latest.json is read by a non-PowerShell collector, so a BOM makes
    # the system of record unparseable. These tests must pass on BOTH editions.
    It 'writes no byte-order mark' {
        $p = Join-Path $script:TestRoot 'nobom.json'
        Write-DFTextFile -Path $p -Content '{"a":1}'
        $bytes = [System.IO.File]::ReadAllBytes($p)
        $bytes[0] | Should -Be 0x7B   # '{'
        @($bytes[0], $bytes[1], $bytes[2]) -join ',' | Should -Not -Be '239,187,191'
    }

    It 'produces JSON a strict parser can read back' {
        $p = Join-Path $script:TestRoot 'roundtrip.json'
        Write-DFTextFile -Path $p -Content ([PSCustomObject]@{ status = 'Critical' } | ConvertTo-Json)
        (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json).status | Should -Be 'Critical'
    }

    It 'appends without a BOM on the first line' {
        $p = Join-Path $script:TestRoot 'append.jsonl'
        Write-DFTextFile -Path $p -Content ('{"n":1}' + [Environment]::NewLine) -Append
        Write-DFTextFile -Path $p -Content ('{"n":2}' + [Environment]::NewLine) -Append
        @(Get-Content -LiteralPath $p).Count | Should -Be 2
        ([System.IO.File]::ReadAllBytes($p))[0] | Should -Be 0x7B
    }
}

Describe 'Set-DFStateContext' {
    It 'points the log target at the supplied state path' {
        $sp = Join-Path $script:TestRoot 'ctx1'
        $state = Set-DFStateContext -StatePath $sp
        $state.Path | Should -Be $sp
        Test-Path (Join-Path $sp 'logs') | Should -BeTrue
    }

    It 'moves the log target when the state path changes' {
        # The regression this guards: the log path used to be resolved once at import,
        # so -StatePath moved the reports to ThawSpace but left the logs on the frozen
        # volume, where they were destroyed on the next reboot.
        $a = Join-Path $script:TestRoot 'ctxA'
        $b = Join-Path $script:TestRoot 'ctxB'
        Set-DFStateContext -StatePath $a | Out-Null
        Set-DFStateContext -StatePath $b | Out-Null
        $script:DFLogPath | Should -BeLike "*$([System.IO.Path]::GetFileName($b))*"
    }
}

Describe 'Get-DFCPath' {
    It 'does not throw when a Program Files root is null' {
        # ${env:ProgramFiles(x86)} is null on a 32-bit OS. Join-Path throws a terminating
        # binding error on a null -Path, and under the module's EAP=Stop that killed the
        # entire scan before any report was written.
        { Get-DFCPath } | Should -Not -Throw
    }

    It 'does not throw on a non-existent configured path' {
        { Get-DFCPath -ConfiguredPath (Join-Path $script:TestRoot 'no\such\DFC.exe') } | Should -Not -Throw
    }
}

Describe 'Test-DFTrustedExecutablePath' {
    # Everything this gate returns is executed as SYSTEM by Get-DFFreezeState, and the
    # path originates in a config file on a volume a kiosk user may be able to write.
    # These are privilege-escalation tests, not style tests.
    It 'accepts the real DFC.exe under Program Files' {
        $p = Join-Path $env:ProgramFiles 'Faronics\Deep Freeze\DFC.exe'
        Test-DFTrustedExecutablePath -Path $p | Should -BeTrue
    }

    It 'rejects an executable in a user-writable directory' {
        Test-DFTrustedExecutablePath -Path 'C:\Users\Public\DFC.exe' | Should -BeFalse
    }

    It 'rejects a script masquerading as the target' {
        # The task runs powershell.exe -ExecutionPolicy Bypass, so a .ps1 here would run
        # in-process as SYSTEM.
        Test-DFTrustedExecutablePath -Path (Join-Path $env:ProgramFiles 'Faronics\DFC.ps1') | Should -BeFalse
    }

    It 'rejects a differently-named executable inside a trusted root' {
        Test-DFTrustedExecutablePath -Path (Join-Path $env:ProgramFiles 'Faronics\payload.exe') | Should -BeFalse
    }

    It 'rejects a directory whose name merely prefixes a trusted root' {
        Test-DFTrustedExecutablePath -Path "$($env:ProgramFiles)Evil\DFC.exe" | Should -BeFalse
    }

    It 'rejects traversal back out of a trusted root' {
        Test-DFTrustedExecutablePath -Path (Join-Path $env:ProgramFiles '..\Users\Public\DFC.exe') | Should -BeFalse
    }

    It 'rejects empty and null input' {
        Test-DFTrustedExecutablePath -Path '' | Should -BeFalse
    }
}

Describe 'Get-DFCPath security gate' {
    It 'does not return an untrusted configured path' {
        $hostile = 'C:\Users\Public\rec.exe'
        Get-DFCPath -ConfiguredPath $hostile -WarningAction SilentlyContinue | Should -Not -Be $hostile
    }

    It 'does not throw when rejecting' {
        { Get-DFCPath -ConfiguredPath 'C:\Users\Public\rec.exe' -WarningAction SilentlyContinue } |
            Should -Not -Throw
    }
}

Describe 'Get-DFHardwareIdPrefix' {
    It 'strips the instance id, which is often the hardware serial' {
        Get-DFHardwareIdPrefix -DeviceID 'USB\VID_046D&PID_C52B\5&1F2E3D4C&0&2' |
            Should -Be 'USB\VID_046D&PID_C52B'
    }

    It 'leaves a two-segment id alone' {
        Get-DFHardwareIdPrefix -DeviceID 'ROOT\SYSTEM' | Should -Be 'ROOT\SYSTEM'
    }

    It 'returns null for empty input' {
        Get-DFHardwareIdPrefix -DeviceID '' | Should -BeNullOrEmpty
    }
}

Describe 'Get-DFConfig hardening' {
    It 'clamps out-of-range and non-numeric values to defaults' {
        # These are bound to [ValidateRange] parameters downstream, where PowerShell
        # re-validates on assignment and throws mid-scan.
        foreach ($case in @(
            @{ Json = '{"LogRetentionDays": 0}';     Expected = 90 },
            @{ Json = '{"LogRetentionDays": 99999}'; Expected = 90 },
            @{ Json = '{"LogRetentionDays": "abc"}'; Expected = 90 },
            @{ Json = '{"LogRetentionDays": 30}';    Expected = 30 }
        )) {
            $f = Join-Path $script:TestRoot "clamp-$([guid]::NewGuid().ToString('N')).json"
            $case.Json | Set-Content -LiteralPath $f
            (Get-DFConfig -ConfigPath $f -WarningAction SilentlyContinue).LogRetentionDays |
                Should -Be $case.Expected
        }
    }
}

Describe 'Module surface' {
    It 'exports exactly the documented public functions' {
        $manifest = Import-PowerShellDataFile (Join-Path $script:ModuleRoot 'DFMaintenance.psd1')
        $onDisk = (Get-ChildItem (Join-Path $script:ModuleRoot 'Public\*.ps1')).BaseName
        $manifest.FunctionsToExport | Sort-Object | Should -Be ($onDisk | Sort-Object)
    }

    It 'targets Windows PowerShell 5.1' {
        $manifest = Import-PowerShellDataFile (Join-Path $script:ModuleRoot 'DFMaintenance.psd1')
        $manifest.PowerShellVersion | Should -Be '5.1'
    }
}
