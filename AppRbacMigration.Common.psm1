Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-RequiredModule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [version]$MinimumVersion
    )

    $module = Get-Module -ListAvailable -Name $Name |
        Where-Object Version -ge $MinimumVersion |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if (-not $module) {
        throw "Required module '$Name' version $MinimumVersion or later is not installed. Run: Install-Module $Name -Scope CurrentUser"
    }
}

function Connect-AppRbacServices {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TenantId,

        [string[]]$GraphScopes = @(
            'Application.Read.All',
            'AppRoleAssignment.ReadWrite.All',
            'Directory.Read.All'
        ),

        [switch]$ExchangeOnly,
        [switch]$GraphOnly
    )

    if (-not $ExchangeOnly) {
        Assert-RequiredModule -Name Microsoft.Graph.Authentication -MinimumVersion 2.0
        Assert-RequiredModule -Name Microsoft.Graph.Applications -MinimumVersion 2.0
        Import-Module Microsoft.Graph.Authentication
        Import-Module Microsoft.Graph.Applications
        Connect-MgGraph -TenantId $TenantId -Scopes $GraphScopes -NoWelcome
    }

    if (-not $GraphOnly) {
        Assert-RequiredModule -Name ExchangeOnlineManagement -MinimumVersion 3.4
        Import-Module ExchangeOnlineManagement
        Connect-ExchangeOnline -ShowBanner:$false

        $exchangeConnection = Get-ConnectionInformation |
            Where-Object {
                $_.State -eq 'Connected' -and
                -not $_.IsEopSession
            } |
            Select-Object -Last 1

        if (-not $exchangeConnection) {
            throw 'Exchange Online connected, but connection information could not be retrieved.'
        }
        $graphContext = Get-MgContext
        if (-not $graphContext -or -not $graphContext.TenantId) {
            throw 'Microsoft Graph connection context could not be retrieved.'
        }
        if ([string]$exchangeConnection.TenantID -ne [string]$graphContext.TenantId) {
            throw "Tenant mismatch. Microsoft Graph is connected to '$($graphContext.TenantId)', but Exchange Online is connected to '$($exchangeConnection.TenantID)'."
        }
    }
}

function ConvertTo-ODataLiteral {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    return $Value.Replace("'", "''")
}

function Get-EntraServicePrincipalByAppId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$AppId,

        [string[]]$Property = @(
            'id',
            'appId',
            'displayName',
            'accountEnabled',
            'servicePrincipalType',
            'appOwnerOrganizationId',
            'tags',
            'keyCredentials',
            'passwordCredentials'
        )
    )

    $escapedAppId = ConvertTo-ODataLiteral -Value $AppId
    $servicePrincipals = @(Get-MgServicePrincipal -Filter "appId eq '$escapedAppId'" -Property $Property -All)

    if (@($servicePrincipals).Count -eq 0) {
        return $null
    }

    if (@($servicePrincipals).Count -gt 1) {
        throw "Multiple Entra service principals were returned for AppId '$AppId'."
    }

    return $servicePrincipals[0]
}

function Get-EntraApplicationByAppId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$AppId
    )

    $escapedAppId = ConvertTo-ODataLiteral -Value $AppId
    $applications = @(Get-MgApplication -Filter "appId eq '$escapedAppId'" -Property @(
            'id',
            'appId',
            'displayName',
            'signInAudience',
            'createdDateTime',
            'keyCredentials',
            'passwordCredentials',
            'requiredResourceAccess'
        ) -All)

    if (@($applications).Count -eq 0) {
        return $null
    }

    if (@($applications).Count -gt 1) {
        throw "Multiple Entra applications were returned for AppId '$AppId'."
    }

    return $applications[0]
}

function Get-ExchangeServicePrincipalByAppId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$AppId
    )

    $matchedPrincipals = @(Get-ServicePrincipal | Where-Object { [string]$_.AppId -eq $AppId })

    if (@($matchedPrincipals).Count -eq 0) {
        return $null
    }

    if (@($matchedPrincipals).Count -gt 1) {
        throw "Multiple Exchange service-principal pointers were returned for AppId '$AppId'."
    }

    return $matchedPrincipals[0]
}

function Get-SupportedScopeGroupDirectMembers {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Group
    )

    $recipientTypeDetails = [string]$Group.RecipientTypeDetails
    switch ($recipientTypeDetails) {
        'GroupMailbox' {
            return @(Get-UnifiedGroupLinks -Identity $Group.Identity -LinkType Members -ResultSize Unlimited)
        }
        'MailUniversalSecurityGroup' {
            return @(Get-DistributionGroupMember -Identity $Group.Identity -ResultSize Unlimited)
        }
        'MailUniversalDistributionGroup' {
            return @(Get-DistributionGroupMember -Identity $Group.Identity -ResultSize Unlimited)
        }
        default {
            throw "Scope group type '$recipientTypeDetails' is not supported by this toolkit. Use a Microsoft 365 Group, mail-enabled security group, or distribution list, or select an explicit recipient filter."
        }
    }
}

function Get-ApplicationAccessPolicyForApp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$AppId,

        [string]$PolicyIdentity
    )

    if ($PolicyIdentity) {
        $policy = Get-ApplicationAccessPolicy -Identity $PolicyIdentity
        $policyAppIds = @(([string]$policy.AppId -split '\s*,\s*') | Where-Object { $_ })
        if ($policyAppIds -contains '*' -or @($policyAppIds).Count -ne 1) {
            throw "Policy '$PolicyIdentity' applies to multiple applications or all applications. This toolkit converts only one-application policies."
        }
        if ($policyAppIds -notcontains $AppId) {
            throw "Policy '$PolicyIdentity' does not apply to AppId '$AppId'."
        }
        return $policy
    }

    $policies = @(Get-AllApplicationAccessPolicies | Where-Object {
            $policyAppIds = @(([string]$_.AppId -split '\s*,\s*') | Where-Object { $_ })
            $policyAppIds -contains $AppId -or $policyAppIds -contains '*'
        })
    if (@($policies).Count -eq 0) {
        throw "No Application Access Policy was found for AppId '$AppId'."
    }

    if (@($policies).Count -gt 1) {
        throw "Multiple Application Access Policies were found for AppId '$AppId'. Specify -PolicyIdentity explicitly."
    }

    $selectedPolicy = $policies[0]
    $selectedAppIds = @(([string]$selectedPolicy.AppId -split '\s*,\s*') | Where-Object { $_ })
    if ($selectedAppIds -contains '*' -or @($selectedAppIds).Count -ne 1) {
        throw "Policy '$($selectedPolicy.Identity)' applies to multiple applications or all applications. This toolkit converts only one-application policies."
    }

    return $selectedPolicy
}

function Get-ApplicationAccessPolicyScopeIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Policy
    )

    $policyScopeProperty = $Policy.PSObject.Properties['PolicyScopeGroupId']
    if ($policyScopeProperty -and $policyScopeProperty.Value) {
        return [string]$policyScopeProperty.Value
    }

    $scopeNameProperty = $Policy.PSObject.Properties['ScopeName']
    if ($scopeNameProperty -and $scopeNameProperty.Value) {
        return [string]$scopeNameProperty.Value
    }

    return $null
}

function Get-AllApplicationAccessPolicies {
    [CmdletBinding()]
    param()

    try {
        return @(Get-ApplicationAccessPolicy -ErrorAction Stop)
    }
    catch {
        $message = [string]$_.Exception.Message
        if ($message -match "couldn't be found" -and $message -match '\\\*') {
            Write-Verbose 'No Application Access Policies exist in the Exchange Online organization.'
            return @()
        }
        throw
    }
}

function Get-GraphApplicationPermissionDetails {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ServicePrincipalId
    )

    $resourceCache = @{}
    $details = foreach ($assignment in @(Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $ServicePrincipalId -All)) {
        if (-not $resourceCache.ContainsKey([string]$assignment.ResourceId)) {
            $resourceCache[[string]$assignment.ResourceId] = Get-MgServicePrincipal -ServicePrincipalId $assignment.ResourceId -Property @(
                'id',
                'appId',
                'displayName',
                'appRoles'
            )
        }

        $resource = $resourceCache[[string]$assignment.ResourceId]
        $appRole = $resource.AppRoles | Where-Object Id -eq $assignment.AppRoleId | Select-Object -First 1

        [pscustomobject]@{
            AssignmentId       = [string]$assignment.Id
            ClientPrincipalId  = [string]$assignment.PrincipalId
            ResourceId         = [string]$assignment.ResourceId
            ResourceAppId      = [string]$resource.AppId
            ResourceName       = [string]$resource.DisplayName
            AppRoleId          = [string]$assignment.AppRoleId
            PermissionValue    = if ($appRole) { [string]$appRole.Value } else { $null }
            PermissionName     = if ($appRole) { [string]$appRole.DisplayName } else { $null }
            AssignmentCreated  = $assignment.CreatedDateTime
        }
    }

    return @($details)
}

function Get-ObjectOwnerSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Application', 'ServicePrincipal')]
        [string]$ObjectType,

        [Parameter(Mandatory)]
        [string]$ObjectId
    )

    $owners = if ($ObjectType -eq 'Application') {
        @(Get-MgApplicationOwner -ApplicationId $ObjectId -All)
    }
    else {
        @(Get-MgServicePrincipalOwner -ServicePrincipalId $ObjectId -All)
    }

    return @($owners | ForEach-Object {
            $displayName = $_.AdditionalProperties['displayName']
            $userPrincipalName = $_.AdditionalProperties['userPrincipalName']
            $appId = $_.AdditionalProperties['appId']

            [pscustomobject]@{
                Id                = [string]$_.Id
                ObjectType        = [string]$_.AdditionalProperties['@odata.type']
                DisplayName       = [string]$displayName
                UserPrincipalName = [string]$userPrincipalName
                AppId             = [string]$appId
            }
        })
}

function Write-ToolkitJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$Path,

        [int]$Depth = 12
    )

    $parent = Split-Path -Parent $Path
    if ($parent) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $InputObject | ConvertTo-Json -Depth $Depth | Set-Content -Path $Path -Encoding utf8
}

function Assert-ExecutionApproved {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [bool]$Execute,

        [Parameter(Mandatory)]
        [string[]]$PlannedChanges
    )

    if ($Execute) {
        return
    }

    Write-Host ''
    Write-Host 'PREVIEW ONLY - no tenant changes were made.' -ForegroundColor Yellow
    Write-Host ''
    foreach ($change in $PlannedChanges) {
        Write-Host " - $change"
    }
    Write-Host ''
    Write-Host 'Run again with -Execute after reviewing the plan.' -ForegroundColor Yellow
    return
}

Export-ModuleMember -Function @(
    'Assert-RequiredModule',
    'Connect-AppRbacServices',
    'ConvertTo-ODataLiteral',
    'Get-EntraServicePrincipalByAppId',
    'Get-EntraApplicationByAppId',
    'Get-ExchangeServicePrincipalByAppId',
    'Get-SupportedScopeGroupDirectMembers',
    'Get-AllApplicationAccessPolicies',
    'Get-ApplicationAccessPolicyScopeIdentity',
    'Get-ApplicationAccessPolicyForApp',
    'Get-GraphApplicationPermissionDetails',
    'Get-ObjectOwnerSummary',
    'Write-ToolkitJson',
    'Assert-ExecutionApproved'
)
