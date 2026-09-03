# Title: New Legacy Application Access Policy Lab
# Author: Kevin Tigges
# Date: 2026-09-03
# Summary: Creates a legacy Application Access Policy test application and mailbox scope.

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [string]$AcceptedDomain,

    [Parameter(Mandatory)]
    [ValidateCount(1, 20)]
    [string[]]$AuthorizedMailboxAddresses,

    [Parameter(Mandatory)]
    [string]$DeniedMailboxAddress,

    [string]$AppDisplayName = 'App RBAC Migration Lab - Legacy AAP',
    [string]$ScopeGroupName = 'App-RBAC-Lab-Mailboxes',
    [string]$ScopeGroupPrimarySmtpAddress,
    [int]$CertificateValidDays = 30,
    [switch]$CreateSharedMailboxes,
    [switch]$Execute,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'output\lab')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'AppRbacMigration.Common.psm1') -Force

if (-not $ScopeGroupPrimarySmtpAddress) {
    $ScopeGroupPrimarySmtpAddress = "$($ScopeGroupName.ToLowerInvariant())@$AcceptedDomain"
}

$plannedChanges = @(
    "Create a single-tenant Entra application named '$AppDisplayName'.",
    'Create its Entra service principal.',
    "Create a $CertificateValidDays-day self-signed certificate in Cert:\CurrentUser\My and upload the public key.",
    'Grant and admin-consent Microsoft Graph Mail.Read application permission.',
    "Create or reuse the mail-enabled security group '$ScopeGroupPrimarySmtpAddress'.",
    'Add the authorized mailboxes as direct group members.',
    'Create a legacy Exchange Online Application Access Policy with RestrictAccess.',
    'Run positive and negative Application Access Policy tests.',
    "Write the lab state to '$OutputDirectory'."
)

if ($CreateSharedMailboxes) {
    $plannedChanges += 'Create missing authorized and denied addresses as shared mailboxes.'
}

if (-not $Execute) {
    Assert-ExecutionApproved -Execute:$false -PlannedChanges $plannedChanges
    return
}

Connect-AppRbacServices -TenantId $TenantId -GraphScopes @(
    'Application.ReadWrite.All',
    'AppRoleAssignment.ReadWrite.All',
    'Directory.ReadWrite.All'
)

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$escapedDisplayName = ConvertTo-ODataLiteral -Value $AppDisplayName
$existingApps = @(Get-MgApplication -Filter "displayName eq '$escapedDisplayName'" -Property @('id', 'appId', 'displayName') -All)
if ($existingApps.Count -gt 0) {
    throw "An Entra application named '$AppDisplayName' already exists. Use a unique -AppDisplayName or remove the previous lab."
}

Write-Host "Creating Entra application '$AppDisplayName'..." -ForegroundColor Cyan
$application = New-MgApplication -DisplayName $AppDisplayName -SignInAudience 'AzureADMyOrg'
$servicePrincipal = New-MgServicePrincipal -AppId $application.AppId

Write-Host 'Creating a short-lived lab certificate...' -ForegroundColor Cyan
$certificate = New-SelfSignedCertificate `
    -Subject "CN=$AppDisplayName" `
    -CertStoreLocation 'Cert:\CurrentUser\My' `
    -KeyAlgorithm RSA `
    -KeyLength 2048 `
    -HashAlgorithm SHA256 `
    -KeyExportPolicy NonExportable `
    -NotAfter (Get-Date).AddDays($CertificateValidDays)

$keyCredential = @{
    Type          = 'AsymmetricX509Cert'
    Usage         = 'Verify'
    Key           = $certificate.RawData
    DisplayName   = 'App RBAC migration lab certificate'
    StartDateTime = $certificate.NotBefore.ToUniversalTime()
    EndDateTime   = $certificate.NotAfter.ToUniversalTime()
}

Update-MgApplication -ApplicationId $application.Id -KeyCredentials @($keyCredential)
$publicCertificatePath = Join-Path $OutputDirectory 'AppRbacMigrationLab.cer'
Export-Certificate -Cert $certificate -FilePath $publicCertificatePath -Force | Out-Null

Write-Host 'Granting Microsoft Graph Mail.Read application permission...' -ForegroundColor Cyan
$graphServicePrincipal = Get-MgServicePrincipal `
    -Filter "appId eq '00000003-0000-0000-c000-000000000000'" `
    -Property @('id', 'appId', 'displayName', 'appRoles') `
    -All |
    Select-Object -First 1

if (-not $graphServicePrincipal) {
    throw 'The Microsoft Graph service principal was not found in the tenant.'
}

$mailReadRole = $graphServicePrincipal.AppRoles |
    Where-Object {
        $_.Value -eq 'Mail.Read' -and
        $_.AllowedMemberTypes -contains 'Application'
    } |
    Select-Object -First 1

if (-not $mailReadRole) {
    throw 'The Microsoft Graph Mail.Read application role was not found.'
}

$requiredResourceAccess = @(
    @{
        ResourceAppId = [string]$graphServicePrincipal.AppId
        ResourceAccess = @(
            @{
                Id = $mailReadRole.Id
                Type = 'Role'
            }
        )
    }
)
Update-MgApplication `
    -ApplicationId $application.Id `
    -RequiredResourceAccess $requiredResourceAccess

$permissionAssignment = New-MgServicePrincipalAppRoleAssignment `
    -ServicePrincipalId $servicePrincipal.Id `
    -PrincipalId $servicePrincipal.Id `
    -ResourceId $graphServicePrincipal.Id `
    -AppRoleId $mailReadRole.Id

function Get-OrCreateTestMailbox {
    param(
        [Parameter(Mandatory)]
        [string]$Address
    )

    $recipient = Get-Recipient -Identity $Address -ErrorAction SilentlyContinue
    if ($recipient) {
        return $recipient
    }

    if (-not $CreateSharedMailboxes) {
        throw "Mailbox '$Address' does not exist. Create it first or run with -CreateSharedMailboxes."
    }

    $localPart = $Address.Split('@')[0]
    Write-Host "Creating shared mailbox '$Address'..." -ForegroundColor Cyan
    New-Mailbox `
        -Shared `
        -Name $localPart `
        -Alias $localPart `
        -DisplayName "App RBAC Lab - $localPart" `
        -PrimarySmtpAddress $Address
}

$authorizedRecipients = foreach ($address in $AuthorizedMailboxAddresses) {
    Get-OrCreateTestMailbox -Address $address
}
$deniedRecipient = Get-OrCreateTestMailbox -Address $DeniedMailboxAddress

$scopeGroup = Get-DistributionGroup -Identity $ScopeGroupPrimarySmtpAddress -ErrorAction SilentlyContinue
if (-not $scopeGroup) {
    Write-Host "Creating mail-enabled security group '$ScopeGroupPrimarySmtpAddress'..." -ForegroundColor Cyan
    $scopeGroup = New-DistributionGroup `
        -Name $ScopeGroupName `
        -Alias $ScopeGroupName `
        -Type Security `
        -PrimarySmtpAddress $ScopeGroupPrimarySmtpAddress
}

$directMembers = @(Get-DistributionGroupMember -Identity $scopeGroup.Identity -ResultSize Unlimited)
foreach ($recipient in $authorizedRecipients) {
    $isMember = $directMembers |
        Where-Object {
            [string]$_.ExternalDirectoryObjectId -eq [string]$recipient.ExternalDirectoryObjectId -or
            [string]$_.PrimarySmtpAddress -eq [string]$recipient.PrimarySmtpAddress
        } |
        Select-Object -First 1

    if (-not $isMember) {
        Write-Host "Adding '$($recipient.PrimarySmtpAddress)' to '$ScopeGroupPrimarySmtpAddress'..." -ForegroundColor Cyan
        Add-DistributionGroupMember -Identity $scopeGroup.Identity -Member $recipient.Identity
    }
}

Write-Host 'Creating the legacy Application Access Policy...' -ForegroundColor Cyan
New-ApplicationAccessPolicy `
    -AppId $application.AppId `
    -PolicyScopeGroupId $ScopeGroupPrimarySmtpAddress `
    -AccessRight RestrictAccess `
    -Description 'Legacy policy created for App RBAC migration testing.' | Out-Null

$policy = Get-AllApplicationAccessPolicies |
    Where-Object {
        [string]$_.AppId -eq [string]$application.AppId -and
        [string]$_.AccessRight -eq 'RestrictAccess'
    } |
    Select-Object -First 1

if (-not $policy) {
    throw 'The Application Access Policy was created, but it could not be retrieved for validation.'
}

$positiveTests = foreach ($address in $AuthorizedMailboxAddresses) {
    Test-ApplicationAccessPolicy -Identity $address -AppId $application.AppId
}
$negativeTest = Test-ApplicationAccessPolicy -Identity $DeniedMailboxAddress -AppId $application.AppId

$state = [ordered]@{
    CreatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    TenantId = $TenantId
    Application = [ordered]@{
        DisplayName = $application.DisplayName
        AppId = [string]$application.AppId
        ApplicationObjectId = [string]$application.Id
        ServicePrincipalObjectId = [string]$servicePrincipal.Id
    }
    Certificate = [ordered]@{
        Thumbprint = $certificate.Thumbprint
        Subject = $certificate.Subject
        NotBefore = $certificate.NotBefore.ToUniversalTime().ToString('o')
        NotAfter = $certificate.NotAfter.ToUniversalTime().ToString('o')
        PublicCertificatePath = $publicCertificatePath
        StoreLocation = 'Cert:\CurrentUser\My'
    }
    GraphPermission = [ordered]@{
        ResourceAppId = [string]$graphServicePrincipal.AppId
        Permission = 'Mail.Read'
        AppRoleId = [string]$mailReadRole.Id
        AssignmentId = [string]$permissionAssignment.Id
    }
    ScopeGroup = [ordered]@{
        Name = $scopeGroup.DisplayName
        PrimarySmtpAddress = [string]$scopeGroup.PrimarySmtpAddress
        DistinguishedName = [string]$scopeGroup.DistinguishedName
        ExternalDirectoryObjectId = [string]$scopeGroup.ExternalDirectoryObjectId
    }
    AuthorizedMailboxes = @($AuthorizedMailboxAddresses)
    DeniedMailbox = $DeniedMailboxAddress
    ApplicationAccessPolicy = [ordered]@{
        Identity = [string]$policy.Identity
        AppId = [string]$application.AppId
        AccessRight = [string]$policy.AccessRight
        ScopeGroup = $ScopeGroupPrimarySmtpAddress
    }
    PositivePolicyTests = @($positiveTests)
    NegativePolicyTest = $negativeTest
}

$statePath = Join-Path $OutputDirectory 'legacy-lab-state.json'
Write-ToolkitJson -InputObject $state -Path $statePath

Write-Host ''
Write-Host 'Legacy Application Access Policy lab created.' -ForegroundColor Green
Write-Host "Application (client) ID: $($application.AppId)"
Write-Host "Service principal object ID: $($servicePrincipal.Id)"
Write-Host "Certificate thumbprint: $($certificate.Thumbprint)"
Write-Host "Scope group: $ScopeGroupPrimarySmtpAddress"
Write-Host "State file: $statePath"
Write-Host ''
Write-Host 'The certificate private key remains non-exportable in the current user certificate store.' -ForegroundColor Yellow
