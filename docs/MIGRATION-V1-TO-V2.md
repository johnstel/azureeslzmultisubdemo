# Migrating from v1 to v2

This guide is for an operator who already deployed the
[v1.0.0 release](https://github.com/johnstel/azureeslzmultisubdemo/releases/tag/v1.0.0)
into a sandbox and wants to move to v2 without surprising anyone. It also
explains when **not** to migrate.

v1 remains available and supported for maintenance on the
[`release/v1` branch](https://github.com/johnstel/azureeslzmultisubdemo/tree/release/v1).
Nothing in v2 removes or deprecates that release.

## Should you migrate?

| Situation | Recommendation |
|---|---|
| You want the smallest possible demo of management groups, a few policies, and optional RBAC | Stay on v1 |
| You need the v2 control catalog, compliance overlays, data-protection, backup, logging, or Defender governance | Migrate to v2, safe demo profile |
| You have customer-specific allowlists, a Critical Infrastructure branch, or NERC CIP evidence obligations | Migrate to v2, customer-control profile |
| You are mid-audit and cannot absorb new policy assignments right now | Stay on v1 until the audit closes |

Migration is not urgent and is not automatic. v2 is a larger, more opinionated
governance surface; adopt it deliberately.

## What changed

### Hierarchy

v1 created demo root, Platform, Connectivity, Landing Zones, and one workload
branch (`corp` or `online`). v2 keeps that exact shape and adds one **opt-in**
sibling under Landing Zones:

```text
<namePrefix>-landingzones
├── <namePrefix>-corp | <namePrefix>-online
└── <namePrefix>-criticalinfra        new in v2, only when enableCriticalInfrastructure = true
```

With `enableCriticalInfrastructure=false` (the default), the deployed hierarchy
is identical to v1. See
[`docs/CONTROL-SCOPE-AND-INHERITANCE.md`](CONTROL-SCOPE-AND-INHERITANCE.md).

### Removed parameter: `subscriptionOwnersGroupObjectId`

This is the one **breaking** parameter change. v1 accepted
`subscriptionOwnersGroupObjectId` and granted that group **permanent Owner** on
both sandbox subscriptions when `deployRoleAssignments=true`.

v2 removes the parameter entirely. `main.bicep` creates no Owner assignment at
all, and a routine redeployment cannot replay a privileged request. PIM-ready
eligible Owner is instead handled by the separately invoked, confirmation-gated
`scripts/owner-eligibility-request.*` workflow.

A v1 parameter file containing `subscriptionOwnersGroupObjectId` will fail
against the v2 template. Remove the entry; do not map it to another parameter.

Any **permanent Owner role assignment created by a previous v1 deployment still
exists in Azure.** v2 neither reuses nor deletes it: v2 teardown only removes
the five ordinary assignments for the four v2 baseline groups. Review and
remove standing Owner deliberately, after eligible Owner activation is proven
to work — see
[`docs/IDENTITY-GOVERNANCE-RUNBOOK.md`](IDENTITY-GOVERNANCE-RUNBOOK.md).

### Replaced control: resource-group tagging

| | v1 | v2 |
|---|---|---|
| Required tags | `Application`, `Environment`, `Owner` | `CostCenter`, `ApplicationName`, `Owner`, `Environment`, `DataClassification`, `SSP-ID` |
| Mechanism | One custom definition, `<namePrefix>-require-workload-rg-tags` | Initiative composing six instances of the built-in require-tag-on-resource-group definition |
| Assignment scope | Workload branch (`<namePrefix>-<archetype>`) | Landing Zones |
| Assignment name | `demo-require-rg-tags` | `demo-require-rg-tags` at the new scope |
| Inheritance to child resources | None | Optional `Modify` initiative, off by default |

Note that `Application` became `ApplicationName`, and three tags were added.
Existing resource groups tagged for v1 will report non-compliant against the
new requirements until they are tagged or exempted. Evaluate that in
`DoNotEnforce` before doing anything else.

### Added in v2

These are all off, audit-only, or non-enforcing by default:

- A machine-readable control catalog
  ([`policy/control-catalog.json`](../policy/control-catalog.json)) and the
  generated [control matrix](CONTROL-MATRIX.md).
- Customer deployment-restriction allowlists for locations, resource types, and
  VM SKUs (customer-control profile).
- Workload network-ingress and private-access guardrails, and optional
  approved-firewall route audits.
- Storage, Key Vault, and customer-managed-key data-protection guardrails.
- Backup coverage and vault posture controls, and an optional customer-owned
  vault.
- Central Log Analytics reuse or creation, optional Sentinel onboarding, and
  Activity Log / resource diagnostics export.
- Microsoft cloud security benchmark (on by default, `DoNotEnforce`), with
  optional CIS and NIST SP 800-53 Rev. 5 overlays.
- Defender for Cloud plan governance markers, all paid plans disabled by
  default with no identity.
- The opt-in NERC CIP technical overlay at Critical Infrastructure only.
- Governed, expiring policy exemptions via `policyExemptions`.
- Report-only Conditional Access and PIM artifacts, the eligible-Owner
  workflow, and the read-only privileged access review.
- New operator scripts: `migrate-legacy-rg-tags`, `remediate-resource-tags`,
  `review-privileged-access`, `validate-identity-artifacts`,
  `validate-rbac-artifacts`, and `owner-eligibility-request`.

### Unchanged

- No policy is assigned at the tenant root.
- No subscription or Entra identity is created.
- Deny assignments default to `DoNotEnforce`.
- RBAC and evidence resources are independently opt-in.
- Deployment and teardown require exact environment confirmations.
- The same `preflight` / `what-if` / `deploy` / `teardown` script names and
  parameter-file conventions.

## Migration procedure

Perform this in a sandbox first. Each step is reversible except where noted.

### 1. Read before you change anything

- [`docs/CONTROL-MATRIX.md`](CONTROL-MATRIX.md) — what v2 will evaluate.
- [`docs/SHARED-SERVICES-AND-COST.md`](SHARED-SERVICES-AND-COST.md) — which
  switches cost money.
- [`docs/ENFORCEMENT-AND-REMEDIATION.md`](ENFORCEMENT-AND-REMEDIATION.md) —
  how to promote and roll back.

### 2. Capture the v1 baseline

Record the current state so you can compare and, if needed, restore:

```bash
az policy assignment list \
  --scope "/providers/Microsoft.Management/managementGroups/<namePrefix>" \
  --disable-scope-strict-match --output json > /tmp/v1-assignments.json
az role assignment list \
  --scope "/subscriptions/<workload-subscription-guid>" --output json > /tmp/v1-roles.json
```

```powershell
az policy assignment list `
  --scope "/providers/Microsoft.Management/managementGroups/<namePrefix>" `
  --disable-scope-strict-match --output json > $env:TEMP\v1-assignments.json
az role assignment list `
  --scope "/subscriptions/<workload-subscription-guid>" --output json > $env:TEMP\v1-roles.json
```

Keep these outside the repository. They can contain principal IDs.

### 3. Rebuild the parameter file from the v2 template

Do not hand-edit the v1 file. Start from
[`parameters/demo.parameters.template.json`](../parameters/demo.parameters.template.json)
(or `parameters/customer-control.template.bicepparam` for the customer-control
profile, compiled to `parameters/demo.parameters.json` with
`az bicep build-params` because the lifecycle scripts read only ARM JSON), copy
across only your tenant root ID, name prefix, archetype,
subscription IDs, and the four group object IDs, and leave every new switch at
its shipped default.

Drop `subscriptionOwnersGroupObjectId`.

Keep `denyPolicyEnforcementMode` at `DoNotEnforce`.

Your working file stays local and untracked; `parameters/demo.parameters.json`
is git-ignored.

### 4. Validate offline, then preflight and what-if

```bash
./tests/test.sh
./scripts/preflight.sh parameters/demo.parameters.json
./scripts/what-if.sh parameters/demo.parameters.json
```

```powershell
.\tests\test.ps1
.\scripts\preflight.ps1 -ParameterFile .\parameters\demo.parameters.json
.\scripts\what-if.ps1 -ParameterFile .\parameters\demo.parameters.json
```

Read the what-if output in full. Expect many new definitions and assignments,
and expect the resource-group tag assignment to move from the workload branch
to Landing Zones. If you see an unexpected deletion, stop and reconcile it
against the v1 baseline from step 2.

### 5. Deploy v2 alongside the v1 artifacts

```bash
export ESLZ_DEPLOY_CONFIRMATION="DEPLOY-ESLZ-DEMO"
./scripts/deploy.sh parameters/demo.parameters.json
```

```powershell
$env:ESLZ_DEPLOY_CONFIRMATION = "DEPLOY-ESLZ-DEMO"
.\scripts\deploy.ps1 -ParameterFile .\parameters\demo.parameters.json
```

At this point the legacy v1 tag assignment and definition still exist. That is
intentional: the replacement is deployed and observed before anything is
removed.

### 6. Observe compliance before removing the legacy control

Let compliance data populate, then review non-compliance against the new
six-tag requirement. Decide for each finding whether to tag the resource group,
accept it, or record an expiring exemption. Do not remove the v1 control while
findings are unexplained.

### 7. Remove the legacy tag policy

Only after the replacement is deployed **and** approved. Preview first; preview
performs no Azure operation:

```bash
./scripts/migrate-legacy-rg-tags.sh parameters/demo.parameters.json
```

```powershell
.\scripts\migrate-legacy-rg-tags.ps1 -ParameterFile .\parameters\demo.parameters.json
```

Then execute with the separate migration confirmation:

```bash
export ESLZ_TAG_MIGRATION_CONFIRMATION="REMOVE-LEGACY-RG-TAG-POLICY"
./scripts/migrate-legacy-rg-tags.sh parameters/demo.parameters.json --execute
```

```powershell
$env:ESLZ_TAG_MIGRATION_CONFIRMATION = "REMOVE-LEGACY-RG-TAG-POLICY"
.\scripts\migrate-legacy-rg-tags.ps1 -ParameterFile .\parameters\demo.parameters.json -Execute
```

Execution first performs read-only checks of the active tenant and
subscription, both supplied subscriptions, exact management-group ancestry, the
legacy assignment-to-definition link, and the presence of the replacement
initiative and Landing Zones assignment. It then prompts for the validated
`<tenantId>/<namePrefix>-<workloadArchetype>` value.

It removes only `demo-require-rg-tags` at the legacy workload management-group
scope and `<namePrefix>-require-workload-rg-tags` at the demo root. Each
artifact is checked independently, so an already-absent assignment does not
prevent definition cleanup, and only verified not-found responses are treated
as complete. Any other read error stops the migration. These scripts are never
called automatically by preview, deployment, or teardown.

### 8. Optionally adopt tag inheritance

`enableTagInheritance=true` adds a `Modify` assignment that fills in a missing
tag from the resource group. It starts no remediation task; existing resources
are only updated by the separate, confirmed `remediate-resource-tags` workflow.
An existing resource value always wins, so customer-supplied tags are never
overwritten.

### 9. Review standing Owner

Remove any permanent Owner assignment left over from v1, after confirming
eligible Owner activation works at both subscriptions. Use the read-only
inventory as evidence:

```bash
./scripts/review-privileged-access.sh --tenant-id <tenant-guid> --subscription-id <subscription-guid>
```

```powershell
.\scripts\review-privileged-access.ps1 -TenantId <tenant-guid> -SubscriptionId <subscription-guid>
```

### 10. Adopt further v2 capability one switch at a time

Enable one thing, re-run what-if, deploy, observe, then move on. Enabling
several new controls plus an enforcement promotion in a single deployment makes
attribution of any failure much harder.

## Rolling back to v1

1. Check out the `release/v1` branch or the `v1.0.0` tag in a separate working
   copy.
2. Rebuild a v1 parameter file, reinstating `subscriptionOwnersGroupObjectId`
   if you intend to restore standing Owner.
3. Run preflight and what-if and read the change list. Redeploying v1 does not
   automatically delete v2 assignments, definitions, or the Critical
   Infrastructure management group.
4. Remove v2-only artifacts deliberately, or run v2 teardown first and then
   deploy v1 into a clean hierarchy.

Resources changed by a remediation task, data already ingested into a
workspace, and instances already protected by backup are not reversed by
returning to v1.

## Related documents

- [Control scope and inheritance](CONTROL-SCOPE-AND-INHERITANCE.md)
- [Enforcement and remediation runbook](ENFORCEMENT-AND-REMEDIATION.md)
- [Identity governance runbook](IDENTITY-GOVERNANCE-RUNBOOK.md)
- [Shared services and cost](SHARED-SERVICES-AND-COST.md)
- [NERC CIP responsibility and evidence](NERC-CIP-MATRIX.md)
