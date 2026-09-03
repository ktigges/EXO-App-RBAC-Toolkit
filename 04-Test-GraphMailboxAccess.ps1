# Title: Test Microsoft Graph Mailbox Access
# Author: Kevin Tigges
# Date: 2026-09-03
# Summary: Tests authorized and unauthorized mailbox access using app-only certificate authentication.

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [string]$AppId,

    [Parameter(Mandatory)]
    [string]$PositiveMailbox,

    [Parameter(Mandatory)]
    [string]$NegativeMailbox,

    [Parameter(Mandatory)]
    [string]$CertificateThumbprint
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'AppRbacMigration.Common.psm1') -Force
Assert-RequiredModule -Name Microsoft.Graph.Authentication -MinimumVersion 2.0
Import-Module Microsoft.Graph.Authentication

$certificate = Get-Item -Path "Cert:\CurrentUser\My\$CertificateThumbprint" -ErrorAction Stop
if (-not $certificate.HasPrivateKey) {
    throw "Certificate '$CertificateThumbprint' does not have an accessible private key."
}
if ($certificate.NotAfter -le (Get-Date)) {
    throw "Certificate '$CertificateThumbprint' is expired."
}

Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
Connect-MgGraph `
    -TenantId $TenantId `
    -ClientId $AppId `
    -CertificateThumbprint $CertificateThumbprint `
    -ContextScope Process `
    -NoWelcome

function Invoke-MailReadTest {
    param(
        [Parameter(Mandatory)]
        [string]$Mailbox
    )

    $encodedMailbox = [uri]::EscapeDataString($Mailbox)
    $uri = "https://graph.microsoft.com/v1.0/users/$encodedMailbox/messages?`$top=1&`$select=id,subject,receivedDateTime"
    return Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject
}

Write-Host "Testing authorized mailbox '$PositiveMailbox'..." -ForegroundColor Cyan
$positiveResult = Invoke-MailReadTest -Mailbox $PositiveMailbox
if ($null -eq $positiveResult) {
    throw "The positive mailbox request for '$PositiveMailbox' returned no response object."
}
Write-Host "Authorized mailbox test succeeded for '$PositiveMailbox'." -ForegroundColor Green

Write-Host "Testing unauthorized mailbox '$NegativeMailbox'..." -ForegroundColor Cyan
$negativeSucceeded = $false
$negativeError = $null
try {
    $null = Invoke-MailReadTest -Mailbox $NegativeMailbox
    $negativeSucceeded = $true
}
catch {
    $negativeError = $_
}

if ($negativeSucceeded) {
    throw "The negative mailbox request unexpectedly succeeded for '$NegativeMailbox'."
}

$statusCode = $null
if ($negativeError.Exception.PSObject.Properties.Name -contains 'ResponseStatusCode') {
    $statusCode = [int]$negativeError.Exception.ResponseStatusCode
}
$errorText = @(
    [string]$negativeError.Exception.Message
    [string]$negativeError.ErrorDetails.Message
) -join ' '

if ($statusCode -ne 403 -and $errorText -notmatch '403|ErrorAccessDenied|Authorization_RequestDenied|AccessDenied') {
    throw "The negative mailbox request failed, but not with an authorization denial. Status: '$statusCode'. Error: $errorText"
}

Write-Host "Unauthorized mailbox test was correctly denied for '$NegativeMailbox'." -ForegroundColor Green
Disconnect-MgGraph | Out-Null

[pscustomobject]@{
    AppId = $AppId
    PositiveMailbox = $PositiveMailbox
    PositiveResult = 'Succeeded'
    NegativeMailbox = $NegativeMailbox
    NegativeResult = 'Denied'
    TestedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
}
