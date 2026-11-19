function Set-DFDirectorySecurity {
    <#
    .SYNOPSIS
        Restricts a directory to SYSTEM and Administrators, with read-only access for users.

    .DESCRIPTION
        The state directory holds dfmaintenance.json, and that file's DFCPath value is
        executed as SYSTEM by the nightly scan. A directory created with inherited defaults
        at a volume root is frequently writable by authenticated users, which turns the
        config file into a SYSTEM code-execution vector on a machine students physically
        use. Get-DFCPath now validates the path it executes, but the directory should not
        be user-writable in the first place -- defence in depth, because the config also
        steers where reports are written and how long they are kept.

        Inheritance is disabled and explicit rules are applied:
          NT AUTHORITY\SYSTEM        Full control
          BUILTIN\Administrators     Full control
          BUILTIN\Users              Read and execute

        Well-known SIDs are used rather than account names, because 'BUILTIN\Users' does
        not exist under that name on a non-English Windows install.

        Never throws: a scan must not fail because ACLs could not be tightened. The caller
        is told whether it succeeded so it can warn.

    .OUTPUTS
        [bool] whether the DACL was applied.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Restrict directory permissions')) { return $false }

    try {
        # Well-known SIDs: locale-independent.
        $systemSid = New-Object System.Security.Principal.SecurityIdentifier(
            [System.Security.Principal.WellKnownSidType]::LocalSystemSid, $null)
        $adminSid = New-Object System.Security.Principal.SecurityIdentifier(
            [System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
        $usersSid = New-Object System.Security.Principal.SecurityIdentifier(
            [System.Security.Principal.WellKnownSidType]::BuiltinUsersSid, $null)

        $inherit    = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        $propagate  = [System.Security.AccessControl.PropagationFlags]::None
        $allow      = [System.Security.AccessControl.AccessControlType]::Allow

        $acl = Get-Acl -LiteralPath $Path

        # $true = protect from inheritance, $false = do NOT copy inherited rules down.
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($existing in @($acl.Access)) {
            [void]$acl.RemoveAccessRule($existing)
        }

        foreach ($rule in @(
            (New-Object System.Security.AccessControl.FileSystemAccessRule(
                $systemSid, 'FullControl',   $inherit, $propagate, $allow)),
            (New-Object System.Security.AccessControl.FileSystemAccessRule(
                $adminSid,  'FullControl',   $inherit, $propagate, $allow)),
            (New-Object System.Security.AccessControl.FileSystemAccessRule(
                $usersSid,  'ReadAndExecute', $inherit, $propagate, $allow))
        )) {
            $acl.AddAccessRule($rule)
        }

        Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
        Write-DFLog -Component 'Security' -Message "Restricted permissions on '$Path'."
        return $true
    } catch {
        Write-DFLog -Level 'Warning' -Component 'Security' `
            -Message "Could not restrict permissions on '$Path': $($_.Exception.Message)"
        Write-Warning "Could not restrict permissions on '$Path': $($_.Exception.Message). The config file steers a SYSTEM-executed path; secure this directory manually."
        return $false
    }
}
