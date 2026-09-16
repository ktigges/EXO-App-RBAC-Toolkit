# Application Access Policy to App RBAC Toolkit

This toolkit inventories legacy Exchange Online Application Access Policies (AAPs) and automates only App RBAC preparation. It never removes a broad Entra permission or a legacy AAP. Perform those changes manually, one application at a time.

For field definitions and extended background, see [INVENTORY-OUTPUT-GUIDE.md](INVENTORY-OUTPUT-GUIDE.md) and [DETAILED-MIGRATION-GUIDE.md](DETAILED-MIGRATION-GUIDE.md). For a command-by-command lab, see [Application-Access-Policy-Migration-Runbook.txt](Application-Access-Policy-Migration-Runbook.txt).

## Requirements

- PowerShell 7.4 or later.
- ExchangeOnlineManagement **3.6.0 exactly**. Versions 3.7.0 and later are not supported by this toolkit's macOS browser/MFA workflow.
- Microsoft Graph PowerShell 2.0 or later.
- OpenSSL on `PATH` for script 01. Windows does not include OpenSSL by default.
- Appropriate Entra and Exchange administrative roles.

```powershell
Install-Module ExchangeOnlineManagement -RequiredVersion 3.6.0 -Scope CurrentUser
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
Install-Module Microsoft.Graph.Applications -Scope CurrentUser
```

## Know the Two Service Principals

Creating an app registration also creates an Entra Enterprise Application. That Enterprise Application is the tenant's Entra service principal.

App RBAC requires Exchange Online to create its own pointer to that existing Entra service principal:

- **Application/client ID:** identifies the application in both systems.
- **Entra service-principal object ID:** the Enterprise Application object ID.
- **Exchange service-principal pointer:** an Exchange object created with both IDs. It is not another Entra application or Enterprise Application.

[![Legacy Application Access Policy wiring](docs/diagrams/legacy-aap.svg)](docs/diagrams/legacy-aap.svg)

[![Exchange Online App RBAC wiring](docs/diagrams/app-rbac.svg)](docs/diagrams/app-rbac.svg)

## Automation Boundary

| Script | Behavior |
|---|---|
| `01-New-LegacyAapLab.ps1` | Creates a disposable legacy AAP test application. |
| `02-Export-AapInventory.ps1` | Read-only inventory and HTML review dashboard. |
| `03-Convert-AapToAppRbac.ps1` | Prepare only: creates/reuses the Exchange pointer and scope, then creates the App RBAC role assignment. |
| `04-Test-GraphMailboxAccess.ps1` | Read-only live `Mail.Read` authorization test for one mailbox. |
| `05-New-AppRbacLab.ps1` | Creates a separate Windows-only native App RBAC lab. |

Script 03 accepts only `-Phase Prepare`. It leaves the broad Entra grant and legacy AAP unchanged. The toolkit contains no automated Cutover or Cleanup path.

[![Prepare is automated; Cutover and Cleanup are manual](docs/diagrams/migration-phases.svg)](docs/diagrams/migration-phases.svg)

## 1. Test the Process with the Lab App

Choose an allowed mailbox and a denied mailbox. The denied mailbox must not belong to the scope group.

```powershell
$TenantId = '00000000-0000-0000-0000-000000000000'
$AcceptedDomain = 'contoso.com'
$AllowedMailbox = 'allowed@contoso.com'
$DeniedMailbox = 'denied@contoso.com'

$lab = @{
    TenantId                    = $TenantId
    AcceptedDomain              = $AcceptedDomain
    AuthorizedMailboxAddresses = @($AllowedMailbox)
    DeniedMailboxAddress        = $DeniedMailbox
    AppDisplayName              = 'AAP Migration Lab'
    ScopeGroupName              = 'AAP-Lab-Mailboxes'
    GraphPermissionValue        = 'Mail.Read'
    AuthenticationMode         = 'Browser'
}

./01-New-LegacyAapLab.ps1 @lab
./01-New-LegacyAapLab.ps1 @lab -Execute
```

The first command previews; the second creates:

- An Entra app registration and its Enterprise Application/service principal.
- An OpenSSL certificate, private key, and uploaded public certificate.
- The selected Microsoft Graph application permission with admin consent.
- A mail-enabled security group containing only the allowed mailbox.
- A legacy `RestrictAccess` AAP for the app and group.
- `Output/lab/legacy-lab-state.json` containing the created IDs and paths.

The script also calculates legacy AAP access for the allowed and denied mailboxes. It does not create App RBAC or prove live Graph enforcement.

Load the state and run the live `Mail.Read` checks separately:

```powershell
$state = Get-Content ./Output/lab/legacy-lab-state.json -Raw | ConvertFrom-Json

./04-Test-GraphMailboxAccess.ps1 `
    -TenantId $TenantId `
    -AppId $state.Application.AppId `
    -Mailbox $AllowedMailbox `
    -ExpectedAccess Allowed `
    -CertificatePemPath $state.Certificate.CertificatePemPath `
    -PrivateKeyPath $state.Certificate.PrivateKeyPath

./04-Test-GraphMailboxAccess.ps1 `
    -TenantId $TenantId `
    -AppId $state.Application.AppId `
    -Mailbox $DeniedMailbox `
    -ExpectedAccess Denied `
    -CertificatePemPath $state.Certificate.CertificatePemPath `
    -PrivateKeyPath $state.Certificate.PrivateKeyPath
```

## 2. Export and Review All Applications

```powershell
./02-Export-AapInventory.ps1 `
    -TenantId $TenantId `
    -AuthenticationMode Browser
```

Open the newest `Output/inventory-yyyyMMdd-HHmmss/inventory-review.html`, then review these files in order:

1. `migration-readiness-issues.csv`: blockers and warnings.
2. `application-access-policies.csv`: App ID, policy identity, access type, and scope group.
3. `applications.csv`: app display name and `ServicePrincipalObjectId`. This is the Entra Enterprise Application object ID used by Exchange.
4. `application-permissions.csv`: permission, assignment ID, and recommended Exchange application role.
5. `scope-members.csv`: intended mailbox membership and nested groups.
6. `existing-app-rbac-assignments.csv`: preparation that already exists.

Join the files by `AppId`. Do not prepare wildcard policies, `DenyAccess` policies, ambiguous permissions, unknown owners, or unverified mailbox scopes.

## 3. Prepare the Exchange Objects for Every Approved App

For each reviewed application, create a parameter block with its own App ID, role, scope, and test mailboxes. Run preview and Execute once for that application, then move to the next approved application.

```powershell
$app = @{
    TenantId             = $TenantId
    AppId                = 'APPLICATION-CLIENT-ID'
    ApplicationRoleName  = 'Application Mail.Read'
    EntraPermissionValue = 'Mail.Read'
    ScopeType            = 'ExistingPolicyGroup'
    PositiveMailbox      = 'allowed@contoso.com'
    NegativeMailbox      = 'denied@contoso.com'
    AuthenticationMode   = 'Browser'
}

./03-Convert-AapToAppRbac.ps1 @app -Phase Prepare
./03-Convert-AapToAppRbac.ps1 @app -Phase Prepare -Execute
```

Prepare creates only the missing objects required for the approved mapping:

1. Exchange service-principal pointer to the existing Entra service principal.
2. Exchange Management Scope based on the existing AAP group, unless an approved alternate scope was selected.
3. Exchange application-role assignment over that scope.
4. A migration state file under `Output/migrations/`.

It also checks that the positive mailbox is in scope and the negative mailbox is out of scope. Repeat this reviewed Prepare operation for all approved apps. Do not put Cutover or Cleanup commands in a loop.

After propagation, inspect the prepared objects:

```powershell
Get-ServicePrincipal | Where-Object AppId -eq $app.AppId |
    Format-List DisplayName, AppId, ObjectId, Identity

Get-ManagementRoleAssignment | Where-Object Role -eq $app.ApplicationRoleName |
    Format-Table Name, Role, App, CustomResourceScope

Test-ServicePrincipalAuthorization `
    -Identity $app.AppId -Resource $app.PositiveMailbox |
    Where-Object RoleName -eq $app.ApplicationRoleName

Test-ServicePrincipalAuthorization `
    -Identity $app.AppId -Resource $app.NegativeMailbox |
    Where-Object RoleName -eq $app.ApplicationRoleName
```

Required results are `InScope=True` for the positive mailbox and `InScope=False` for the negative mailbox.

## 4. Migrate One Application Manually

Finish all steps for one App ID before selecting the next application.

### Manually remove the matching broad Entra grant

Use the `AssignmentId` from `application-permissions.csv`, then retrieve and display that exact assignment before deletion:

```powershell
Connect-MgGraph -TenantId $TenantId `
    -Scopes Application.Read.All,AppRoleAssignment.ReadWrite.All `
    -ContextScope Process -NoWelcome

$AppId = $app.AppId
$AssignmentId = 'ASSIGNMENT-ID-FROM-APPLICATION-PERMISSIONS-CSV'
$entraSp = Get-MgServicePrincipal -Filter "appId eq '$AppId'" -All |
    Select-Object -First 1
$assignment = Get-MgServicePrincipalAppRoleAssignment `
    -ServicePrincipalId $entraSp.Id -All |
    Where-Object Id -eq $AssignmentId

$assignment | Format-List Id, PrincipalId, ResourceId, AppRoleId
```

Stop if no assignment is returned or its IDs do not match the reviewed inventory. After change approval, remove that one assignment manually:

```powershell
Remove-MgServicePrincipalAppRoleAssignment `
    -ServicePrincipalId $entraSp.Id `
    -AppRoleAssignmentId $assignment.Id `
    -Confirm
```

Disconnect Graph, wait for propagation, and obtain a fresh app-only token. Run script 04 once for the allowed mailbox and once for the denied mailbox. The allowed request must succeed and the denied request must return an authorization denial. Also test the application's normal business operation.

If the denied request succeeds, stop. Check for another broad permission grant, stale tokens, and propagation delay. Do not remove the legacy AAP.

### Manually retire the legacy AAP

After the observation period and application-owner approval, retrieve the exact policy identity from `application-access-policies.csv` and inspect it:

```powershell
$PolicyIdentity = 'POLICY-IDENTITY-FROM-APPLICATION-ACCESS-POLICIES-CSV'
$policy = Get-ApplicationAccessPolicy -Identity $PolicyIdentity
$policy | Format-List Identity, AppId, AccessRight, PolicyScopeGroupId, Description
```

Stop unless the policy App ID and scope match the reviewed application. Remove that one policy manually:

```powershell
Remove-ApplicationAccessPolicy -Identity $policy.Identity -Confirm
```

Repeat the App RBAC configuration tests, live allowed/denied tests, and normal workload test. Then export a fresh inventory and archive it with the change record.

## Testing Rules

These tests answer different questions:

| Test | What it proves |
|---|---|
| `Test-ApplicationAccessPolicy` | Legacy AAP configuration calculation. |
| `Test-ServicePrincipalAuthorization` | App RBAC role and scope calculation. |
| Script 04 or the application's own app-only request | Live data-plane enforcement with an application token. |

Signing into Outlook as a mailbox user uses delegated authorization and does not prove app-only access. Configuration tests also do not replace a fresh-token live test after the broad grant is removed.