# Entra Conditional Access and PIM runbook

This runbook documents identity-governance artifacts that Azure Policy
**cannot** implement, because Azure Policy governs Azure Resource Manager
resources while sign-in and role-activation behavior are controlled through
Microsoft Entra ID (Conditional Access) and Privileged Identity Management
(PIM), both configured through Microsoft Graph.

**Nothing in this folder is applied to any tenant by this repository.** The
files under `identity/` are declarative, report-only inputs for a future,
separately reviewed apply workflow. This repository never calls Microsoft
Graph, never modifies Entra ID, and never enables Conditional Access.

## Why this is separate from Azure Policy

| Control plane | What it governs | Where it lives in this repo |
|---|---|---|
| Azure Policy (`modules/policy-library.bicep`, `modules/policy-assignment.bicep`) | ARM resource properties: allowed regions, resource types, required tags | Deployed by `main.bicep` at the demo management-group hierarchy |
| Conditional Access (`identity/conditional-access/`) | Sign-in behavior: which authentication controls apply to which users, apps, and client types | Static JSON inputs only; no deployment path in this repository |
| Privileged Identity Management (`identity/pim/`) | Directory-role activation: eligible vs. permanent assignment, approval, MFA, duration | Static JSON inputs only; no deployment path in this repository |

Azure Policy cannot require MFA, block legacy authentication protocols, or
enforce time-bound, approved role activation — those are Entra ID/Microsoft
Graph concepts, not ARM resource properties.

## Artifacts in this folder

```text
identity/
  conditional-access/
    ca-privileged-role-mfa.template.json   Phishing-resistant MFA for privileged directory roles
    ca-azure-mgmt-mfa.template.json        MFA for the Microsoft Azure Management application
    ca-block-legacy-auth.template.json     Blocks legacy authentication protocols
  pim/
    pim-activation-global-administrator.template.json
    pim-activation-privileged-role-administrator.template.json
  schema/
    conditional-access-policy.schema.json  JSON Schema for the Conditional Access templates
    pim-activation-policy.schema.json      JSON Schema for the PIM templates
```

Every Conditional Access template defaults to
`"state": "enabledForReportingButNotEnforced"` (report-only) and every PIM
template defaults to `"assignmentType": "eligible"` with approval, MFA,
justification, notification, and a bounded activation duration required.
Neither can be silently changed to an enforcing/permanent shape without
editing the JSON, and `scripts/validate-identity-artifacts.sh` /
`scripts/validate-identity-artifacts.ps1` fail the build if anyone does.

## Required Entra licenses

| Feature used | Minimum license |
|---|---|
| Conditional Access | Microsoft Entra ID P1 |
| Authentication Strengths (phishing-resistant MFA) | Microsoft Entra ID P1 for the control; passwordless/FIDO2/certificate-based methods have their own prerequisites |
| Privileged Identity Management | Microsoft Entra ID P2 (or Microsoft Entra ID Governance / Microsoft Entra Suite / EMS E5) |

License every user in scope of a policy before moving it out of report-only,
or Microsoft Graph will reject the policy at apply time.

## Required directory roles to review or apply these artifacts

- **Security Administrator** or **Conditional Access Administrator** — review
  and (eventually) apply Conditional Access policies.
- **Privileged Role Administrator** — review and (eventually) apply PIM role
  settings.
- Reviewers only need **Security Reader** / **Global Reader** to read
  report-only sign-in impact in the Entra sign-in logs.

None of these roles are granted by this repository. `main.bicep` grants only
Azure RBAC (subscription/management-group scope), never Microsoft Entra
directory roles.

## Emergency-access (break-glass) exclusions — mandatory

Every template in `identity/conditional-access/` and `identity/pim/` declares
an `emergencyAccessExclusion` object with `required: true` and a
`REPLACE_WITH_*` placeholder. This is intentional and enforced by
`scripts/validate-identity-artifacts.sh` / `.ps1`:

- Conditional Access templates fail validation unless the emergency-access
  placeholder both exists **and** appears in `conditions.users.excludeGroups`.
- PIM templates fail validation unless the emergency-access placeholder
  exists in `emergencyAccessExclusion`.

**Any future apply workflow must run this validation before calling
Microsoft Graph, and must refuse to apply a template whose placeholder still
starts with `REPLACE_WITH_`.** This prevents a Conditional Access or PIM
misconfiguration from locking every administrator out of the tenant, per
Microsoft's break-glass account guidance. Provision at least two cloud-only,
non-federated, non-PIM-managed emergency-access accounts, exclude them from
every Conditional Access policy, and monitor sign-ins to them with an alert.

## Workload identities

- The Azure management MFA and legacy-auth policies target `"All users"`.
  Workload identities (service principals, managed identities) are governed
  separately from user Conditional Access by design; do not add service
  principals to `includeUsers`/`includeRoles` in these templates.
- If workload-identity Conditional Access is later required (Entra ID
  Workload Identities Premium), create a dedicated template under
  `identity/conditional-access/` scoped to `conditions.clientApplications`
  rather than editing the user-facing templates in this folder.
- Confirm no service principal depends on a legacy/basic-auth protocol
  (for example SMTP AUTH) before enabling `ca-block-legacy-auth` outside
  report-only mode.

## Rollout order

1. Deploy/keep every template in this folder in report-only (`state`) /
   eligible (`assignmentType`) mode — this is the default and the only mode
   this repository supports.
2. Replace every `REPLACE_WITH_*` emergency-access placeholder with a real,
   monitored object ID.
3. Run `scripts/validate-identity-artifacts.sh` (or `.ps1`) and confirm it
   passes.
4. Review Entra sign-in logs and the PIM audit history for the report-only
   period (Microsoft recommends at least one full business cycle, commonly
   two weeks or more) to confirm no unexpected user or workload is impacted.
5. Only then, in a separate, explicitly reviewed change, apply one policy at
   a time through Microsoft Graph (outside the scope of this repository) and
   re-observe before applying the next.

## Monitoring

- Entra ID → **Sign-in logs** filtered by Conditional Access result, and the
  built-in **Conditional Access insights and reporting** workbook, to see
  what each report-only policy would have done.
- Entra ID → **Privileged Identity Management** → **Audit history** for
  activation requests, approvals, and denials.
- Alert on sign-ins to the emergency-access accounts; they should be rare and
  always investigated.

## Rollback

- Conditional Access: set `state` back to `enabledForReportingButNotEnforced`
  (or `disabled`) through Microsoft Graph/the Entra portal. Because these
  artifacts always keep emergency-access accounts excluded, rollback never
  requires break-glass access to itself be restored.
- PIM: role settings changes take effect on the next activation request, so
  rolling back a `unifiedRoleManagementPolicy` update immediately relaxes the
  requirement for new activations; already-active, time-bound activations
  expire on their own per `maximumActivationDurationHours`.
- Neither rollback path requires deleting or recreating a user, group, or
  subscription managed by `main.bicep`.

## Static validation (no tenant contact)

```bash
./scripts/validate-identity-artifacts.sh
```

```powershell
.\scripts\validate-identity-artifacts.ps1
```

Both scripts are also invoked as the final step of `tests/test.sh` and
`tests/test.ps1`. They check, purely by reading the JSON files in this
repository:

- every Conditional Access template stays report-only by default;
- every PIM template stays eligible (never permanent) with approval, MFA,
  justification, and notifications required, and a 1–8 hour activation
  window;
- the emergency-access placeholder is present, non-empty, and (for
  Conditional Access) actually excluded;
- no tenant-specific GUID (other than the public, well-known Microsoft Azure
  Management application ID) appears anywhere under `identity/`.
