function Get-DFDriverInventory {
    <#
    .SYNOPSIS
        Inventories installed device drivers and flags stale or problematic ones.

    .DESCRIPTION
        Drivers are the part of the maintenance story that Deep Freeze Cloud's
        patch management does not cover, so this is the inventory that has no
        other source of truth in the environment.

        Reports Microsoft-supplied and third-party drivers separately: on a
        kiosk/classroom build the drivers that actually cause trouble (graphics,
        audio, touch, network) are almost always third-party, and the Microsoft
        inbox drivers are noise in the report.

        Devices in an error state are surfaced via Win32_PnPEntity ConfigManagerErrorCode,
        which catches the "this touchscreen has silently not worked for a month"
        class of problem that nobody reports on a public device.

    .OUTPUTS
        PSCustomObject with Drivers, ProblemDevices and summary counts.

    .EXAMPLE
        Get-DFDriverInventory -StaleAfterDays 730

    .EXAMPLE
        (Get-DFDriverInventory).ProblemDevices
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        # A driver older than this is reported as stale.
        [ValidateRange(0, 10000)]
        [int] $StaleAfterDays = 1095,

        # Include Microsoft-supplied inbox drivers in the Drivers collection.
        [switch] $IncludeMicrosoftDrivers
    )

    $result = [ordered]@{
        Computer         = $env:COMPUTERNAME
        Timestamp        = (Get-Date).ToString('o')
        StaleAfterDays   = $StaleAfterDays
        TotalDrivers     = 0
        ThirdPartyCount  = 0
        StaleCount       = 0
        ProblemCount     = 0
        DisabledCount    = 0
        Drivers          = @()
        ProblemDevices   = @()
        DisabledDevices  = @()
        Error            = $null
    }

    try {
        $signed = Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop |
            Where-Object { $_.DeviceName -and $_.DriverVersion }

        $result.TotalDrivers = @($signed).Count
        $cutoff = (Get-Date).AddDays(-$StaleAfterDays)

        $drivers = foreach ($d in $signed) {
            $isMicrosoft = $d.DriverProviderName -like 'Microsoft*'
            if (-not $IncludeMicrosoftDrivers -and $isMicrosoft) { continue }

            $driverDate = $null
            if ($d.DriverDate) {
                try { $driverDate = [datetime]$d.DriverDate } catch { $driverDate = $null }
            }

            [PSCustomObject]@{
                DeviceName    = $d.DeviceName
                DeviceClass   = $d.DeviceClass
                Provider      = $d.DriverProviderName
                DriverVersion = $d.DriverVersion
                DriverDate    = if ($driverDate) { $driverDate.ToString('yyyy-MM-dd') } else { $null }
                AgeDays       = if ($driverDate) { [math]::Round(((Get-Date) - $driverDate).TotalDays) } else { $null }
                IsStale       = ($driverDate -and $driverDate -lt $cutoff)
                IsMicrosoft   = $isMicrosoft
                # Only the hardware-class prefix (e.g. USB\VID_046D&PID_C52B). The third
                # segment of a DeviceID is the instance id, which for many devices is the
                # hardware SERIAL NUMBER -- a stable per-unit identifier the README claims
                # these reports do not contain. VID/PID is what driver triage needs anyway.
                HardwareId    = Get-DFHardwareIdPrefix -DeviceID $d.DeviceID
            }
        }

        $result.Drivers         = @($drivers | Sort-Object -Property @{ Expression = 'AgeDays'; Descending = $true })
        $result.ThirdPartyCount = @($result.Drivers | Where-Object { -not $_.IsMicrosoft }).Count
        $result.StaleCount      = @($result.Drivers | Where-Object { $_.IsStale }).Count

        # ConfigManagerErrorCode 0 means the device is working correctly, but "non-zero"
        # is not the same as "broken". On a locked-down kiosk some codes are the INTENDED
        # state -- IT disables webcams, Bluetooth and card readers deliberately -- and
        # treating them as faults raises a permanent DRV001 Warning that never clears and
        # trains everyone to ignore the finding.
        #
        #   22 CM_PROB_DISABLED         device deliberately disabled
        #   24 CM_PROB_DEVICE_NOT_THERE device not present
        #   45 CM_PROB_PHANTOM          not currently connected (e.g. undocked, unplugged)
        $benignCodes = @(22, 24, 45)

        $nonZero = @(
            Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue |
                Where-Object { $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -ne 0 }
        )

        $asRecord = {
            param($d)
            [PSCustomObject]@{
                Name       = $d.Name
                HardwareId = Get-DFHardwareIdPrefix -DeviceID $d.DeviceID
                ErrorCode  = $d.ConfigManagerErrorCode
                Status     = $d.Status
            }
        }

        $result.ProblemDevices = @(
            $nonZero | Where-Object { $_.ConfigManagerErrorCode -notin $benignCodes } |
                ForEach-Object { & $asRecord $_ }
        )
        # Kept separately for visibility: useful to see, never a finding.
        $result.DisabledDevices = @(
            $nonZero | Where-Object { $_.ConfigManagerErrorCode -in $benignCodes } |
                ForEach-Object { & $asRecord $_ }
        )
        $result.ProblemCount  = $result.ProblemDevices.Count
        $result.DisabledCount = $result.DisabledDevices.Count

        Write-DFLog -Component 'DriverInventory' `
            -Message "Drivers: $($result.TotalDrivers) total, $($result.StaleCount) stale, $($result.ProblemCount) in error." `
            -Data @{ Total = $result.TotalDrivers; Stale = $result.StaleCount; Problems = $result.ProblemCount }
    } catch {
        $result.Error = $_.Exception.Message
        Write-DFLog -Level 'Error' -Component 'DriverInventory' -Message "Driver inventory failed: $($_.Exception.Message)"
    }

    return [PSCustomObject]$result
}
