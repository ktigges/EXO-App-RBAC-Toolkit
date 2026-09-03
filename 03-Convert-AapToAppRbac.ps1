# Title: Convert Application Access Policy to App RBAC
# Author: Kevin Tigges
# Date: 2026-09-03
# Summary: Migrates an application through App RBAC Prepare, Cutover, and Cleanup phases.

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [string]$AppId,

    [Parameter(Mandatory)]
    [ValidateSet('Prepare', 'Cutover', 'Cleanup')]
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

    [ValidateRange(30, 1440)]
    [int]$MinimumPreparationMinutes = 120,

    [switch]$SkipPropagationWait,
    [switch]$AcknowledgeScopeWidening,
    [switch]$ReuseExistingScope,
    [string]$LiveValidationScriptPath,
    [hashtable]$LiveValidationParameters = @{},
    [switch]$AcknowledgeManualLiveValidation,
    [switch]$AutoRollbackOnValidationFailure,
    [switch]$ObservationValidated,
    [switch]$Execute,
    [string]$StatePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'AppRbacMigration.Common.psm1') -Force

if (-not $StatePath) {
    $safeAppId = $AppId -replace '[^a-zA-Z0-9-]', '_'
    $StatePath = Join-Path $PSScriptRoot "output\migrations\$safeAppId.json"
}

Connect-AppRbacServices -TenantId $TenantId -GraphScopes @(
    'Application.Read.All',
    'AppRoleAssignment.ReadWrite.All',
    'Directory.Read.All'
)
$resolvedTenantId = [string](Get-MgContext).TenantId

$servicePrincipal = Get-EntraServicePrincipalByAppId -AppId $AppId
if (-not $servicePrincipal) {
    throw "No Entra service principal was found for AppId '$AppId'."
}

$application = Get-EntraApplicationByAppId -AppId $AppId
$policy = $null
if ($ScopeType -eq 'ExistingPolicyGroup' -or $Phase -eq 'Cleanup') {
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

function Get-TargetEntraPermissionAssignment {
    if (-not $EntraPermissionValue) {
        throw '-EntraPermissionValue is required for Cutover and Cleanup validation.'
    }

    $matchedAssignments = @(Get-GraphApplicationPermissionDetails -ServicePrincipalId $servicePrincipal.Id |
            Where-Object PermissionValue -eq $EntraPermissionValue)

    if ($matchedAssignments.Count -gt 1) {
        throw "Multiple Entra app-role assignments with permission '$EntraPermissionValue' were found. Remove the intended assignment manually or make the selection unambiguous."
    }

    return $matchedAssignments | Select-Object -First 1
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

function Assert-LiveValidationInputs {
    if (-not $LiveValidationScriptPath) {
        return
    }

    if (-not (Test-Path $LiveValidationScriptPath -PathType Leaf)) {
        throw "Live validation script '$LiveValidationScriptPath' was not found."
    }

    $standardParameters = @('TenantId', 'AppId', 'PositiveMailbox', 'NegativeMailbox')
    $providedParameters = @($standardParameters) + @($LiveValidationParameters.Keys)
    $command = Get-Command -Name $LiveValidationScriptPath -ErrorAction Stop
    $missingParameters = foreach ($parameter in $command.Parameters.Values) {
        $isMandatory = @($parameter.Attributes |
                Where-Object {
                    $_ -is [System.Management.Automation.ParameterAttribute] -and
                    $_.Mandatory
                }).Count -gt 0

        if ($isMandatory -and $providedParameters -notcontains $parameter.Name) {
            $parameter.Name
        }
    }

    if (@($missingParameters).Count -gt 0) {
        throw "Live validation script is missing required parameters: $($missingParameters -join ', '). Supply them through -LiveValidationParameters."
    }
}

function Invoke-LiveValidation {
    if (-not $LiveValidationScriptPath) {
        return $false
    }

    Assert-LiveValidationInputs
    $hostExecutable = (Get-Process -Id $PID).Path
    $argumentList = @(
        '-NoProfile',
        '-File',
        $LiveValidationScriptPath,
        '-TenantId',
        $TenantId,
        '-AppId',
        $AppId,
        '-PositiveMailbox',
        $PositiveMailbox,
        '-NegativeMailbox',
        $NegativeMailbox
    )

    foreach ($key in $LiveValidationParameters.Keys) {
        $argumentList += "-$key"
        $value = $LiveValidationParameters[$key]
        if ($value -is [bool]) {
            if ($value) {
                continue
            }
            throw "Boolean live-validation parameter '$key' is false. Omit false switch parameters."
        }
        $argumentList += [string]$value
    }

    & $hostExecutable @argumentList | Out-Host
    $validationExitCode = $LASTEXITCODE
    if ($validationExitCode -ne 0) {
        throw "Live validation script exited with code $validationExitCode."
    }

    return $true
}

if ($Phase -eq 'Prepare') {
    $createdScope = $false
    $createdAssignment = $false
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
        CutoverAtUtc = $null
        CleanupAtUtc = $null
    }
    Write-ToolkitJson -InputObject $state -Path $StatePath

    Write-Host ''
    Write-Host 'Prepare phase complete. The existing authorization path remains active.' -ForegroundColor Green
    Write-Host "State file: $StatePath"
    return
}

if (-not (Test-Path $StatePath)) {
    throw "State file '$StatePath' was not found. Run the Prepare phase first."
}

$state = Get-Content -Path $StatePath -Raw | ConvertFrom-Json
if ([string]$state.AppId -ne $AppId) {
    throw "State file AppId '$($state.AppId)' does not match requested AppId '$AppId'."
}
if ([string]$state.ApplicationRoleName -ne $ApplicationRoleName) {
    throw "State file role '$($state.ApplicationRoleName)' does not match requested role '$ApplicationRoleName'."
}

$exchangeServicePrincipal = Get-ExchangeServicePrincipalByAppId -AppId $AppId
if (-not $exchangeServicePrincipal) {
    throw 'The Exchange service-principal pointer created during Prepare no longer exists.'
}

$matchingAssignments = @(Get-TargetRoleAssignment -ExchangeServicePrincipal $exchangeServicePrincipal)
if ($matchingAssignments.Count -ne 1) {
    throw "Expected exactly one matching App RBAC assignment; found $($matchingAssignments.Count)."
}

$authorizationTests = Assert-AuthorizationTests

if ($Phase -eq 'Cutover') {
    if (-not $SkipPropagationWait) {
        $preparedAt = [datetime]::Parse([string]$state.PreparedAtUtc).ToUniversalTime()
        $ageMinutes = ((Get-Date).ToUniversalTime() - $preparedAt).TotalMinutes
        if ($ageMinutes -lt $MinimumPreparationMinutes) {
            throw "The App RBAC assignment was prepared $([math]::Floor($ageMinutes)) minutes ago. Wait at least $MinimumPreparationMinutes minutes or explicitly use -SkipPropagationWait after independent validation."
        }
    }

    if (-not $LiveValidationScriptPath -and -not $AcknowledgeManualLiveValidation) {
        throw 'Cutover requires -LiveValidationScriptPath or -AcknowledgeManualLiveValidation.'
    }
    Assert-LiveValidationInputs

    $entraPermissionAssignment = Get-TargetEntraPermissionAssignment
    if (-not $entraPermissionAssignment) {
        throw "Entra permission '$EntraPermissionValue' is already absent. Confirm whether cutover was previously completed."
    }

    $plannedChanges = @(
        "Remove Entra application permission '$EntraPermissionValue' from '$($servicePrincipal.DisplayName)'.",
        'Keep the legacy Application Access Policy in place.',
        'Require a newly issued token and live positive and negative application tests.',
        "Record cutover state in '$StatePath'."
    )
    if ($LiveValidationScriptPath) {
        $plannedChanges += "Execute live validation script '$LiveValidationScriptPath'."
    }

    if (-not $Execute) {
        Assert-ExecutionApproved -Execute:$false -PlannedChanges $plannedChanges
        return
    }

    $removedPermissionState = [ordered]@{
        PermissionValue = $EntraPermissionValue
        AssignmentId = [string]$entraPermissionAssignment.AssignmentId
        ResourceId = [string]$entraPermissionAssignment.ResourceId
        AppRoleId = [string]$entraPermissionAssignment.AppRoleId
        RemovalStartedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        RemovedAtUtc = $null
    }
    $state | Add-Member -NotePropertyName RemovedEntraPermission -NotePropertyValue $removedPermissionState -Force
    Write-ToolkitJson -InputObject $state -Path $StatePath

    Write-Host "Removing Entra permission '$EntraPermissionValue'..." -ForegroundColor Cyan
    Remove-MgServicePrincipalAppRoleAssignment `
        -ServicePrincipalId $servicePrincipal.Id `
        -AppRoleAssignmentId $entraPermissionAssignment.AssignmentId

    $removedPermissionState.RemovedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    $state | Add-Member -NotePropertyName RemovedEntraPermission -NotePropertyValue $removedPermissionState -Force
    Write-ToolkitJson -InputObject $state -Path $StatePath

    $liveValidationSucceeded = $false
    try {
        if ($LiveValidationScriptPath) {
            Write-Host 'Running live application validation...' -ForegroundColor Cyan
            $liveValidationSucceeded = Invoke-LiveValidation
        }
        else {
            Write-Warning 'Complete live positive and negative application tests immediately with a newly issued token.'
        }
    }
    catch {
        if ($AutoRollbackOnValidationFailure) {
            Write-Warning "Live validation failed. Restoring Entra permission '$EntraPermissionValue'."
            try {
                $graphContext = Get-MgContext
                if (-not $graphContext -or [string]$graphContext.TenantId -ne $resolvedTenantId) {
                    Connect-MgGraph -TenantId $TenantId -Scopes @(
                        'Application.Read.All',
                        'AppRoleAssignment.ReadWrite.All'
                    ) -NoWelcome
                }

                New-MgServicePrincipalAppRoleAssignment `
                    -ServicePrincipalId $servicePrincipal.Id `
                    -PrincipalId $servicePrincipal.Id `
                    -ResourceId $entraPermissionAssignment.ResourceId `
                    -AppRoleId $entraPermissionAssignment.AppRoleId | Out-Null
            }
            catch {
                Write-Error @"
Automatic rollback failed. Restore the permission immediately with:

Connect-MgGraph -TenantId '$TenantId' -Scopes 'Application.Read.All','AppRoleAssignment.ReadWrite.All'
New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId '$($servicePrincipal.Id)' -PrincipalId '$($servicePrincipal.Id)' -ResourceId '$($entraPermissionAssignment.ResourceId)' -AppRoleId '$($entraPermissionAssignment.AppRoleId)'

Rollback error: $($_.Exception.Message)
"@
            }
        }
        throw
    }

    $state | Add-Member -NotePropertyName CutoverAtUtc -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
    $state | Add-Member -NotePropertyName LiveValidationSucceeded -NotePropertyValue $liveValidationSucceeded -Force
    $state | Add-Member -NotePropertyName AuthorizationTests -NotePropertyValue $authorizationTests -Force
    Write-ToolkitJson -InputObject $state -Path $StatePath

    Write-Host ''
    Write-Host 'Cutover phase complete. The legacy Application Access Policy remains in place.' -ForegroundColor Green
    if (-not $liveValidationSucceeded) {
        Write-Warning 'Do not run Cleanup until live application validation has been completed and documented.'
    }
    return
}

if ($Phase -eq 'Cleanup') {
    if (-not $ObservationValidated) {
        throw 'Cleanup requires -ObservationValidated to confirm that live operation and the observation window are complete.'
    }

    $entraPermissionAssignment = Get-TargetEntraPermissionAssignment
    if ($entraPermissionAssignment) {
        throw "Entra permission '$EntraPermissionValue' is still assigned. Remove it and complete live validation before Cleanup."
    }

    $policy = Get-ApplicationAccessPolicyForApp -AppId $AppId -PolicyIdentity $PolicyIdentity
    Assert-LiveValidationInputs

    $policyScopeGroupId = Get-ApplicationAccessPolicyScopeIdentity -Policy $policy
    if (-not $policyScopeGroupId) {
        throw "Legacy policy '$($policy.Identity)' does not expose a scope identity required for rollback."
    }
    $policyScopeRecipient = Get-Recipient -Identity $policyScopeGroupId -ErrorAction Stop
    $rollbackScopeIdentity = if ($policyScopeRecipient.PrimarySmtpAddress) {
        [string]$policyScopeRecipient.PrimarySmtpAddress
    }
    else {
        [string]$policyScopeRecipient.Identity
    }

    $legacyPolicyBackup = [ordered]@{
        Identity = [string]$policy.Identity
        AppId = @(([string]$policy.AppId -split '\s*,\s*') | Where-Object { $_ })
        PolicyScopeGroupId = $rollbackScopeIdentity
        AccessRight = [string]$policy.AccessRight
        Description = [string]$policy.Description
    }

    $plannedChanges = @(
        "Remove legacy Application Access Policy '$($policy.Identity)'.",
        'Retain the Exchange App RBAC assignment and its mailbox scope.',
        'Repeat positive and negative App RBAC authorization tests after removal.',
        "Record cleanup state in '$StatePath'."
    )
    if ($LiveValidationScriptPath) {
        $plannedChanges += "Execute live validation script '$LiveValidationScriptPath' after policy removal."
    }

    if (-not $Execute) {
        Assert-ExecutionApproved -Execute:$false -PlannedChanges $plannedChanges
        return
    }

    $state | Add-Member -NotePropertyName LegacyPolicyBackup -NotePropertyValue $legacyPolicyBackup -Force
    $state | Add-Member -NotePropertyName CleanupStartedAtUtc -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
    Write-ToolkitJson -InputObject $state -Path $StatePath

    Write-Host "Removing Application Access Policy '$($policy.Identity)'..." -ForegroundColor Cyan
    Remove-ApplicationAccessPolicy -Identity $policy.Identity -Confirm:$false

    try {
        $postCleanupTests = Assert-AuthorizationTests
        $postCleanupLiveValidation = if ($LiveValidationScriptPath) {
            Invoke-LiveValidation
        }
        else {
            $false
        }
    }
    catch {
        Write-Warning 'Post-cleanup validation failed. Restoring the legacy policy and Entra permission from the saved rollback data.'
        $restorePolicyParameters = @{
            AppId = $legacyPolicyBackup.AppId
            PolicyScopeGroupId = $legacyPolicyBackup.PolicyScopeGroupId
            AccessRight = $legacyPolicyBackup.AccessRight
        }
        if ($legacyPolicyBackup.Description) {
            $restorePolicyParameters.Description = $legacyPolicyBackup.Description
        }
        New-ApplicationAccessPolicy @restorePolicyParameters | Out-Null

        if ($state.PSObject.Properties.Name -contains 'RemovedEntraPermission' -and $state.RemovedEntraPermission) {
            $existingPermission = Get-TargetEntraPermissionAssignment
            if (-not $existingPermission) {
                $graphContext = Get-MgContext
                if (-not $graphContext -or [string]$graphContext.TenantId -ne $resolvedTenantId) {
                    Connect-MgGraph -TenantId $TenantId -Scopes @(
                        'Application.Read.All',
                        'AppRoleAssignment.ReadWrite.All'
                    ) -NoWelcome
                }

                New-MgServicePrincipalAppRoleAssignment `
                    -ServicePrincipalId $servicePrincipal.Id `
                    -PrincipalId $servicePrincipal.Id `
                    -ResourceId ([string]$state.RemovedEntraPermission.ResourceId) `
                    -AppRoleId ([string]$state.RemovedEntraPermission.AppRoleId) | Out-Null
            }
        }
        throw
    }

    $state | Add-Member -NotePropertyName CleanupAtUtc -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
    $state | Add-Member -NotePropertyName RemovedPolicyIdentity -NotePropertyValue ([string]$policy.Identity) -Force
    $state | Add-Member -NotePropertyName PostCleanupAuthorizationTests -NotePropertyValue $postCleanupTests -Force
    $state | Add-Member -NotePropertyName PostCleanupLiveValidationSucceeded -NotePropertyValue $postCleanupLiveValidation -Force
    Write-ToolkitJson -InputObject $state -Path $StatePath

    Write-Host ''
    Write-Host 'Cleanup phase complete. App RBAC is now the retained Exchange authorization path.' -ForegroundColor Green
}
