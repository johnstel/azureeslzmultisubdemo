# Release notes for v2.0.0

Repository version: `2.0.0`

Validated IaC only; no customer Azure deployment was performed. The release gate
requires the Bash and PowerShell validation suites, Bicep compilation, and
whitespace checks to pass before the release commit is approved.

## Features

- Full v2 control catalog with generated control matrix, explicit control scope
  and inheritance guidance, and cross-platform validation.
- Safe demo profile at `parameters/demo.parameters.template.json` for the full
  v2 control surface with metered services, remediation, RBAC, and evidence
  resources disabled by default.
- Customer-control profile at `parameters/customer-control.template.bicepparam`
  for customer-owned allowlists, Critical Infrastructure hierarchy adoption, and
  NERC CIP evidence workflows.
- Expanded Azure Policy coverage for deployment restrictions, tags and tag
  inheritance, network ingress, private access, firewall route expectations,
  storage and Key Vault posture, backup coverage, logging, Defender governance,
  Microsoft Cloud Security Benchmark, CIS, NIST, and NERC CIP overlays.
- Report-only Entra Conditional Access and PIM artifacts, PIM-ready Owner
  request workflow, and read-only privileged-access review tooling.

## Breaking changes

- `subscriptionOwnersGroupObjectId` was removed. v2 creates no permanent Owner
  assignment and does not replay privileged access during normal deployments.
- The v2 tag baseline replaces the v1 `Application` tag with `ApplicationName`
  and adds `CostCenter`, `DataClassification`, and `SSP-ID`.
- Resource-group tag policy moves from the workload branch to the Landing Zones
  branch, so existing v1 deployments should assess non-compliance before
  enforcement.

## Migration from v1

Use [Migrating from v1 to v2](MIGRATION-V1-TO-V2.md) before changing an
existing sandbox. v1 remains available at the
[v1.0.0 release](https://github.com/johnstel/azureeslzmultisubdemo/releases/tag/v1.0.0)
and the
[release/v1 maintenance branch](https://github.com/johnstel/azureeslzmultisubdemo/tree/release/v1).
Nothing in v2 modifies the `v1.0.0` tag or `release/v1` branch.

## Safety defaults

- Default templates contain placeholders and are intentionally non-deployable
  until customer values are supplied.
- Deny assignments remain in `DoNotEnforce` by default.
- The following capabilities require explicit opt-in parameters:
  - RBAC: `deployRoleAssignments`
  - Evidence resources: `deployEvidenceResources`
  - Tag inheritance remediation: `enableTagInheritance`
  - Backup remediation: `enableVmBackupRemediation`
  - Central logging: `deployCentralLogAnalytics` or
    `existingLogAnalyticsWorkspaceResourceId`
  - Sentinel: `deploySentinel`
  - Defender paid plans: `enableDefenderCspm`, `enableDefenderForServers`, and
    `enableDefenderForStorage`
  - Critical Infrastructure overlays: `enableCriticalInfrastructure` and
    `enableNercCipOverlay`
- Tenant root is not assigned policy, no subscription or Entra identity is
  created, and destructive lifecycle operations require exact confirmations.

## Paid-service opt-ins

The shipped defaults create no paid always-on Azure service. Paid-service
switches remain off unless a customer deliberately enables them after reviewing
[Shared services and cost](SHARED-SERVICES-AND-COST.md), including Log
Analytics creation or ingestion, Sentinel onboarding, Activity Log and resource
diagnostic export, Defender CSPM, Defender for Servers, Defender for Storage,
malware scanning, Recovery Services protected instances, and vault diagnostics.

## Known limitations

- This release is repository validation only; no live customer Azure deployment,
  Azure Policy remediation task, Defender plan activation, backup protection, or
  Entra control deployment was performed.
- Built-in policy and initiative definitions can change in Azure. Re-run the
  repository validators and a tenant-scope what-if before any deployment.
- NERC CIP content is a technical overlay and evidence guide, not a compliance
  certification or audit opinion.
- Customer-owned prerequisites such as subscriptions, groups, approvers,
  workspaces, keys, vaults, route tables, and emergency-access processes remain
  outside this template.

## Release publication

Validate release readiness against the
[v2.0.0 milestone](https://github.com/johnstel/azureeslzmultisubdemo/issues?q=milestone%3A%22v2.0.0%22)
and the release gate dependency chain before publishing.
The v2.0.0 tag and GitHub Release must be created only after this release commit is merged to `main` and all repository checks pass, and both must point to that same approved `main` commit.
