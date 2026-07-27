# Beginner's Guide: Deploying the Azure Landing Zone Demo

This guide assumes you are new to Azure, management groups, Azure Policy, RBAC,
Bicep, and the Azure command-line tools. You do not need to understand the
Bicep code before following the safe preview steps.

> **Start here if this is your first Azure infrastructure deployment.**
>
> The project can reorganize two existing subscriptions and create governance
> controls. Those are meaningful tenant-level changes. Use only sandbox
> subscriptions, ask your Azure administrator to review the plan, and stop after
> what-if until you are comfortable with the preview.

## What this project does

The project builds a small example of an Azure landing zone. A landing zone is
an organized starting point for subscriptions and workloads. It establishes
where subscriptions belong, who has access, which rules apply, and which
regions or services are allowed.

This demo:

- creates a dedicated management-group hierarchy beneath your existing tenant
  root;
- moves two **existing** sandbox subscriptions into that hierarchy;
- creates and assigns five custom Azure policies;
- optionally assigns Azure roles to five existing Microsoft Entra security
  groups;
- optionally creates two resource groups, one virtual network, and one network
  security group as inexpensive evidence resources.

It does **not**:

- create or purchase Azure subscriptions;
- create users, security groups, or other Microsoft Entra identities;
- deploy virtual machines, Azure Firewall, VPN Gateway, Bastion, databases,
  analytics platforms, or paid always-on services;
- assign a demo policy to the tenant root;
- deploy anything when you run the local tests or preflight script;
- deploy anything unless you deliberately unlock and confirm the deployment
  script.

## The Azure mental model using Active Directory

If you know on-premises Active Directory, this compact mapping provides a useful
starting point:

| Azure term | Simple meaning | Active Directory analogy |
|---|---|---|
| Microsoft Entra tenant | Your organization's cloud identity boundary | Roughly an AD forest or domain boundary |
| Tenant root management group | The top Azure governance scope | The domain root when thinking about inheritance |
| Management group | A container for child management groups and subscriptions | An organizational unit (OU) |
| Subscription | A billing, quota, access, and resource boundary | A large delegated business-unit or server-estate boundary; there is no exact AD equivalent |
| Resource group | A lifecycle container for related Azure resources | An application or server OU used for scoped delegation |
| Azure resource | A deployed item such as a VNet or VM | A computer, server, or managed service being administered |
| Microsoft Entra security group | A group of identities used to grant access | An AD security group |
| Azure RBAC role assignment | Who can perform specific actions at a scope | Delegation of Control or an ACL applied to a group |
| Azure Policy definition | A reusable governance rule | A Group Policy Object (GPO) |
| Azure Policy assignment | Applies a policy definition to a scope | Linking a GPO to a domain or OU |
| Policy and RBAC inheritance | Parent governance normally flows downward | GPO and delegated-permission inheritance |
| Bicep | Declarative Infrastructure as Code for Azure | PowerShell or DSC automation that builds the desired structure |
| Deployment | Azure applies the Bicep configuration | Running the approved automation to make the change |

The most useful part of the analogy is inheritance. Assigning a policy or role
at a management group can affect its child management groups, subscriptions,
resource groups, and resources—similar to linking a GPO or delegating
permissions high in an OU tree.

The analogy is not exact:

- management groups contain subscriptions, not users or computers;
- subscriptions also carry billing and quota boundaries, which OUs do not;
- Azure Policy evaluates Azure Resource Manager resources, not Windows user or
  computer settings;
- Microsoft Entra directory roles and Azure resource roles are separate
  permission systems.

This demo root is therefore best pictured as a dedicated **Azure Lab OU** below
the domain root. All experimental policies and permissions begin inside that
lab boundary rather than at the top of the organization.

## The hierarchy this demo creates

```text
Tenant root management group (already exists)
└── Enterprise-Scale Sandbox Demo (new dedicated demo root)
    ├── Platform
    │   └── Connectivity
    │       └── Existing sandbox subscription A
    └── Landing Zones
        └── Corp or Online
            └── Existing sandbox subscription B
```

- The **Connectivity** subscription represents centrally managed networking.
- The **Corp** or **Online** subscription represents an application workload.
- `Corp` is a workload that normally connects to corporate networks or shared
  services.
- `Online` is a workload that is primarily internet-facing. In this demo the
  difference is the branch name; no internet-facing resource is created.

If `namePrefix` is `eslz-demo`, the management-group IDs will be:

```text
eslz-demo
eslz-demo-platform
eslz-demo-connectivity
eslz-demo-landingzones
eslz-demo-corp
```

Selecting `online` changes the last ID to `eslz-demo-online`.

## What you need before starting

You need:

1. Windows 10 or 11 with Windows Terminal and PowerShell 7 (primary), or a
   macOS/Linux terminal with Bash;
2. access to the Azure portal at <https://portal.azure.com>;
3. the Azure CLI;
4. on macOS/Linux, `jq` for JSON and `ripgrep` for local safety tests;
5. two existing, enabled sandbox subscriptions in the same Microsoft Entra
   tenant;
6. five existing Microsoft Entra security groups;
7. an Azure administrator who can grant the tenant- and subscription-level
   permissions described below.

This project does not accept subscription names in place of IDs. Azure
subscription IDs and Microsoft Entra object IDs are GUIDs shaped like:

```text
12345678-1234-1234-1234-123456789abc
```

The IDs identify objects; they are not passwords or client secrets. The real
parameter file is excluded by `.gitignore`, but you should still follow your
organization's data-handling rules.

## Step 1: Open the project

### Windows PowerShell (primary)

Open Windows Terminal, select a **PowerShell 7** profile, and move into the
project:

```powershell
Set-Location "$HOME\Code\azureeslzmultisubdemo"
```

### macOS or Linux

```bash
cd ~/Code/azureeslzmultisubdemo
```

You can inspect the files with Finder, Visual Studio Code, or another text
editor. The most important files are:

| File | Purpose |
|---|---|
| `README.md` | Technical overview and quick commands |
| `docs/BEGINNERS-GUIDE.md` | This step-by-step guide |
| `docs/FIRST-RUN-CHECKLIST.md` | One-page operator checklist for the actual run |
| `main.bicep` | Main Azure deployment plan |
| `parameters/demo.parameters.template.json` | Safe parameter template |
| `parameters/demo.parameters.json` | Your local copy containing real IDs |
| `scripts/*.ps1` | Windows PowerShell lifecycle scripts |
| `scripts/*.sh` | macOS/Linux Bash lifecycle scripts |
| `tests/test.ps1` | Windows PowerShell safety and structure tests |
| `tests/test.sh` | macOS/Linux Bash safety and structure tests |

## Step 2: Install the local tools

### Windows PowerShell (primary)

Use Windows Package Manager from PowerShell:

```powershell
winget install --exact --id Microsoft.PowerShell
winget install --exact --id Microsoft.AzureCLI
```

Close and reopen Windows Terminal after installation. Select the PowerShell 7
profile, which runs `pwsh`, and verify:

```powershell
$PSVersionTable.PSVersion
az version
```

PowerShell 7 and Windows PowerShell 5.1 are separate products. Use PowerShell 7
for the `.ps1` scripts in this guide. The scripts do not require `jq` on
Windows.

Official instructions:

- [Install PowerShell on Windows](https://learn.microsoft.com/powershell/scripting/install/install-powershell-on-windows)
- [Install Azure CLI on Windows](https://learn.microsoft.com/cli/azure/install-azure-cli-windows)

### macOS

Use Homebrew:

```bash
brew update
brew install azure-cli jq ripgrep
```

Verify:

```bash
az version
jq --version
rg --version
```

See [Install Azure CLI on macOS](https://learn.microsoft.com/cli/azure/install-azure-cli-macos).

### Linux

For Ubuntu or Debian, use the current Microsoft installation instructions:

```bash
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
sudo apt-get update
sudo apt-get install -y jq ripgrep
```

If your organization prohibits piping an installation script to Bash, follow
the step-by-step repository setup in
[Install Azure CLI on Linux](https://learn.microsoft.com/cli/azure/install-azure-cli-linux).
Other distributions have different package instructions on that page.

Verify:

```bash
az version
jq --version
rg --version
```

### All operating systems

Install or update the Bicep component used by Azure CLI:

```text
az bicep install
az bicep version
```

The remaining Azure CLI commands are the same on Windows, macOS, and Linux.
Only the script names, path separators, environment-variable syntax, and line
continuation syntax differ.

## Step 3: Identify the correct tenant

A tenant is the Microsoft Entra directory that owns the identities and contains
the subscriptions. Both sandbox subscriptions must belong to the same tenant.

In the Azure portal:

1. Sign in to <https://portal.azure.com>.
2. Search for **Microsoft Entra ID**.
3. Open **Overview**.
4. Copy the **Tenant ID**.

Microsoft documents this process in
[Get subscription and tenant IDs in the Azure portal](https://learn.microsoft.com/azure/azure-portal/get-subscription-tenant-id).

Sign in from PowerShell or your terminal, replacing the example with the Tenant
ID:

```text
az login --tenant YOUR_TENANT_ID
```

A browser window opens for authentication. If your organization uses
multifactor authentication, complete that prompt. Then verify the active
account:

```text
az account show --output table
```

If you belong to several organizations, confirming the tenant is essential.
Running commands in the wrong tenant is a common source of "not found" and
"not authorized" errors.

## Step 4: Collect the two subscription IDs

In the Azure portal:

1. Search for **Subscriptions**.
2. Locate the two sandbox subscriptions.
3. Open each subscription.
4. Copy the **Subscription ID** from its Overview page.

You can also list subscriptions visible to your signed-in account:

```text
az account list --all --output table
```

Decide which subscription fills each role:

| Parameter | Which subscription to use |
|---|---|
| `connectivitySubscriptionId` | The sandbox used for the Platform/Connectivity branch |
| `workloadSubscriptionId` | The other sandbox used for the Corp or Online branch |

The IDs must be different. This project moves the subscriptions to new
management-group parents; it never deletes the subscriptions.

## Step 5: Find the tenant-root management-group ID

In the Azure portal:

1. Search for **Management groups**.
2. Open the hierarchy.
3. Locate **Tenant Root Group**.
4. Open its details and copy its management-group ID.

In many tenants, the root management-group ID is the same GUID as the Tenant
ID, but you should verify it instead of assuming.

You can list the management groups visible to your account:

```text
az account management-group list --output table
```

The value goes into `tenantRootManagementGroupId`. The project only uses this
root as the **parent** of the dedicated demo root. It does not assign demo
policies there.

The first use of management groups in a tenant can require Azure to initialize
the service, which may take several minutes. See Microsoft's
[management-group quickstart](https://learn.microsoft.com/azure/governance/management-groups/create-management-group-portal).

## Step 6: Prepare five Microsoft Entra security groups

RBAC answers: "Who is allowed to perform which actions, and where?" This project
assigns Azure roles to groups rather than individual people so membership can
be managed centrally.

Use five distinct security groups. Suggested names are:

```text
AZ-ESLZ-Demo-Governance-Admins
AZ-ESLZ-Demo-Subscription-Owners
AZ-ESLZ-Demo-Network-Operators
AZ-ESLZ-Demo-Workload-Contributors
AZ-ESLZ-Demo-Read-Only-Auditors
```

If the groups do not exist, an authorized Microsoft Entra administrator can
create them at <https://entra.microsoft.com>:

1. Open **Entra ID**.
2. Select **Groups** > **All groups**.
3. Select **New group**.
4. Set **Group type** to **Security**.
5. Set **Membership type** to **Assigned**.
6. Give the group a clear name and description.
7. Add appropriate owners and members.
8. Select **Create**.

For this demo, ordinary Azure resource access groups are sufficient. They do
not need the special **Microsoft Entra roles can be assigned to the group**
setting because this project assigns Azure resource roles, not Entra directory
roles.

To copy a group Object ID:

1. Go to **Entra ID** > **Groups** > **All groups**.
2. Open the group.
3. Copy **Object ID** from Overview or Properties.

Do not copy a group owner's user ID, the Tenant ID, or an application/client
ID. The preflight script checks that all five values look like GUIDs and that
they are distinct. It cannot verify group type without additional directory
permissions.

Microsoft documents group management and the immutable Object ID in
[How to manage groups](https://learn.microsoft.com/entra/fundamentals/how-to-manage-groups).

### What access each group receives

RBAC creation is disabled during the safest first deployment. When you later
set `deployRoleAssignments` to `true`, the project assigns:

| Group | Azure access | Scope |
|---|---|---|
| Governance admins | Management Group Contributor | Demo root and descendants |
| Governance admins | Resource Policy Contributor | Demo root and descendants |
| Subscription owners | Owner | Each sandbox subscription |
| Network operators | Network Contributor | Connectivity subscription |
| Workload contributors | Contributor | Workload subscription |
| Read-only auditors | Reader | Demo root and descendants |

The five groups produce seven role assignments because governance admins
receive two roles and subscription owners receive one assignment in each
subscription.

An Azure role assignment consists of a principal, role, and scope. See
[Understand Azure role assignments](https://learn.microsoft.com/azure/role-based-access-control/role-assignments).

## Step 7: Confirm the deployment operator's permissions

The account running the deployment must already be authorized. The roles that
the template may create do not give the operator permission early enough to
bootstrap the same deployment.

Ask your Azure administrator to confirm that your account has permission to:

- create child management groups below the tenant root;
- move both sandbox subscriptions into management groups;
- create custom policy definitions and assignments under the demo root;
- create tenant-, management-group-, subscription-, and resource-group-scope
  deployments;
- assign Azure roles when `deployRoleAssignments` is `true`;
- create resource groups and networking resources when
  `deployEvidenceResources` is `true`.

Being a subscription Owner does not automatically give you authority at the
tenant root. Likewise, being a Microsoft Entra Global Administrator does not
automatically grant Azure resource access.

If bootstrap access is missing, a Global Administrator can temporarily enable
**Microsoft Entra ID** > **Properties** > **Access management for Azure
resources**. This grants that person User Access Administrator at Azure root
scope. It is powerful access and should be disabled after the necessary scoped
roles are assigned. Follow Microsoft's
[elevated-access procedure](https://learn.microsoft.com/azure/role-based-access-control/elevate-access-global-admin);
do not enable it casually.

## Step 8: Create your local parameter file

Windows PowerShell (primary):

```powershell
Copy-Item .\parameters\demo.parameters.template.json .\parameters\demo.parameters.json
```

macOS or Linux:

```bash
cp parameters/demo.parameters.template.json parameters/demo.parameters.json
```

Open `parameters/demo.parameters.json` in a text editor. Replace all
`REPLACE_WITH_*` strings.

### Parameter explanation

| Parameter | What to enter |
|---|---|
| `deploymentLocation` | Where Azure stores tenant deployment history; `eastus` is fine and does not constrain resources |
| `tenantRootManagementGroupId` | The existing Tenant Root Group ID |
| `namePrefix` | A unique 3–24 character lowercase name such as `eslz-demo` |
| `demoRootDisplayName` | Friendly portal label for the new demo root |
| `workloadArchetype` | `corp` or `online` |
| `connectivitySubscriptionId` | Existing connectivity sandbox subscription GUID |
| `workloadSubscriptionId` | Existing workload sandbox subscription GUID |
| `governanceAdminsGroupObjectId` | Governance security-group Object ID |
| `subscriptionOwnersGroupObjectId` | Subscription owners security-group Object ID |
| `networkOperatorsGroupObjectId` | Network operators security-group Object ID |
| `workloadContributorsGroupObjectId` | Workload contributors security-group Object ID |
| `readOnlyAuditorsGroupObjectId` | Auditors security-group Object ID |
| `denyPolicyEnforcementMode` | Keep `DoNotEnforce` for the first deployment |
| `deployRoleAssignments` | Keep `false` for the first deployment |
| `deployEvidenceResources` | Keep `false` for the first deployment |
| `evidenceLocation` | Approved region for the optional VNet/NSG, such as `eastus2` |

### Safe first-run settings

Keep these exact values initially:

```json
"denyPolicyEnforcementMode": {
  "value": "DoNotEnforce"
},
"deployRoleAssignments": {
  "value": false
},
"deployEvidenceResources": {
  "value": false
}
```

`DoNotEnforce` means the deny policy assignments exist and can be evaluated,
but Azure does not block deployments because of them. Audit policies still
report findings. This gives you time to inspect scope and impact.

JSON is strict:

- retain the double quotation marks;
- retain commas between fields;
- do not add comments;
- enter booleans as `true` or `false`, without quotation marks.

## Step 9: Run local tests

Windows PowerShell (primary):

```powershell
.\tests\test.ps1
```

macOS or Linux:

```bash
./tests/test.sh
```

This compiles the Bicep and checks important safety properties. It does not sign
in to Azure and does not change Azure.

Expected ending:

The expected ending is either `All Windows PowerShell validation and safety
tests passed.` or `All local validation and safety tests passed.`

If this fails, do not continue. Read the first `ERROR` message. The later
messages are often consequences of the first failure.

## Step 10: Run preflight

Windows PowerShell (primary):

```powershell
.\scripts\preflight.ps1 -ParameterFile .\parameters\demo.parameters.json
```

macOS or Linux:

```bash
./scripts/preflight.sh parameters/demo.parameters.json
```

Both versions of preflight:

- check that the required local tools exist;
- refuses parameter placeholders;
- validates the prefix and GUID shapes;
- ensures the subscription IDs and five group IDs are distinct;
- builds the Bicep locally;
- reads the current Azure account;
- confirms both subscriptions are enabled and in the signed-in tenant;
- confirms the tenant-root management group is visible.

These checks are read-only. Passing preflight means the inputs are plausible; it
does not guarantee the operator has every write permission required for
deployment.

## Step 11: Run Azure what-if

Windows PowerShell (primary):

```powershell
.\scripts\what-if.ps1 -ParameterFile .\parameters\demo.parameters.json
```

macOS or Linux:

```bash
./scripts/what-if.sh parameters/demo.parameters.json
```

Azure Resource Manager what-if predicts changes without applying them. It may
still require the same permissions as deployment because Azure performs
server-side validation.

Common symbols are:

| Symbol | Meaning |
|---|---|
| `+` | Azure predicts a new resource |
| `~` | Azure predicts a modification |
| `-` | Azure predicts a deletion |
| `=` | No change |
| `*` or `Ignore` | Azure cannot fully determine the change |

For the first deployment, expect creation of management groups, subscription
associations, policy definitions, policy assignments, and nested deployment
records. With the safe defaults, do not expect role assignments, resource
groups, a VNet, or an NSG.

Stop and investigate if what-if shows:

- a change at `/providers/Microsoft.Management/managementGroups/<tenant-root>`;
- any subscription other than the two sandbox IDs;
- deletion of an existing resource;
- a paid service such as a VM, public IP, firewall, gateway, database, or
  analytics workspace;
- a management-group name that collides with an existing hierarchy.

What-if occasionally reports noise when it cannot resolve a runtime expression.
Treat the preview as a decision aid, not an infallible guarantee. Microsoft's
[Bicep what-if documentation](https://learn.microsoft.com/azure/azure-resource-manager/bicep/deploy-what-if)
explains its behavior and limitations.

## Step 12: Understand the policies before deployment

All five custom policy definitions live at the dedicated demo root. Policy
assignments occur only at the demo root or below.

### 1. Allowed continental-US locations

Scope: demo root and descendants.

Allowed regions:

```text
centralus
eastus
eastus2
northcentralus
southcentralus
westcentralus
westus
westus2
westus3
```

The rule ignores the Azure `global` location used by location-independent
resources. Its assignment starts in `DoNotEnforce`.

### 2. Audit public IP resources

Scope: demo root and descendants.

This reports `Microsoft.Network/publicIPAddresses` resources. It audits rather
than blocks. It is a simple demonstration signal, not a complete network
security assessment.

### 3. Block common expensive services and VM sizes

Scope: demo root and descendants.

The rule includes commonly costly service types such as Azure Firewall,
Bastion, NAT Gateway, VPN Gateway, AKS, Databricks, Synapse, and Analysis
Services. It also limits VM SKUs to a small B-series list. Its assignment starts
in `DoNotEnforce`.

This is a demo guardrail, not a complete cost-management program.

### 4. Audit Platform tags

Scope: Platform branch.

Taggable Platform resources are audited for `Owner` and `CostCenter`.

### 5. Require workload resource-group tags

Scope: Corp or Online workload branch.

Workload resource groups must have `Application`, `Environment`, and `Owner`
tags. Its assignment starts in `DoNotEnforce`.

Azure Policy is inherited from parent scopes and evaluates resources beneath
management groups. See
[Overview of Azure Policy](https://learn.microsoft.com/azure/governance/policy/overview).

## Step 13: Perform the first governance-only deployment

Only continue after:

- local tests pass;
- preflight passes;
- what-if has been reviewed;
- an Azure administrator approves the target hierarchy and permissions;
- both subscriptions are confirmed sandboxes.

### Windows PowerShell (primary)

Unlock deployment for the current PowerShell session and run:

```powershell
$env:ESLZ_DEPLOY_CONFIRMATION = "DEPLOY-ESLZ-DEMO"
.\scripts\deploy.ps1 -ParameterFile .\parameters\demo.parameters.json
```

### macOS or Linux

```bash
export ESLZ_DEPLOY_CONFIRMATION="DEPLOY-ESLZ-DEMO"
./scripts/deploy.sh parameters/demo.parameters.json
```

The script runs preflight and what-if again. It then displays the target demo
root and both subscription IDs. Type the exact `namePrefix` when prompted.

Typing anything else cancels the deployment.

The project uses a tenant-scope deployment because it creates management groups
and then targets child management groups, subscriptions, and resource groups
through Bicep modules. Microsoft's
[tenant deployment documentation](https://learn.microsoft.com/azure/azure-resource-manager/bicep/deploy-to-tenant)
explains this deployment model.

Do not close PowerShell or your terminal simply because a command appears quiet. Azure
deployments run in Azure after submission. If interrupted, inspect tenant
deployment state before retrying:

```text
az deployment tenant list --output table
```

## Step 14: Verify the result

### Verify the management-group hierarchy in the portal

1. Search for **Management groups**.
2. Select **Refresh** if necessary.
3. Expand the new demo root.
4. Confirm the Platform/Connectivity and Landing Zones/Corp-or-Online branches.
5. Confirm each sandbox subscription appears under the intended leaf.

Management-group and subscription movement can take time to appear throughout
the portal.

### Verify policies

1. Search for **Policy**.
2. Open **Assignments**.
3. Change the scope to the demo root.
4. Confirm the five assignment names beginning with `Demo`.
5. Open each assignment and verify its scope and enforcement mode.

Policy compliance evaluation is asynchronous. A newly assigned policy can show
`Not started` or no compliance result for a while.

### Verify using Azure CLI

Replace `eslz-demo` if you selected a different prefix:

```text
az account management-group show --name eslz-demo --expand --recurse --output jsonc
```

List policy assignments at the demo root:

```text
az policy assignment list --scope /providers/Microsoft.Management/managementGroups/eslz-demo --output table
```

At this stage, `deployRoleAssignments=false` and
`deployEvidenceResources=false`, so there should be no demo role assignments or
evidence resource groups yet.

## Step 15: Optionally enable RBAC

Have an administrator review the RBAC matrix first. Then change:

```json
"deployRoleAssignments": {
  "value": true
}
```

Run tests, preflight, and what-if again:

Windows PowerShell:

```powershell
.\tests\test.ps1
.\scripts\preflight.ps1 -ParameterFile .\parameters\demo.parameters.json
.\scripts\what-if.ps1 -ParameterFile .\parameters\demo.parameters.json
```

macOS or Linux:

```bash
./tests/test.sh
./scripts/preflight.sh parameters/demo.parameters.json
./scripts/what-if.sh parameters/demo.parameters.json
```

What-if should show seven role assignments for the five security groups. If the
principal IDs or scopes differ from your expectation, stop.

Then run the guarded deployment again:

Windows PowerShell:

```powershell
$env:ESLZ_DEPLOY_CONFIRMATION = "DEPLOY-ESLZ-DEMO"
.\scripts\deploy.ps1 -ParameterFile .\parameters\demo.parameters.json
```

macOS or Linux:

```bash
export ESLZ_DEPLOY_CONFIRMATION="DEPLOY-ESLZ-DEMO"
./scripts/deploy.sh parameters/demo.parameters.json
```

Deploying the same Bicep again is expected. Infrastructure as Code is
declarative: Azure compares the desired configuration with current state and
only applies differences.

## Step 16: Optionally create evidence resources

Change:

```json
"deployEvidenceResources": {
  "value": true
}
```

Then repeat tests, preflight, what-if, and the guarded deployment.

This creates:

```text
Connectivity subscription
└── rg-<prefix>-connectivity
    ├── vnet-<prefix>-shared
    └── nsg-<prefix>-shared

Workload subscription
└── rg-<prefix>-<corp-or-online>-demo
```

The VNet contains one subnet and no connected compute. The NSG contains only
Azure's default security rules. There is no public IP.

## Step 17: Consider enforcing the deny policies

Leave `denyPolicyEnforcementMode` as `DoNotEnforce` until:

- the hierarchy and inheritance are correct;
- current resources have been evaluated;
- the allowed locations match your real requirements;
- teams understand which services and VM SKUs will be blocked;
- an administrator approves enforcement.

To enforce, change:

```json
"denyPolicyEnforcementMode": {
  "value": "Default"
}
```

Then run what-if and deploy again. `Default` turns the deny effects on.

This does not automatically delete existing noncompliant resources. It can
block future creation or updates that violate the rules.

## Cost expectations

The default governance-only deployment creates management groups, custom
policies, assignments, and deployment records. These governance objects do not
run compute workloads.

The optional evidence configuration adds resource groups, one VNet, and one
NSG. Those resources do not carry an hourly charge by themselves. The project
does not create services that commonly produce ongoing demo costs.

Never assume that everything later added to the resource groups is free.
Connected services, network gateways, public IPs, private endpoints, firewalls,
traffic, logging, storage, or compute can introduce charges. Check
[Azure pricing](https://azure.microsoft.com/pricing/) and your organization's
budgets before extending the demo.

## Step 18: Preview teardown

Teardown reverses the demo. Preview it first:

Windows PowerShell (primary):

```powershell
.\scripts\teardown.ps1 -ParameterFile .\parameters\demo.parameters.json
```

macOS or Linux:

```bash
./scripts/teardown.sh parameters/demo.parameters.json
```

This only prints the plan. It does not change Azure.

The plan:

1. deletes the optional evidence resource groups;
2. removes the seven demo role assignments;
3. removes the five policy assignments and definitions;
4. moves both subscriptions back to the supplied tenant root;
5. deletes the leaf management groups, then the demo root.

It never deletes subscriptions or Microsoft Entra groups.

Before execution, verify that moving the subscriptions to the tenant root is
acceptable. If the subscriptions originally lived under a different management
group, edit the teardown approach instead of using this script as-is; the
script's return destination is the `tenantRootManagementGroupId` parameter.

## Step 19: Execute teardown only when approved

### Windows PowerShell (primary)

```powershell
$env:ESLZ_TEARDOWN_CONFIRMATION = "DELETE-ESLZ-DEMO"
.\scripts\teardown.ps1 -ParameterFile .\parameters\demo.parameters.json -Execute
```

### macOS or Linux

```bash
export ESLZ_TEARDOWN_CONFIRMATION="DELETE-ESLZ-DEMO"
./scripts/teardown.sh parameters/demo.parameters.json --execute
```

Type the exact `namePrefix` when prompted.

If someone added other resources, assignments, or child management groups after
deployment, Azure may refuse cleanup. That refusal is protective. Inspect the
remaining items before deleting anything else.

## Troubleshooting

### `Parameter file still contains REPLACE_WITH_* placeholders`

You copied the template but did not replace every placeholder. Search the real
parameter file:

Windows PowerShell:

```powershell
Select-String -Path .\parameters\demo.parameters.json -Pattern "REPLACE_WITH_"
```

macOS or Linux:

```bash
rg -n "REPLACE_WITH_" parameters/demo.parameters.json
```

Replace every result with the correct ID.

### `Azure CLI is not signed in`

Run:

```text
az login --tenant YOUR_TENANT_ID
```

Then rerun preflight.

### Windows says that running scripts is disabled

Your PowerShell execution policy or corporate device policy is blocking local
scripts. Do not weaken a corporate policy without approval. Ask your
administrator whether locally authored scripts are permitted.

If your organization approves a one-process exception, it can launch a single
test run without changing the user or machine policy:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\test.ps1
```

Use the same pattern with a lifecycle script only after its normal safety
review. A centrally enforced Group Policy can still prevent the exception.

### The subscriptions do not appear

Check the current tenant and visible subscriptions:

```text
az account show --output table
az account list --all --output table
```

You may be signed into the wrong directory or may not have access.

### `Cannot read tenant-root management group`

Possible causes:

- the management-group ID is wrong;
- management groups have not been initialized;
- your account lacks tenant-root read access;
- you signed into the wrong tenant.

Ask an administrator to verify the root ID and grant the smallest necessary
scope.

### `AuthorizationFailed` or `does not have authorization`

The operator lacks an action at the reported scope. Read the full error:

- `Microsoft.Management/managementGroups/write` relates to hierarchy creation;
- `Microsoft.Management/managementGroups/subscriptions/write` relates to moving
  subscriptions;
- `Microsoft.Authorization/policyDefinitions/write` or
  `policyAssignments/write` relates to policy;
- `Microsoft.Authorization/roleAssignments/write` relates to RBAC;
- `Microsoft.Resources/deployments/*` relates to nested Bicep deployments.

Do not solve every authorization error by assigning Owner at tenant root. Ask
an administrator for the narrowest suitable role and scope.

### Subscription movement is blocked

A subscription can have restrictions, inherited governance, or permissions
that prevent movement. Confirm that both the current parent and destination are
permitted and that moving the subscription will not remove critical inherited
policy or access.

### What-if shows many `Ignore` changes

What-if cannot always expand runtime expressions or nested deployments. Review
the diagnostic messages and the explicit target scopes. Do not interpret
`Ignore` as approval.

### A policy does not show compliance immediately

Policy evaluation is asynchronous. The assignment can exist before compliance
data appears. Wait and refresh the Policy Compliance view.

### A deployment was interrupted

Check server-side state:

```text
az deployment tenant list --output table
```

Do not immediately submit another deployment with different parameters until
you know whether the first one is still running.

### Teardown cannot delete a management group

The management group probably still contains a subscription, child group,
policy assignment, role assignment, or another protected item. Inspect the
hierarchy and remove only the known demo objects. Do not use broad recursive
deletion.

## Safe stopping points

You can stop safely after any of these:

1. **After local tests:** nothing touched Azure.
2. **After preflight:** Azure was only read.
3. **After what-if:** Azure validated and predicted changes but did not deploy.
4. **After governance-only deployment:** hierarchy and policy exist, but RBAC
   and evidence resources remain disabled.
5. **After teardown preview:** only a cleanup plan was printed.

If you are uncertain, stop at what-if and ask an Azure administrator to review
the output.

## Glossary

**Azure Resource Manager (ARM)**  
The control plane that receives deployment requests and manages Azure
resources.

**Bicep**  
A readable Infrastructure-as-Code language that Azure CLI compiles into an ARM
template.

**Compliance**  
Whether an Azure resource meets an assigned policy rule.

**Deny**  
An Azure Policy effect that blocks a noncompliant creation or update when
enforced.

**DoNotEnforce**  
A policy-assignment mode that leaves the assignment present without enforcing
deny effects.

**GUID**  
A globally unique identifier, usually displayed as five groups of letters and
numbers separated by hyphens.

**Infrastructure as Code (IaC)**  
Managing infrastructure through versioned text files instead of manually
clicking through the portal.

**Management group**  
A governance container above subscriptions. Policies and RBAC can inherit down
from it.

**Microsoft Entra ID**  
Microsoft's cloud identity and directory service, formerly Azure Active
Directory.

**Object ID**  
The unique Microsoft Entra identifier for a user, group, service principal, or
other directory object.

**Policy assignment**  
Attaches a policy definition to a scope and provides its parameter values and
enforcement mode.

**Policy definition**  
The reusable rule describing what Azure should audit or deny.

**Principal**  
The identity receiving access, such as a user, security group, managed identity,
or service principal.

**RBAC**  
Role-based access control: Azure's system for granting a principal a role at a
specific scope.

**Resource group**  
A lifecycle container for related resources inside one subscription.

**Scope**  
Where a policy or role applies: management group, subscription, resource group,
or individual resource.

**Subscription**  
An Azure billing, quota, access, and resource boundary.

**Tenant**  
The Microsoft Entra directory representing an organization.

**Tenant root management group**  
The top management group in an Azure tenant. Governance assigned there can
affect every subscription, which is why this demo avoids assigning policy there.

**Virtual network (VNet)**  
An isolated logical network in Azure.

**What-if**  
An Azure Resource Manager preview of changes that a Bicep deployment would
attempt.

## Official references

- [What is Bicep?](https://learn.microsoft.com/azure/azure-resource-manager/bicep/overview)
- [Deploy Bicep at tenant scope](https://learn.microsoft.com/azure/azure-resource-manager/bicep/deploy-to-tenant)
- [Preview Bicep changes with what-if](https://learn.microsoft.com/azure/azure-resource-manager/bicep/deploy-what-if)
- [Management groups overview](https://learn.microsoft.com/azure/governance/management-groups/overview)
- [Azure Policy overview](https://learn.microsoft.com/azure/governance/policy/overview)
- [Azure RBAC overview](https://learn.microsoft.com/azure/role-based-access-control/overview)
- [Find tenant and subscription IDs](https://learn.microsoft.com/azure/azure-portal/get-subscription-tenant-id)
- [Manage Microsoft Entra groups](https://learn.microsoft.com/entra/fundamentals/how-to-manage-groups)
- [Install PowerShell on Windows](https://learn.microsoft.com/powershell/scripting/install/install-powershell-on-windows)
- [Install Azure CLI on Windows](https://learn.microsoft.com/cli/azure/install-azure-cli-windows)
- [Install Azure CLI on macOS](https://learn.microsoft.com/cli/azure/install-azure-cli-macos)
- [Install Azure CLI on Linux](https://learn.microsoft.com/cli/azure/install-azure-cli-linux)
