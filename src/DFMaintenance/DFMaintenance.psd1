@{
    RootModule           = 'DFMaintenance.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = 'a7f3c2d1-5e94-4b18-9c6a-2d8f1e0b4a73'
    Author               = 'Carle Health Desktop Engineering'
    Description          = 'Compliance, inventory and freeze-state verification for Deep Freeze protected endpoints.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop')

    FunctionsToExport = @(
        'Initialize-DFMaintenance'
        'Get-DFFreezeState'
        'Get-DFWindowsUpdateStatus'
        'Get-DFDriverInventory'
        'Get-DFSoftwareInventory'
        'Get-DFComplianceSnapshot'
        'Export-DFComplianceReport'
        'Test-DFRebootPending'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('DeepFreeze', 'Faronics', 'WindowsUpdate', 'Compliance', 'Kiosk')
            ProjectUri = 'https://github.com/pkirby11-debug/DF_Driver_Maintenance'
        }
    }
}
