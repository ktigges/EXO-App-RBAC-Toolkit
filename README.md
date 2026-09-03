# Application Access Policy to Exchange Online App RBAC Toolkit

This toolkit inventories legacy Application Access Policies, migrates an existing application to Exchange Online RBAC for Applications, and creates a separate application for testing new Exchange Online App RBAC authorization.

Tenant-changing scripts run in preview mode unless `-Execute` is supplied.

> **Only need the current status?** Run the second script. It is read-only and exports the current policies, applications, permissions, scopes, credentials, and migration-readiness findings.

```powershell
.\02-Export-AapInventory.ps1 `
    -TenantId "04c70b4f-47b8-4c11-bd5c-404698569670"
```

## Test in four steps

Set the test values:

```powershell
$TenantId = "04c70b4f-47b8-4c11-bd5c-404698569670"
$AcceptedDomain = "kytigges.com"
$AuthorizedMailboxes = @(
    "aap-lab-invoices@kytigges.com",
    "aap-lab-errors@kytigges.com"
)
$DeniedMailbox = "aap-lab-denied@kytigges.com"

Set-Location "C:\Users\kevintigges\OneDrive - Microsoft\Working FIles\Application Access Policy Migration\Toolkit"
```

The denied mailbox must remain outside the authorized group. It confirms that the application cannot access mailboxes beyond its approved scope.

### 1. Create the legacy test configuration

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

This creates an Entra application, Enterprise Application service principal, certificate, Microsoft Graph `Mail.Read` permission, scope group, and legacy `RestrictAccess` policy. Results are saved in `output\lab\legacy-lab-state.json`.

If the configuration already exists, skip this step and use the existing state file.

### 2. Export the inventory

```powershell
.\02-Export-AapInventory.ps1 -TenantId $TenantId
```

The read-only inventory is saved under `output\inventory-yyyyMMdd-HHmmss`.

Review `migration-readiness-issues.csv` first, followed by the policy, application, permission, scope-member, credential, and existing App RBAC exports. See [INVENTORY-OUTPUT-GUIDE.md](INVENTORY-OUTPUT-GUIDE.md) for full definitions.

Optional limited effective-access scan:

```powershell
.\02-Export-AapInventory.ps1 `
    -TenantId $TenantId `
    -EvaluateEffectiveAccess `
    -MaxMailboxes 25
```

### 3. Test the migration

Load the existing application information:

```powershell
$state = Get-Content ".\output\lab\legacy-lab-state.json" -Raw |
    ConvertFrom-Json

$AppId = $state.Application.AppId
$CertificateThumbprint = $state.Certificate.Thumbprint
```

#### Prepare

Prepare creates the Exchange service-principal pointer, Management Scope, and App RBAC role assignment. It leaves the Entra permission and legacy policy active.

```powershell
$prepare = @{
    TenantId = $TenantId
    AppId = $AppId
    Phase = "Prepare"
    ApplicationRoleName = "Application Mail.Read"
    EntraPermissionValue = "Mail.Read"
    ScopeType = "ExistingPolicyGroup"
    PositiveMailbox = $AuthorizedMailboxes[0]
    NegativeMailbox = $DeniedMailbox
}

# Preview, then execute
.\03-Convert-AapToAppRbac.ps1 @prepare
.\03-Convert-AapToAppRbac.ps1 @prepare -Execute
```

Confirm `InScope = True` for the authorized mailbox and `InScope = False` for the denied mailbox. Wait at least two hours before Cutover.

#### Cutover

Cutover removes the broad Entra `Mail.Read` assignment and performs live positive and negative Graph tests. Automatic rollback restores the Entra permission if validation fails.

```powershell
$cutover = @{
    TenantId = $TenantId
    AppId = $AppId
    Phase = "Cutover"
    ApplicationRoleName = "Application Mail.Read"
    EntraPermissionValue = "Mail.Read"
    ScopeType = "ExistingPolicyGroup"
    PositiveMailbox = $AuthorizedMailboxes[0]
    NegativeMailbox = $DeniedMailbox
    LiveValidationScriptPath = ".\04-Test-GraphMailboxAccess.ps1"
    LiveValidationParameters = @{
        CertificateThumbprint = $CertificateThumbprint
    }
    AutoRollbackOnValidationFailure = $true
}

# Preview, then execute
.\03-Convert-AapToAppRbac.ps1 @cutover
.\03-Convert-AapToAppRbac.ps1 @cutover -Execute
```

Observe the application after Cutover. Confirm normal processing, newly issued tokens, successful authorized access, and denied unauthorized access.

#### Cleanup

Cleanup removes the legacy policy. Run it only after the observation period has been completed and approved.

```powershell
$cleanup = @{
    TenantId = $TenantId
    AppId = $AppId
    Phase = "Cleanup"
    ApplicationRoleName = "Application Mail.Read"
    EntraPermissionValue = "Mail.Read"
    ScopeType = "ExistingPolicyGroup"
    PositiveMailbox = $AuthorizedMailboxes[0]
    NegativeMailbox = $DeniedMailbox
    ObservationValidated = $true
}

# Preview, then execute
.\03-Convert-AapToAppRbac.ps1 @cleanup
.\03-Convert-AapToAppRbac.ps1 @cleanup -Execute
```

Run the inventory again after Cleanup to record the final state.

### 4. Test a new application using App RBAC directly

This creates a separate application with Exchange `Application Mail.Read`. It does not receive Microsoft Graph `Mail.Read` through Entra admin consent.

```powershell
$nativeParameters = @{
    TenantId = $TenantId
    AcceptedDomain = $AcceptedDomain
    AuthorizedMailboxAddresses = @(
        "rbac-lab-invoices@kytigges.com",
        "rbac-lab-errors@kytigges.com"
    )
    DeniedMailboxAddress = "rbac-lab-denied@kytigges.com"
    CreateSharedMailboxes = $true
}

# Preview, then execute
.\05-New-AppRbacLab.ps1 @nativeParameters
.\05-New-AppRbacLab.ps1 @nativeParameters -Execute
```

After allowing up to two hours for propagation, run the live Graph test:

```powershell
$nativeState = Get-Content `
    ".\output\native-app-rbac-lab\native-app-rbac-lab-state.json" `
    -Raw | ConvertFrom-Json

.\04-Test-GraphMailboxAccess.ps1 `
    -TenantId $TenantId `
    -AppId $nativeState.Application.AppId `
    -PositiveMailbox $nativeState.AuthorizedMailboxes[0] `
    -NegativeMailbox $nativeState.DeniedMailbox `
    -CertificateThumbprint $nativeState.Certificate.Thumbprint
```

## Safety requirements

- Use tenant-changing scripts only in an approved nonproduction or test tenant.
- Preview every change before adding `-Execute`.
- Verify that Microsoft Graph and Exchange Online connect to the same tenant.
- Use the Enterprise Application service-principal object ID for Exchange `New-ServicePrincipal -ObjectId`.
- Do not automatically convert `DenyAccess`, wildcard, or multi-application policies.
- Resolve nested groups because App RBAC `MemberOfGroup` scopes evaluate direct members only.
- Treat Entra application permissions and App RBAC grants as additive while both exist.
- Keep the legacy policy through Cutover and the observation period.
- Require both an authorized-mailbox test and an unauthorized-mailbox test.

## Prerequisites

- Windows PowerShell 7 or Windows PowerShell 5.1
- ExchangeOnlineManagement 3.4 or later
- Microsoft Graph PowerShell 2.0 or later
- Rights to manage Entra applications, application permissions, Exchange policies, Management Scopes, service-principal pointers, role assignments, groups, and test mailboxes

```powershell
Install-Module ExchangeOnlineManagement -Scope CurrentUser
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
Install-Module Microsoft.Graph.Applications -Scope CurrentUser
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
| `02-Export-AapInventory.ps1` | Exports inventory and migration-readiness findings |
| `03-Convert-AapToAppRbac.ps1` | Runs Prepare, Cutover, or Cleanup |
| `04-Test-GraphMailboxAccess.ps1` | Tests live authorized and unauthorized mailbox access |
| `05-New-AppRbacLab.ps1` | Creates a separate application using App RBAC directly |
| `INVENTORY-OUTPUT-GUIDE.md` | Explains the inventory outputs |

## Migration exceptions

- `DenyAccess` requires redesign as a positive App RBAC scope.
- Wildcard and multi-application policies must be separated before migration.
- Nested groups are not expanded by `MemberOfGroup` scopes.
- `RecipientFilter` and `AdministrativeUnit` scopes require `-AcknowledgeScopeWidening`.
- Organization-wide role assignments are intentionally excluded.

## Rollback

Use `-AutoRollbackOnValidationFailure` during Cutover. For manual rollback, restore the original Entra application permission first, obtain a new token, and repeat the positive and negative tests. Do not remove App RBAC as the first rollback action.

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