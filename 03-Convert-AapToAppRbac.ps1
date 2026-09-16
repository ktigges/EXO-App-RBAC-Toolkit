# Title: Convert Application Access Policy to App RBAC
# Author: Kevin Tigges
# Date: 2026-09-03
# Summary: Prepares one application for App RBAC without performing Cutover or Cleanup.

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [string]$AppId,

    [Parameter(Mandatory)]
    [ValidateSet('Prepare')]
    [string]$Phase,

    [Parameter(Mandatory)]
    [string]$ApplicationRoleName,

    [string]$EntraPermissionValue,
    [string]$PolicyIdentity,

    [ValidateSet('ExistingPolicyGroup', 'RecipientFilter', 'AdministrativeUnit')]
    [string]$ScopeType = 'ExistingPolicyGroup',

    [string]$ManagementScopeName,
    [string]$RecipientFilter,
    [string]$AdministrativeUnitId,

    [Parameter(Mandatory)]
    [string]$PositiveMailbox,

    [Parameter(Mandatory)]
    [string]$NegativeMailbox,

    [switch]$AcknowledgeScopeWidening,
    [switch]$ReuseExistingScope,
    [switch]$Execute,
    [ValidateSet('Auto', 'Browser')]
    [string]$AuthenticationMode = 'Auto',
    [string]$StatePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'AppRbacMigration.Common.psm1') -Force

if (-not $StatePath) {
    $safeAppId = $AppId -replace '[^a-zA-Z0-9-]', '_'
    $StatePath = Join-Path (Join-Path (Join-Path $PSScriptRoot 'Output') 'migrations') "$safeAppId.json"
}

Connect-AppRbacServices -TenantId $TenantId -GraphScopes @(
    'Application.Read.All',
    'AppRoleAssignment.Read.All',
    'Directory.Read.All'
) -AuthenticationMode $AuthenticationMode
$resolvedTenantId = [string](Get-MgContext).TenantId

$servicePrincipal = Get-EntraServicePrincipalByAppId -AppId $AppId
if (-not $servicePrincipal) {
    throw "No Entra service principal was found for AppId '$AppId'."
}

$application = Get-EntraApplicationByAppId -AppId $AppId
$policy = $null
if ($ScopeType -eq 'ExistingPolicyGroup') {
    $policy = Get-ApplicationAccessPolicyForApp -AppId $AppId -PolicyIdentity $PolicyIdentity
}

if (-not $ManagementScopeName -and $ScopeType -ne 'AdministrativeUnit') {
    $ManagementScopeName = "AppRBAC-$($servicePrincipal.DisplayName)-Scope"
    if ($ManagementScopeName.Length -gt 64) {
        $ManagementScopeName = $ManagementScopeName.Substring(0, 64)
    }
}

function Get-TargetRecipientFilter {
    if ($ScopeType -eq 'ExistingPolicyGroup') {
        if ([string]$policy.AccessRight -ne 'RestrictAccess') {
            throw "Policy '$($policy.Identity)' uses AccessRight '$($policy.AccessRight)'. DenyAccess policies cannot be converted directly to an App RBAC grant. Select an explicit positive RecipientFilter or AdministrativeUnit scope."
        }

        $scopeIdentity = Get-ApplicationAccessPolicyScopeIdentity -Policy $policy
        if (-not $scopeIdentity) {
            throw "The Application Access Policy '$($policy.Identity)' does not expose a scope group identity."
        }

        $scopeRecipient = Get-Recipient -Identity $scopeIdentity
        if (-not $scopeRecipient.DistinguishedName) {
            throw "The policy scope '$scopeIdentity' does not have a distinguished name."
        }

        $nestedGroups = @(Get-SupportedScopeGroupDirectMembers -Group $scopeRecipient |
                Where-Object {
                    [string]$_.RecipientType -match 'Group' -or
                    [string]$_.RecipientTypeDetails -match 'Group|Distribution'
                })

        if ($nestedGroups.Count -gt 0) {
            $names = $nestedGroups.DisplayName -join ', '
            throw "The legacy scope contains nested groups: $names. App RBAC MemberOfGroup evaluates direct members only. Flatten the scope or use an attribute-based filter."
        }

        return "MemberOfGroup -eq '$($scopeRecipient.DistinguishedName)'"
    }

    if ($ScopeType -eq 'RecipientFilter') {
        if (-not $RecipientFilter) {
            throw '-RecipientFilter is required when -ScopeType RecipientFilter is selected.'
        }
        return $RecipientFilter
    }

    return $null
}

function Get-TargetRoleAssignment {
    param(
        [Parameter(Mandatory)]
        [object]$ExchangeServicePrincipal
    )

    return @(Get-ManagementRoleAssignment -RoleAssignee $ExchangeServicePrincipal.ObjectId |
            Where-Object {
                [string]$_.Role -eq $ApplicationRoleName -and
                (
                    ($ScopeType -eq 'AdministrativeUnit' -and [string]$_.RecipientAdministrativeUnitScope -eq $AdministrativeUnitId) -or
                    (($ScopeType -eq 'ExistingPolicyGroup' -or $ScopeType -eq 'RecipientFilter') -and [string]$_.CustomResourceScope -eq $ManagementScopeName)
                )
            })
}

function Assert-AuthorizationTests {
    $attempts = 6
    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        $positiveRows = @(Test-ServicePrincipalAuthorization -Identity $AppId -Resource $PositiveMailbox |
                Where-Object { [string]$_.RoleName -eq $ApplicationRoleName })
        $negativeRows = @(Test-ServicePrincipalAuthorization -Identity $AppId -Resource $NegativeMailbox |
                Where-Object { [string]$_.RoleName -eq $ApplicationRoleName })

        $positiveInScope = @($positiveRows | Where-Object InScope -eq $true).Count -gt 0
        $negativeInScope = @($negativeRows | Where-Object InScope -eq $true).Count -gt 0

        if ($positiveInScope -and -not $negativeInScope) {
            return [ordered]@{
                PositiveMailbox = $PositiveMailbox
                PositiveInScope = $positiveInScope
                NegativeMailbox = $NegativeMailbox
                NegativeInScope = $negativeInScope
            }
        }

        if ($attempt -lt $attempts) {
            Start-Sleep -Seconds 10
        }
    }

    if (-not $positiveInScope) {
        throw "Positive mailbox '$PositiveMailbox' is not in scope for '$ApplicationRoleName' after $attempts attempts."
    }
    throw "Negative mailbox '$NegativeMailbox' is unexpectedly in scope for '$ApplicationRoleName' after $attempts attempts."
}

function Get-PolicyControlledEntraPermissionAssignments {
    $supportedPermissionValues = @(
        'Mail.Read',
        'Mail.ReadBasic',
        'Mail.ReadBasic.All',
        'Mail.ReadWrite',
        'Mail.Send',
        'MailboxSettings.Read',
        'MailboxSettings.ReadWrite',
        'Calendars.Read',
        'Calendars.ReadWrite',
        'Contacts.Read',
        'Contacts.ReadWrite',
        'full_access_as_app'
    )

    return @(Get-GraphApplicationPermissionDetails -ServicePrincipalId $servicePrincipal.Id |
            Where-Object { $supportedPermissionValues -contains [string]$_.PermissionValue })
}

function ConvertTo-NormalizedFilter {
    param(
        [AllowNull()]
        [string]$Filter
    )

    if (-not $Filter) {
        return ''
    }

    $normalized = ($Filter -replace '\s+', ' ').Trim()
    while ($normalized.StartsWith('(') -and $normalized.EndsWith(')')) {
        $normalized = $normalized.Substring(1, $normalized.Length - 2).Trim()
    }
    return $normalized
}

if ($Phase -eq 'Prepare') {
    $createdScope = $false
    $createdAssignment = $false

    if (-not $EntraPermissionValue) {
        throw '-EntraPermissionValue is required during Prepare to validate the permission being migrated.'
    }

    $policyControlledAssignments = @(Get-PolicyControlledEntraPermissionAssignments)
    $selectedPermissionAssignments = @($policyControlledAssignments |
            Where-Object PermissionValue -eq $EntraPermissionValue)
    if ($selectedPermissionAssignments.Count -ne 1) {
        throw "Expected exactly one Entra application permission '$EntraPermissionValue' controlled by Application Access Policies; found $($selectedPermissionAssignments.Count)."
    }

    $otherPolicyControlledAssignments = @($policyControlledAssignments |
            Where-Object PermissionValue -ne $EntraPermissionValue)
    if ($otherPolicyControlledAssignments.Count -gt 0) {
        $otherPermissionValues = @($otherPolicyControlledAssignments.PermissionValue |
                Sort-Object -Unique) -join ', '
        throw "AppId '$AppId' also has Application Access Policy-controlled permissions: $otherPermissionValues. This workflow migrates one permission-to-role mapping and must not remove the shared legacy policy while other controlled permissions remain. Create a coordinated migration design for this application before continuing."
    }

    $allAppPolicies = @(Get-AllApplicationAccessPolicies | Where-Object {
            $policyAppIds = @(([string]$_.AppId -split '\s*,\s*') | Where-Object { $_ })
            $policyAppIds -contains $AppId -or $policyAppIds -contains '*'
        })
    $denyPolicies = @($allAppPolicies | Where-Object { [string]$_.AccessRight -eq 'DenyAccess' })
    if ($denyPolicies.Count -gt 0) {
        $denyPolicyNames = $denyPolicies.Identity -join ', '
        throw "DenyAccess policies apply to AppId '$AppId': $denyPolicyNames. App RBAC requires an explicitly designed positive scope and this toolkit will not convert the application automatically."
    }

    if ($ScopeType -ne 'ExistingPolicyGroup' -and -not $AcknowledgeScopeWidening) {
        throw "ScopeType '$ScopeType' can grant access beyond the mailbox set protected by the current Application Access Policy during coexistence. Review the target scope and supply -AcknowledgeScopeWidening to continue."
    }

    $targetRecipientFilter = Get-TargetRecipientFilter
    $existingScope = $null
    if ($ScopeType -eq 'ExistingPolicyGroup' -or $ScopeType -eq 'RecipientFilter') {
        $existingScope = Get-ManagementScope -Identity $ManagementScopeName -ErrorAction SilentlyContinue
        if ($existingScope) {
            $existingFilter = ConvertTo-NormalizedFilter -Filter ([string]$existingScope.RecipientFilter)
            $targetFilter = ConvertTo-NormalizedFilter -Filter $targetRecipientFilter
            if ($existingFilter -ne $targetFilter -and -not $ReuseExistingScope) {
                throw "Management Scope '$ManagementScopeName' already exists with a different recipient filter. Use a unique scope name or explicitly supply -ReuseExistingScope after verifying its membership."
            }
        }
    }

    $exchangeServicePrincipal = Get-ExchangeServicePrincipalByAppId -AppId $AppId
    $plannedChanges = [System.Collections.Generic.List[string]]::new()

    if (-not $existingScope -and ($ScopeType -eq 'ExistingPolicyGroup' -or $ScopeType -eq 'RecipientFilter')) {
        $plannedChanges.Add("Create Management Scope '$ManagementScopeName' with recipient filter: $targetRecipientFilter")
    }
    if (-not $exchangeServicePrincipal) {
        $plannedChanges.Add("Create the Exchange service-principal pointer for AppId '$AppId' and object ID '$($servicePrincipal.Id)'.")
    }
    $plannedChanges.Add("Assign Exchange role '$ApplicationRoleName' to '$($servicePrincipal.DisplayName)' using scope type '$ScopeType'.")
    $plannedChanges.Add("Test authorized mailbox '$PositiveMailbox' and unauthorized mailbox '$NegativeMailbox'.")
    $plannedChanges.Add("Write preparation state to '$StatePath'.")
    $plannedChanges.Add('Leave the existing Entra application permission and Application Access Policy unchanged during Prepare.')
    if ($ScopeType -ne 'ExistingPolicyGroup') {
        $plannedChanges.Add('The App RBAC scope is additive and becomes effective immediately. Its mailbox population may differ from the legacy policy during coexistence.')
    }

    if (-not $Execute) {
        Assert-ExecutionApproved -Execute:$false -PlannedChanges $plannedChanges
        return
    }

    if (-not $existingScope -and ($ScopeType -eq 'ExistingPolicyGroup' -or $ScopeType -eq 'RecipientFilter')) {
        Write-Host "Creating Management Scope '$ManagementScopeName'..." -ForegroundColor Cyan
        $existingScope = New-ManagementScope `
            -Name $ManagementScopeName `
            -RecipientRestrictionFilter $targetRecipientFilter
        $createdScope = $true
    }

    if (-not $exchangeServicePrincipal) {
        Write-Host 'Creating Exchange service-principal pointer...' -ForegroundColor Cyan
        $exchangeServicePrincipal = New-ServicePrincipal `
            -AppId $AppId `
            -ObjectId $servicePrincipal.Id `
            -DisplayName $servicePrincipal.DisplayName
    }

    $existingAssignments = @(Get-TargetRoleAssignment -ExchangeServicePrincipal $exchangeServicePrincipal)
    if ($existingAssignments.Count -gt 1) {
        throw 'Multiple matching App RBAC assignments already exist.'
    }

    $assignment = $existingAssignments | Select-Object -First 1
    if (-not $assignment) {
        $assignmentName = "AppRBAC-$($servicePrincipal.DisplayName)-$($ApplicationRoleName -replace '^Application ', '')"
        if ($assignmentName.Length -gt 64) {
            $assignmentName = $assignmentName.Substring(0, 64)
        }

        $assignmentParameters = @{
            Name = $assignmentName
            App = $servicePrincipal.Id
            Role = $ApplicationRoleName
        }
        if ($ScopeType -eq 'ExistingPolicyGroup' -or $ScopeType -eq 'RecipientFilter') {
            $assignmentParameters.CustomResourceScope = $ManagementScopeName
        }
        elseif ($ScopeType -eq 'AdministrativeUnit') {
            if (-not $AdministrativeUnitId) {
                throw '-AdministrativeUnitId is required when -ScopeType AdministrativeUnit is selected.'
            }
            $assignmentParameters.RecipientAdministrativeUnitScope = $AdministrativeUnitId
        }

        Write-Host "Creating App RBAC assignment '$assignmentName'..." -ForegroundColor Cyan
        $assignment = New-ManagementRoleAssignment @assignmentParameters
        $createdAssignment = $true
    }

    try {
        $authorizationTests = Assert-AuthorizationTests
    }
    catch {
        if ($createdAssignment -and $assignment) {
            Remove-ManagementRoleAssignment -Identity $assignment.Name -Confirm:$false -ErrorAction Continue
        }
        if ($createdScope -and $existingScope) {
            Remove-ManagementScope -Identity $ManagementScopeName -Confirm:$false -ErrorAction Continue
        }
        throw
    }
    $state = [ordered]@{
        PreparedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        TenantId = $TenantId
        AppId = $AppId
        ApplicationDisplayName = [string]$servicePrincipal.DisplayName
        ApplicationObjectId = if ($application) { [string]$application.Id } else { $null }
        ServicePrincipalObjectId = [string]$servicePrincipal.Id
        ExchangeServicePrincipalIdentity = [string]$exchangeServicePrincipal.ObjectId
        ApplicationRoleName = $ApplicationRoleName
        EntraPermissionValue = $EntraPermissionValue
        ScopeType = $ScopeType
        ManagementScopeName = $ManagementScopeName
        RecipientFilter = $targetRecipientFilter
        AdministrativeUnitId = $AdministrativeUnitId
        PolicyIdentity = if ($policy) { [string]$policy.Identity } else { $PolicyIdentity }
        RoleAssignmentName = [string]$assignment.Name
        AuthorizationTests = $authorizationTests
    }
    Write-ToolkitJson -InputObject $state -Path $StatePath

    Write-Host ''
    Write-Host 'Prepare phase complete. The existing authorization path remains active.' -ForegroundColor Green
    Write-Host "State file: $StatePath"
    return
}
