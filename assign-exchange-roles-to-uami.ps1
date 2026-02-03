param(
    [Parameter(Mandatory = $true)]
    [string]$UamiClientId
)

# Requires Microsoft Graph PowerShell SDK
# Install-Module Microsoft.Graph -Scope CurrentUser

$ErrorActionPreference = "Stop"

# Connect with permissions to assign app roles
Connect-MgGraph -Scopes "AppRoleAssignment.ReadWrite.All","Application.Read.All","Directory.Read.All" -Tenant 5380364e-35d4-4293-8bfe-fa76e835384e -UseDeviceCode

# Resolve managed identity service principal by appId (client ID)
$miSp = Get-MgServicePrincipal -Filter "appId eq '$UamiClientId'"
if (-not $miSp) {
    throw "Managed identity service principal not found for appId $UamiClientId"
}

# Resource service principals
$exoSp = Get-MgServicePrincipal -Filter "appId eq '00000002-0000-0ff1-ce00-000000000000'"
$graphSp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"

if (-not $exoSp) { throw "Exchange Online service principal not found." }
if (-not $graphSp) { throw "Microsoft Graph service principal not found." }

# Minimal app role required for Exchange Online PowerShell with managed identity
$exoRoles = @("Exchange.ManageAsApp")

# Roles to remove if present (excess permissions)
$exoRolesToRemove = @("Exchange.ManageAsAppV2","full_access_as_app")
$graphRolesToRemove = @("Mail.Read","Mail.Send")

# Get existing assignments for the managed identity
$existing = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $miSp.Id -All

function Assign-AppRole {
    param(
        [object]$ResourceSp,
        [string]$RoleValue
    )

    $role = $ResourceSp.AppRoles | Where-Object { $_.Value -eq $RoleValue -and $_.IsEnabled }
    if (-not $role) {
        throw "App role '$RoleValue' not found on resource $($ResourceSp.DisplayName)."
    }

    $already = $existing | Where-Object {
        $_.ResourceId -eq $ResourceSp.Id -and $_.AppRoleId -eq $role.Id
    }

    if ($already) {
        Write-Host "Already assigned: $RoleValue"
        return
    }

    New-MgServicePrincipalAppRoleAssignment `
        -ServicePrincipalId $miSp.Id `
        -BodyParameter @{
            principalId = $miSp.Id
            resourceId  = $ResourceSp.Id
            appRoleId   = $role.Id
        } | Out-Null

    Write-Host "Assigned: $RoleValue"
}

function Remove-AppRoleIfAssigned {
    param(
        [object]$ResourceSp,
        [string]$RoleValue
    )

    $role = $ResourceSp.AppRoles | Where-Object { $_.Value -eq $RoleValue }
    if (-not $role) {
        return
    }

    $assignment = $existing | Where-Object {
        $_.ResourceId -eq $ResourceSp.Id -and $_.AppRoleId -eq $role.Id
    }

    if (-not $assignment) {
        return
    }

    Remove-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $miSp.Id -AppRoleAssignmentId $assignment.Id
    Write-Host "Removed: $RoleValue"
}

foreach ($r in $exoRolesToRemove) { Remove-AppRoleIfAssigned -ResourceSp $exoSp -RoleValue $r }
foreach ($r in $graphRolesToRemove) { Remove-AppRoleIfAssigned -ResourceSp $graphSp -RoleValue $r }

foreach ($r in $exoRoles) { Assign-AppRole -ResourceSp $exoSp -RoleValue $r }

Write-Host "Done."