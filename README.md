# Azure Enterprise-Scale Landing Zone — Two-Subscription Demo

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

The allowed-location policy uses `Indexed` mode, ignores the location-agnostic
`global` value, and excludes the B2C directory resource type, following the
safe shape of Azure's built-in allowed-locations control. Resource groups are
governed separately by workload tag policy. Change
`denyPolicyEnforcementMode` to `Default` only after reviewing what-if and the
policy impact.

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

1. deletes the two optional evidence resource groups and waits for completion;
2. deletes the seven demo role assignments for the five groups by principal and scope;
3. removes policy assignments, then policy definitions;
4. moves both subscriptions back to the supplied tenant-root management group;
5. deletes leaf management groups and then the dedicated demo root.

It never deletes subscriptions or Entra groups. A dry run is the default. If
other resources or assignments have been added under the hierarchy, Azure will
refuse management-group deletion; inspect and remove those items deliberately.

## Project layout

```text
main.bicep
docs/
  BEGINNERS-GUIDE.md
  FIRST-RUN-CHECKLIST.md
modules/
  hierarchy.bicep
  policy-library.bicep
  policy-assignment.bicep
  management-group-rbac.bicep
  subscription-rbac.bicep
  evidence-connectivity.bicep
  evidence-network.bicep
  evidence-workload.bicep
parameters/
scripts/
  preflight.ps1
  what-if.ps1
  deploy.ps1
  teardown.ps1
  preflight.sh
  what-if.sh
  deploy.sh
  teardown.sh
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
