# Title: New Native App RBAC Lab
# Author: Kevin Tigges
# Date: 2026-09-03
# Summary: Creates a separate test application configured directly with Exchange Online App RBAC.

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

    [string]$AppDisplayName = 'App RBAC Migration Lab - Native App RBAC',
    [string]$ScopeGroupName = 'App-RBAC-Native-Lab-Mailboxes',
    [string]$ScopeGroupPrimarySmtpAddress,
    [string]$ManagementScopeName = 'App RBAC Native Lab Mailboxes',
    [int]$CertificateValidDays = 30,
    [switch]$CreateSharedMailboxes,
    [switch]$Execute,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'output\native-app-rbac-lab')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'AppRbacMigration.Common.psm1') -Force

if (-not $ScopeGroupPrimarySmtpAddress) {
    $ScopeGroupPrimarySmtpAddress = "$($ScopeGroupName.ToLowerInvariant())@$AcceptedDomain"
}

$plannedChanges = @(
    "Create a single-tenant Entra application named '$AppDisplayName'.",
    'Create its Entra Enterprise Application service principal.',
    "Create a $CertificateValidDays-day self-signed certificate in Cert:\CurrentUser\My and upload only the public key.",
    'Do not declare or grant Microsoft Graph Mail.Read through Entra ID.',
    "Create or reuse the mail-enabled security group '$ScopeGroupPrimarySmtpAddress'.",
    'Add the authorized mailboxes as direct group members.',
    "Create Exchange Management Scope '$ManagementScopeName'.",
    'Create the Exchange service-principal pointer.',
    "Assign Exchange role 'Application Mail.Read' to the service principal through the Management Scope.",
    'Run positive and negative App RBAC authorization tests.',
    "Write the test state to '$OutputDirectory'."
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
    'Directory.ReadWrite.All'
)

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$escapedDisplayName = ConvertTo-ODataLiteral -Value $AppDisplayName
$existingApps = @(Get-MgApplication -Filter "displayName eq '$escapedDisplayName'" -Property @('id', 'appId', 'displayName') -All)
if ($existingApps.Count -gt 0) {
    throw "An Entra application named '$AppDisplayName' already exists. Use a unique -AppDisplayName or remove the previous test application."
}

Write-Host "Creating Entra application '$AppDisplayName'..." -ForegroundColor Cyan
$application = New-MgApplication `
    -DisplayName $AppDisplayName `
    -SignInAudience 'AzureADMyOrg'

$servicePrincipal = New-MgServicePrincipal -AppId $application.AppId

Write-Host 'Creating the application certificate...' -ForegroundColor Cyan
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
    DisplayName   = 'Native App RBAC test certificate'
    StartDateTime = $certificate.NotBefore.ToUniversalTime()
    EndDateTime   = $certificate.NotAfter.ToUniversalTime()
}

Update-MgApplication `
    -ApplicationId $application.Id `
    -KeyCredentials @($keyCredential)

$publicCertificatePath = Join-Path $OutputDirectory 'NativeAppRbacLab.cer'
Export-Certificate -Cert $certificate -FilePath $publicCertificatePath -Force | Out-Null

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
        -DisplayName "App RBAC Native Lab - $localPart" `
        -PrimarySmtpAddress $Address
}

$authorizedRecipients = foreach ($address in $AuthorizedMailboxAddresses) {
    Get-OrCreateTestMailbox -Address $address
}
$null = Get-OrCreateTestMailbox -Address $DeniedMailboxAddress

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

$existingScope = Get-ManagementScope -Identity $ManagementScopeName -ErrorAction SilentlyContinue
if ($existingScope) {
    throw "Management Scope '$ManagementScopeName' already exists. Use a unique -ManagementScopeName."
}

$scopeGroup = Get-DistributionGroup -Identity $ScopeGroupPrimarySmtpAddress
$recipientFilter = "MemberOfGroup -eq '$($scopeGroup.DistinguishedName)'"

Write-Host "Creating Management Scope '$ManagementScopeName'..." -ForegroundColor Cyan
$managementScope = New-ManagementScope `
    -Name $ManagementScopeName `
    -RecipientRestrictionFilter $recipientFilter

Write-Host 'Creating the Exchange service-principal pointer...' -ForegroundColor Cyan
$exchangeServicePrincipal = New-ServicePrincipal `
    -AppId $application.AppId `
    -ObjectId $servicePrincipal.Id `
    -DisplayName $servicePrincipal.DisplayName

$assignmentName = "AppRBAC-Native-Lab-MailRead-$($application.AppId.Substring(0, 8))"
Write-Host "Creating App RBAC role assignment '$assignmentName'..." -ForegroundColor Cyan
$roleAssignment = New-ManagementRoleAssignment `
    -Name $assignmentName `
    -App $servicePrincipal.Id `
    -Role 'Application Mail.Read' `
    -CustomResourceScope $ManagementScopeName

$positiveResults = @()
$negativeResult = $null
for ($attempt = 1; $attempt -le 6; $attempt++) {
    $positiveResults = foreach ($address in $AuthorizedMailboxAddresses) {
        Test-ServicePrincipalAuthorization -Identity $application.AppId -Resource $address |
            Where-Object RoleName -eq 'Application Mail.Read'
    }
    $negativeResult = Test-ServicePrincipalAuthorization `
        -Identity $application.AppId `
        -Resource $DeniedMailboxAddress |
        Where-Object RoleName -eq 'Application Mail.Read'

    $allPositive = @($positiveResults | Where-Object InScope -ne $true).Count -eq 0 -and
        @($positiveResults).Count -eq $AuthorizedMailboxAddresses.Count
    $negativeInScope = @($negativeResult | Where-Object InScope -eq $true).Count -gt 0

    if ($allPositive -and -not $negativeInScope) {
        break
    }

    if ($attempt -eq 6) {
        Remove-ManagementRoleAssignment -Identity $roleAssignment.Name -Confirm:$false -ErrorAction Continue
        Remove-ManagementScope -Identity $managementScope.Name -Confirm:$false -ErrorAction Continue
        throw 'The App RBAC positive or negative authorization test did not produce the expected result.'
    }
    Start-Sleep -Seconds 10
}

$state = [ordered]@{
    CreatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    TenantId = $TenantId
    Application = [ordered]@{
        DisplayName = [string]$application.DisplayName
        AppId = [string]$application.AppId
        ApplicationObjectId = [string]$application.Id
        ServicePrincipalObjectId = [string]$servicePrincipal.Id
        DeclaredGraphApplicationPermissions = @()
        ConsentedGraphApplicationPermissions = @()
    }
    Certificate = [ordered]@{
        Thumbprint = $certificate.Thumbprint
        Subject = $certificate.Subject
        NotBefore = $certificate.NotBefore.ToUniversalTime().ToString('o')
        NotAfter = $certificate.NotAfter.ToUniversalTime().ToString('o')
        PublicCertificatePath = $publicCertificatePath
        StoreLocation = 'Cert:\CurrentUser\My'
    }
    ScopeGroup = [ordered]@{
        Name = [string]$scopeGroup.DisplayName
        PrimarySmtpAddress = [string]$scopeGroup.PrimarySmtpAddress
        DistinguishedName = [string]$scopeGroup.DistinguishedName
        ExternalDirectoryObjectId = [string]$scopeGroup.ExternalDirectoryObjectId
    }
    ManagementScope = [ordered]@{
        Name = [string]$managementScope.Name
        RecipientFilter = $recipientFilter
    }
    ExchangeServicePrincipal = [ordered]@{
        AppId = [string]$exchangeServicePrincipal.AppId
        ObjectId = [string]$exchangeServicePrincipal.ObjectId
    }
    RoleAssignment = [ordered]@{
        Name = [string]$roleAssignment.Name
        Role = 'Application Mail.Read'
        CustomResourceScope = $ManagementScopeName
    }
    AuthorizedMailboxes = @($AuthorizedMailboxAddresses)
    DeniedMailbox = $DeniedMailboxAddress
    PositiveAuthorizationTests = @($positiveResults)
    NegativeAuthorizationTest = $negativeResult
}

$statePath = Join-Path $OutputDirectory 'native-app-rbac-lab-state.json'
Write-ToolkitJson -InputObject $state -Path $statePath

Write-Host ''
Write-Host 'Native App RBAC test application created.' -ForegroundColor Green
Write-Host "Application (client) ID: $($application.AppId)"
Write-Host "Service principal object ID: $($servicePrincipal.Id)"
Write-Host "Certificate thumbprint: $($certificate.Thumbprint)"
Write-Host "Management Scope: $ManagementScopeName"
Write-Host "Role assignment: $assignmentName"
Write-Host "State file: $statePath"
Write-Host ''
Write-Host 'No Microsoft Graph Mail.Read application permission was declared or consented in Entra ID.' -ForegroundColor Yellow
Write-Host 'Allow up to two hours before performing the live Microsoft Graph mailbox test.' -ForegroundColor Yellow
