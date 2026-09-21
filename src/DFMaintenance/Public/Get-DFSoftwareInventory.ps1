function Get-DFSoftwareInventory {
    <#
    .SYNOPSIS
        Inventories installed third-party software and versions.

    .DESCRIPTION
        Reads the uninstall registry hives rather than querying Win32_Product.

        Win32_Product is avoided on purpose: enumerating it triggers an MSI
        consistency check against every installed package, which is slow and can
        cause an unexpected repair/reconfigure. On a classroom machine mid-lesson
        that is a visible failure, and on a Frozen machine the repair is discarded
        anyway, so it is all cost and no benefit.

        Covers both 64- and 32-bit machine hives, plus per-user installs from the loaded
        user hives under HKEY_USERS. HKCU is deliberately NOT used: the scan runs as SYSTEM,
        so HKCU would be SYSTEM's own profile and would silently report nothing while
        appearing to cover per-user software.

    .OUTPUTS
        PSCustomObject with Software collection and summary counts.

    .EXAMPLE
        Get-DFSoftwareInventory

    .EXAMPLE
        Get-DFSoftwareInventory -TrackedSoftware 'Google Chrome','Adobe Acrobat','Zoom'
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        # When supplied, only entries whose DisplayName matches one of these
        # (wildcards allowed) are returned. Keeps the report focused on the apps
        # that actually matter for patching.
        [string[]] $TrackedSoftware,

        # Include entries Windows marks as system components / updates.
        [switch] $IncludeSystemComponents
    )

    # Machine-wide hives are always readable.
    $hives = [System.Collections.Generic.List[string]]::new()
    $hives.Add('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')
    $hives.Add('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')

    # Per-user installs need care. The scan runs as SYSTEM from Task Scheduler, so HKCU is
    # SYSTEM's OWN profile -- never a student's -- and reading it would report nothing while
    # appearing to cover per-user software. Enumerate the loaded user hives under
    # HKEY_USERS instead, filtered to real user SIDs.
    #
    # Limitation: a profile whose hive is not currently loaded (nobody logged on at 03:00,
    # which is the normal case on a classroom kiosk) is not visible here. Per-user installs
    # on a shared kiosk are therefore best-effort; machine-wide coverage is complete.
    $userHiveCount = 0
    try {
        # A plain foreach, not a ForEach-Object pipeline: the pipeline scriptblock gets its
        # own scope, so a counter incremented inside it would not survive.
        $userKeys = @(
            Get-ChildItem -Path 'Registry::HKEY_USERS' -ErrorAction Stop |
                Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' }
        )
        foreach ($userKey in $userKeys) {
            $hives.Add("Registry::$($userKey.Name)\Software\Microsoft\Windows\CurrentVersion\Uninstall\*")
            $hives.Add("Registry::$($userKey.Name)\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*")
            $userHiveCount++
        }
    } catch {
        Write-Verbose "Could not enumerate HKEY_USERS: $($_.Exception.Message)"
    }

    $result = [ordered]@{
        Computer       = $env:COMPUTERNAME
        Timestamp      = (Get-Date).ToString('o')
        TotalCount     = 0
        UserHivesRead  = 0
        Software       = @()
        Error          = $null
    }

    try {
        $entries = foreach ($hive in $hives) {
            Get-ItemProperty -Path $hive -ErrorAction SilentlyContinue | ForEach-Object {
                if (-not $_.DisplayName) { return }
                if (-not $IncludeSystemComponents -and ($_.SystemComponent -eq 1)) { return }
                # Entries with a parent key are patches/hotfixes of another product.
                if (-not $IncludeSystemComponents -and $_.ParentKeyName) { return }

                $installDate = $null
                if ($_.InstallDate -and $_.InstallDate -match '^\d{8}$') {
                    try { $installDate = [datetime]::ParseExact($_.InstallDate, 'yyyyMMdd', $null) } catch { }
                }

                [PSCustomObject]@{
                    DisplayName    = $_.DisplayName
                    DisplayVersion = $_.DisplayVersion
                    Publisher      = $_.Publisher
                    InstallDate    = if ($installDate) { $installDate.ToString('yyyy-MM-dd') } else { $null }
                    Scope          = if ($_.PSPath -like '*HKEY_USERS*') { 'User' } else { 'Machine' }
                    Architecture   = if ($_.PSPath -like '*WOW6432Node*') { 'x86' } else { 'x64' }
                }
            }
        }

        $software = @($entries | Sort-Object DisplayName, DisplayVersion -Unique)

        if ($TrackedSoftware) {
            $software = @(
                $software | Where-Object {
                    $name = $_.DisplayName
                    ($TrackedSoftware | Where-Object { $name -like "*$_*" }).Count -gt 0
                }
            )
        }

        $result.Software      = $software
        $result.TotalCount    = $software.Count
        $result.UserHivesRead = $userHiveCount

        Write-DFLog -Component 'SoftwareInventory' -Message "Software inventory: $($result.TotalCount) entries." `
            -Data @{ Count = $result.TotalCount }
    } catch {
        $result.Error = $_.Exception.Message
        Write-DFLog -Level 'Error' -Component 'SoftwareInventory' -Message "Software inventory failed: $($_.Exception.Message)"
    }

    return [PSCustomObject]$result
}
