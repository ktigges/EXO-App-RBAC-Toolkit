# Title: Test Microsoft Graph Mailbox Access
# Author: Kevin Tigges
# Date: 2026-09-03
# Summary: Tests one mailbox access expectation using app-only certificate authentication.

[CmdletBinding(DefaultParameterSetName = 'Pem')]
param(
    [Parameter(Mandatory)]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [string]$AppId,

    [Parameter(Mandatory)]
    [string]$Mailbox,

    [Parameter(Mandatory)]
    [ValidateSet('Allowed', 'Denied')]
    [string]$ExpectedAccess,

    [Parameter(Mandatory, ParameterSetName = 'Thumbprint')]
    [string]$CertificateThumbprint,

    [Parameter(Mandatory, ParameterSetName = 'Pem')]
    [string]$CertificatePemPath,

    [Parameter(Mandatory, ParameterSetName = 'Pem')]
    [string]$PrivateKeyPath,

    [string]$OutputDirectory = (Join-Path (Join-Path $PSScriptRoot 'Output') 'live-validation')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'AppRbacMigration.Common.psm1') -Force
Assert-RequiredModule -Name Microsoft.Graph.Authentication -MinimumVersion 2.0
Import-Module Microsoft.Graph.Authentication

$certificate = if ($PSCmdlet.ParameterSetName -eq 'Pem') {
    if (-not (Test-Path -LiteralPath $CertificatePemPath -PathType Leaf)) {
        throw "Certificate PEM file was not found at '$CertificatePemPath'."
    }
    if (-not (Test-Path -LiteralPath $PrivateKeyPath -PathType Leaf)) {
        throw "Private key file was not found at '$PrivateKeyPath'."
    }

    [System.Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPemFile(
        $CertificatePemPath,
        $PrivateKeyPath
    )
}
else {
    Assert-WindowsCertificateStore -Operation 'Certificate-thumbprint Microsoft Graph mailbox validation'
    Get-Item -Path "Cert:\CurrentUser\My\$CertificateThumbprint" -ErrorAction Stop
}

if (-not $certificate.HasPrivateKey) {
    throw 'The supplied certificate does not have an accessible private key.'
}
if ($certificate.NotAfter -le (Get-Date)) {
    throw "The supplied certificate expired at '$($certificate.NotAfter.ToUniversalTime().ToString('o'))'."
}

Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
$graphConnectionParameters = @{
    TenantId    = $TenantId
    ClientId    = $AppId
    ContextScope = 'Process'
    NoWelcome   = $true
}
if ($PSCmdlet.ParameterSetName -eq 'Pem') {
    $graphConnectionParameters.Certificate = $certificate
}
else {
    $graphConnectionParameters.CertificateThumbprint = $CertificateThumbprint
}
Connect-MgGraph @graphConnectionParameters

function Invoke-MailReadTest {
    param(
        [Parameter(Mandatory)]
        [string]$Mailbox
    )

    $encodedMailbox = [uri]::EscapeDataString($Mailbox)
    $uri = "https://graph.microsoft.com/v1.0/users/$encodedMailbox/messages?`$top=1&`$select=id,subject,receivedDateTime"
    return Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject
}

Write-Host "Testing mailbox '$Mailbox'; expected access: $ExpectedAccess..." -ForegroundColor Cyan
$requestSucceeded = $false
$requestError = $null
$response = $null
try {
    $response = Invoke-MailReadTest -Mailbox $Mailbox
    $requestSucceeded = $true
}
catch {
    $requestError = $_
}

$statusCode = $null
$errorText = ''
if ($requestError) {
    if ($requestError.Exception.PSObject.Properties.Name -contains 'ResponseStatusCode') {
        $statusCode = [int]$requestError.Exception.ResponseStatusCode
    }
    $errorText = @(
        [string]$requestError.Exception.Message
        [string]$requestError.ErrorDetails.Message
    ) -join ' '
}

if ($ExpectedAccess -eq 'Allowed') {
    if (-not $requestSucceeded) {
        throw "Mailbox '$Mailbox' was expected to be allowed, but the request failed. Status: '$statusCode'. Error: $errorText"
    }
    if ($null -eq $response) {
        throw "Mailbox '$Mailbox' was expected to be allowed, but the request returned no response object."
    }
    $actualAccess = 'Allowed'
}
else {
    if ($requestSucceeded) {
        throw "Authorization validation failed: mailbox '$Mailbox' was expected to be denied, but Microsoft Graph allowed the request. The Graph test ran correctly; the expected mailbox restriction is not yet enforced. Do not run Cleanup. Verify that no broad Entra mailbox permission remains, allow recent policy or App RBAC changes to propagate, obtain a new token, and retry."
    }
    if ($statusCode -ne 403 -and $errorText -notmatch '403|ErrorAccessDenied|Authorization_RequestDenied|AccessDenied') {
        throw "Mailbox '$Mailbox' was expected to be denied, but the request failed for another reason. Status: '$statusCode'. Error: $errorText"
    }
    $actualAccess = 'Denied'
}

Write-Host "Mailbox '$Mailbox' matched expected access '$ExpectedAccess'." -ForegroundColor Green
Disconnect-MgGraph | Out-Null

$result = [pscustomobject]@{
    AppId = $AppId
    Mailbox = $Mailbox
    ExpectedAccess = $ExpectedAccess
    ActualAccess = $actualAccess
    TestedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
}

$safeAppId = $AppId -replace '[^a-zA-Z0-9-]', '_'
$safeMailbox = $Mailbox -replace '[^a-zA-Z0-9-]', '_'
$resultPath = Join-Path $OutputDirectory ("live-validation-{0}-{1}-{2}.json" -f $safeAppId, $safeMailbox, (Get-Date -Format 'yyyyMMdd-HHmmss'))
Write-ToolkitJson -InputObject $result -Path $resultPath

Write-Host "Validation result: $resultPath" -ForegroundColor Green
$result
