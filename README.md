# IMPORTANT: USE EXCHANGEONLINEMANAGEMENT 3.6.0 ONLY

**DO NOT USE EXCHANGEONLINEMANAGEMENT 3.7.0+ WITH THIS TOOLKIT. REMOVE ALL 3.7+ VERSIONS AND INSTALL 3.6.0 EXACTLY BEFORE CONTINUING.**

Version 3.7.0 introduced a different authentication stack that is not supported by this toolkit's macOS browser/MFA workflow. Run the following commands in a fresh PowerShell session:

```powershell
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Remove-Module ExchangeOnlineManagement -Force -ErrorAction SilentlyContinue

$unsupportedVersions = @(
    Get-Module ExchangeOnlineManagement -ListAvailable |
        Where-Object Version -GE ([version]'3.7.0') |
        Select-Object -ExpandProperty Version -Unique
)

foreach ($version in $unsupportedVersions) {
    Write-Host "Removing ExchangeOnlineManagement $version..." -ForegroundColor Yellow
    Uninstall-Module ExchangeOnlineManagement `
        -RequiredVersion $version `
        -Force `
        -ErrorAction Stop
}

Install-Module ExchangeOnlineManagement `
    -RequiredVersion 3.6.0 `
    -Scope CurrentUser `
    -Force
```

Close that PowerShell session, open a new one, and verify the installation before running any toolkit script:

```powershell
# Run this verification in a fresh PowerShell session.
$unsupportedVersions = @(
    Get-Module ExchangeOnlineManagement -ListAvailable |
        Where-Object Version -GE ([version]'3.7.0')
)
if ($unsupportedVersions.Count -gt 0) {
    throw "ExchangeOnlineManagement 3.7.0 or later is still installed. Remove it before continuing."
}

Import-Module ExchangeOnlineManagement -RequiredVersion 3.6.0 -Force
$loadedVersion = (Get-Module ExchangeOnlineManagement).Version
if ($loadedVersion -ne [version]'3.6.0') {
    throw "Expected ExchangeOnlineManagement 3.6.0, but loaded $loadedVersion."
}

Write-Host "ExchangeOnlineManagement $loadedVersion is ready." -ForegroundColor Green
```

**EXPECTED RESULT: `ExchangeOnlineManagement 3.6.0 is ready.` DO NOT CONTINUE IF THE CHECK THROWS AN ERROR.**

# IMPORTANT: OPENSSL REQUIREMENTS

**SCRIPT 01 REQUIRES OPENSSL ON BOTH MACOS AND WINDOWS. WINDOWS DOES NOT INCLUDE OPENSSL BY DEFAULT. INSTALL OPENSSL SEPARATELY AND ENSURE `openssl` (`openssl.exe` ON WINDOWS) IS AVAILABLE ON `PATH` BEFORE RUNNING SCRIPT 01.**

Script 01 uses OpenSSL to generate its PEM private key and certificate. On Windows, install a trusted OpenSSL distribution and add the directory containing `openssl.exe` to the user or system `PATH`. On macOS, install OpenSSL if `openssl` is not already available. Open a new PowerShell session after changing `PATH`, then verify:

```powershell
$openSslCommand = Get-Command openssl `
    -CommandType Application `
    -ErrorAction SilentlyContinue

if (-not $openSslCommand) {
    throw "OpenSSL was not found on PATH. Install it and open a new PowerShell session before running script 01."
}

Write-Host "OpenSSL executable: $($openSslCommand.Path)" -ForegroundColor Green
& $openSslCommand.Path version
if ($LASTEXITCODE -ne 0) {
    throw "OpenSSL was found but did not run successfully."
}
```

**DO NOT CONTINUE WITH SCRIPT 01 UNLESS THE COMMAND PRINTS AN OPENSSL EXECUTABLE PATH AND VERSION.**

- Script 01 requires the OpenSSL executable on `PATH` on macOS and Windows.
- Scripts 02 and 03 do not generate certificates and do not require OpenSSL.
- Script 05 is Windows-only and uses the Windows certificate store with `New-SelfSignedCertificate`; it does not require OpenSSL.

# Application Access Policy to Exchange Online App RBAC Toolkit

## Microsoft change this toolkit addresses

| Item | Current status |
|---|---|
| Change | Exchange Online Application Access Policies are a legacy mailbox-scoping model. Microsoft identifies RBAC for Applications as their replacement and says new access configurations should use App RBAC. |
| Message Center ID | Not yet published in the cited Microsoft Learn guidance. This repository has no verified MC number as of September 11, 2026. Microsoft Learn says a future deprecation announcement will require migration; update this item when Microsoft publishes that notice. |
| Retirement date | No firm retirement date has been published. Do not treat this toolkit as evidence of a Microsoft enforcement date. |
| Official guidance | [Application Access Policies (legacy)](https://learn.microsoft.com/exchange/permissions-exo/application-access-policies) and [Role Based Access Control for Applications in Exchange Online](https://learn.microsoft.com/exchange/permissions-exo/application-rbac) |

Application permissions such as Microsoft Graph `Mail.Read` are organization-wide by default. A legacy Application Access Policy constrains an Entra-granted permission to selected mailboxes. App RBAC replaces that two-part model with an Exchange application role assignment associated with a resource scope, such as a Management Scope or Administrative Unit. During migration, the grants are additive: leaving the organization-wide Entra permission in place can allow access beyond the App RBAC scope. The safe sequence is to inventory first, create and validate the scoped App RBAC assignment, remove the matching broad Entra grant during cutover, observe the workload with a new token, and remove the legacy policy only after validation.

This toolkit can inventory legacy Application Access Policies, assess migration readiness, migrate an existing application to Exchange Online RBAC for Applications, or create optional applications for testing. These are separate workflows. You do not need to create a test application to inventory an existing tenant.

Tenant-changing scripts run in preview mode unless `-Execute` is supplied. `02-Export-AapInventory.ps1` is read-only against the tenant and only writes reports to the local output directory.

## Prerequisites

- PowerShell 7.4 or later
- ExchangeOnlineManagement 3.6.0 exactly; versions 3.7.0 and later use a different authentication stack and are not supported by this toolkit configuration
- Microsoft Graph PowerShell 2.0 or later
- OpenSSL on `PATH` when running script 01
- Rights to read Entra applications, Exchange policies, groups, and mailboxes during discovery
- Approved rights to create Exchange service-principal pointers, Management Scopes, and role assignments and to remove Entra grants during migration

```powershell
Install-Module ExchangeOnlineManagement -RequiredVersion 3.6.0 -Scope CurrentUser
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
Install-Module Microsoft.Graph.Applications -Scope CurrentUser
```

Scripts 01, 02, 03, and 05 accept `-AuthenticationMode Auto` or `Browser`. Both use interactive browser authentication. Device-code authentication is not supported by this toolkit configuration. Every Exchange Online connection checks for and imports version 3.6.0 exactly; installing a newer version alongside 3.6.0 does not cause the newer version to be loaded.

## Production migration workflow

Follow these steps in order for an existing tenant. Discovery and analysis are read-only. Do not run script 03 until one application has been reviewed and approved.

### Step 1: Collect the tenant inventory

Create a named output directory so the evidence from this run is easy to identify later:

```powershell
$TenantId = "00000000-0000-0000-0000-000000000000"
Set-Location "C:\Path\Application Access Policy Migration"

$runStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$inventoryPath = Join-Path $PWD "Output\inventory-$runStamp"

.\02-Export-AapInventory.ps1 `
    -TenantId $TenantId `
    -OutputDirectory $inventoryPath
```

The script authenticates to Microsoft Graph and Exchange Online, then collects:

- Legacy Application Access Policies and their application IDs.
- Related App registrations and Enterprise Application service principals.
- Current Entra application permissions and suggested Exchange application-role mappings.
- Application and service-principal owners and credentials.
- Policy scope groups and their direct members.
- Existing Exchange App RBAC service-principal pointers and role assignments.
- Migration-readiness findings detected from the collected configuration.

The run creates CSV files, `inventory.json`, and a standalone `inventory-review.html` dashboard under the selected directory. Collection is complete only when the script prints `Application Access Policy inventory complete` and exits without an error.

### Step 2: Open and review the collected data

Open `inventory-review.html` from the inventory output directory in a web browser. This is the easiest way to review the discovered policies, applications, permissions, scope members, credentials, existing App RBAC assignments, and readiness findings.

The dashboard is a local HTML report with the inventory embedded in it; opening it does not send inventory data to another service.

Then check the run summary and generated files:

```powershell
$inventory = Get-Content (Join-Path $inventoryPath 'inventory.json') -Raw |
    ConvertFrom-Json

$inventory.Summary | Format-List
Get-ChildItem $inventoryPath | Select-Object Name, Length
```

Confirm that `TenantId` is the intended tenant and that the policy, application, permission, and scope-member counts are plausible. A zero-byte or header-only CSV can be valid when no matching records exist, but an unexpected zero count must be investigated before migration. If the script did not finish successfully, discard that run as incomplete and correct the collection error before continuing.

#### Triage readiness findings

Start with the High and Medium findings rather than selecting an application immediately:

```powershell
$issues = Import-Csv (Join-Path $inventoryPath 'migration-readiness-issues.csv')

$issues |
    Group-Object Severity, Category |
    Sort-Object Name |
    Select-Object Count, Name |
    Format-Table -AutoSize

$issues |
    Sort-Object Severity, AppId, Category |
    Format-Table Severity, AppId, Category, Detail -Wrap
```

- **High:** Stop normal migration for that application until the finding is resolved or an approved manual design addresses it.
- **Medium:** Record an owner and resolution plan, then decide whether it must be completed before Prepare or before Cutover.
- **No finding:** Continue analysis; absence of a generated finding is not by itself migration approval.

`DenyAccess`, wildcard or multi-application policies, unresolved objects, and nested groups require remediation or a manual scope design. They are not candidates for the standard one-app-at-a-time conversion.

#### Review each application

Use `AppId` to correlate records across the dashboard and CSV files. For every policy-controlled application, record the following migration worksheet before choosing a candidate:

| Decision input | Inventory source | Required conclusion |
|---|---|---|
| Application and policy | `application-access-policies.csv` | Identify one App ID, one policy, its access right, and its scope group. |
| Identity and ownership | `applications.csv` | Confirm the App registration, Enterprise Application service-principal object ID, enabled state, and accountable owner. |
| Permission mapping | `application-permissions.csv` | Confirm each workload permission and whether the suggested Exchange application role is functionally equivalent. |
| Authorized population | `scope-members.csv` | Confirm the intended mailboxes are direct members and identify one allowed and one denied validation mailbox. |
| Credential viability | `credential-expiration.csv` | Confirm which credential production uses and that it remains valid through cutover, observation, and rollback. |
| Existing configuration | `existing-app-rbac-assignments.csv` | Determine whether an App RBAC pointer, role, or scope already exists and whether access would become additive or duplicated. |
| Readiness findings | `migration-readiness-issues.csv` | Assign an owner and disposition to every High and Medium finding for the App ID. |

Validate the worksheet with the application owner. Inventory can identify configured permissions, but only the owner can confirm which APIs and operations the workload actually uses. Do not remove a broad Entra permission solely because the inventory suggests an Exchange role with a similar name.

Assign one outcome to each application:

| Outcome | Meaning |
|---|---|
| `Ready` | Identity, ownership, permission mapping, positive scope, credentials, test mailboxes, and rollback plan are confirmed; no unresolved High findings remain. |
| `Remediate` | The standard migration may apply after specific ownership, credential, membership, or configuration findings are corrected. |
| `Manual redesign` | The application uses `DenyAccess`, wildcard/shared policy behavior, nested membership, multiple controlled permissions, or another scope model that script 03 cannot safely infer. |
| `Out of scope` | The policy or application is obsolete, unused, or not approved for this migration effort; document the separate cleanup owner and decision. |

#### Capture an effective-access baseline when needed

For each `Ready` candidate, decide whether to collect the optional legacy access baseline. It is strongly recommended when the migration will rely on a known allowed/denied mailbox pair. Rerun collection into a new timestamped directory with `-EvaluateEffectiveAccess` and a bounded, deterministic mailbox set. The next section explains the parameters and provides examples.

#### Approval gate

Proceed to script 03 only after the worksheet has been reviewed and the application is marked `Ready`. Copy the confirmed `TenantId`, `AppId`, `RecommendedExchangeApplicationRole`, current Entra `PermissionValue`, scope design, positive mailbox, and negative mailbox into the parameter block in [Migration workflow for one approved application](#migration-workflow-for-one-approved-application).

Archive the inventory directory with the change record. Run a fresh inventory immediately before Cutover to detect configuration drift, and run another after Cleanup to capture the final state.

See [INVENTORY-OUTPUT-GUIDE.md](INVENTORY-OUTPUT-GUIDE.md) for every field and finding type.

#### Effective-access parameter reference

You do not need this switch to inventory policies, applications, permissions, or policy scope-group members. Use it only when you want Exchange to calculate the current legacy policy outcome for selected app/mailbox pairs.

An application permission such as `Mail.Read` answers **what can the app do?** The Application Access Policy answers **which mailboxes can it do that against?** Exchange therefore needs two values to calculate effective access:

- An application/client ID.
- A target mailbox whose current policy result should be evaluated.

The script already gets App IDs from the inventoried policies. It gets target mailboxes from Exchange Online; you are not granting or configuring a mailbox by including it in this check. For each selected pair, the script runs `Test-ApplicationAccessPolicy -AppId <app> -Identity <mailbox>` and records `Granted` or `Denied` in `effective-legacy-access.csv`.

You do not provide an "effective mailbox," and the script does not require a mailbox parameter. By default it evaluates all existing mailboxes. `-MailboxFilter` and `-MaxMailboxes` are optional controls that reduce that test set so a tenant-wide check does not become an unnecessarily large app-by-mailbox matrix.

The parameters control each side of that test:

| Parameter | What it selects |
|---|---|
| `-EvaluateEffectiveAccess` | Enables the optional policy calculation. |
| `-EffectiveAccessAppId` | Limits testing to one existing policy App ID. It does not identify a mailbox. If omitted, all inventoried policy App IDs are tested. |
| `-MailboxFilter` | Limits which existing Exchange mailboxes are used as test targets. If omitted, all mailboxes are selected. |
| `-MaxMailboxes` | Takes only the first number of mailboxes from the selected mailbox list. It does not limit applications. |

For a useful baseline, select a deterministic mailbox population containing at least one mailbox expected to be allowed and one expected to be denied. For example, tag approved test mailboxes with a custom attribute and run:

```powershell
.\02-Export-AapInventory.ps1 `
    -TenantId $TenantId `
    -EvaluateEffectiveAccess `
    -MailboxFilter "CustomAttribute1 -eq 'AppRbacValidation'"
```

To test only one existing application against that same mailbox population, add:

```powershell
-EffectiveAccessAppId "00000000-0000-0000-0000-000000000000"
```

Effective-access results are written to `effective-legacy-access.csv`. `Granted` means the legacy policy calculation permits that app/mailbox pair; `Denied` means it does not. This uses `Test-ApplicationAccessPolicy`; it is a configuration check, not a live token or Graph API test.

This inventory and pre-check path does not create an application, change permissions or policies, create App RBAC assignments, remove legacy access, or perform a migration.

### Step 3: Prepare App RBAC for one approved application

Before selecting an application or running script 03, complete the [detailed inventory collection and analysis](#detailed-inventory-collection-and-analysis) workflow above. The inventory is the source for the App ID, service-principal object ID, current permissions, policy type, scope group, mailbox population, owners, credentials, and existing App RBAC assignments. Do not substitute the example values in this section for tenant evidence.

Assume the customer has this existing configuration:

| Item | Example value |
|---|---|
| Application ID | `12345678-1234-1234-1234-123456789012` |
| Current Entra permission | Microsoft Graph `Mail.Read` |
| Current legacy policy | `RestrictAccess` using the `Finance-App-Mailboxes` group |
| Mailbox that should remain allowed | `finance-inbox@contoso.com` |
| Mailbox that should remain denied | `executive@contoso.com` |
| Application certificate | Installed locally with its private key |

`03-Convert-AapToAppRbac.ps1` **creates the migration configuration automatically when Prepare is run with `-Execute`**. It does not create another Entra application or Enterprise Application. It reuses the existing Entra service principal, creates its Exchange service-principal pointer, creates a Management Scope from the legacy policy group, and assigns `Application Mail.Read` over that scope.

It does not automatically select an app from the inventory or migrate every app. You choose one App ID, permission, and positive/negative test mailbox, then run that app through Prepare, Cutover, and Cleanup.

Set the values once:

```powershell
$app = @{
    TenantId = "00000000-0000-0000-0000-000000000000"
    AppId = "12345678-1234-1234-1234-123456789012"
    ApplicationRoleName = "Application Mail.Read"
    EntraPermissionValue = "Mail.Read"
    ScopeType = "ExistingPolicyGroup"
    PositiveMailbox = "finance-inbox@contoso.com"
    NegativeMailbox = "executive@contoso.com"
}
```

#### Preview and execute Prepare

Preview first. The preview reads and validates the current configuration but changes nothing.

```powershell
.\03-Convert-AapToAppRbac.ps1 @app -Phase Prepare
```

Then run Prepare with `-Execute` to create the App RBAC configuration:

```powershell
.\03-Convert-AapToAppRbac.ps1 @app -Phase Prepare -Execute
```

The old Entra `Mail.Read` permission and legacy policy remain active. Script 03 saves this app's migration state under `Output\migrations`.

#### Validate after Prepare

Wait at least two hours for App RBAC propagation. First confirm that the existing legacy policy still calculates the expected access:

```powershell
Test-ApplicationAccessPolicy `
    -Identity $app.PositiveMailbox `
    -AppId $app.AppId

Test-ApplicationAccessPolicy `
    -Identity $app.NegativeMailbox `
    -AppId $app.AppId
```

The positive mailbox must be `Granted` and the negative mailbox must be `Denied`. Then confirm that the new App RBAC assignment calculates the same scope:

```powershell
Test-ServicePrincipalAuthorization `
    -Identity $app.AppId `
    -Resource $app.PositiveMailbox |
    Where-Object RoleName -eq $app.ApplicationRoleName

Test-ServicePrincipalAuthorization `
    -Identity $app.AppId `
    -Resource $app.NegativeMailbox |
    Where-Object RoleName -eq $app.ApplicationRoleName
```

The positive mailbox must show `InScope` as `True`; the negative mailbox must show `InScope` as `False`. These commands evaluate Exchange configuration and do not call Microsoft Graph. Perform any application-level mailbox test separately through the application's normal test procedure.

Do not continue unless the legacy policy and App RBAC scope checks return the expected results.

### Step 4: Cut over and validate the application

After completing the post-Prepare checks, preview Cutover:

```powershell
.\03-Convert-AapToAppRbac.ps1 @app `
    -Phase Cutover -AcknowledgeManualLiveValidation
```

Then run Cutover with `-Execute`:

```powershell
.\03-Convert-AapToAppRbac.ps1 @app `
    -Phase Cutover -AcknowledgeManualLiveValidation -Execute
```

Cutover removes the broad Entra `Mail.Read` permission. `-AcknowledgeManualLiveValidation` confirms that the application's normal mailbox test will be performed separately. This workflow does not run the dual-mailbox Graph test or automatic validation rollback.

### Step 5: Observe and clean up

After the application owner confirms normal operation during the observation period, preview and execute Cleanup:

```powershell
.\03-Convert-AapToAppRbac.ps1 @app `
    -Phase Cleanup -ObservationValidated

.\03-Convert-AapToAppRbac.ps1 @app `
    -Phase Cleanup -ObservationValidated -Execute
```

Cleanup removes the legacy Application Access Policy and leaves App RBAC as the authorization path. Finish all three phases for this App ID before starting the next application.

> This automated example supports an app with one policy-controlled mailbox permission. Script 03 stops before changes when the app has multiple controlled permissions because those roles require one coordinated migration design.

## Production validation reference

`-EvaluateEffectiveAccess` in script 02 records the current legacy Application Access Policy result and is useful as a before-migration baseline.

Use separate `Test-ServicePrincipalAuthorization` calls before and after Cutover:

```powershell
Test-ServicePrincipalAuthorization `
    -Identity $app.AppId `
    -Resource $app.PositiveMailbox |
    Where-Object RoleName -eq $app.ApplicationRoleName

Test-ServicePrincipalAuthorization `
    -Identity $app.AppId `
    -Resource $app.NegativeMailbox |
    Where-Object RoleName -eq $app.ApplicationRoleName
```

The positive mailbox must show `InScope` as `True`; the negative mailbox must show `InScope` as `False`. This tests Exchange configuration, not a live token or mailbox request. Run the application's normal mailbox operation separately before Cleanup and retain that result with the change record.

For an optional direct Microsoft Graph check, run script 04 once per mailbox. Do not pass positive and negative mailboxes in one invocation:

```powershell
.\04-Test-GraphMailboxAccess.ps1 `
    -TenantId $app.TenantId `
    -AppId $app.AppId `
    -Mailbox $app.PositiveMailbox `
    -ExpectedAccess Allowed `
    -CertificatePemPath "/path/to/application.cert.pem" `
    -PrivateKeyPath "/path/to/application.key.pem"

.\04-Test-GraphMailboxAccess.ps1 `
    -TenantId $app.TenantId `
    -AppId $app.AppId `
    -Mailbox $app.NegativeMailbox `
    -ExpectedAccess Denied `
    -CertificatePemPath "/path/to/application.cert.pem" `
    -PrivateKeyPath "/path/to/application.key.pem"
```

Run those as two separate commands. On Windows, use `-CertificateThumbprint` instead of the two PEM path parameters when the certificate and private key are in `Cert:\CurrentUser\My`. If a mailbox expected to be denied succeeds, the Graph call worked but authorization did not enforce the expected scope. This is a failed authorization result, not a script malfunction. Stop the migration, do not run Cleanup, verify that broad Entra mailbox permission is absent, wait for propagation, obtain a new token, and retry.

## Production migration notes

- Script 03 migrates an existing application; it does not require script 01 or any lab state.
- Use script 02 to identify the App ID, current permission, legacy policy, and scope before selecting the next app.
- `-EvaluateEffectiveAccess` in script 02 records current legacy access only.
- `Test-ServicePrincipalAuthorization` validates App RBAC scope configuration; the application's normal test validates real operation.
- Prepare stops before changes when an app has multiple policy-controlled permissions. Those apps require one coordinated migration design.
- Finish Prepare, Cutover, observation, and Cleanup for one App ID before starting another.

## Safety requirements

- Use lab-creation scripts 01 and 05 only in an approved nonproduction or test tenant.
- Use script 03 in production only through an approved change, validation, observation, and rollback plan.
- Preview every change before adding `-Execute`.
- Verify that Microsoft Graph and Exchange Online connect to the same tenant.
- Use the Enterprise Application service-principal object ID for Exchange `New-ServicePrincipal -ObjectId`.
- Do not automatically convert `DenyAccess`, wildcard, or multi-application policies.
- Resolve nested groups because App RBAC `MemberOfGroup` scopes evaluate direct members only.
- Treat Entra application permissions and App RBAC grants as additive while both exist.
- Keep the legacy policy through Cutover and the observation period.
- Require both an authorized-mailbox test and an unauthorized-mailbox test.

### Required execution platform

Exchange Online operations require ExchangeOnlineManagement 3.6.0 and interactive browser authentication. Versions 3.7.0 and later are not supported by this toolkit configuration. Script 01 generates its certificate and private key with OpenSSL instead of the Windows certificate store.

Scripts 01, 02, 03, and 05 accept `-AuthenticationMode Auto` or `Browser`; both modes open the interactive browser sign-in. The signed-in account can complete MFA in that browser session.

For example:

```powershell
.\02-Export-AapInventory.ps1 -TenantId $TenantId
```

If another module version is selected, close all PowerShell sessions, open a fresh PowerShell 7 session, and verify the installed versions:

```powershell
Get-Module ExchangeOnlineManagement -ListAvailable |
    Select-Object Name, Version, Path
```

## What changes

The Entra application, Enterprise Application service principal, and certificate normally remain in place. The authorization changes:

| Before migration | After migration |
|---|---|
| Entra grants broad Microsoft Graph mailbox permission | Broad Entra mailbox permission is removed |
| Application Access Policy limits that permission | Exchange application role grants the required operation |
| No Exchange service-principal pointer is required | Exchange pointer connects the role to the existing Entra service principal |
| Legacy policy group defines access | App RBAC resource scope defines access |

## Files

| File | Purpose |
|---|---|
| `AppRbacMigration.Common.psm1` | Shared validation, connection, lookup, and output helpers |
| `01-New-LegacyAapLab.ps1` | Creates the legacy test configuration |
| `02-Export-AapInventory.ps1` | Exports inventory and tests legacy policy access for all apps or one app |
| `03-Convert-AapToAppRbac.ps1` | Runs Prepare, Cutover, or Cleanup |
| `04-Test-GraphMailboxAccess.ps1` | Optionally tests one live mailbox access expectation per invocation |
| `05-New-AppRbacLab.ps1` | Creates a separate application using App RBAC directly |
| `INVENTORY-OUTPUT-GUIDE.md` | Explains the inventory outputs |

## Migration exceptions

- `DenyAccess` requires redesign as a positive App RBAC scope.
- Wildcard and multi-application policies must be separated before migration.
- Nested groups are not expanded by `MemberOfGroup` scopes.
- `RecipientFilter` and `AdministrativeUnit` scopes require `-AcknowledgeScopeWidening`.
- Organization-wide role assignments are intentionally excluded.

## Rollback

For rollback, restore the original Entra application permission first, obtain a new token, and repeat the separate authorization and application tests. Do not remove App RBAC as the first rollback action.

## Production checklist

- [ ] Inventory reviewed and blockers resolved
- [ ] Application and service-principal owners confirmed
- [ ] Positive and negative mailboxes approved
- [ ] Role and resource scope confirmed
- [ ] Prepare previewed, executed, and tested
- [ ] Two-hour propagation period completed
- [ ] Cutover and rollback approved
- [ ] Live positive and negative tests passed
- [ ] Observation period completed
- [ ] Cleanup previewed and executed
- [ ] Final inventory captured

## Microsoft documentation

- [Role Based Access Control for Applications in Exchange Online](https://learn.microsoft.com/exchange/permissions-exo/application-rbac)
- [Application Access Policies in Exchange Online](https://learn.microsoft.com/exchange/permissions-exo/application-access-policies)
- [Grant and revoke API permissions with Microsoft Graph PowerShell](https://learn.microsoft.com/powershell/microsoftgraph/how-to-grant-revoke-api-permissions)

## Optional test applications

Use this section only after reviewing the production workflow above and only in an approved nonproduction tenant. These scripts create disposable applications and are not required to discover or migrate existing applications.

`01-New-LegacyAapLab.ps1` creates a legacy Application Access Policy configuration that can be discovered by script 02 and migrated with script 03. `05-New-AppRbacLab.ps1` creates a separate application directly on App RBAC. Script 04 optionally tests one mailbox and one expected access result per invocation.

Set the test values:

```powershell
$TenantId = "00000000-0000-0000-0000-000000000000"
$AcceptedDomain = "contoso.com"
$AuthorizedMailboxes = @(
    "aap-lab-invoices@contoso.com",
    "aap-lab-errors@contoso.com"
)
$DeniedMailbox = "aap-lab-denied@contoso.com"

Set-Location "C:\Path\Application Access Policy Migration"
```

The denied mailbox must remain outside the authorized group. It confirms that the application cannot access mailboxes beyond its approved scope.

### 1. Create a legacy test application

```powershell
$legacyParameters = @{
    TenantId = $TenantId
    AcceptedDomain = $AcceptedDomain
    AuthorizedMailboxAddresses = $AuthorizedMailboxes
    DeniedMailboxAddress = $DeniedMailbox
    CreateSharedMailboxes = $true
}

# Preview
.\01-New-LegacyAapLab.ps1 @legacyParameters

# Execute after reviewing the preview
.\01-New-LegacyAapLab.ps1 @legacyParameters -Execute
```

This creates an Entra application, Enterprise Application service principal, certificate, Microsoft Graph `Mail.Read` permission, scope group, and legacy `RestrictAccess` policy. Results are saved in `Output\lab\legacy-lab-state.json`.

### 2. Inventory the legacy test application

```powershell
.\02-Export-AapInventory.ps1 -TenantId $TenantId
```

Open `inventory-review.html` in the new `Output\inventory-yyyyMMdd-HHmmss` directory and review the test application exactly as described in Steps 1 and 2 of the production workflow.

### 3. Optionally migrate the legacy test application

Load the disposable App ID and certificate:

```powershell
$state = Get-Content ".\Output\lab\legacy-lab-state.json" -Raw |
    ConvertFrom-Json

$AppId = $state.Application.AppId
$CertificatePemPath = (Resolve-Path $state.Certificate.CertificatePemPath).Path
$PrivateKeyPath = (Resolve-Path $state.Certificate.PrivateKeyPath).Path
```

Use these values in Step 3 of the production workflow and set `$app.AppId = $AppId`. The Prepare, Cutover, and Cleanup commands are otherwise identical.

### 4. Create and test a new App RBAC application directly

This creates a separate application with Exchange `Application Mail.Read`. It does not receive Microsoft Graph `Mail.Read` through Entra admin consent.

```powershell
$nativeParameters = @{
    TenantId = $TenantId
    AcceptedDomain = $AcceptedDomain
    AuthorizedMailboxAddresses = @(
        "rbac-lab-invoices@contoso.com",
        "rbac-lab-errors@contoso.com"
    )
    DeniedMailboxAddress = "rbac-lab-denied@contoso.com"
    CreateSharedMailboxes = $true
}

# Preview, then execute
.\05-New-AppRbacLab.ps1 @nativeParameters
.\05-New-AppRbacLab.ps1 @nativeParameters -Execute
```

After allowing up to two hours for propagation, test each mailbox scope separately:

```powershell
$nativeState = Get-Content `
    ".\Output\native-app-rbac-lab\native-app-rbac-lab-state.json" `
    -Raw | ConvertFrom-Json

Test-ServicePrincipalAuthorization `
    -Identity $nativeState.Application.AppId `
    -Resource $nativeState.AuthorizedMailboxes[0] |
    Where-Object RoleName -eq 'Application Mail.Read'

Test-ServicePrincipalAuthorization `
    -Identity $nativeState.Application.AppId `
    -Resource $nativeState.DeniedMailbox |
    Where-Object RoleName -eq 'Application Mail.Read'
```