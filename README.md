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
| Corp/Online | Audit public inbound SSH/RDP NSG rules and subnets without NSGs | Audit assignment in `DoNotEnforce` |
| Corp/Online and opt-in Critical Infrastructure | Audit selected PaaS public network access and private endpoint readiness | Audit |
| Corp/Online and opt-in Critical Infrastructure | Audit supplied route-table expectations for an approved firewall | Explicit opt-in, Audit |
| Demo root | Microsoft cloud security benchmark (built-in initiative, enabled by default) | Assignment in `DoNotEnforce` |
| Demo root | CIS Microsoft Azure Foundations Benchmark v2.0.0 (built-in initiative, opt-in) | Assignment in `DoNotEnforce` |
| Demo root | NIST SP 800-53 Rev. 5 (built-in initiative, opt-in) | Assignment in `DoNotEnforce` |

The allowed-location policy uses `Indexed` mode, ignores the location-agnostic
`global` value, and excludes the B2C directory resource type, following the
safe shape of Azure's built-in allowed-locations control. Resource groups are
governed separately by a tagging initiative defined at the demo root and
assigned at Landing Zones. Change
`denyPolicyEnforcementMode` to `Default` only after reviewing what-if and the
policy impact. The resource-group tagging initiative composes six instances of
Azure's built-in **Require a tag on resource groups** definition and provides a
tag-specific noncompliance message for each requirement.

The customer-control profile is separate from the broader safe demo location
profile. Its `customerAllowedLocations`, `customerAllowedResourceTypes`, and
`customerAllowedVmSkus` parameters are change-controlled allowlists. The
resource-type default includes this project's evidence resources and child
types needed for diagnostics, VM extensions, private endpoints, backup, and
Azure Policy remediation. Keep `denyPolicyEnforcementMode` set to
`DoNotEnforce` until those lists and a what-if/policy impact report are approved.

The workload network-ingress initiative recognizes `*`, `Internet`,
`0.0.0.0/0`, and arbitrary public IPv4 host/CIDR source values in singular and
array NSG aliases. Private, non-routable/reserved IPv4 ranges and supported
Azure service tags are not treated as public. TCP or any-protocol destination
ranges are parsed so ranges containing `22` or `3389` are detected alongside
exact and wildcard ports. It is not assigned to Platform or Connectivity.
Exceptional public paths or special-purpose workload subnets must use a
documented, time-bound Azure Policy exemption. The existing demo-root
public-IP audit remains the only public-IP resource control.

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
`main.bicep`; domain initiatives remain explicit future work driven by the
authoritative [`policy/control-catalog.json`](policy/control-catalog.json).

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
later. This project still never configures or claims to configure the Azure
Monitor Agent itself — the two AMA audit policies above only audit current
agent presence, independent of any paid plan.

This project never silently enables Defender plans, configures Microsoft
Sentinel analytics/incidents, or claims that any of these controls alone
prove Microsoft Cloud Security Benchmark (MCSB) or
regulatory-compliance-dashboard compliance; see `docs/CONTROL-MATRIX.md` for
the full REQ-DEF-01 through REQ-DEF-09 mapping, including why the
all-or-nothing "Configure Microsoft Defender for Cloud plans" initiative and
the deprecated Log Analytics (MMA) auto-provisioning policy are intentionally
never assigned. REQ-DEF-09 separately documents Foundational CSPM — the
free, always-on Defender for Cloud baseline that populates the audit-only
controls above — as its own catalog entry distinct from the paid Defender
CSPM plan (REQ-DEF-02): Foundational CSPM is not an assignable Azure Policy
resource and is present whether or not REQ-DEF-02 is ever opted in.

## Required permissions

The person or service principal running the deployment must have:

1. permission to create child management groups under the supplied tenant-root
   management group and to write policy definitions/assignments at the demo
   hierarchy;
2. permission to move both existing subscriptions into the new hierarchy;
3. Owner or Role Based Access Control Administrator at each target scope when
   `deployRoleAssignments=true`;
4. Contributor on both subscriptions when `deployEvidenceResources=true`.

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
"deployRoleAssignments": { "value": false },
"deployEvidenceResources": { "value": false }
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
parameters/
scripts/
  owner-eligibility-request.ps1
  preflight.ps1
  what-if.ps1
  deploy.ps1
  teardown.ps1
  validate-identity-artifacts.ps1
  validate-rbac-artifacts.ps1
  owner-eligibility-request.sh
  preflight.sh
  what-if.sh
  deploy.sh
  teardown.sh
  validate-identity-artifacts.sh
  validate-rbac-artifacts.sh
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
