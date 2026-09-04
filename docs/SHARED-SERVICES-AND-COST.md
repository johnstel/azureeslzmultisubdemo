# Shared services and cost

This document explains the shared services this project can integrate with —
Log Analytics, Microsoft Sentinel, Microsoft Defender for Cloud, Azure Firewall
and private endpoints, customer-managed keys, and backup — and exactly which
switch turns a free governance control into a metered Azure service.

> **Cost notice.** Every heading marked **metered** below can generate an Azure
> bill. This project cannot guarantee a cost, and Azure pricing changes.
> Confirm the current Azure pricing page for each service, in your own currency
> and region, before enabling anything on this page. Nothing here is a price
> quote.

## The safe default costs nothing to run

With the shipped defaults in
[`parameters/demo.parameters.template.json`](../parameters/demo.parameters.template.json),
the project creates only governance-plane objects: management groups, policy
definitions, initiatives, and non-enforcing assignments. Those objects have no
Azure consumption charge.

No workspace, Sentinel onboarding, Defender plan, firewall, public IP, private
endpoint, DNS zone, key, vault, protected item, VM, or storage account is
created by the default profile.

## Cost switch summary

| Switch | Default | Effect when enabled | Metered? |
|---|---|---|---|
| `deployEvidenceResources` | `false` | Two resource groups, one small VNet, one NSG | No hourly charge for these object types |
| `deployRoleAssignments` | `false` | Five ordinary RBAC assignments across four groups: three at the demo root plus one operator assignment in each of the two subscriptions | No |
| `enableTagInheritance` | `false` | `Modify` assignment, no remediation task | No, until a task is started |
| `existingLogAnalyticsWorkspaceResourceId` | `''` | Reuses a workspace you already pay for | Your existing workspace bill |
| `deployCentralLogAnalytics` | `false` | Creates a Log Analytics workspace | **Yes** — ingestion and retention |
| `deploySentinel` | `false` | Onboards Sentinel onto the effective workspace | **Yes** — per-GB analysis on top of Log Analytics |
| `activityLogExportPolicyEffect` | `Disabled` | Exports subscription Activity Logs | **Yes** — increases ingestion |
| `resourceDiagnosticsPolicyEffect` | `Disabled` | Exports resource diagnostics | **Yes** — increases ingestion |
| `enableDefenderCspm` | `false` | Defender CSPM plan (incl. CIEM) | **Yes** — per-resource plan pricing |
| `enableDefenderForServers` | `false` | Defender for Servers plan | **Yes** |
| `enableDefenderForStorage` | `false` | Defender for Storage plan | **Yes** |
| `enableDefenderStorageMalwareScanning` | `false` | On-upload malware scanning extension | **Yes** — additional per-GB |
| `deployRecoveryServicesVault` | `false` | Vault, resource group, backup policy | Vault itself is not hourly-charged |
| `enableVmBackupRemediation` | `false` | Remediation-capable backup assignment | **Yes**, once instances are protected |
| `enableVaultDiagnostics` | `false` | Vault diagnostic settings | **Yes** — ingestion |
| `enableFirewallRouteGuardrails` | `false` | Audits route tables against an approved firewall | No — audits only, deploys nothing |

Two of these deserve special attention because the cost is created **after**
the switch, by resource activity rather than by deployment:
`enableVmBackupRemediation` (protected instances and backup storage) and the
two log-export effects (ingestion volume).

## Log Analytics

Centralized logging is the shared service most of the other controls depend on.
There are exactly two supported paths and they are mutually exclusive:

- **Reuse an existing customer-owned workspace** — the recommended integration
  path. Set `existingLogAnalyticsWorkspaceResourceId` to the full resource ID.
  No workspace is created or modified; the ID is read to compute the effective
  workspace ID that downstream modules consume.
- **Create a new central workspace** — set `deployCentralLogAnalytics=true`.
  This creates a **metered** workspace in a new `rg-<namePrefix>-monitoring`
  resource group in the connectivity subscription.

Setting both, or setting `deploySentinel=true` with neither configured, is an
invalid configuration. Rather than silently deploying nothing or returning an
empty workspace ID, the module fails the deployment explicitly with a
configuration-error resource so the mistake surfaces immediately.

Cost controls to decide **before** enabling any export:

| Parameter | Default | Why it matters |
|---|---|---|
| `centralLogAnalyticsRetentionInDays` | `30` | Retention beyond the included period is billable |
| `centralLogAnalyticsDailyQuotaGb` | `-1` (no cap) | A daily cap bounds worst-case ingestion, at the cost of dropping data once reached |
| `resourceDiagnosticsCategoryGroup` | `audit` | `allLogs` ingests substantially more than `audit` |

Coverage of `resourceDiagnosticsCategoryGroup` is limited to the resource types
included by the selected Microsoft-built initiative. Unsupported types are
intentionally not claimed as covered; extend them with explicit custom
diagnostics policies after verifying aliases, categories, and least-privilege
remediation roles.

Teardown deletes the `rg-<namePrefix>-monitoring` resource group only when this
project created it (`deployCentralLogAnalytics=true` **and** no existing
workspace ID supplied). A customer-supplied workspace and its resource group
are never deleted, even if names collide.

## Microsoft Sentinel — metered

`deploySentinel=true` onboards Sentinel onto the effective workspace and adds
per-GB Sentinel analysis charges **on top of** Log Analytics ingestion. The
module onboards only; it configures no analytics rules, automation rules, data
connectors, workbooks, or incidents, and it never deletes or replaces a
supplied existing workspace.

Because Sentinel cost scales with ingested volume, decide the log-export
effects and the daily quota first, and onboard Sentinel second. Onboarding
Sentinel onto a workspace that is already receiving `allLogs` from every
supported resource type is the most common way to be surprised by a bill.

Sentinel onboarding alone is not detection. Analytics rules, an incident
workflow, and named responders are customer-owned and are recorded as manual
evidence in [`docs/NERC-CIP-MATRIX.md`](NERC-CIP-MATRIX.md).

## Microsoft Defender for Cloud

Three paid plans are exposed, each behind its own explicit, safe-by-default
opt-in: `enableDefenderCspm`, `enableDefenderForServers`, and
`enableDefenderForStorage`.

While a parameter stays `false`, the corresponding assignment creates **no
managed identity at all** (`identity.type` is `None`) and its effect is
`Disabled`. A normal deployment therefore cannot enable a paid plan, incur
license cost, or create a standing identity.

Setting one to `true` flips that plan's identity to `SystemAssigned` and its
effect to `DeployIfNotExists` — and still grants that identity **no role**.
These built-ins only support remediation via Owner at subscription scope, and
this project deliberately refuses to grant Owner or User Access Administrator
to any managed identity. Opting in therefore fails closed: the identity exists
but is role-less until a customer separately, temporarily, and outside this
template authorizes it. Treat that as a feature, not a defect.

Free, audit-only signals are always assigned and require no opt-in, no
identity, and no role: the VM vulnerability-assessment audit and the Windows
and Linux Azure Monitor Agent presence audits. They deploy no scanner and
depend on no paid plan.

Additional decisions this project makes explicitly:

- `enableDefenderCiem` (default `true`, only applies when
  `enableDefenderCspm=true`) toggles the CSPM plan's Entra Permissions
  Management (CIEM) extension by name.
- `defenderForServersSubPlan` (default `P2`) and
  `defenderForServersAgentlessVmScanningEnabled` (default `true`). Agentless VM
  scanning is supported only on P2, so requesting P1 together with agentless
  scanning fails deployment instead of silently degrading.
- `enableDefenderStorageMalwareScanning` defaults to `false` even though the
  built-in's own default is `true`, so enabling the Storage plan never silently
  enables an additional metered per-GB feature.

The all-or-nothing "Configure Microsoft Defender for Cloud plans" initiative is
never assigned: it exposes no assignment-time parameters, so it would enable
all twelve member plans at once with no per-plan opt-out.

Foundational CSPM — the free Defender for Cloud baseline that populates the
audit-only controls — is configured through the subscription's
`Microsoft.Security/pricings` `CloudPosture` resource, not an Azure Policy
assignment, so this template never deploys it. Its state on an existing
subscription is whatever the customer has separately configured.

## Azure Firewall and private endpoints

This project **audits** network boundary posture. It creates no Azure Firewall,
no public IP, no private endpoint, no private DNS zone, and no route table.
That is why the network controls add no cost.

- `enableFirewallRouteGuardrails` (default `false`) audits supplied route-table
  expectations against an approved firewall. Enabling it requires an approved
  firewall resource ID and private IP plus non-empty route-table IDs and
  prefixes; incomplete input fails validation rather than auditing against
  nothing.
- `privateAccessPublicNetworkPolicyEffect` and
  `privateAccessServiceCategories` drive the workload and Critical
  Infrastructure private-access audits for public network access and
  private-endpoint readiness.
- The demo-root public-IP audit remains the only public-IP resource control.

The **customer** owns the actual shared network services: the firewall itself,
its policy and rules, route tables and user-defined routes, private endpoints,
private DNS zones and their virtual-network links, and any DNS forwarding.
Azure Firewall, VPN and NAT gateways, Bastion, and public IPs are all metered
and are all outside this project. Budget them as shared platform services in
the connectivity subscription, and remember that a private endpoint has its own
hourly and per-GB charges.

Exceptional public paths and special-purpose subnets must use a documented,
time-bound exemption rather than an untracked exception. See
[`docs/ENFORCEMENT-AND-REMEDIATION.md`](ENFORCEMENT-AND-REMEDIATION.md).

## Customer-managed keys

CMK controls are service-specific and audit-first, never a blanket deny across
every Azure service. This project audits CMK readiness; it creates no key
vault, key, managed identity, or private endpoint.

Adopting CMK adds customer-owned dependencies that Azure Policy cannot satisfy
for you:

- a managed identity with `get`, `wrapKey`, and `unwrapKey` on the key;
- a key rotation process with an owner;
- key availability — a deleted, disabled, expired, or purged key makes the
  encrypted data unreadable;
- soft delete and purge protection for recovery. **Purge protection must never
  be disabled once enabled**, which is why a global `Disabled` selection for
  the data-protection effect is mapped back to `Audit` for the purge-protection
  control rather than being propagated;
- network reachability of the vault when public network access is restricted,
  which usually means a private endpoint the customer deploys.

`approvedCustomerManagedKeyVaultUris` and `approvedCustomerManagedKeyNames` are
empty by default and are change-controlled allowlists. A key vault, its keys,
and any private endpoint in front of it are metered and customer-owned.

## Backup

Backup governance is audit-only by default and adds no cost.

- `deployRecoveryServicesVault=false` (default) creates no vault, backup
  policy, or protected item.
- A Recovery Services vault has no hourly charge by itself. **Protected
  instances and backup storage are metered**, which is why vault creation is
  explicit, tagged as metered and customer-owned, and never combined with
  approved existing vault records.
- Enabling `enableVmBackupRemediation` protects nothing by itself. Pre-existing
  virtual machines are protected only by a remediation task, which this project
  never starts. With `vmBackupConfigurationEffect='DeployIfNotExists'` **and**
  `denyPolicyEnforcementMode='Default'`, matching virtual machines are also
  protected automatically as they are created or updated. Both switches are
  cost decisions.
- `approvedBackupVaults` entries must reference vaults inside the workload and
  critical-infrastructure subscriptions unless
  `allowCrossSubscriptionBackupVaults=true`, because the built-in deploys the
  protected item into the vault's subscription and this template only grants
  roles inside the assignment scope. Approving a central backup subscription
  means separately granting the assignment identity Backup Contributor there.
- Retention settings (`backupDailyRetentionInDays`,
  `backupWeeklyRetentionInWeeks`, `backupMonthlyRetentionInMonths`,
  `backupYearlyRetentionInYears`) drive backup storage volume and therefore
  cost. Longer retention and immutability improve recoverability and increase
  spend.

## Shared-service ownership

| Shared service | Created by this project? | Owner |
|---|---|---|
| Log Analytics workspace | Only with `deployCentralLogAnalytics=true` | Customer platform team |
| Sentinel analytics, incidents, responders | No | Customer security operations |
| Defender plan licensing and Owner grants | No | Customer subscription owners |
| Azure Firewall, route tables, private endpoints, private DNS | No | Customer network team |
| Key Vault, keys, rotation, CMK identities | No | Customer key custodians |
| Recovery Services vault and protected items | Only with the explicit opt-ins above | Customer backup owners |
| Break-glass accounts and Entra configuration | No | Customer identity team |

## Before you enable anything metered

1. Confirm current pricing for the specific service, region, and currency.
2. Decide retention and quota before ingestion, not after.
3. Set an Azure budget and cost alert on the subscription that will hold the
   spend.
4. Record who approved the spend and who owns the ongoing bill.
5. Re-run what-if and read the change list before deploying.
6. Know how to reverse it — see the rollback stage in
   [`docs/ENFORCEMENT-AND-REMEDIATION.md`](ENFORCEMENT-AND-REMEDIATION.md).
   Note that data already ingested and instances already protected are not
   reversed by turning a switch back off.
