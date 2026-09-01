# First-Run Checklist

Use this page while operating the demo. Read
[BEGINNERS-GUIDE.md](BEGINNERS-GUIDE.md) before your first attempt.

## 1. Safety check

- [ ] Both target subscriptions are existing sandboxes.
- [ ] The subscriptions contain nothing that depends on their current
      management-group parent.
- [ ] An Azure administrator approved the proposed hierarchy.
- [ ] No one expects this project to create subscriptions or Entra identities.
- [ ] I understand that what-if is a preview and deploy changes Azure.

## 2. Values to collect

Do not place secrets in this worksheet.

| Value | Collected? |
|---|---|
| Microsoft Entra Tenant ID | [ ] |
| Tenant Root Group management-group ID | [ ] |
| Connectivity sandbox Subscription ID | [ ] |
| Workload sandbox Subscription ID | [ ] |
| Governance admins group Object ID | [ ] |
| Subscription privileged-access group Object ID (separate one-shot PIM workflow only) | [ ] |
| Network operators group Object ID | [ ] |
| Workload contributors group Object ID | [ ] |
| Read-only auditors group Object ID | [ ] |

The two subscription IDs must differ. Every supplied security-group Object ID
must be distinct. Before collecting eligible Owner inputs, read
[AZURE-RBAC-PIM.md](AZURE-RBAC-PIM.md).

## 3. Clone and prepare the project

Open Windows Terminal with a PowerShell 7 profile. Install
[Git](https://git-scm.com/downloads) first if `git --version` reports that the
command is unavailable.

```powershell
git --version
New-Item -ItemType Directory -Path "$HOME\Code" -Force | Out-Null
Set-Location "$HOME\Code"
git clone https://github.com/johnstel/azureeslzmultisubdemo.git
Set-Location .\azureeslzmultisubdemo
$PSVersionTable.PSVersion
az version
az bicep version
az login --tenant YOUR_TENANT_ID
az account show --output table
```

macOS or Linux alternative:

```bash
git --version
mkdir -p ~/Code
cd ~/Code
git clone https://github.com/johnstel/azureeslzmultisubdemo.git
cd azureeslzmultisubdemo
az version
jq --version
rg --version
az bicep version
az login --tenant YOUR_TENANT_ID
az account show --output table
```

- [ ] The repository was cloned successfully.
- [ ] The terminal is in the `azureeslzmultisubdemo` folder.
- [ ] The displayed tenant is correct.
- [ ] Both sandbox subscriptions appear in `az account list --all --output table`.

## 4. Prepare safe parameters

Windows PowerShell:

```powershell
Copy-Item .\parameters\demo.parameters.template.json .\parameters\demo.parameters.json
```

macOS or Linux:

```bash
cp parameters/demo.parameters.template.json parameters/demo.parameters.json
```

- [ ] Every `REPLACE_WITH_*` value has been replaced.
- [ ] `denyPolicyEnforcementMode` is `DoNotEnforce`.
- [ ] `deployRoleAssignments` is `false`.
- [ ] `deployEvidenceResources` is `false`.
- [ ] `namePrefix` is unique and identifies a demo.

## 5. Validate without deploying

Windows PowerShell (primary):

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

- [ ] Local tests pass.
- [ ] Preflight passes.
- [ ] What-if references only the two intended subscriptions.
- [ ] What-if creates a dedicated demo root below the tenant root.
- [ ] What-if does not assign policy at the tenant root.
- [ ] What-if shows no deletion.
- [ ] What-if shows no VM, public IP, gateway, firewall, database, or analytics
      resource.
- [ ] An Azure administrator reviewed the preview.

Stop if any box above cannot be checked.

## 6. Deploy governance only

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

Type the exact `namePrefix` only after the script repeats the correct demo root
and both subscription IDs.

## 7. Verify

- [ ] The management-group hierarchy is correct in the Azure portal.
- [ ] Each subscription is under the intended leaf.
- [ ] Five policy assignments exist only at the demo root or below.
- [ ] Deny assignments show `DoNotEnforce`.
- [ ] No RBAC assignment was created while `deployRoleAssignments=false`.
- [ ] The main compiled output and what-if contain no
      `roleEligibilityScheduleRequests`.
- [ ] No resource group, VNet, or NSG was created while
      `deployEvidenceResources=false`.

## 8. Optional later phases

Enable one change at a time. Run tests, preflight, and what-if again before each
deployment.

- [ ] Administrator approved `deployRoleAssignments=true`.
- [ ] What-if shows exactly five ordinary role assignments and no permanent Owner.
- [ ] Entra P2 or Entra ID Governance licensing is confirmed for every eligible
      privileged-group member.
- [ ] Customer-managed emergency access exists, is tested and monitored, and
      no emergency account or object ID is stored in this repository.
- [ ] Owner PIM settings at both subscriptions require approval, MFA,
      justification, a four-hour activation maximum, and notifications.
- [ ] The deployment principal has narrowly scoped, time-bound bootstrap access.
- [ ] Existing Owner eligibility and pending requests were checked separately at
      each target subscription.
- [ ] One-shot local parameters contain a fresh request GUID, privileged group,
      `AdminAssign`, finite schedule, and justification while
      `submitEligibilityRequest=false`.
- [ ] `submitEligibilityRequest=true` is used only in the prepared local file
      for a subscription-scope what-if; what-if submits no request.
- [ ] Each one-shot what-if shows exactly one eligible Owner
      request and no active or permanent Owner assignment.
- [ ] Administrator approved that exact preview before one-time submission.
- [ ] A distinct request GUID is used for each subscription and is never reused.
- [ ] Both PIM activations were tested before any role-assignment restriction
      policy was enforced.
- [ ] Administrator approved `deployEvidenceResources=true`.
- [ ] What-if shows two resource groups, one VNet, and one NSG only.
- [ ] Policy owners approved changing `denyPolicyEnforcementMode` to `Default`.

## 9. Teardown

Preview:

Windows PowerShell (primary):

```powershell
.\scripts\teardown.ps1 -ParameterFile .\parameters\demo.parameters.json
```

macOS or Linux:

```bash
./scripts/teardown.sh parameters/demo.parameters.json
```

- [ ] Returning both subscriptions to the Tenant Root Group is acceptable.
- [ ] No one added other resources or governance objects to the demo hierarchy.
- [ ] The teardown plan references only this demo.

Execute only with approval:

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

Afterward:

- [ ] Both subscriptions still exist and are enabled.
- [ ] Both subscriptions are at the approved return scope.
- [ ] Demo policy and five ordinary RBAC assignments are gone.
- [ ] Both eligible Owner schedules were removed with separately reviewed,
      one-shot PIM `AdminRemove` requests using their existing schedule IDs and
      fresh request GUIDs; teardown does not automate this.
- [ ] The dedicated demo management groups are gone.
- [ ] The five Microsoft Entra security groups still exist.
