# Title: Export Application Access Policy Inventory
# Author: Kevin Tigges
# Date: 2026-09-03
# Summary: Exports legacy policy, application, permission, credential, scope, and App RBAC inventory data.

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$TenantId,

    [string]$OutputDirectory = (Join-Path $PSScriptRoot ("output\inventory-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))),
    [switch]$EvaluateEffectiveAccess,
    [string]$MailboxFilter,
    [ValidateRange(0, 100000)]
    [int]$MaxMailboxes = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'AppRbacMigration.Common.psm1') -Force

Connect-AppRbacServices -TenantId $TenantId -GraphScopes @(
    'Application.Read.All',
    'Directory.Read.All'
)

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$issues = [System.Collections.Generic.List[object]]::new()
$policyRows = [System.Collections.Generic.List[object]]::new()
$applicationRows = [System.Collections.Generic.List[object]]::new()
$permissionRows = [System.Collections.Generic.List[object]]::new()
$credentialRows = [System.Collections.Generic.List[object]]::new()
$scopeMemberRows = [System.Collections.Generic.List[object]]::new()
$existingRbacRows = [System.Collections.Generic.List[object]]::new()
$effectiveAccessRows = [System.Collections.Generic.List[object]]::new()

$permissionToRole = @{
    'Mail.Read'                 = 'Application Mail.Read'
    'Mail.ReadBasic'            = 'Application Mail.ReadBasic'
    'Mail.ReadBasic.All'        = 'Application Mail.ReadBasic'
    'Mail.ReadWrite'            = 'Application Mail.ReadWrite'
    'Mail.Send'                 = 'Application Mail.Send'
    'MailboxSettings.Read'      = 'Application MailboxSettings.Read'
    'MailboxSettings.ReadWrite' = 'Application MailboxSettings.ReadWrite'
    'Calendars.Read'            = 'Application Calendars.Read'
    'Calendars.ReadWrite'       = 'Application Calendars.ReadWrite'
    'Contacts.Read'             = 'Application Contacts.Read'
    'Contacts.ReadWrite'        = 'Application Contacts.ReadWrite'
    'full_access_as_app'        = 'Application EWS.AccessAsApp'
}

$policies = @(Get-AllApplicationAccessPolicies)
if (@($policies).Count -eq 0) {
    Write-Warning 'No Application Access Policies were found.'
}

$appCache = @{}
$servicePrincipalCache = @{}

foreach ($policy in $policies) {
    $appId = [string]$policy.AppId
    Write-Host "Inventorying policy '$($policy.Identity)' for AppId '$appId'..." -ForegroundColor Cyan

    $policyAppIds = @(($appId -split '\s*,\s*') | Where-Object { $_ })
    if ($policyAppIds -contains '*' -or @($policyAppIds).Count -ne 1) {
        $issues.Add([pscustomobject]@{
                Severity = 'High'
                AppId = $appId
                PolicyIdentity = [string]$policy.Identity
                Category = 'SharedOrWildcardPolicy'
                Detail = 'The policy applies to multiple applications or all applications and requires manual separation before one-app-at-a-time migration.'
            })
    }

    if (-not $servicePrincipalCache.ContainsKey($appId)) {
        $servicePrincipalCache[$appId] = Get-EntraServicePrincipalByAppId -AppId $appId
    }
    if (-not $appCache.ContainsKey($appId)) {
        $appCache[$appId] = Get-EntraApplicationByAppId -AppId $appId
    }

    $servicePrincipal = $servicePrincipalCache[$appId]
    $application = $appCache[$appId]

    if (-not $servicePrincipal) {
        $issues.Add([pscustomobject]@{
                Severity = 'High'
                AppId = $appId
                PolicyIdentity = [string]$policy.Identity
                Category = 'MissingServicePrincipal'
                Detail = 'No Entra service principal was found for the policy AppId.'
            })
    }

    if (-not $application) {
        $issues.Add([pscustomobject]@{
                Severity = 'Medium'
                AppId = $appId
                PolicyIdentity = [string]$policy.Identity
                Category = 'MissingApplicationObject'
                Detail = 'No Entra application-registration object was found for the policy AppId.'
            })
    }

    $scopeIdentity = Get-ApplicationAccessPolicyScopeIdentity -Policy $policy

    $scopeRecipient = $null
    $scopeLookupError = $null
    if ($scopeIdentity) {
        try {
            $scopeRecipient = Get-Recipient -Identity $scopeIdentity -ErrorAction Stop
        }
        catch {
            $scopeLookupError = $_.Exception.Message
            $issues.Add([pscustomobject]@{
                    Severity = 'High'
                    AppId = $appId
                    PolicyIdentity = [string]$policy.Identity
                    Category = 'ScopeRecipientLookupFailed'
                    Detail = "Scope '$scopeIdentity' could not be resolved: $scopeLookupError"
                })
        }
    }
    else {
        $issues.Add([pscustomobject]@{
                Severity = 'High'
                AppId = $appId
                PolicyIdentity = [string]$policy.Identity
                Category = 'MissingScopeIdentity'
                Detail = 'The policy did not expose PolicyScopeGroupId or ScopeName.'
            })
    }

    $policyRows.Add([pscustomobject]@{
            PolicyIdentity = [string]$policy.Identity
            AppId = $appId
            AccessRight = [string]$policy.AccessRight
            Description = [string]$policy.Description
            ScopeIdentity = $scopeIdentity
            ScopeDisplayName = if ($scopeRecipient) { [string]$scopeRecipient.DisplayName } else { $null }
            ScopePrimarySmtpAddress = if ($scopeRecipient) { [string]$scopeRecipient.PrimarySmtpAddress } else { $null }
            ScopeRecipientType = if ($scopeRecipient) { [string]$scopeRecipient.RecipientTypeDetails } else { $null }
            ScopeDistinguishedName = if ($scopeRecipient) { [string]$scopeRecipient.DistinguishedName } else { $null }
            ScopeExternalDirectoryObjectId = if ($scopeRecipient) { [string]$scopeRecipient.ExternalDirectoryObjectId } else { $null }
        })

    if ([string]$policy.AccessRight -eq 'DenyAccess') {
        $issues.Add([pscustomobject]@{
                Severity = 'High'
                AppId = $appId
                PolicyIdentity = [string]$policy.Identity
                Category = 'DenyAccessPolicy'
                Detail = 'DenyAccess policies cannot be converted directly to an App RBAC grant. Define an explicit positive recipient scope for the mailboxes that should remain authorized.'
            })
    }

    if ($scopeRecipient) {
        $members = @()
        $memberEnumerationSucceeded = $true
        try {
            $members = @(Get-SupportedScopeGroupDirectMembers -Group $scopeRecipient)
        }
        catch {
            $memberEnumerationSucceeded = $false
            $issues.Add([pscustomobject]@{
                    Severity = 'High'
                    AppId = $appId
                    PolicyIdentity = [string]$policy.Identity
                    Category = 'ScopeMemberEnumerationFailed'
                    Detail = "Direct members of '$($scopeRecipient.Identity)' could not be enumerated: $($_.Exception.Message)"
                })
        }

        if ($memberEnumerationSucceeded -and @($members).Count -eq 0) {
            $issues.Add([pscustomobject]@{
                    Severity = 'Medium'
                    AppId = $appId
                    PolicyIdentity = [string]$policy.Identity
                    Category = 'EmptyScopeGroup'
                    Detail = "The scope group '$($scopeRecipient.DisplayName)' has no direct members."
                })
        }

        foreach ($member in $members) {
            $isNestedGroup = [string]$member.RecipientType -match 'Group' -or
                [string]$member.RecipientTypeDetails -match 'Group|Distribution'

            $scopeMemberRows.Add([pscustomobject]@{
                    PolicyIdentity = [string]$policy.Identity
                    AppId = $appId
                    ScopeIdentity = $scopeIdentity
                    ScopeDisplayName = [string]$scopeRecipient.DisplayName
                    MemberDisplayName = [string]$member.DisplayName
                    MemberPrimarySmtpAddress = [string]$member.PrimarySmtpAddress
                    MemberExternalDirectoryObjectId = [string]$member.ExternalDirectoryObjectId
                    MemberRecipientType = [string]$member.RecipientType
                    MemberRecipientTypeDetails = [string]$member.RecipientTypeDetails
                    IsNestedGroup = $isNestedGroup
                    AppRbacScopeResult = if ($isNestedGroup) { 'Nested group object is in scope; its members are not expanded.' } else { 'Direct member is in scope.' }
                })

            if ($isNestedGroup) {
                $issues.Add([pscustomobject]@{
                        Severity = 'High'
                        AppId = $appId
                        PolicyIdentity = [string]$policy.Identity
                        Category = 'NestedGroup'
                        Detail = "Scope group '$($scopeRecipient.DisplayName)' contains nested group '$($member.DisplayName)'. Nested members are out of scope in an App RBAC MemberOfGroup filter."
                    })
            }
        }
    }

    if ($servicePrincipal) {
        $servicePrincipalOwners = @(Get-ObjectOwnerSummary -ObjectType ServicePrincipal -ObjectId $servicePrincipal.Id)
        $applicationOwners = if ($application) {
            @(Get-ObjectOwnerSummary -ObjectType Application -ObjectId $application.Id)
        }
        else {
            @()
        }

        if (@($servicePrincipalOwners).Count -eq 0 -and @($applicationOwners).Count -eq 0) {
            $issues.Add([pscustomobject]@{
                    Severity = 'High'
                    AppId = $appId
                    PolicyIdentity = [string]$policy.Identity
                    Category = 'NoOwner'
                    Detail = 'Neither the application nor service principal has an Entra owner.'
                })
        }

        $applicationRows.Add([pscustomobject]@{
                AppId = $appId
                DisplayName = [string]$servicePrincipal.DisplayName
                ServicePrincipalObjectId = [string]$servicePrincipal.Id
                ApplicationObjectId = if ($application) { [string]$application.Id } else { $null }
                AccountEnabled = $servicePrincipal.AccountEnabled
                ServicePrincipalType = [string]$servicePrincipal.ServicePrincipalType
                SignInAudience = if ($application) { [string]$application.SignInAudience } else { $null }
                CreatedDateTime = if ($application) { $application.CreatedDateTime } else { $null }
                ServicePrincipalOwners = (($servicePrincipalOwners | ForEach-Object { $_.DisplayName }) -join '; ')
                ApplicationOwners = (($applicationOwners | ForEach-Object { $_.DisplayName }) -join '; ')
                Tags = (@($servicePrincipal.Tags) -join '; ')
            })

        foreach ($credential in @($servicePrincipal.KeyCredentials)) {
            $credentialRows.Add([pscustomobject]@{
                    AppId = $appId
                    ObjectType = 'ServicePrincipal'
                    ObjectId = [string]$servicePrincipal.Id
                    CredentialType = 'Certificate'
                    DisplayName = [string]$credential.DisplayName
                    KeyId = [string]$credential.KeyId
                    StartDateTime = $credential.StartDateTime
                    EndDateTime = $credential.EndDateTime
                    DaysUntilExpiration = if ($credential.EndDateTime) { [math]::Floor(($credential.EndDateTime - (Get-Date)).TotalDays) } else { $null }
                })
        }

        foreach ($credential in @($servicePrincipal.PasswordCredentials)) {
            $credentialRows.Add([pscustomobject]@{
                    AppId = $appId
                    ObjectType = 'ServicePrincipal'
                    ObjectId = [string]$servicePrincipal.Id
                    CredentialType = 'ClientSecret'
                    DisplayName = [string]$credential.DisplayName
                    KeyId = [string]$credential.KeyId
                    StartDateTime = $credential.StartDateTime
                    EndDateTime = $credential.EndDateTime
                    DaysUntilExpiration = if ($credential.EndDateTime) { [math]::Floor(($credential.EndDateTime - (Get-Date)).TotalDays) } else { $null }
                })
        }

        if ($application) {
            foreach ($credential in @($application.KeyCredentials)) {
                $credentialRows.Add([pscustomobject]@{
                        AppId = $appId
                        ObjectType = 'Application'
                        ObjectId = [string]$application.Id
                        CredentialType = 'Certificate'
                        DisplayName = [string]$credential.DisplayName
                        KeyId = [string]$credential.KeyId
                        StartDateTime = $credential.StartDateTime
                        EndDateTime = $credential.EndDateTime
                        DaysUntilExpiration = if ($credential.EndDateTime) { [math]::Floor(($credential.EndDateTime - (Get-Date)).TotalDays) } else { $null }
                    })
            }

            foreach ($credential in @($application.PasswordCredentials)) {
                $credentialRows.Add([pscustomobject]@{
                        AppId = $appId
                        ObjectType = 'Application'
                        ObjectId = [string]$application.Id
                        CredentialType = 'ClientSecret'
                        DisplayName = [string]$credential.DisplayName
                        KeyId = [string]$credential.KeyId
                        StartDateTime = $credential.StartDateTime
                        EndDateTime = $credential.EndDateTime
                        DaysUntilExpiration = if ($credential.EndDateTime) { [math]::Floor(($credential.EndDateTime - (Get-Date)).TotalDays) } else { $null }
                    })
            }
        }

        $permissions = @(Get-GraphApplicationPermissionDetails -ServicePrincipalId $servicePrincipal.Id)
        foreach ($permission in $permissions) {
            $recommendedRole = if ($permissionToRole.ContainsKey([string]$permission.PermissionValue)) {
                $permissionToRole[[string]$permission.PermissionValue]
            }
            else {
                $null
            }

            $permissionRows.Add([pscustomobject]@{
                    AppId = $appId
                    ServicePrincipalObjectId = [string]$servicePrincipal.Id
                    ResourceName = $permission.ResourceName
                    ResourceAppId = $permission.ResourceAppId
                    PermissionValue = $permission.PermissionValue
                    PermissionName = $permission.PermissionName
                    AssignmentId = $permission.AssignmentId
                    RecommendedExchangeApplicationRole = $recommendedRole
                    IsKnownApplicationAccessPolicyPermission = [bool]$recommendedRole
                })
        }

        $exchangeServicePrincipal = Get-ExchangeServicePrincipalByAppId -AppId $appId
        if ($exchangeServicePrincipal) {
            $assignments = @(Get-ManagementRoleAssignment -RoleAssignee $exchangeServicePrincipal.ObjectId)
            foreach ($assignment in $assignments) {
                $existingRbacRows.Add([pscustomobject]@{
                        AppId = $appId
                        ExchangeServicePrincipalIdentity = [string]$exchangeServicePrincipal.ObjectId
                        AssignmentName = [string]$assignment.Name
                        Role = [string]$assignment.Role
                        CustomResourceScope = [string]$assignment.CustomResourceScope
                        RecipientAdministrativeUnitScope = [string]$assignment.RecipientAdministrativeUnitScope
                        EffectiveUserName = [string]$assignment.EffectiveUserName
                    })
            }
        }
    }
}

foreach ($credential in $credentialRows) {
    if ($null -ne $credential.DaysUntilExpiration -and $credential.DaysUntilExpiration -lt 0) {
        $issues.Add([pscustomobject]@{
                Severity = 'High'
                AppId = $credential.AppId
                PolicyIdentity = $null
                Category = 'ExpiredCredential'
                Detail = "$($credential.ObjectType) $($credential.CredentialType) '$($credential.DisplayName)' expired $(-1 * $credential.DaysUntilExpiration) days ago."
            })
    }
    elseif ($null -ne $credential.DaysUntilExpiration -and $credential.DaysUntilExpiration -le 90) {
        $issues.Add([pscustomobject]@{
                Severity = 'Medium'
                AppId = $credential.AppId
                PolicyIdentity = $null
                Category = 'CredentialExpiresSoon'
                Detail = "$($credential.ObjectType) $($credential.CredentialType) '$($credential.DisplayName)' expires in $($credential.DaysUntilExpiration) days."
            })
    }
}

if ($EvaluateEffectiveAccess) {
    Write-Host 'Evaluating effective legacy Application Access Policy results...' -ForegroundColor Cyan
    $mailboxParameters = @{
        ResultSize = 'Unlimited'
        Properties = @(
            'DisplayName',
            'UserPrincipalName',
            'PrimarySmtpAddress',
            'RecipientTypeDetails',
            'ExternalDirectoryObjectId',
            'CustomAttribute1',
            'CustomAttribute2',
            'CustomAttribute3'
        )
    }
    if ($MailboxFilter) {
        $mailboxParameters.Filter = $MailboxFilter
    }

    $mailboxes = @(Get-EXOMailbox @mailboxParameters)
    if ($MaxMailboxes -gt 0) {
        $mailboxes = @($mailboxes | Select-Object -First $MaxMailboxes)
    }

    $uniqueAppIds = @($policies.AppId | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    $totalTests = @($uniqueAppIds).Count * @($mailboxes).Count
    $testNumber = 0

    foreach ($appId in $uniqueAppIds) {
        foreach ($mailbox in $mailboxes) {
            $testNumber++
            Write-Progress `
                -Activity 'Testing Application Access Policy results' `
                -Status "$testNumber of $totalTests" `
                -PercentComplete (($testNumber / [math]::Max($totalTests, 1)) * 100)

            try {
                $result = Test-ApplicationAccessPolicy -Identity $mailbox.UserPrincipalName -AppId $appId -ErrorAction Stop
                $effectiveAccessRows.Add([pscustomobject]@{
                        AppId = $appId
                        MailboxDisplayName = [string]$mailbox.DisplayName
                        UserPrincipalName = [string]$mailbox.UserPrincipalName
                        PrimarySmtpAddress = [string]$mailbox.PrimarySmtpAddress
                        RecipientTypeDetails = [string]$mailbox.RecipientTypeDetails
                        ExternalDirectoryObjectId = [string]$mailbox.ExternalDirectoryObjectId
                        CustomAttribute1 = [string]$mailbox.CustomAttribute1
                        CustomAttribute2 = [string]$mailbox.CustomAttribute2
                        CustomAttribute3 = [string]$mailbox.CustomAttribute3
                        AccessCheckResult = [string]$result.AccessCheckResult
                    })
            }
            catch {
                $issues.Add([pscustomobject]@{
                        Severity = 'Medium'
                        AppId = $appId
                        PolicyIdentity = $null
                        Category = 'EffectiveAccessTestFailed'
                        Detail = "Policy test failed for '$($mailbox.UserPrincipalName)': $($_.Exception.Message)"
                    })
            }
        }
    }
    Write-Progress -Activity 'Testing Application Access Policy results' -Completed
}

$policyRows | Export-Csv -Path (Join-Path $OutputDirectory 'application-access-policies.csv') -NoTypeInformation -Encoding utf8
$applicationRows | Sort-Object AppId -Unique | Export-Csv -Path (Join-Path $OutputDirectory 'applications.csv') -NoTypeInformation -Encoding utf8
$permissionRows | Sort-Object AppId, ResourceName, PermissionValue -Unique | Export-Csv -Path (Join-Path $OutputDirectory 'application-permissions.csv') -NoTypeInformation -Encoding utf8
$credentialRows | Sort-Object AppId, EndDateTime | Export-Csv -Path (Join-Path $OutputDirectory 'credential-expiration.csv') -NoTypeInformation -Encoding utf8
$scopeMemberRows | Sort-Object AppId, ScopeIdentity, MemberPrimarySmtpAddress | Export-Csv -Path (Join-Path $OutputDirectory 'scope-members.csv') -NoTypeInformation -Encoding utf8
$existingRbacRows | Sort-Object AppId, AssignmentName | Export-Csv -Path (Join-Path $OutputDirectory 'existing-app-rbac-assignments.csv') -NoTypeInformation -Encoding utf8
$issues | Sort-Object Severity, AppId, Category | Export-Csv -Path (Join-Path $OutputDirectory 'migration-readiness-issues.csv') -NoTypeInformation -Encoding utf8

if ($EvaluateEffectiveAccess) {
    $effectiveAccessRows |
        Sort-Object AppId, UserPrincipalName |
        Export-Csv -Path (Join-Path $OutputDirectory 'effective-legacy-access.csv') -NoTypeInformation -Encoding utf8
}

$summary = [ordered]@{
    GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    TenantId = $TenantId
    PolicyCount = @($policyRows).Count
    ApplicationCount = @($applicationRows | Select-Object AppId -Unique).Count
    PermissionCount = @($permissionRows).Count
    ScopeMemberCount = @($scopeMemberRows).Count
    ExistingAppRbacAssignmentCount = @($existingRbacRows).Count
    IssueCount = @($issues).Count
    EffectiveAccessEvaluated = [bool]$EvaluateEffectiveAccess
    EffectiveAccessResultCount = @($effectiveAccessRows).Count
    OutputDirectory = $OutputDirectory
}

Write-ToolkitJson -InputObject ([ordered]@{
        Summary = $summary
        Policies = @($policyRows)
        Applications = @($applicationRows)
        Permissions = @($permissionRows)
        Credentials = @($credentialRows)
        ScopeMembers = @($scopeMemberRows)
        ExistingAppRbacAssignments = @($existingRbacRows)
        Issues = @($issues)
        EffectiveLegacyAccess = @($effectiveAccessRows)
    }) -Path (Join-Path $OutputDirectory 'inventory.json')

Write-Host ''
Write-Host 'Application Access Policy inventory complete.' -ForegroundColor Green
$summary.GetEnumerator() | Format-Table -AutoSize
