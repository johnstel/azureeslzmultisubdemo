# Azure Enterprise-Scale Landing Zone — Two-Subscription Demo

> **Version status:** `main` is the **v2 development line** (`2.0.0-dev`).
> Use the stable current implementation at the
> [v1.0.0 release](https://github.com/johnstel/azureeslzmultisubdemo/releases/tag/v1.0.0)
> and the [release/v1 maintenance branch](https://github.com/johnstel/azureeslzmultisubdemo/tree/release/v1).
> Contributors should track planned v2 work in the
> [v2.0.0 milestone](https://github.com/johnstel/azureeslzmultisubdemo/issues?q=milestone%3A%22v2.0.0%22).

> **New to Azure?** Start with the
> [Beginner's Guide](docs/BEGINNERS-GUIDE.md). It explains every Azure concept,
> required ID, permission, command, safety checkpoint, deployment phase, portal
> verification step, and teardown action in plain language, using familiar
> Active Directory concepts such as OUs, security groups, delegated access, and
> GPO inheritance. Keep the
> [First-Run Checklist](docs/FIRST-RUN-CHECKLIST.md) open while operating the
> demo.

Windows PowerShell 7 is the primary operator experience. Equivalent Bash
scripts and instructions are included for macOS and Linux.

This project is a deliberately small, deployable landing-zone demonstration for an
existing Microsoft Entra tenant and **two existing Azure sandbox subscriptions**.
It does not create subscriptions, identities, virtual machines, analytics
services, or any paid always-on service.

The default parameter templates are intentionally non-deployable. They contain
placeholders, keep deny policies in `DoNotEnforce`, and disable both RBAC and
evidence resources. Start with preflight and tenant-scope what-if; only the guarded
deployment script can perform a live deployment.

## Architecture

```text
Tenant root management group (existing; never receives demo policy)
└── Demo root (new dedicated intermediate management group)
    ├── Platform
    │   └── Connectivity
    │       └── Existing connectivity sandbox subscription
    └── Landing Zones
        └── Corp or Online (selected by parameter)
            └── Existing workload sandbox subscription
```

The management-group names are derived from `namePrefix`. For example, a prefix
of `eslz-demo` creates `eslz-demo`, `eslz-demo-platform`,
`eslz-demo-connectivity`, `eslz-demo-landingzones`, and either
`eslz-demo-corp` or `eslz-demo-online`.

## Policy layers

All custom definitions are stored at the dedicated demo root, not the tenant
root:

| Scope | Control | Default effect |
|---|---|---|
| Demo root | Allow only `centralus`, `eastus`, `eastus2`, `northcentralus`, `southcentralus`, `westcentralus`, `westus`, `westus2`, and `westus3` | Deny assignment in `DoNotEnforce` |
| Demo root | Audit creation of public IP address resources | Audit |
| Demo root | Block common costly service types and VM SKUs outside an intentionally small allowlist | Deny assignment in `DoNotEnforce` |
| Demo root | Customer deployment-restrictions initiative: `eastus`/`eastus2`, approved resource types and VM SKUs, managed disks, and public IP creation | Deny members in `DoNotEnforce`; audit members remain Audit |
| Platform | Audit `Owner` and `CostCenter` tags on taggable resources | Audit |
| Landing Zones | Require `CostCenter`, `ApplicationName`, `Owner`, `Environment`, `DataClassification`, and `SSP-ID` tags on resource groups | Initiative assignment in `DoNotEnforce` |
| Landing Zones | Inherit those six tags to taggable child resources only when missing | Modify initiative assignment in `DoNotEnforce` |
| Corp/Online | Audit public inbound SSH/RDP NSG rules and subnets without NSGs | Audit assignment in `DoNotEnforce` |
| Corp/Online and opt-in Critical Infrastructure | Audit selected PaaS public network access and private endpoint readiness | Audit |
| Corp/Online and opt-in Critical Infrastructure | Audit supplied route-table expectations for an approved firewall | Explicit opt-in, Audit |
| Demo root | Microsoft cloud security benchmark (built-in initiative, enabled by default) | Assignment in `DoNotEnforce` |
| Demo root | CIS Microsoft Azure Foundations Benchmark v2.0.0 (built-in initiative, opt-in) | Assignment in `DoNotEnforce` |
| Demo root | NIST SP 800-53 Rev. 5 (built-in initiative, opt-in) | Assignment in `DoNotEnforce` |
| Landing Zones | Storage and Key Vault data-protection initiative: secure transfer, minimum TLS, public blob and network access, shared-key posture, Key Vault soft delete, deletion protection, RBAC authorization, firewall/public network access, private-link and diagnostics readiness, and service-specific customer-managed key audits | Audit assignment in `DoNotEnforce` |
| Demo root | Export subscription Activity Logs to the effective central Log Analytics workspace (built-in) | Assignment in `DoNotEnforce`, policy effect defaults `Disabled` |
| Demo root | Export supported resource diagnostic logs to the effective central Log Analytics workspace (built-in initiative) | Assignment in `DoNotEnforce`, policy effect defaults `AuditIfNotExists` |

The allowed-location policy uses `Indexed` mode, ignores the location-agnostic
`global` value, and excludes the B2C directory resource type, following the
safe shape of Azure's built-in allowed-locations control. Resource groups are
governed separately by a tagging initiative defined at the demo root and
assigned at Landing Zones. Change
`denyPolicyEnforcementMode` to `Default` only after reviewing what-if and the
policy impact. The resource-group tagging initiative composes six instances of
Azure's built-in **Require a tag on resource groups** definition and provides a
tag-specific noncompliance message for each requirement.

The companion tag-inheritance initiative composes six instances of the verified
**Inherit a tag from the resource group if missing** built-in
(`ea3f2387-9b95-492a-a190-fcdc54f7b070`). Its `Indexed` mode limits evaluation
to taggable resources. Each `Modify` operation adds only an absent tag whose
resource-group value is non-empty, so an existing resource value always wins.
The Landing Zones assignment has a system-assigned identity in
`deploymentLocation` and the role declared by the built-in: Contributor
(`b24988ac-6180-42a0-ab88-20f7382dd24c`). The narrower Tag Contributor role
cannot perform the resource update used by this built-in's remediation path.
The assignment, identity, and RBAC are omitted unless
`enableTagInheritance=true`; when enabled, the assignment still inherits the
safe `DoNotEnforce` default and creates no remediation task.

### Deliberately remediate existing resource tags

After an approved deployment with `enableTagInheritance=true`, the
`tagInheritanceRemediation` output provides the assignment ID and six definition
reference IDs. Starting remediation remains a separate operator action. The
scripts validate the live assignment ID, exact Landing Zones scope, initiative,
system identity, non-global location, and exact six built-in references before
showing a no-change preview:

```bash
./scripts/remediate-resource-tags.sh parameters/demo.parameters.json
```

```powershell
.\scripts\remediate-resource-tags.ps1 -ParameterFile .\parameters\demo.parameters.json
```

Only after reviewing that preview, set
`ESLZ_TAG_REMEDIATION_CONFIRMATION=REMEDIATE-MISSING-RESOURCE-TAGS` and rerun
with `--execute` (Bash) or `-Execute` (PowerShell). Both workflows then require
typing the validated tenant, scope, and assignment before revalidating the live
controls and creating six tasks. The PowerShell workflow uses the supported
`Start-AzPolicyRemediation` cmdlet. Do not substitute a different policy or
role: these tasks only add missing values and must not overwrite
customer-supplied resource tags.

Two explicit parameter profiles expose the same controls without committing
customer values: the safe demo JSON template
[`parameters/demo.parameters.template.json`](parameters/demo.parameters.template.json)
and the customer-control Bicep template
[`parameters/customer-control.template.bicepparam`](parameters/customer-control.template.bicepparam).
The customer-control profile is separate from the broader safe demo location
profile. Its `customerAllowedLocations`, `customerAllowedResourceTypes`, and
`customerAllowedVmSkus` parameters are change-controlled allowlists. The
resource-type default includes this project's evidence resources and child
types needed for diagnostics, VM extensions, private endpoints, backup, and
Azure Policy remediation. Both templates retain explicit replacement
placeholders for external identities and resources, keep paid and remediating
switches off, and require `DoNotEnforce` until those lists and a what-if/policy
impact report are approved. Resource diagnostics are `Disabled` until an
operator supplies a canonical `existingLogAnalyticsWorkspaceResourceId` (or
explicitly enables `deployCentralLogAnalytics`), then explicitly selects
`AuditIfNotExists` or `DeployIfNotExists`; the latter also requires the
separate remediation-RBAC opt-ins.

`policyExemptions` is an empty-by-default structured input for time-bound,
customer-approved exemptions. Each supplied record requires its target scope,
policy assignment ID, owner, justification, expiry, ticket/reference,
approver, and creation/review metadata; initiative reference IDs and permitted
ancestor scopes are explicit optional arrays. Records are validated by the
governed exemption module and no exemption is created by either profile unless
a complete record is supplied.

The workload network-ingress initiative recognizes `*`, `Internet`,
`0.0.0.0/0`, and arbitrary public IPv4 host/CIDR source values in singular and
array NSG aliases. Private, non-routable/reserved IPv4 ranges and supported
Azure service tags are not treated as public. TCP or any-protocol destination
ranges are parsed so ranges containing `22` or `3389` are detected alongside
exact and wildcard ports. It is not assigned to Platform or Connectivity.
Exceptional public paths or special-purpose workload subnets must use a
documented, time-bound Azure Policy exemption. The existing demo-root
public-IP audit remains the only public-IP resource control.

For rollout phasing, prefer resource selectors or `DoNotEnforce` assignment
mode. Use an exemption only when a specific deployed scope needs a reviewed,
ticketed exception with a mandatory owner and expiry.

### Storage, Key Vault, and customer-managed keys

The Landing Zones data-protection initiative composes verified built-in
definitions for storage secure transfer, minimum TLS version, public blob
access, network access, shared-key authorization, and for Key Vault soft
delete, deletion (purge) protection, RBAC authorization, firewall/public
network access, and resource-log readiness. Private-link readiness for both
services is owned by the private-access initiative described below
(REQ-NET-04 and REQ-NET-05), so it is not repeated here. `dataProtectionPolicyEffect` defaults to `Audit`; controls whose
built-in supports only `Audit`/`Disabled` or `AuditIfNotExists`/`Disabled`
follow that choice without ever being escalated to `Deny`. Purge protection is
only ever audited or required, never disabled: it is bound to a dedicated
`purgeProtectionEffect` that allows `Audit` or `Deny` only, so selecting
`Disabled` for `dataProtectionPolicyEffect` still leaves that control auditing.

Each built-in member is pinned to the exact major version recorded in
`policy/control-catalog.json` (for example `2.*.*`) through the reusable
`definitionVersion` support in `modules/policy-initiative.bicep`, so a future
major revision of a built-in never changes the assignment's behaviour without
review. The in-repository custom member is intentionally unpinned, because
`definitionVersion` applies only to built-in definitions.

The public-access and diagnostics controls audit configuration and readiness
only. They do not deploy a private endpoint, private DNS zone, virtual
network, or diagnostic setting, so a compliant result must not be reported as
delivered private connectivity or delivered logging.

Customer-managed key (CMK) coverage is service-specific and audit-first, not a
blanket deny across every Azure service. The verified storage CMK built-in only
confirms that encryption uses a Key Vault key source, so the in-repository
`${namePrefix}-audit-storage-cmk-approved-key` definition adds the approved
inventory check driven by the `approvedCustomerManagedKeyVaultUris` and
`approvedCustomerManagedKeyNames` parameters. Both default to empty, which
reports nothing. Before enabling CMK, the customer owns these dependencies:

- **Identity:** a managed identity granted `get`, `wrapKey`, and `unwrapKey` on
  the key. This repository never grants key access or changes data-plane
  permissions.
- **Key rotation:** a documented rotation process and the re-wrap behavior of
  each service that consumes the key.
- **Availability:** a deleted, disabled, expired, or purged key makes encrypted
  data unreadable, so key lifecycle must be monitored.
- **Recovery:** Key Vault soft delete and purge protection must stay enabled;
  purge protection must never be disabled once enabled.
- **Private network:** when vault public network access is restricted, the
  consuming service needs approved private connectivity that the customer
  deploys and operates.

### Private access and firewall-route guardrails

The private-access initiative audits Storage and Key Vault public network
access plus the applicable built-in private-link posture. It is scoped only to
the workload branch and, when enabled, Critical Infrastructure; Platform and
Connectivity are excluded. `privateAccessPublicNetworkPolicyEffect` defaults
to `Audit`. Do not select `Deny` until each workload has an approved private
endpoint, private DNS-zone links and records, endpoint approval, subnet
connectivity, and a tested management and data-plane access path.

`enableFirewallRouteGuardrails` defaults to `false`. Enabling it requires
non-empty `approvedFirewallResourceId`, `approvedFirewallPrivateIp`,
`approvedRouteTableResourceIds`, and `approvedRouteTablePrefixes`; no
placeholder is accepted or inferred. The resulting audit checks only supplied
route tables and prefixes for a virtual-appliance next hop using the approved
private IP. It does not deploy or prove the firewall, VNet peering, private
DNS, private endpoints, subnet associations, route propagation, or end-to-end
traffic traversal. Those are customer-owned hub-routing architecture and
operational-validation dependencies, separate from Azure Policy evidence.

### Backup coverage and vault posture

The `demo-backup-posture` initiative is assigned to the Landing Zones branch
and is audit-first: it reports virtual machines without Azure Backup coverage
(`vmBackupCoveragePolicyEffect`) and Recovery Services vault public network
access (`vaultPublicNetworkPolicyEffect`), customer-managed-key encryption
(`vaultEncryptionPolicyEffect` plus `vaultDoubleEncryptionRequired`),
immutability (`vaultImmutabilityPolicyEffect` plus
`vaultCheckLockedImmutabilityOnly`), soft delete
(`vaultSoftDeletePolicyEffect` plus `vaultCheckAlwaysOnSoftDeleteOnly`), and
multi-user authorization (`vaultMultiUserAuthorizationPolicyEffect`). Auditing
creates no vault, no backup policy, and no protection relationship, and it
never changes a setting on an existing vault.

Soft delete and multi-user authorization use their own verified built-ins
(`31b8092a-36b8-434b-9af7-5ec844364148` and
`c7031eab-0fc0-4cd9-acd0-4497bd66d91a`), catalogued as REQ-BKP-08 and
REQ-BKP-09. `vaultCheckAlwaysOnSoftDeleteOnly` defaults to `false`, so
`Enabled` and `AlwaysOn` are both compliant; `AlwaysOn` is irreversible and is
therefore opt-in. Multi-user authorization depends on a customer-owned
Resource Guard that this template never creates. The public-network-access
control evaluates the vault's `publicNetworkAccess` property only — it does not
prove that private endpoints, private DNS, or private connectivity exist.

Approved **existing** vaults and backup policies are the preferred integration
path. Supply them through `approvedVaultRegions` and `approvedBackupVaults`,
where each entry records `workload`, `region`, `vaultResourceId`,
`backupPolicyResourceId`, and `inclusionTagValues`. Each entry is validated:
vault and backup policy IDs must be canonical absolute ARM resource IDs (a
`/subscriptions/<guid>/resourceGroups/...` path with valid resource-name
segments), the region must be an approved vault region, and the backup policy
must live in the referenced vault.

The mapping is composite: `workload` plus `region` must be unique, so one
workload can appear in several regions and one region can host several
workloads. The built-in that configures backup targets virtual machines by
**location plus inclusion tag value only** — the `workload` field is
documentation that names the assignment, not a policy condition — so two
records in the same region must not share an inclusion tag value, or their
assignments would compete for the same virtual machines. A Recovery Services
vault is a single-region resource and the built-in protects only virtual
machines colocated with the vault, so each `vaultResourceId` must map to
exactly one region: covering several regions requires a separate vault per
region.

The built-in places its remediation deployment in the subscription and
resource group parsed from the supplied `backupPolicyId`, so a vault in a
central backup subscription is supported. That placement is not assumed:
`allowCrossSubscriptionBackupVaults` (default `false`) must be set explicitly
to accept a vault outside the workload and critical-infrastructure
subscriptions, and the assignment identity then needs Backup Contributor in
that vault's subscription. `backupRetentionStandardId` records which customer
retention standard applies — no universal retention period is defined for
every workload.

`enableVmBackupRemediation` defaults to `false` and cannot be enabled without
valid `approvedBackupVaults` entries, a `vmBackupInclusionTagName`, and a
documented `backupRetentionStandardId`. When enabled, one remediating
assignment per approved vault record is created with a system-assigned
identity, the deployment region, and the built-in Virtual Machine Contributor
and Backup Contributor roles. `vmBackupConfigurationEffect` stays
`AuditIfNotExists` until `DeployIfNotExists` is selected deliberately.

This template never starts a remediation task. It is not the only way virtual
machines get protected: a `DeployIfNotExists` effect assigned with
`denyPolicyEnforcementMode = 'Default'` also protects **new or updated**
matching virtual machines automatically, without any remediation task, and
each protected instance is metered. The safe default keeps
`denyPolicyEnforcementMode = 'DoNotEnforce'`, so nothing deploys until both
the effect and the enforcement mode are changed deliberately. The
`backupRemediation` output reports `vmBackupEnforcementMode` and
`vmBackupAutomaticProtectionOnResourceWrite` alongside the assignment IDs and
identity principal IDs so a remediation of pre-existing virtual machines can
be started separately after review.

`enableVaultDiagnostics` (default `false`) assigns the verified built-in
resource-diagnostics initiative restricted to
`microsoft.recoveryservices/vaults`, sending vault logs to the effective
central monitoring workspace. It requires `deployCentralLogAnalytics=true` or
an `existingLogAnalyticsWorkspaceResourceId`.

Diagnostics behave like any other `DeployIfNotExists` control: with
`vaultDiagnosticsEffect = 'DeployIfNotExists'` and
`denyPolicyEnforcementMode = 'Default'`, diagnostic settings are created
**automatically** on vault create or update, without any remediation task, and
every stream then billed for Log Analytics ingestion and retention. The safe
default keeps `AuditIfNotExists` and `DoNotEnforce`, so nothing is deployed and
no ingestion cost is incurred until both are changed deliberately. The
`backupRemediation` output reports `vaultDiagnosticsEnforcementMode` and
`vaultDiagnosticsAutomaticSettingsOnResourceWrite` next to
`vaultDiagnosticsPrincipalId` and `vaultDiagnosticsWorkspaceResourceId`.

Least privilege follows the effect. With the default `AuditIfNotExists` — or
with `Disabled` — the control is assigned through the identity-free assignment
module, so **no** managed identity is created and **no** role assignment is made
anywhere. Only `vaultDiagnosticsEffect = 'DeployIfNotExists'` uses the
remediating assignment that attaches a system-assigned identity and grants Log
Analytics Contributor; `backupRemediation.vaultDiagnosticsIdentityAttached`
reports which path is active, and `vaultDiagnosticsRoleDefinitionIds` is empty on
the audit path.

That identity is granted Log Analytics Contributor at the assigned Landing Zones
scope, which does **not** cover a workspace in the connectivity subscription or
in a customer subscription, so a `DeployIfNotExists` deployment would fail there.
`grantVaultDiagnosticsWorkspaceAccess` (default `false`) creates the missing
least-privilege role assignment — only Log Analytics Contributor, only on the
effective workspace resource. It requires `enableVaultDiagnostics=true`,
`vaultDiagnosticsEffect = 'DeployIfNotExists'`, and a canonical absolute
effective workspace resource ID of the form
`/subscriptions/<guid>/resourceGroups/<name>/providers/Microsoft.OperationalInsights/workspaces/<name>`
with no surrounding whitespace; an audit or disabled effect can therefore never
grant a role. The resulting role assignment IDs are returned in
`backupRemediation.vaultDiagnosticsWorkspaceRoleAssignmentIds`.

`deployRecoveryServicesVault` (default `false`) is the only switch that creates
a **metered, customer-owned** vault and backup policy, in a
`rg-<namePrefix>-backup` resource group tagged `CostModel=Metered` and
`Ownership=Customer-owned`. It is rejected when `approvedBackupVaults` records
are supplied, and it additionally requires a non-empty `approvedVaultRegions`
list that contains `recoveryServicesVaultLocation` and a documented
`backupRetentionStandardId`, so no metered vault can be created in an
unapproved region or tagged with an undocumented retention standard. Retention
and protection posture are parameterized through `backupDailyRetentionInDays`,
`backupWeeklyRetentionInWeeks`, `backupMonthlyRetentionInMonths`,
`backupYearlyRetentionInYears`, `vaultSoftDeleteState`,
`vaultSoftDeleteRetentionInDays`, and `vaultImmutabilityState` (`Locked` is
irreversible; `Unlocked` is the default). The created vault sets
`publicNetworkAccess` to `Disabled` by default; a private endpoint, its
subnet, and the `privatelink.<region>.backup.windowsazure.com` private DNS
zone remain separate customer-owned prerequisites that this template does not
create, so plan them before backup traffic is expected to work. No existing
vault is ever deleted or replaced, and no live virtual machine is backed up by
this template.

### Security benchmark and optional compliance overlays

The demo root assigns the stable **Microsoft cloud security benchmark** (MCSB)
built-in initiative (`1f3afdf9-d0c9-4c3d-847f-89da613e70a8`) by default through
`enableMicrosoftCloudSecurityBenchmark`. Two overlays are independently opt-in
and disabled by default:

| Parameter | Built-in initiative | Pinned version | Default |
|---|---|---|---|
| `enableMicrosoftCloudSecurityBenchmark` | Microsoft cloud security benchmark | `57.*.*` | `true` |
| `enableCisAzureFoundationsBenchmark` | CIS Microsoft Azure Foundations Benchmark v2.0.0 | `1.*.*` | `false` |
| `enableNistSp80053Rev5` | NIST SP 800-53 Rev. 5 | `14.*.*` | `false` |

Every initiative ID and pinned major version traces to
[`policy/control-catalog.json`](policy/control-catalog.json) (REQ-BASE-01
through REQ-BASE-03) and the generated
[control matrix](docs/CONTROL-MATRIX.md). Assignments are made only at the
dedicated demo root — never at the tenant root — and reuse
`denyPolicyEnforcementMode`, so the safe default remains a non-enforcing
`DoNotEnforce` audit posture.

Version behavior and previews:

- Each assignment pins the supported major version (for example `57.*.*`), so
  Azure picks up minor and patch updates of the same major version without
  silently adopting a new major revision. MCSB's built-in definition is updated
  in place very frequently; re-verify its current version before promoting the
  assignment to `Default`.
- Preview or superseded initiatives are never selected automatically. The
  separate *Microsoft cloud security benchmark v2*
  (`e3ec7e09-768c-4b64-882c-fcada3772047`), *NIST SP 800-53 R5.1.1*
  (`60205a79-6280-4e20-a147-e2011e09dc78`), and *CIS v1.4.0*
  (`c3f5c4d9-9a1d-4a99-85c0-7f93e384d5c5`) initiatives are documented in the
  catalog only and must be independently re-verified before any future switch.
- MCSB and CIS are audit-only, so their assignments request no managed identity.
  NIST SP 800-53 Rev. 5 contains four fixed Guest Configuration
  `DeployIfNotExists`/`Modify` members, so enabling it creates a system-assigned
  identity granted only the verified Contributor role
  (`b24988ac-6180-42a0-ab88-20f7382dd24c`) at the demo root.

Overlap with the organizational controls above is intentional: the data
protection, network, and logging controls in these benchmarks are the
authoritative source of truth, so this repository does not create duplicate
custom definitions for the same intent. There is also **no** single assignable
"Azure Security Baseline" initiative — Azure service security baselines (for
example Storage, Key Vault, and Compute) are Microsoft Learn guidance that maps
into individual service controls (REQ-BASE-04), not one initiative.

Assigning any of these initiatives produces compliance signal only. It does not
by itself establish, claim, or certify regulatory compliance, and no Defender
for Cloud plan is enabled by these assignments.

### Reusable initiative composition

`modules/policy-initiative.bicep` creates a custom initiative at its caller's
management-group scope. It accepts initiative parameter definitions, typed
policy references and groups, rejects empty or case-insensitively duplicate
reference IDs, records v2 Bicep-managed metadata, and exposes deterministic
definition outputs for later assignment modules.

`examples/initiative-composition.bicep` is a compile-time example scoped only
to a supplied dedicated demo-root management group. It combines the verified
built-in allowed-locations definition with the in-repository public-IP audit
definition, passes audit-first initiative parameters through to the built-in,
and creates no assignment or metered resource. The example is not called by
`main.bicep`; the deployed domain initiatives (workload network ingress and
Landing Zones data protection) are composed directly in `main.bicep` from the
authoritative [`policy/control-catalog.json`](policy/control-catalog.json).

### Reusable governed policy exemptions

`modules/policy-exemption.bicep` creates traceable, expiring Azure Policy
exemptions at management-group, subscription, or resource-group scope by using
`exemptionScopeType` with matching scope inputs. It requires assignment ID,
display name, description, exemption category (`Waiver` or `Mitigated`),
accountable owner, justification, expiry, and ticket/evidence reference.
Metadata always records source, approver, created/reviewed UTC dates, and v2
governance ownership. Initiative-specific exemptions can optionally set
`policyDefinitionReferenceIds` and must provide an explicit
`allowedPolicyDefinitionReferenceIds` allowlist when doing so.

The module enforces canonical RFC3339 UTC timestamp format and valid calendar
dates. Approval workflows and operator preflight are responsible for ensuring
the expiry is in the future at execution time.

Use `Mitigated` when compensating controls are already in place, and `Waiver`
when accepting temporary risk with explicit sign-off. Do not use exemptions as
an untracked replacement for remediation, selector-based rollout, or
`DoNotEnforce` pilot assignments.

## Least-privilege RBAC model

Bicep does not create Microsoft Entra identities. The repeatable main deployment
accepts the object IDs of four baseline **security groups**:

| Group parameter | Assignment |
|---|---|
| `governanceAdminsGroupObjectId` | Management Group Contributor and Resource Policy Contributor at the demo root |
| `networkOperatorsGroupObjectId` | Network Contributor on the connectivity subscription |
| `workloadContributorsGroupObjectId` | Contributor on the workload subscription |
| `readOnlyAuditorsGroupObjectId` | Reader at the demo root |

Ordinary RBAC is disabled by default with `deployRoleAssignments=false`.
Enabling ordinary RBAC does not grant Owner. `main.bicep` contains no Owner
eligibility request, so normal redeployment cannot replay a one-time PIM
request. The deployment principal needs enough existing access to create the
ordinary assignments; the template never bootstraps its own authority.

PIM-ready Owner is handled separately by the one-shot Bash and PowerShell
operator workflows in `scripts/owner-eligibility-request.*`. They require a
fresh caller-supplied request GUID and finite schedule, verify the exact object
is an existing security-enabled group, check current eligibility and pending
requests, and run what-if before stopping by default. Direct use of the backing
Bicep artifact is unsupported. Approval, MFA, activation justification,
four-hour activation duration, and notification expectations remain a static
report-only contract in
`identity/azure-rbac/owner-activation-requirements.template.json`; configure
and verify those PIM role settings separately at both subscriptions before
opting in. See [PIM-ready Azure RBAC](docs/AZURE-RBAC-PIM.md).

## Entra Conditional Access and PIM (identity governance, not Azure Policy)

Azure Policy cannot require MFA, block legacy authentication, or govern
privileged-role activation. `identity/` contains report-only Conditional Access
and PIM activation requirements for later, separately reviewed use. The
directory-role artifacts use Microsoft Graph concepts; the Azure RBAC Owner
requirements govern the separately opt-in ARM eligibility schedule. This
repository never modifies Entra ID or enables Conditional Access. The isolated
Owner operator workflow performs one read-only Entra group lookup; normal
deployment and offline validators do not. Every artifact defaults to
report-only/eligible; directory controls require a real emergency-access
exclusion, while the Azure RBAC contract keeps emergency access entirely
customer-managed and outside the repository. See the
[Entra Conditional Access and PIM runbook](docs/ENTRA-CONDITIONAL-ACCESS-PIM.md)
for licensing, required directory roles, workload-identity guidance, rollout
order, monitoring, and rollback. Validate these artifacts locally with:

```bash
./scripts/validate-identity-artifacts.sh
```

```powershell
.\scripts\validate-identity-artifacts.ps1
```

## Service-principal and access-review governance

Standing privileged permissions are reviewed with evidence, not removed by
automation. `scripts/review-privileged-access.sh` and
`scripts/review-privileged-access.ps1` produce an identical read-only
inventory of Azure role assignments for an explicitly supplied tenant,
subscriptions, and optional management groups. They highlight Owner, User
Access Administrator, and other high-privilege roles, broad management-group
or subscription scopes, and every direct service-principal or managed-identity
grant, and they count Owner principals per subscription, including Owners
inherited from a management group. Results from inherited queries are
deduplicated by role-assignment ID while recording which requested
subscriptions observed each grant. The scripts change nothing, never call
Microsoft Graph, and never conclude that a grant is excessive; the criteria
that decide what is surfaced live in `policy/access-review-criteria.json`.

```bash
./scripts/review-privileged-access.sh \
  --tenant-id <tenant-guid> \
  --subscription-id <subscription-guid>
```

Reports are written to the source-control-ignored `.access-reviews/`
directory, contain no secrets or display names, and belong in the customer's
evidence store. See
[Service-principal and privileged access reviews](docs/ACCESS-REVIEWS.md) for
the Entra access-review cadence, reviewer ownership, evidence retention, the
remediation decision workflow, and how Defender CSPM CIEM complements the
inventory when licensed.

## Cost rationale

With `deployEvidenceResources=false`, the project creates only governance-plane
objects (management groups, policies, assignments, and optionally RBAC), which
do not incur Azure resource consumption charges.

With evidence enabled, it adds:

- one tagged resource group in each sandbox subscription;
- one small VNet and NSG in the connectivity resource group.

VNets, NSGs, and resource groups have no hourly charge by themselves. There is
no NAT Gateway, VPN Gateway, Firewall, Bastion, public IP, VM, Log Analytics
workspace, storage account, or other metered service. Azure pricing can change,
so confirm the current Azure pricing pages before using this beyond a demo.

### Optional central monitoring

By default (`deployCentralLogAnalytics=false`, `deploySentinel=false`,
`existingLogAnalyticsWorkspaceResourceId=''`), the project creates **no**
Log Analytics workspace and enables **no** Microsoft Sentinel resources. This
is the safe default and incurs no monitoring cost.

Two opt-in paths exist for centralized monitoring in the connectivity
subscription, and only one may be used at a time:

- **Reuse an existing customer-owned workspace** (recommended default
  integration path): set `existingLogAnalyticsWorkspaceResourceId` to the
  resource ID of an existing Log Analytics workspace. No workspace is created
  or modified; the demo only reads the ID to compute the effective workspace
  ID used by downstream modules.
- **Create a new central workspace**: set `deployCentralLogAnalytics=true`.
  This creates a metered Log Analytics workspace (data ingestion and
  retention charges apply) in a new `rg-<namePrefix>-monitoring` resource
  group. This must not be combined with `existingLogAnalyticsWorkspaceResourceId`.

Setting both `deployCentralLogAnalytics=true` and
`existingLogAnalyticsWorkspaceResourceId` at the same time, or setting
`deploySentinel=true` without either a new or an existing workspace
configured, is an invalid configuration. Rather than silently deploying
nothing or returning an empty effective workspace ID, the module fails the
deployment explicitly with a configuration-error resource so the mistake is
caught immediately.

Setting `deploySentinel=true` additionally onboards Microsoft Sentinel onto
the effective workspace (new or existing), which adds per-GB Sentinel
analysis charges on top of Log Analytics ingestion cost. This module does not
configure analytics rules, automation rules, connectors, workbooks,
incidents, or Defender plans, and it never deletes or replaces a supplied
existing workspace. Teardown only deletes the `rg-<namePrefix>-monitoring`
resource group when `deployCentralLogAnalytics=true` **and** no existing
workspace ID was supplied (that is, only when this project actually created
it); a conflicting configuration never creates the group, so teardown never
deletes it either. Teardown also parses `existingLogAnalyticsWorkspaceResourceId`
and skips deleting any resource group — including the generated
`rg-<namePrefix>-connectivity` group — whose subscription and name match the
supplied existing workspace, even if the names happen to collide.

The demo root also assigns two remediation-capable built-ins for Activity Log
and supported-resource diagnostics export. Both assignments use
system-assigned identities and never start remediation tasks automatically.
They consume the same effective workspace ID output used by central
monitoring. If either assignment effect is enabled (`DeployIfNotExists` for
Activity Logs or `AuditIfNotExists`/`DeployIfNotExists` for resource
diagnostics) without a valid effective workspace ID in the exact form
`/subscriptions/<guid>/resourceGroups/<name>/providers/Microsoft.OperationalInsights/workspaces/<name>`,
template validation fails explicitly.

Remediation RBAC grants for these logging assignments are separately opt-in.
Set both `deployRoleAssignments=true` and
`deployLoggingRemediationRoleAssignments=true` to allow role assignment
creation. In audit/disabled modes, no logging remediation-role grants are
created.

`resourceDiagnosticsCategoryGroup` selects the built-in initiative profile:
`audit` (default) or `allLogs`. Coverage is limited to the resource types
included by the selected Microsoft-built initiative; unsupported resource types
are intentionally not claimed as covered here. Extend unsupported types by
adding and assigning explicit custom diagnostics policies or a custom initiative
in this repository after verifying required aliases, categories, and
least-privilege remediation roles.

### Optional customer-owned backup vault

With `deployRecoveryServicesVault=false` (the default), no Recovery Services
vault, backup policy, or protected item is created, so backup governance stays
audit-only and adds no cost. A Recovery Services vault itself has no hourly
charge, but protected instances and backup storage are metered, which is why
vault creation is explicit, tagged as metered and customer-owned, and never
combined with approved existing vault records. Enabling backup remediation
does not protect anything by itself: pre-existing virtual machines are
protected only by a remediation task, which this project never starts. With
`vmBackupConfigurationEffect = 'DeployIfNotExists'` **and**
`denyPolicyEnforcementMode = 'Default'`, however, matching virtual machines are
also protected automatically when they are created or updated, and every
protected instance and its backup storage are metered. Both switches are
therefore deliberate cost decisions.

### Microsoft Defender for Cloud governance markers

This project assigns Microsoft Defender CSPM (Cloud Security Posture
Management, including CIEM findings), Defender for Servers, and Defender for
Storage, each behind its own explicit, safe-by-default (`false`) opt-in
parameter: `enableDefenderCspm`, `enableDefenderForServers`,
`enableDefenderForStorage`. While a parameter stays `false` (the default),
the corresponding assignment creates **no managed identity at all**
(`identity.type` is `None`) and its `effect` is `Disabled`, so a normal
deployment of this project can never enable a paid plan, incur license cost,
or create any standing identity or role. A free, audit-only policy that
checks for a supported vulnerability assessment solution on virtual machines
is also always assigned (no parameter); it never deploys a scanner and never
depends on a paid plan. Two further free, audit-only policies — one for
Windows, one for Linux — check that the current, supported Azure Monitor
Agent is present on virtual machines; like the vulnerability-assessment
audit, they require no identity, no role, and no opt-in.

Setting an `enableDefender*` parameter to `true` only flips that plan's
`identity.type` to `SystemAssigned` and its `effect` to
`DeployIfNotExists` — it still never grants that identity any role. These
three paid-plan built-ins only support remediation via the Owner role at the
subscription scope, and this project's automatic RBAC granting deliberately
refuses to grant Owner or User Access Administrator to any managed identity
(see `modules/remediating-policy-assignment.bicep`) as a
privilege-escalation guardrail. A single management-group-scoped identity
inherited across every descendant subscription would be Owner everywhere at
once, which is too broad a blast radius to grant automatically or even
semi-automatically. Opting in therefore fails closed: the identity exists
but is role-less until a customer separately, and temporarily, authorizes
Owner outside this template — following the same fail-closed,
separately-approved, time-bounded posture documented in
`docs/AZURE-RBAC-PIM.md` (that workflow targets a different principal type
and scope and is not invoked directly by these assignments, but is the
established precedent to follow rather than granting standing Owner).
Enabling any of these plans still requires the customer to review current
Defender plan licensing/per-resource pricing and any role assignments
Microsoft's own tooling then requires.

Each built-in's own extension parameters beyond `effect` are explicitly
modeled in `modules/defender-plan-assignment.bicep` — defaulted to match the
built-in's own verified default so behavior is unchanged, but now named,
documented, and auditable rather than silently inherited. Two of these are
also exposed at the top level of this project: `enableDefenderCiem` (default
`true`, only applies when `enableDefenderCspm` is `true`) explicitly toggles
the CSPM plan's Entra Permissions Management (CIEM) extension by name, per
issue #20; `defenderForServersSubPlan` (default `P2`) and
`defenderForServersAgentlessVmScanningEnabled` (default `true`) explicitly
choose the Defender for Servers sub-plan and its agentless-VM-scanning
extension, so this project makes and documents that choice itself instead of
leaving it to whatever a customer separately selects in Defender for Cloud
later. Microsoft documents agentless VM scanning as supported only on the
Servers P2 sub-plan, so `modules/defender-plan-assignment.bicep` fails
deployment rather than silently accepting `defenderForServersSubPlan = 'P1'`
together with agentless scanning still requested. This project still never
configures or claims to configure the Azure Monitor Agent itself — the two
AMA audit policies above only audit current agent presence, independent of
any paid plan.

This project never silently enables Defender plans, configures Microsoft
Sentinel analytics/incidents, or claims that any of these controls alone
prove Microsoft Cloud Security Benchmark (MCSB) or
regulatory-compliance-dashboard compliance; see `docs/CONTROL-MATRIX.md` for
the full REQ-DEF-01 through REQ-DEF-09 mapping, and
`docs/NERC-CIP-MATRIX.md` for NERC CIP shared-responsibility evidence
boundaries, including why the
all-or-nothing "Configure Microsoft Defender for Cloud plans" initiative and
the deprecated Log Analytics (MMA) auto-provisioning policy are intentionally
never assigned. REQ-DEF-09 separately documents Foundational CSPM — the free
Defender for Cloud baseline that populates the audit-only controls above —
as its own catalog entry distinct from the paid Defender CSPM plan
(REQ-DEF-02): Foundational CSPM is configured via the
`Microsoft.Security/pricings` `CloudPosture` resource's Free pricing tier at
subscription scope, not an Azure Policy assignment, so this template
intentionally never deploys it (out of scope: modifying a live
subscription). Foundational CSPM's enabled/disabled state on an existing
subscription is whatever a customer has separately configured — it is not
tied to whether REQ-DEF-02 is ever opted in — but starting October 27, 2026
Microsoft stops auto-enabling it only for newly created Azure subscriptions;
customers must explicitly opt in per new subscription outside this template
(existing subscriptions are unaffected). See REQ-DEF-09's notes in
`policy/control-catalog.json` for the verified source.

## Required permissions

The person or service principal running the deployment must have:

1. permission to create child management groups under the supplied tenant-root
   management group and to write policy definitions/assignments at the demo
   hierarchy;
2. permission to move both existing subscriptions into the new hierarchy;
3. Owner or Role Based Access Control Administrator at each target scope when
   `deployRoleAssignments=true`;
4. Contributor on both subscriptions when `deployEvidenceResources=true`;
5. Owner or Role Based Access Control Administrator at the Landing Zones
   management group when `enableVmBackupRemediation=true`, or when
   `enableVaultDiagnostics=true` **and**
   `vaultDiagnosticsEffect = 'DeployIfNotExists'`, because only those
   assignments create a system-assigned identity and grant it Virtual Machine
   Contributor plus Backup Contributor (backup) or Log Analytics Contributor
   (diagnostics). An `AuditIfNotExists` or `Disabled` diagnostics assignment
   needs no identity and no role assignment;
6. Backup Contributor for the backup remediation identity in the vault's own
   subscription when `allowCrossSubscriptionBackupVaults=true`, since the
   built-in deploys the protected item into that subscription and this
   template only grants roles inside the assignment scope;
7. Owner or Role Based Access Control Administrator on the resource group that
   holds the effective Log Analytics workspace when
   `grantVaultDiagnosticsWorkspaceAccess=true`, so the deployment can grant the
   diagnostics identity Log Analytics Contributor on that workspace; the
   workspace resource group is in the connectivity subscription when
   `deployCentralLogAnalytics=true`, or in whichever subscription
   `existingLogAnalyticsWorkspaceResourceId` points to. Without that grant, a
   `DeployIfNotExists` diagnostics remediation fails outside the assignment
   scope;
8. Contributor on the workload subscription when
   `deployRecoveryServicesVault=true`, because the optional vault, its
   resource group, and its backup policy are created at subscription scope.

In many tenants, a Global Administrator must first enable **Access management
for Azure resources** so the initial tenant-level operator can receive User
Access Administrator at root. Use that elevation only for bootstrap and remove
it afterward. This project does not grant Microsoft Entra directory roles.

## Clone the repository

Install [Git](https://git-scm.com/downloads) if the `git` command is not already
available, then clone the repository and move into its folder.

Windows PowerShell:

```powershell
New-Item -ItemType Directory -Path "$HOME\Code" -Force | Out-Null
Set-Location "$HOME\Code"
git clone https://github.com/johnstel/azureeslzmultisubdemo.git
Set-Location .\azureeslzmultisubdemo
```

macOS or Linux:

```bash
mkdir -p ~/Code
cd ~/Code
git clone https://github.com/johnstel/azureeslzmultisubdemo.git
cd azureeslzmultisubdemo
```

Run the remaining commands from the `azureeslzmultisubdemo` folder.

## Prepare parameters

Windows PowerShell (primary):

```powershell
Copy-Item .\parameters\demo.parameters.template.json .\parameters\demo.parameters.json
```

macOS or Linux:

```bash
cp parameters/demo.parameters.template.json parameters/demo.parameters.json
```

Replace every `REPLACE_WITH_*` value. Use subscription GUIDs, Entra security
group object IDs, and the existing tenant-root management-group ID. The two
subscription IDs must be different. Keep the demo prefix unique and 3–24
characters using lowercase letters, numbers, and hyphens.

For a first review, retain:

```json
"denyPolicyEnforcementMode": { "value": "DoNotEnforce" },
"dataProtectionPolicyEffect": { "value": "Audit" },
"deployRoleAssignments": { "value": false },
"deployEvidenceResources": { "value": false },
"enableTagInheritance": { "value": false }
```

Benchmark defaults keep only the stable MCSB baseline enabled; add the CIS or
NIST overlays independently after reviewing their impact:

```json
"enableMicrosoftCloudSecurityBenchmark": { "value": true },
"enableCisAzureFoundationsBenchmark": { "value": false },
"enableNistSp80053Rev5": { "value": false }
```

An equivalent Bicep parameter template is provided at
`parameters/main.template.bicepparam`.

## Validate and preview

These commands are read-only with respect to Azure resources.

Windows PowerShell (primary):

```powershell
.\scripts\preflight.ps1 -ParameterFile .\parameters\demo.parameters.json
.\scripts\what-if.ps1 -ParameterFile .\parameters\demo.parameters.json
```

macOS or Linux:

```bash
./scripts/preflight.sh parameters/demo.parameters.json
./scripts/what-if.sh parameters/demo.parameters.json
```

Preflight builds every Bicep entry point, rejects placeholders and malformed or
duplicate IDs, checks the signed-in tenant, confirms both subscriptions exist
and are enabled, and verifies that the tenant-root management group can be read.
What-if runs a tenant-scope preview but does not deploy.

You can also run local tests without signing in.

Windows PowerShell:

```powershell
.\tests\test.ps1
```

macOS or Linux:

```bash
./tests/test.sh
```

## Deploy (explicit opt-in only)

No deployment has been run as part of this project. To deliberately deploy
after reviewing what-if:

Windows PowerShell (primary):

```powershell
$env:ESLZ_DEPLOY_CONFIRMATION = "DEPLOY-ESLZ-DEMO"
.\scripts\deploy.ps1 -ParameterFile .\parameters\demo.parameters.json
```

macOS or Linux:

```bash
export ESLZ_DEPLOY_CONFIRMATION="DEPLOY-ESLZ-DEMO"
./scripts/deploy.sh parameters/demo.parameters.json
```

The script runs preflight and what-if again before asking for an interactive
confirmation. It then creates a named tenant deployment. Do not use the script
against production subscriptions.

## Migrate the legacy resource-group tag policy

Existing deployments may retain the former workload-scoped assignment and
custom definition after the replacement demo-root initiative and Landing Zones
assignment are deployed.
First review what-if, deploy the replacement, and obtain approval. Then preview
the migration; preview mode performs no Azure operation:

```powershell
.\scripts\migrate-legacy-rg-tags.ps1 -ParameterFile .\parameters\demo.parameters.json
```

```bash
./scripts/migrate-legacy-rg-tags.sh parameters/demo.parameters.json
```

Only after the replacement is approved, execute with the separate migration
confirmation. Execution first performs read-only checks of the active tenant
and subscription, both supplied subscriptions, exact management-group ancestry,
the legacy assignment-definition link, and the replacement initiative and
Landing Zones assignment. It prompts for the validated
`<tenantId>/<namePrefix>-<workloadArchetype>` only after those checks pass:

```powershell
$env:ESLZ_TAG_MIGRATION_CONFIRMATION = "REMOVE-LEGACY-RG-TAG-POLICY"
.\scripts\migrate-legacy-rg-tags.ps1 -ParameterFile .\parameters\demo.parameters.json -Execute
```

```bash
export ESLZ_TAG_MIGRATION_CONFIRMATION="REMOVE-LEGACY-RG-TAG-POLICY"
./scripts/migrate-legacy-rg-tags.sh parameters/demo.parameters.json --execute
```

The scripts remove only `demo-require-rg-tags` at the legacy workload
management-group scope and `<namePrefix>-require-workload-rg-tags` at the demo
root. Each artifact is checked independently, so an already-absent assignment
does not prevent definition cleanup; only verified not-found responses are
treated as complete. All other read errors stop the migration. The scripts are
never called automatically by preview, deployment, or teardown scripts.

## Teardown

Teardown is not automatic because subscription movement, RBAC, policy, and
resource deletion are consequential. Preview the exact reverse-order commands:

Windows PowerShell (primary):

```powershell
.\scripts\teardown.ps1 -ParameterFile .\parameters\demo.parameters.json
```

macOS or Linux:

```bash
./scripts/teardown.sh parameters/demo.parameters.json
```

To execute them, first verify that the two subscriptions can safely return to
the supplied tenant root, then run:

Windows PowerShell (primary):

```powershell
$env:ESLZ_TEARDOWN_CONFIRMATION = "DELETE-ESLZ-DEMO"
.\scripts\teardown.ps1 -ParameterFile .\parameters\demo.parameters.json -Execute
```

macOS or Linux:

```bash
export ESLZ_TEARDOWN_CONFIRMATION="DELETE-ESLZ-DEMO"
./scripts/teardown.sh parameters/demo.parameters.json --execute
```

The script:

1. deletes the two optional evidence resource groups and waits for completion,
   unless a supplied existing workspace resource group happens to share the
   same subscription and name, in which case that group is skipped;
2. deletes the demo-created monitoring resource group (`rg-<namePrefix>-monitoring`)
   and waits for completion, but only when `deployCentralLogAnalytics=true`
   **and** no existing workspace ID was supplied;
3. deletes the five ordinary demo role assignments for the four baseline groups by principal and scope; eligible Owner schedules require separate one-shot PIM `AdminRemove` requests and are not automatically removed;
4. removes policy assignments, then policy definitions;
5. moves both subscriptions back to the supplied tenant-root management group;
6. deletes leaf management groups and then the dedicated demo root.

It never deletes subscriptions, Entra groups, or a customer-supplied existing
Log Analytics workspace referenced via `existingLogAnalyticsWorkspaceResourceId`.
A dry run is the default. If other resources or assignments have been added
under the hierarchy, Azure will refuse management-group deletion; inspect and
remove those items deliberately.

## Project layout

```text
main.bicep
docs/
  BEGINNERS-GUIDE.md
  FIRST-RUN-CHECKLIST.md
  ENTRA-CONDITIONAL-ACCESS-PIM.md
  AZURE-RBAC-PIM.md
  ACCESS-REVIEWS.md
  NERC-CIP-MATRIX.md
identity/
  azure-rbac/
    owner-eligibility-request.bicep
    owner-eligibility-request.parameters.template.json
    owner-activation-requirements.template.json
  conditional-access/
    ca-privileged-role-mfa.template.json
    ca-azure-mgmt-mfa.template.json
    ca-block-legacy-auth.template.json
    ca-pim-activation-mfa.template.json
  pim/
    pim-activation-global-administrator.template.json
    pim-activation-privileged-role-administrator.template.json
  schema/
    conditional-access-policy.schema.json
    pim-activation-policy.schema.json
    known-entra-ids.json
examples/
  initiative-composition.bicep
modules/
  hierarchy.bicep
  policy-library.bicep
  policy-initiative.bicep
  policy-assignment.bicep
  remediating-policy-assignment.bicep
  remediating-policy-rbac.bicep
  management-group-rbac.bicep
  subscription-rbac.bicep
  evidence-connectivity.bicep
  evidence-network.bicep
  evidence-workload.bicep
  central-monitoring.bicep
  central-monitoring-workspace.bicep
  central-monitoring-sentinel.bicep
  backup-vault.bicep
  backup-vault-resources.bicep
parameters/
scripts/
  owner-eligibility-request.ps1
  preflight.ps1
  what-if.ps1
  deploy.ps1
  teardown.ps1
  validate-identity-artifacts.ps1
  validate-rbac-artifacts.ps1
  review-privileged-access.ps1
  owner-eligibility-request.sh
  preflight.sh
  what-if.sh
  deploy.sh
  teardown.sh
  validate-identity-artifacts.sh
  validate-rbac-artifacts.sh
  review-privileged-access.sh
tests/
  test.ps1
  test.sh
```

## Safety boundaries

- No policy is assigned at the tenant root.
- No subscription or Entra identity is created.
- Tests and static validators are offline; normal preflight performs read-only
  Azure checks and never changes Azure or Entra. The separate Owner workflow
  performs read-only Azure/Entra checks and what-if by default, and requires
  layered explicit confirmation before its one-time submission mode.
- Deny assignments are non-enforcing by default.
- Ordinary RBAC and evidence resources are independently opt-in; eligible Owner
  uses a separate one-shot artifact that is never called by `main.bicep`.
- Deployment and teardown require exact environment confirmations.
- No Conditional Access policy or PIM role setting is applied to any tenant;
  identity-governance templates remain report-only, while the separately
  invoked Owner eligibility request is disabled by default and requires
  explicit placeholders to be replaced.
- No permanent Owner assignment is created; emergency access remains an
  explicitly documented, customer-managed external responsibility.
