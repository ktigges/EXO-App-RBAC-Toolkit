# Title: Complete One Application Access Policy Migration
# Author: Kevin Tigges
# Date: 2026-09-16
# Summary: Optionally performs Cutover or Cleanup for one application prepared by script 03.

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [string]$AppId,

    [Parameter(Mandatory)]
    [ValidateSet('Cutover', 'Cleanup')]
    [string]$Phase,

    [ValidateRange(30, 1440)]
    [int]$MinimumPreparationMinutes = 120,

    [switch]$SkipPropagationWait,
    [switch]$AcknowledgeSingleAppChange,
    [switch]$AcknowledgeExternalLiveValidation,
    [switch]$ObservationValidated,
    [switch]$AutoRollbackOnValidationFailure,

    [string]$CertificatePemPath,
    [string]$PrivateKeyPath,
    [string]$CertificateThumbprint,

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

if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
    throw "Migration state '$StatePath' was not found. Prepare this application with script 03 first."
}

$state = Get-Content -LiteralPath $StatePath -Raw -ErrorAction Stop | ConvertFrom-Json
$requiredStateProperties = @(
    'PreparedAtUtc',
    'TenantId',
    'AppId',
    'ServicePrincipalObjectId',
    'ApplicationRoleName',
    'EntraPermissionValue',
    'PolicyIdentity',
    'RoleAssignmentName',
    'AuthorizationTests'
)
$missingStateProperties = @($requiredStateProperties | Where-Object {
        $state.PSObject.Properties.Name -notcontains $_ -or
        [string]::IsNullOrWhiteSpace([string]$state.$_)
    })
if ($missingStateProperties.Count -gt 0) {
    throw "Migration state is missing required values: $($missingStateProperties -join ', '). Run Prepare again."
}
if ([string]$state.TenantId -ne $TenantId) {
    throw "State tenant '$($state.TenantId)' does not match requested tenant '$TenantId'."
}
if ([string]$state.AppId -ne $AppId) {
    throw "State AppId '$($state.AppId)' does not match requested AppId '$AppId'."
}

$hasPemCredential = -not [string]::IsNullOrWhiteSpace($CertificatePemPath) -or
    -not [string]::IsNullOrWhiteSpace($PrivateKeyPath)
$hasThumbprintCredential = -not [string]::IsNullOrWhiteSpace($CertificateThumbprint)
if ($hasPemCredential -and $hasThumbprintCredential) {
    throw 'Use either PEM certificate paths or a Windows certificate thumbprint, not both.'
}
if ($hasPemCredential -and (
        [string]::IsNullOrWhiteSpace($CertificatePemPath) -or
        [string]::IsNullOrWhiteSpace($PrivateKeyPath))) {
    throw 'Both -CertificatePemPath and -PrivateKeyPath are required for PEM authentication.'
}
$runLiveValidation = $hasPemCredential -or $hasThumbprintCredential
if ($Execute -and -not $runLiveValidation -and -not $AcknowledgeExternalLiveValidation) {
    throw 'Execution requires application credentials for live validation or -AcknowledgeExternalLiveValidation.'
}
if ($Execute -and -not $AcknowledgeSingleAppChange) {
    throw 'Execution requires -AcknowledgeSingleAppChange to confirm this operation targets one reviewed application.'
}

Connect-AppRbacServices -TenantId $TenantId -GraphScopes @(
    'Application.Read.All',
    'AppRoleAssignment.ReadWrite.All',
    'Directory.Read.All'
) -AuthenticationMode $AuthenticationMode

$servicePrincipal = Get-EntraServicePrincipalByAppId -AppId $AppId
if (-not $servicePrincipal) {
    throw "No Entra service principal was found for AppId '$AppId'."
}
if ([string]$servicePrincipal.Id -ne [string]$state.ServicePrincipalObjectId) {
    throw "Current Entra service-principal object ID '$($servicePrincipal.Id)' does not match prepared state '$($state.ServicePrincipalObjectId)'."
}

$exchangeServicePrincipal = Get-ExchangeServicePrincipalByAppId -AppId $AppId
if (-not $exchangeServicePrincipal) {
    throw "The Exchange service-principal pointer prepared for AppId '$AppId' was not found."
}

$roleAssignment = Get-ManagementRoleAssignment -Identity $state.RoleAssignmentName -ErrorAction SilentlyContinue
if (-not $roleAssignment -or [string]$roleAssignment.Role -ne [string]$state.ApplicationRoleName) {
    throw "The prepared App RBAC assignment '$($state.RoleAssignmentName)' was not found with role '$($state.ApplicationRoleName)'."
}

$positiveMailbox = [string]$state.AuthorizationTests.PositiveMailbox
$negativeMailbox = [string]$state.AuthorizationTests.NegativeMailbox
if ([string]::IsNullOrWhiteSpace($positiveMailbox) -or [string]::IsNullOrWhiteSpace($negativeMailbox)) {
    throw 'Prepared state does not contain both positive and negative validation mailboxes.'
}

function Assert-AppRbacAuthorization {
    $attempts = 6
    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        $positiveRows = @(Test-ServicePrincipalAuthorization -Identity $AppId -Resource $positiveMailbox |
                Where-Object RoleName -eq $state.ApplicationRoleName)
        $negativeRows = @(Test-ServicePrincipalAuthorization -Identity $AppId -Resource $negativeMailbox |
                Where-Object RoleName -eq $state.ApplicationRoleName)
        $positiveInScope = @($positiveRows | Where-Object InScope -eq $true).Count -gt 0
        $negativeInScope = @($negativeRows | Where-Object InScope -eq $true).Count -gt 0

        if ($positiveInScope -and -not $negativeInScope) {
            return [ordered]@{
                PositiveMailbox = $positiveMailbox
                PositiveInScope = $true
                NegativeMailbox = $negativeMailbox
                NegativeInScope = $false
            }
        }
        if ($attempt -lt $attempts) {
            Start-Sleep -Seconds 10
        }
    }

    throw "App RBAC validation failed. Expected '$positiveMailbox' in scope and '$negativeMailbox' out of scope for '$($state.ApplicationRoleName)'."
}

function Get-TargetPermissionAssignment {
    $assignments = @(Get-GraphApplicationPermissionDetails -ServicePrincipalId $servicePrincipal.Id |
            Where-Object PermissionValue -eq $state.EntraPermissionValue)
    if ($assignments.Count -gt 1) {
        throw "Multiple active '$($state.EntraPermissionValue)' assignments were found. Select and remove the intended grant manually."
    }
    return $assignments | Select-Object -First 1
}

function Invoke-MailboxValidation {
    if (-not $runLiveValidation) {
        return $false
    }

    $scriptPath = Join-Path $PSScriptRoot '04-Test-GraphMailboxAccess.ps1'
    $hostExecutable = (Get-Process -Id $PID).Path
    foreach ($testCase in @(
            @{ Mailbox = $positiveMailbox; ExpectedAccess = 'Allowed' },
            @{ Mailbox = $negativeMailbox; ExpectedAccess = 'Denied' }
        )) {
        $arguments = @(
            '-NoProfile',
            '-File', $scriptPath,
            '-TenantId', $TenantId,
            '-AppId', $AppId,
            '-Mailbox', $testCase.Mailbox,
            '-ExpectedAccess', $testCase.ExpectedAccess
        )
        if ($hasThumbprintCredential) {
            $arguments += @('-CertificateThumbprint', $CertificateThumbprint)
        }
        else {
            $arguments += @(
                '-CertificatePemPath', $CertificatePemPath,
                '-PrivateKeyPath', $PrivateKeyPath
            )
        }

        & $hostExecutable @arguments | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "Live Graph validation failed for '$($testCase.Mailbox)'."
        }
    }
    return $true
}

function Restore-EntraPermission {
    param([Parameter(Mandatory)][object]$Permission)

    $existingPermission = Get-TargetPermissionAssignment
    if (-not $existingPermission) {
        New-MgServicePrincipalAppRoleAssignment `
            -ServicePrincipalId $servicePrincipal.Id `
            -PrincipalId $servicePrincipal.Id `
            -ResourceId ([string]$Permission.ResourceId) `
            -AppRoleId ([string]$Permission.AppRoleId) | Out-Null
    }
}

$authorizationTests = Assert-AppRbacAuthorization

if ($Phase -eq 'Cutover') {
    if ($state.PSObject.Properties.Name -contains 'CutoverAtUtc' -and $state.CutoverAtUtc) {
        throw "Cutover was already recorded at '$($state.CutoverAtUtc)'."
    }
    if (-not $SkipPropagationWait) {
        $preparedAt = [datetime]::Parse(
            [string]$state.PreparedAtUtc,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind
        ).ToUniversalTime()
        $ageMinutes = ((Get-Date).ToUniversalTime() - $preparedAt).TotalMinutes
        if ($ageMinutes -lt $MinimumPreparationMinutes) {
            throw "Prepare completed $([math]::Round($ageMinutes, 1)) minutes ago. Wait at least $MinimumPreparationMinutes minutes or use -SkipPropagationWait after validating propagation."
        }
    }

    $permission = Get-TargetPermissionAssignment
    if (-not $permission) {
        throw "Active Entra permission '$($state.EntraPermissionValue)' was not found. Verify the application before Cutover."
    }

    $plannedChanges = @(
        "Target only AppId '$AppId' ('$($state.ApplicationDisplayName)').",
        "Remove Entra permission '$($permission.PermissionValue)' assignment '$($permission.AssignmentId)'.",
        "Keep legacy AAP '$($state.PolicyIdentity)' for rollback and observation.",
        'Repeat positive and negative App RBAC authorization tests.',
        $(if ($runLiveValidation) { 'Run fresh-token allowed and denied Graph mailbox tests.' } else { 'Record that live application validation will be completed externally.' }),
        "Update state '$StatePath'."
    )
    if (-not $Execute) {
        Assert-ExecutionApproved -Execute:$false -PlannedChanges $plannedChanges
        return
    }

    $removedPermission = [ordered]@{
        PermissionValue = [string]$permission.PermissionValue
        AssignmentId = [string]$permission.AssignmentId
        ResourceId = [string]$permission.ResourceId
        AppRoleId = [string]$permission.AppRoleId
        RemovalStartedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        RemovedAtUtc = $null
    }
    $state | Add-Member -NotePropertyName RemovedEntraPermission -NotePropertyValue $removedPermission -Force
    Write-ToolkitJson -InputObject $state -Path $StatePath

    Remove-MgServicePrincipalAppRoleAssignment `
        -ServicePrincipalId $servicePrincipal.Id `
        -AppRoleAssignmentId $permission.AssignmentId
    $removedPermission.RemovedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    Write-ToolkitJson -InputObject $state -Path $StatePath

    try {
        $authorizationTests = Assert-AppRbacAuthorization
        $liveValidationSucceeded = Invoke-MailboxValidation
    }
    catch {
        if ($AutoRollbackOnValidationFailure) {
            Write-Warning 'Cutover validation failed. Restoring the removed Entra permission.'
            Restore-EntraPermission -Permission $removedPermission
            $state | Add-Member -NotePropertyName CutoverRollbackAtUtc -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
            Write-ToolkitJson -InputObject $state -Path $StatePath
        }
        throw
    }

    $state | Add-Member -NotePropertyName CutoverAtUtc -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
    $state | Add-Member -NotePropertyName AuthorizationTests -NotePropertyValue $authorizationTests -Force
    $state | Add-Member -NotePropertyName LiveValidationSucceeded -NotePropertyValue ([bool]$liveValidationSucceeded) -Force
    Write-ToolkitJson -InputObject $state -Path $StatePath
    Write-Host 'Single-application Cutover complete. Observe the application before Cleanup.' -ForegroundColor Green
    return
}

if (-not ($state.PSObject.Properties.Name -contains 'CutoverAtUtc') -or -not $state.CutoverAtUtc) {
    throw 'Cleanup requires a completed Cutover in the migration state.'
}
if ($Execute -and -not $ObservationValidated) {
    throw 'Cleanup requires -ObservationValidated.'
}
if ($state.PSObject.Properties.Name -contains 'CleanupAtUtc' -and $state.CleanupAtUtc) {
    throw "Cleanup was already recorded at '$($state.CleanupAtUtc)'."
}
if (Get-TargetPermissionAssignment) {
    throw "Entra permission '$($state.EntraPermissionValue)' is still active. Cleanup is blocked."
}

$policy = Get-ApplicationAccessPolicyForApp `
    -AppId $AppId `
    -PolicyIdentity ([string]$state.PolicyIdentity)
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
    "Target only AppId '$AppId' ('$($state.ApplicationDisplayName)').",
    "Remove legacy AAP '$($policy.Identity)'.",
    "Keep App RBAC assignment '$($state.RoleAssignmentName)'.",
    'Repeat positive and negative App RBAC authorization tests.',
    $(if ($runLiveValidation) { 'Run fresh-token allowed and denied Graph mailbox tests.' } else { 'Record that live application validation will be completed externally.' }),
    "Update state '$StatePath'."
)
if (-not $Execute) {
    Assert-ExecutionApproved -Execute:$false -PlannedChanges $plannedChanges
    return
}

$state | Add-Member -NotePropertyName LegacyPolicyBackup -NotePropertyValue $legacyPolicyBackup -Force
$state | Add-Member -NotePropertyName CleanupStartedAtUtc -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
Write-ToolkitJson -InputObject $state -Path $StatePath

Remove-ApplicationAccessPolicy -Identity $policy.Identity -Confirm:$false
try {
    $authorizationTests = Assert-AppRbacAuthorization
    $liveValidationSucceeded = Invoke-MailboxValidation
}
catch {
    if ($AutoRollbackOnValidationFailure) {
        Write-Warning 'Cleanup validation failed. Restoring the legacy AAP and removed Entra permission.'
        $restorePolicyParameters = @{
            AppId = $legacyPolicyBackup.AppId
            PolicyScopeGroupId = $legacyPolicyBackup.PolicyScopeGroupId
            AccessRight = $legacyPolicyBackup.AccessRight
        }
        if ($legacyPolicyBackup.Description) {
            $restorePolicyParameters.Description = $legacyPolicyBackup.Description
        }
        New-ApplicationAccessPolicy @restorePolicyParameters | Out-Null
        if ($state.PSObject.Properties.Name -contains 'RemovedEntraPermission') {
            Restore-EntraPermission -Permission $state.RemovedEntraPermission
        }
        $state | Add-Member -NotePropertyName CleanupRollbackAtUtc -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
        Write-ToolkitJson -InputObject $state -Path $StatePath
    }
    throw
}

$state | Add-Member -NotePropertyName CleanupAtUtc -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
$state | Add-Member -NotePropertyName RemovedPolicyIdentity -NotePropertyValue ([string]$policy.Identity) -Force
$state | Add-Member -NotePropertyName PostCleanupAuthorizationTests -NotePropertyValue $authorizationTests -Force
$state | Add-Member -NotePropertyName PostCleanupLiveValidationSucceeded -NotePropertyValue ([bool]$liveValidationSucceeded) -Force
Write-ToolkitJson -InputObject $state -Path $StatePath
Write-Host 'Single-application Cleanup complete. App RBAC remains active.' -ForegroundColor Green