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

        Covers both 64- and 32-bit hives plus per-user installs under HKCU, which
        is where browser and helper-app installs on a shared kiosk often land.

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

    $hives = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $result = [ordered]@{
        Computer   = $env:COMPUTERNAME
        Timestamp  = (Get-Date).ToString('o')
        TotalCount = 0
        Software   = @()
        Error      = $null
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
                    Scope          = if ($_.PSPath -like '*HKEY_CURRENT_USER*') { 'User' } else { 'Machine' }
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

        $result.Software   = $software
        $result.TotalCount = $software.Count

        Write-DFLog -Component 'SoftwareInventory' -Message "Software inventory: $($result.TotalCount) entries." `
            -Data @{ Count = $result.TotalCount }
    } catch {
        $result.Error = $_.Exception.Message
        Write-DFLog -Level 'Error' -Component 'SoftwareInventory' -Message "Software inventory failed: $($_.Exception.Message)"
    }

    return [PSCustomObject]$result
}
