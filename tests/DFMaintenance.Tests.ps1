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
