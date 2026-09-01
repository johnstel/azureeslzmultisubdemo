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
| Platform | Audit `Owner` and `CostCenter` tags on taggable resources | Audit |
| Corp/Online | Require `Application`, `Environment`, and `Owner` tags on resource groups | Deny assignment in `DoNotEnforce` |
| Corp/Online | Audit public inbound SSH/RDP NSG rules and subnets without NSGs | Audit assignment in `DoNotEnforce` |
| Corp/Online and opt-in Critical Infrastructure | Audit selected PaaS public network access and private endpoint readiness | Audit |
| Corp/Online and opt-in Critical Infrastructure | Audit supplied route-table expectations for an approved firewall | Explicit opt-in, Audit |

The allowed-location policy uses `Indexed` mode, ignores the location-agnostic
`global` value, and excludes the B2C directory resource type, following the
safe shape of Azure's built-in allowed-locations control. Resource groups are
governed separately by workload tag policy. Change
`denyPolicyEnforcementMode` to `Default` only after reviewing what-if and the
policy impact.

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

Bicep does not create Microsoft Entra identities. Supply the object IDs of five
existing **security groups**:

| Group parameter | Assignment |
|---|---|
| `governanceAdminsGroupObjectId` | Management Group Contributor and Resource Policy Contributor at the demo root |
| `subscriptionOwnersGroupObjectId` | Owner on each of the two sandbox subscriptions |
| `networkOperatorsGroupObjectId` | Network Contributor on the connectivity subscription |
| `workloadContributorsGroupObjectId` | Contributor on the workload subscription |
| `readOnlyAuditorsGroupObjectId` | Reader at the demo root |

RBAC is disabled by default with `deployRoleAssignments=false`. The deployment
principal needs enough access to create these assignments when it is enabled;
the governance group assignments do not bootstrap the deployment principal.

## Entra Conditional Access and PIM (identity governance, not Azure Policy)

Azure Policy cannot require MFA, block legacy authentication, or govern
privileged-role activation — those are Microsoft Entra ID/Microsoft Graph
concepts. `identity/` contains report-only Conditional Access policy inputs
and eligible-only Privileged Identity Management (PIM) activation-policy
inputs for later, separately reviewed use. This repository never calls
Microsoft Graph, never modifies Entra ID, and never enables Conditional
Access; every artifact defaults to report-only/eligible and requires a
real emergency-access (break-glass) exclusion before it could ever be
applied. See the [Entra Conditional Access and PIM runbook](docs/ENTRA-CONDITIONAL-ACCESS-PIM.md)
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
3. deletes the seven demo role assignments for the five groups by principal and scope;
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
identity/
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
  preflight.ps1
  what-if.ps1
  deploy.ps1
  teardown.ps1
  validate-identity-artifacts.ps1
  preflight.sh
  what-if.sh
  deploy.sh
  teardown.sh
  validate-identity-artifacts.sh
tests/
  test.ps1
  test.sh
```

## Safety boundaries

- No policy is assigned at the tenant root.
- No subscription or Entra identity is created.
- No live command runs from tests or preflight.
- Deny assignments are non-enforcing by default.
- RBAC and evidence resources are opt-in.
- Deployment and teardown require exact environment confirmations.
- No Conditional Access policy or PIM role setting is applied to any
  tenant; `identity/` templates are static, report-only/eligible-only
  inputs and always require replacing an emergency-access placeholder.
