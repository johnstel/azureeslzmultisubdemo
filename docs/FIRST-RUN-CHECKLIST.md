# First-Run Checklist

Use this page while operating the demo. Read
[BEGINNERS-GUIDE.md](BEGINNERS-GUIDE.md) before your first attempt.

This checklist covers **v2**. The stable v1 implementation is at the
[v1.0.0 release](https://github.com/johnstel/azureeslzmultisubdemo/releases/tag/v1.0.0)
and the
[release/v1 maintenance branch](https://github.com/johnstel/azureeslzmultisubdemo/tree/release/v1),
with its own checklist. Upgrading an existing v1 deployment?
See [MIGRATION-V1-TO-V2.md](MIGRATION-V1-TO-V2.md).

## 0. Choose a profile

- [ ] **v1 stable** — smallest supported demo; use the v1 release and stop here.
- [ ] **v2 safe demo** — full v2 control surface, nothing paid or enforcing;
      `parameters/demo.parameters.template.json`. *This checklist assumes this
      profile.*
- [ ] **v2 customer control** — change-controlled allowlists, critical
      workloads, or NERC CIP evidence obligations;
      `parameters/customer-control.template.bicepparam`. Same safe defaults and
      the same commands from section 4 onward, but the lifecycle scripts read
      only ARM JSON, so first run
      `az bicep build-params --file parameters/customer-control.template.bicepparam --outfile parameters/demo.parameters.json`
      and re-run it after every edit to the `.bicepparam` source.

## 1. Safety check

- [ ] Both target subscriptions are existing sandboxes.
- [ ] The subscriptions contain nothing that depends on their current
      management-group parent.
- [ ] An Azure administrator approved the proposed hierarchy.
- [ ] No one expects this project to create subscriptions or Entra identities.
- [ ] I understand that what-if is a preview and deploy changes Azure.
- [ ] I have read which switches create **metered** Azure services
      ([SHARED-SERVICES-AND-COST.md](SHARED-SERVICES-AND-COST.md)) and confirmed
      current Azure pricing myself. All of them are off by default and stay off
      in this checklist.
- [ ] I understand that promoting `denyPolicyEnforcementMode` to `Default` can
      **block deployments** for everyone under the hierarchy, and that this
      checklist never does that
      ([ENFORCEMENT-AND-REMEDIATION.md](ENFORCEMENT-AND-REMEDIATION.md)).
- [ ] I understand that no remediation task is started automatically, and that
      starting one changes existing resources.

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
- [ ] No `subscriptionOwnersGroupObjectId` entry remains from a v1 parameter
      file; v2 removed that parameter and creates no permanent Owner.
- [ ] `deployCentralLogAnalytics`, `deploySentinel`, and every
      `enableDefender*` switch are `false`.
- [ ] `activityLogExportPolicyEffect` and `resourceDiagnosticsPolicyEffect` are
      `Disabled`.
- [ ] `enableVmBackupRemediation`, `enableVaultDiagnostics`, and
      `deployRecoveryServicesVault` are `false`.
- [ ] `enableCriticalInfrastructure` is `false` unless you deliberately want the
      opt-in Critical Infrastructure branch, in which case
      `criticalInfrastructureSubscriptionIds` is populated.
- [ ] `enableNercCipTechnicalOverlay` is `false` unless Critical Infrastructure
      is enabled and the overlay was separately approved.
- [ ] `policyExemptions` is empty, or every record has an owner, justification,
      approver, ticket reference, and a future expiry.
- [ ] The completed file contains no secrets, and it is git-ignored.

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
- [ ] What-if shows no Log Analytics workspace, Sentinel onboarding, Defender
      plan, Recovery Services vault, or protected backup item.
- [ ] What-if shows no managed identity for a Defender plan assignment.
- [ ] What-if shows no `<namePrefix>-criticalinfra` management group unless you
      deliberately enabled it.
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
- [ ] Policy assignments exist only at the demo root or below, never at the
      tenant root.
- [ ] Each branch shows the assignments expected for its scope
      ([CONTROL-SCOPE-AND-INHERITANCE.md](CONTROL-SCOPE-AND-INHERITANCE.md)),
      checked with
      `az policy assignment list --scope <scope> --disable-scope-strict-match`.
- [ ] Every deny-capable assignment shows `DoNotEnforce`.
- [ ] Every remediation-capable assignment shows `Disabled` or an audit effect,
      and no remediation task exists.
- [ ] No policy exemption exists that you did not supply and approve.
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
- [ ] One-shot local parameters contain a fresh request GUID, privileged group,
      `AdminAssign`, finite schedule, and justification while
      `submitEligibilityRequest=false`.
- [ ] The workflow-token placeholder was not edited and raw Bicep invocation
      was not used.
- [ ] `submitEligibilityRequest=true` is used only in the prepared local file
      with `scripts/owner-eligibility-request.ps1` or `.sh`.
- [ ] The supported workflow verified an enabled subscription, the exact
      security-enabled Entra group, existing Owner eligibility, unused request
      ID, and no pending or unknown-state matching request.
- [ ] Each one-shot what-if shows exactly one eligible Owner
      request and no active or permanent Owner assignment.
- [ ] Administrator approved that exact preview before one-time submission.
- [ ] One-time submission used the supported workflow's execute flag,
      environment confirmation, and typed request GUID.
- [ ] A distinct request GUID is used for each subscription and is never reused.
- [ ] Both PIM activations were tested before any role-assignment restriction
      policy was enforced.
- [ ] Administrator approved `deployEvidenceResources=true`.
- [ ] What-if shows two resource groups, one VNet, and one NSG only.
- [ ] Administrator approved `enableCriticalInfrastructure=true` and the exact
      `criticalInfrastructureSubscriptionIds` list, if the branch is wanted.
- [ ] The cost owner approved, in writing, any switch that creates a metered
      service, and a budget and cost alert exist on the paying subscription
      ([SHARED-SERVICES-AND-COST.md](SHARED-SERVICES-AND-COST.md)).
- [ ] Compliance data was reviewed and every non-compliant resource is either
      owned, fixed, or covered by an approved expiring exemption.
- [ ] Any remediation task was previewed, separately confirmed, and its
      irreversible effects are understood.
- [ ] Policy owners approved changing `denyPolicyEnforcementMode` to `Default`,
      the rollback path is agreed in advance, and the promotion follows
      [ENFORCEMENT-AND-REMEDIATION.md](ENFORCEMENT-AND-REMEDIATION.md).

## 9. Migrate an existing legacy tag policy

Skip this section for a first deployment. For an upgraded deployment, work
through [MIGRATION-V1-TO-V2.md](MIGRATION-V1-TO-V2.md) first; it covers the
removed `subscriptionOwnersGroupObjectId` parameter, any leftover permanent
Owner assignment, and the full upgrade order. Then:

- [ ] What-if showed the replacement six-tag initiative at the demo root and
      its assignment at Landing Zones.
- [ ] The replacement deployment completed and was approved.
- [ ] The migration preview lists only `demo-require-rg-tags` at the workload
      scope and `<namePrefix>-require-workload-rg-tags` at the demo root.

Preview with `migrate-legacy-rg-tags.ps1` or `migrate-legacy-rg-tags.sh`.
Execution first validates the active tenant/subscription, both supplied
subscriptions, exact management-group ancestry, legacy policy relationship,
and replacement initiative/assignment. Only then does it require
`ESLZ_TAG_MIGRATION_CONFIRMATION` to equal
`REMOVE-LEGACY-RG-TAG-POLICY` and the interactive
`<tenantId>/<namePrefix>-<workloadArchetype>` confirmation.

## 10. Deliberately remediate existing resource tags

Skip this section unless policy owners have approved changing existing
resources.

- [ ] The `tagInheritanceRemediation` output contains the expected Landing
      Zones assignment ID and all six `inherit-*` definition reference IDs.
- [ ] Compliance results show only taggable resources with missing tags whose
      resource groups contain the corresponding non-empty values.
- [ ] The assignment identity's Contributor role has propagated.
- [ ] Policy owners approved one remediation task per definition reference ID.
- [ ] The guarded script preview validated the exact assignment, scope,
      initiative, identity, location, and six references without creating a
      task.
- [ ] The execution environment confirmation and typed tenant/scope/assignment
      confirmation were supplied deliberately; deployment itself started no
      remediation task.
- [ ] Existing resource tag values were sampled afterward and remained
      unchanged.

## 11. Teardown

Preview:

Windows PowerShell (primary):

```powershell
.\scripts\teardown.ps1 -ParameterFile .\parameters\demo.parameters.json
```

macOS or Linux:

```bash
./scripts/teardown.sh parameters/demo.parameters.json
```

- [ ] Returning both subscriptions — and any critical-infrastructure
      subscriptions — to the Tenant Root Group is acceptable.
- [ ] No one added other resources or governance objects to the demo hierarchy.
- [ ] The teardown plan references only this demo.
- [ ] I understand teardown does not delete a customer-supplied Log Analytics
      workspace, data already ingested, backup items already protected, tags
      already written by a remediation task, or PIM eligibility.
- [ ] Teardown is not being used to reverse an enforcement change; that is a
      redeployment with `denyPolicyEnforcementMode` set back to `DoNotEnforce`.

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
