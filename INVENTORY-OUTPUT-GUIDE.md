# Application Access Policy Inventory Output Guide

This guide explains the files produced by `02-Export-AapInventory.ps1`. The inventory is read-only and creates a timestamped folder under `output\inventory-yyyyMMdd-HHmmss`.

## How this helps with the migration

This inventory tells you what exists today, what each application can access, and what must be recreated or corrected before moving from legacy Application Access Policies to Exchange Online App RBAC.

The application is not being replaced or migrated to a new service principal (SPN). The existing Entra application, Enterprise Application service principal, and authentication certificate normally stay in place. The authorization model changes:

- **Today:** Entra grants a broad Microsoft Graph application permission such as `Mail.Read`, and an Application Access Policy limits that permission to selected mailboxes.
- **After migration:** Exchange creates a pointer to the existing Entra service principal and assigns an Exchange application role, such as `Application Mail.Read`, over a specific mailbox scope.

The output files help you make that change safely by answering these questions:

1. Which legacy policies and application IDs must be migrated?
2. Which App registration and Enterprise Application service principal belong to each policy?
3. Which Entra permission is currently granted, and which Exchange App RBAC role may replace it?
4. Which mailboxes are currently authorized, and can the same population be represented by an App RBAC scope?
5. Are there blockers such as missing owners, missing Entra objects, nested groups, `DenyAccess` policies, expiring credentials, or existing App RBAC assignments?

Use the inventory as the baseline for the three migration phases:

- **Prepare:** Create the Exchange service-principal pointer, mailbox scope, and App RBAC role assignment while the legacy authorization remains active.
- **Cutover:** After propagation and testing, remove the broad Entra application permission and validate access with a newly issued token.
- **Cleanup:** After the observation period, remove the legacy Application Access Policy.

Run the inventory before Prepare to establish the baseline, immediately before Cutover to confirm nothing has changed unexpectedly, and after Cleanup to record the final state.

The files provide a point-in-time view of legacy Application Access Policies, related Entra objects, mailbox scopes, credentials, permissions, and existing Exchange Online App RBAC assignments. They support migration planning but do not make migration decisions automatically.

## Recommended review order

1. Review `migration-readiness-issues.csv` for blockers and warnings.
2. Review `application-access-policies.csv` to identify each legacy policy and its scope.
3. Review `applications.csv` and `application-permissions.csv` to confirm the application identity and permission-to-role mapping.
4. Review `scope-members.csv` to validate the authorized mailbox population and identify nested groups.
5. Review `credential-expiration.csv` to confirm that application credentials will remain valid through the migration.
6. Review `existing-app-rbac-assignments.csv` for App RBAC configuration that already exists.
7. Use `inventory.json` when the complete dataset is needed for automation or archival.

Use `AppId` as the primary field for correlating records across files. An empty CSV means that no matching records were found for that export. It is not, by itself, an inventory failure.

## application-access-policies.csv

**Purpose:** One row per legacy Exchange Online Application Access Policy. This is the starting point for identifying applications that may need migration.

| Field | Meaning |
|---|---|
| `PolicyIdentity` | Unique Exchange Online identity of the policy. Use this value when a specific policy must be selected or removed. |
| `AppId` | Entra application/client ID to which the policy applies. A wildcard or comma-separated value requires manual review. |
| `AccessRight` | Legacy policy behavior, normally `RestrictAccess` or `DenyAccess`. `DenyAccess` does not have a direct App RBAC equivalent. |
| `Description` | Description stored on the policy. |
| `ScopeIdentity` | Identity Exchange exposes for the policy's scope group. |
| `ScopeDisplayName` | Display name of the resolved mail-enabled scope group. |
| `ScopePrimarySmtpAddress` | Primary SMTP address of the scope group. |
| `ScopeRecipientType` | Exchange recipient type of the scope group. |
| `ScopeDistinguishedName` | Exchange distinguished name used to construct a group-based App RBAC Management Scope. |
| `ScopeExternalDirectoryObjectId` | Entra object ID of the scope group. |

**Customer review:** Confirm that every policy is expected, each App ID has a known owner, and each scope group represents the intended mailbox population.

## applications.csv

**Purpose:** One row per Entra service principal successfully resolved from an App ID in the policy inventory. It correlates the App registration and Enterprise Application objects.

| Field | Meaning |
|---|---|
| `AppId` | Application/client ID used by the workload and Exchange policy. |
| `DisplayName` | Enterprise Application service-principal display name. |
| `ServicePrincipalObjectId` | Enterprise Application object ID. This is the object ID required by Exchange `New-ServicePrincipal -ObjectId`. |
| `ApplicationObjectId` | App registration object ID. Do not use this as the Exchange service-principal object ID. |
| `AccountEnabled` | Whether the Entra service principal is enabled. |
| `ServicePrincipalType` | Entra service-principal type, normally `Application`. |
| `SignInAudience` | Account audience configured on the App registration, such as `AzureADMyOrg`. |
| `CreatedDateTime` | Creation time of the App registration. |
| `ServicePrincipalOwners` | Semicolon-delimited owners of the Enterprise Application. |
| `ApplicationOwners` | Semicolon-delimited owners of the App registration. |
| `Tags` | Semicolon-delimited service-principal tags. |

**Customer review:** Confirm both object IDs, enabled state, and accountable owners. If an App ID does not appear here, check `migration-readiness-issues.csv` for missing Entra objects.

## application-permissions.csv

**Purpose:** One row per Entra application permission currently granted to an inventoried service principal. This file helps determine which broad Entra permission may be replaced by an Exchange App RBAC role.

| Field | Meaning |
|---|---|
| `AppId` | Application/client ID receiving the permission. |
| `ServicePrincipalObjectId` | Object ID of the Enterprise Application receiving the permission. |
| `ResourceName` | API resource that exposes the permission, such as Microsoft Graph. |
| `ResourceAppId` | Application ID of the API resource. |
| `PermissionValue` | Machine-readable permission value, such as `Mail.Read`. |
| `PermissionName` | Human-readable permission name. |
| `AssignmentId` | Entra app-role assignment ID. This identifies the grant that Cutover may remove. |
| `RecommendedExchangeApplicationRole` | Suggested Exchange App RBAC role where the toolkit has a known mapping. |
| `IsKnownApplicationAccessPolicyPermission` | `True` when the toolkit recognizes a possible Exchange role mapping. This is not proof that the mapping meets the workload's requirements. |

**Customer review:** Validate every API operation used by the application. Do not remove an Entra permission merely because a recommended role is populated; confirm functional equivalence and live-test the workload.

## credential-expiration.csv

**Purpose:** One row per certificate or client secret found on the related App registration or Enterprise Application.

| Field | Meaning |
|---|---|
| `AppId` | Application/client ID associated with the credential. |
| `ObjectType` | Entra object holding the credential: `Application` or `ServicePrincipal`. |
| `ObjectId` | Object ID of that Entra object. |
| `CredentialType` | `Certificate` or `ClientSecret`. |
| `DisplayName` | Credential display name recorded in Entra. |
| `KeyId` | Unique identifier of the credential. This is not the certificate thumbprint. |
| `StartDateTime` | Date and time when the credential becomes valid. |
| `EndDateTime` | Credential expiration date and time. |
| `DaysUntilExpiration` | Whole days remaining at inventory time. A negative value means the credential is expired. |

**Customer review:** Confirm which credential the workload actually uses, where its private material is protected, and whether it remains valid through preparation, propagation, cutover, observation, and rollback periods.

## scope-members.csv

**Purpose:** One row per direct member of each resolved policy scope group. The same mailbox can appear more than once when multiple policies use the same group.

| Field | Meaning |
|---|---|
| `PolicyIdentity` | Legacy policy associated with the scope membership. |
| `AppId` | Application/client ID associated with the policy. |
| `ScopeIdentity` | Exchange identity of the scope group. |
| `ScopeDisplayName` | Display name of the scope group. |
| `MemberDisplayName` | Display name of the direct group member. |
| `MemberPrimarySmtpAddress` | Primary SMTP address of the direct member. |
| `MemberExternalDirectoryObjectId` | Entra object ID of the direct member. |
| `MemberRecipientType` | General Exchange recipient type. |
| `MemberRecipientTypeDetails` | More specific Exchange recipient type, such as `SharedMailbox`. |
| `IsNestedGroup` | `True` when the direct member is itself a group. |
| `AppRbacScopeResult` | Explanation of how the direct member behaves in a group-based App RBAC scope. |

**Customer review:** Verify that all intended authorized mailboxes are direct members. App RBAC `MemberOfGroup` scopes do not expand the members inside a nested group.

## existing-app-rbac-assignments.csv

**Purpose:** One row per Exchange Online App RBAC management-role assignment already associated with an inventoried application.

| Field | Meaning |
|---|---|
| `AppId` | Application/client ID represented by the Exchange service-principal pointer. |
| `ExchangeServicePrincipalIdentity` | Object ID used by the Exchange service-principal pointer. |
| `AssignmentName` | Exchange management-role assignment name. |
| `Role` | Exchange application role, such as `Application Mail.Read`. |
| `CustomResourceScope` | Custom Exchange Management Scope applied to the assignment, when present. |
| `RecipientAdministrativeUnitScope` | Entra Administrative Unit scope applied to the assignment, when present. |
| `EffectiveUserName` | Effective assignee information returned by Exchange Online. |

**Customer review:** An empty file means no existing App RBAC assignments were found for the inventoried applications. Existing assignments must be assessed before creating new ones to avoid duplicate or additive access.

## migration-readiness-issues.csv

**Purpose:** One row per condition requiring attention before or during migration. This is a triage report, not an automatic approval or rejection.

| Field | Meaning |
|---|---|
| `Severity` | Toolkit-assigned priority, normally `High` or `Medium`. |
| `AppId` | Application/client ID affected by the finding. |
| `PolicyIdentity` | Related legacy policy when the finding is policy-specific. It can be blank for application-level findings. |
| `Category` | Stable finding type, such as `MissingServicePrincipal`, `NoOwner`, `NestedGroup`, or `CredentialExpiresSoon`. |
| `Detail` | Human-readable explanation of the condition and its migration significance. |

**Customer review:** Resolve High findings before migration unless an approved design explicitly addresses them. Review Medium findings for scheduling, ownership, and operational risk.

Common findings include:

| Category | Interpretation |
|---|---|
| `SharedOrWildcardPolicy` | The policy covers multiple applications or all applications and must be separated before one-app-at-a-time migration. |
| `MissingServicePrincipal` | The Enterprise Application could not be found for the policy App ID. |
| `MissingApplicationObject` | The App registration could not be found for the policy App ID. |
| `MissingScopeIdentity` | Exchange did not expose a usable policy scope identity. |
| `ScopeRecipientLookupFailed` | The recorded scope could not be resolved to a current Exchange recipient. |
| `ScopeMemberEnumerationFailed` | Direct group membership could not be retrieved. |
| `EmptyScopeGroup` | The scope group has no direct members. |
| `DenyAccessPolicy` | The negative legacy scope requires redesign as a positive App RBAC grant. |
| `NestedGroup` | A group is a direct member; its members will not be expanded by `MemberOfGroup`. |
| `NoOwner` | Neither the App registration nor Enterprise Application has an Entra owner. |
| `ExpiredCredential` | A discovered credential is already expired. |
| `CredentialExpiresSoon` | A discovered credential expires within 90 days. |
| `EffectiveAccessTestFailed` | An optional legacy policy test could not be completed for a mailbox. |

## effective-legacy-access.csv

**Purpose:** Optional output created only when `-EvaluateEffectiveAccess` is used. It contains one row per tested App ID and mailbox combination and records the result returned by `Test-ApplicationAccessPolicy`.

| Field | Meaning |
|---|---|
| `AppId` | Application/client ID tested against the mailbox. |
| `MailboxDisplayName` | Mailbox display name. |
| `UserPrincipalName` | Mailbox user principal name used for the policy test. |
| `PrimarySmtpAddress` | Mailbox primary SMTP address. |
| `RecipientTypeDetails` | Specific Exchange mailbox type. |
| `ExternalDirectoryObjectId` | Entra object ID of the mailbox. |
| `CustomAttribute1` | Exchange custom attribute value captured for analysis. |
| `CustomAttribute2` | Exchange custom attribute value captured for analysis. |
| `CustomAttribute3` | Exchange custom attribute value captured for analysis. |
| `AccessCheckResult` | Effective legacy policy result, such as `Granted` or `Denied`. |

**Customer review:** Use this file to establish a legacy access baseline for positive and negative migration testing. A cmdlet result is not a substitute for a live application test.

## inventory.json

**Purpose:** Machine-readable version of the complete inventory. It includes a run summary and the same policy, application, permission, credential, scope-member, App RBAC assignment, issue, and optional effective-access datasets represented by the CSV files.

Use this file for automation, archival, comparison between inventory runs, or ingestion into another reporting system. Use the CSV files for direct customer review and spreadsheet analysis.

## Important interpretation boundaries

- The inventory represents the tenant at the time it was generated. Repeat it immediately before Prepare and after Cleanup to capture changes.
- Entra application permissions and Exchange App RBAC grants are additive while both exist.
- A recommended role is a planning aid, not an approval to remove an Entra permission.
- `DenyAccess`, wildcard, multi-application, unresolved, and nested-group scenarios require explicit remediation or redesign.
- Keep the legacy Application Access Policy through Cutover and the observation window.
- Require both an authorized-mailbox test and an unauthorized-mailbox test before Cleanup.