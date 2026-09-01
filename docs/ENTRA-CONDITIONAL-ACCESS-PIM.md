# Entra Conditional Access and PIM runbook

This runbook documents directory identity-governance artifacts that Azure
Policy **cannot** implement, because Azure Policy governs Azure Resource
Manager resources while Conditional Access and directory-role activation are
controlled through Microsoft Entra ID and Microsoft Graph. Azure resource-role
PIM uses Azure RBAC/ARM and is documented separately in
[PIM-ready Azure RBAC](AZURE-RBAC-PIM.md).

The normal repository deployment applies nothing from this folder.
Conditional Access, directory-role PIM, and Owner activation settings remain
declarative report-only inputs. The sole deployable artifact is the separately
invoked, disabled-by-default Azure RBAC Owner eligibility request documented in
`AZURE-RBAC-PIM.md`; only its isolated, explicitly invoked operator workflows
call it. Those workflows perform a read-only Entra security-group check and ARM
state inventory before what-if. This repository never modifies Entra ID and
never enables Conditional Access.

## Why this is separate from Azure Policy

| Control plane | What it governs | Where it lives in this repo |
|---|---|---|
| Azure Policy (`modules/policy-library.bicep`, `modules/policy-assignment.bicep`) | ARM resource properties: allowed regions, resource types, required tags | Deployed by `main.bicep` at the demo management-group hierarchy |
| Conditional Access (`identity/conditional-access/`) | Sign-in behavior: which authentication controls apply to which users, apps, and client types | Static JSON inputs only; no deployment path in this repository |
| Privileged Identity Management (`identity/pim/`) | Directory-role activation: eligible vs. permanent assignment, approval, MFA, duration | Static JSON inputs only; no deployment path in this repository |
| Azure resource PIM (`identity/azure-rbac/`) | Subscription Owner eligibility and its mandatory activation baseline | Static report-only requirements plus a separately invoked, disabled-by-default one-shot ARM request artifact; activation policy remains report-only |

Azure Policy cannot require MFA, block legacy authentication protocols, or
enforce time-bound, approved role activation — those are Entra ID/Microsoft
Graph concepts, not ARM resource properties.

## Artifacts in this folder

```text
identity/
  azure-rbac/
    owner-eligibility-request.bicep
    owner-eligibility-request.parameters.template.json
    owner-activation-requirements.template.json
  conditional-access/
    ca-privileged-role-mfa.template.json   Phishing-resistant MFA for privileged directory roles
    ca-azure-mgmt-mfa.template.json        MFA for the Microsoft Azure Management application
    ca-block-legacy-auth.template.json     Blocks legacy authentication protocols
    ca-pim-activation-mfa.template.json    Phishing-resistant MFA for the PIM privileged-role-activation authentication context
  pim/
    pim-activation-global-administrator.template.json
    pim-activation-privileged-role-administrator.template.json
  schema/
    conditional-access-policy.schema.json  JSON Schema for the Conditional Access templates
    pim-activation-policy.schema.json      JSON Schema for the PIM templates
    known-entra-ids.json                   Public, tenant-independent Microsoft Entra/Graph constants (directory role template IDs, built-in authentication-strength policy IDs, the Microsoft Azure Management app ID) referenced by the templates and validators above
```

Every Conditional Access template defaults to
`"state": "enabledForReportingButNotEnforced"` (report-only) and every PIM
template defaults to `"assignmentType": "eligible"` with approval, MFA,
justification, notification, and a bounded activation duration required.
Neither can be silently changed to an enforcing/permanent shape without
editing the JSON, and `scripts/validate-identity-artifacts.sh` /
`scripts/validate-identity-artifacts.ps1` fail the build if anyone does.

Every field follows the shape Microsoft Graph actually expects for a
`conditionalAccessPolicy` resource:

- `conditions.users.includeUsers` uses the Graph literals `All`, `None`, or
  `GuestsOrExternalUsers`, or a user object ID — never a role display name.
- `conditions.users.includeRoles` contains only Microsoft Entra built-in
  directory role **template IDs** (GUIDs), never display names such as
  `Global Administrator` or the non-Graph value `All users`. The canonical
  IDs are recorded once in `identity/schema/known-entra-ids.json` and reused
  by every template and validator. `ca-privileged-role-mfa.template.json`
  must reference **exactly** the six intended privileged role IDs — the
  validators reject the set if a role is missing or if any extra role
  (recognized or not) is added.
- `grantControls.authenticationStrength` is a Graph relationship object
  (`{ "id": "<authenticationStrengthPolicy id>", "displayName": "..." }`),
  never a string inside `grantControls.builtInControls`. The built-in
  Phishing-resistant MFA policy id (`00000000-0000-0000-0000-000000000004`)
  is also recorded in `identity/schema/known-entra-ids.json`.
- `conditions.applications.includeAuthenticationContextClassReferences`, when
  present, contains only Graph `authenticationContextClassReference` ids
  (`c1`–`c25`) recorded in `identity/schema/known-entra-ids.json` — never a
  display name. Microsoft Graph models `conditions.applications` as a
  mutually exclusive choice: a policy scopes either by
  `includeApplications` or by `includeAuthenticationContextClassReferences`,
  never both. `ca-pim-activation-mfa.template.json` is the Conditional
  Access side of the `c1` ("PIM privileged-role activation") authentication
  context: it scopes only by `includeAuthenticationContextClassReferences:
  ["c1"]` (no `includeApplications`) and enforces phishing-resistant MFA
  whenever that context is invoked, and every PIM template's
  `activation.authenticationContext` must reference a `c1`–`c25` id that
  some committed Conditional Access template actually declares — the
  validators cross-check this and fail if a PIM template references a
  context with no enforcing Conditional Access policy.

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
  placeholder both exists **and** is the **only** entry in
  `conditions.users.excludeGroups` — an arbitrary extra excluded group is
  rejected just like a missing one, so the exclusion scope cannot be quietly
  broadened or diluted.
- PIM templates fail validation unless the emergency-access placeholder
  exists in `emergencyAccessExclusion`.

Both `emergencyAccessExclusion.placeholder` (PIM) and `activation.approvers`
(PIM) are schema-valid as either an unpopulated `REPLACE_WITH_*` value or a
syntactically valid object ID; the validators — not the schema — narrow this
per mode: template mode requires the unpopulated placeholder form, populated
mode requires a real object ID and rejects any leftover placeholder.

**Any future apply workflow must run this validation before calling
Microsoft Graph, and must refuse to apply a template whose placeholder still
starts with `REPLACE_WITH_`.** This prevents a Conditional Access or PIM
misconfiguration from locking every administrator out of the tenant, per
Microsoft's break-glass account guidance. Provision at least two cloud-only,
non-federated, non-PIM-managed emergency-access accounts, exclude them from
every Conditional Access policy, and monitor sign-ins to them with an alert.

## Workload identities

- The Azure management MFA and legacy-auth policies target
  `conditions.users.includeUsers: ["All"]`. Workload identities (service
  principals, managed identities) are governed separately from user
  Conditional Access by design; do not add service principals to
  `includeUsers`/`includeRoles` in these templates.
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
2. Run `scripts/validate-identity-artifacts.sh` (or `.ps1`) in the default
   `--mode template` to confirm the committed templates still have every
   `REPLACE_WITH_*` placeholder intact and contain no tenant-specific GUID.
3. Copy the `identity/` tree to a local, gitignored location (never commit
   the copy) and replace every `REPLACE_WITH_*` emergency-access placeholder
   with a real, monitored object ID.
4. Re-run the validator against that local copy in `--mode populated`
   (`--path`/`-Path` pointing at the copy) to confirm every placeholder was
   actually replaced with a valid object ID and every other report-only/
   eligible-only/grant-control rule still holds.
5. Review Entra sign-in logs and the PIM audit history for the report-only
   period (Microsoft recommends at least one full business cycle, commonly
   two weeks or more) to confirm no unexpected user or workload is impacted.
6. Only then, in a separate, explicitly reviewed change, apply one policy at
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

Template mode (default) validates the committed templates under `identity/`
and requires every emergency-access placeholder to remain an unpopulated
`REPLACE_WITH_*` value:

```bash
./scripts/validate-identity-artifacts.sh
```

```powershell
.\scripts\validate-identity-artifacts.ps1
```

Populated mode validates a local, gitignored copy of the templates after an
operator has replaced the placeholders with real object IDs, without ever
calling Microsoft Graph. It refuses to run against the tracked `identity/`
folder so populated, tenant-specific values are never committed:

```bash
./scripts/validate-identity-artifacts.sh --mode populated --path /path/to/local/identity
```

```powershell
.\scripts\validate-identity-artifacts.ps1 -Mode populated -Path C:\path\to\local\identity
```

Both scripts are also invoked (in the default template mode) as the final
step of `tests/test.sh` and `tests/test.ps1`. In every mode they check,
purely by reading JSON files on local disk:

- every Conditional Access template stays report-only by default;
- every PIM template stays eligible (never permanent) with approval, MFA,
  justification, and notifications required, and a 1–8 hour activation
  window;
- the emergency-access placeholder (Conditional Access) and every PIM
  `activation.approvers` entry and `emergencyAccessExclusion.placeholder` are
  present and, depending on mode, either an unpopulated `REPLACE_WITH_*`
  value or a syntactically valid object ID — and (for Conditional Access) the
  emergency-access placeholder is the only `conditions.users.excludeGroups`
  entry;
- `conditions.users` uses Graph-compatible subject values: `includeUsers`
  only contains `All`, `None`, `GuestsOrExternalUsers`, or object IDs, and
  `includeRoles` only contains known directory role template IDs (GUIDs),
  never display names or `All users`;
- `conditions.applications.includeApplications` or
  `includeAuthenticationContextClassReferences` (mutually exclusive — never
  both) and `conditions.clientAppTypes` are non-empty, and each of the four
  named Conditional Access templates matches its intended subject,
  application, client-type, and grant-control combination **exactly** — not
  just a superset — so a template cannot be silently broadened (for example,
  `ca-block-legacy-auth` must scope `clientAppTypes` to exactly the legacy
  protocol set and grant exactly `block`; `ca-privileged-role-mfa` must
  reference exactly the six intended privileged role IDs and must not also
  declare `includeUsers` or an additional `builtInControls` entry alongside
  its `authenticationStrength` relationship; `ca-pim-activation-mfa` must
  scope only by `includeAuthenticationContextClassReferences` and must not
  also declare `includeApplications`);
- `grantControls.authenticationStrength`, when present, references a known
  built-in `authenticationStrengthPolicy` id and is never duplicated as a
  `grantControls.builtInControls` string;
- every PIM `activation.authenticationContext` and every Conditional Access
  `includeAuthenticationContextClassReferences` entry is a known Graph
  `authenticationContextClassReference` id (`c1`–`c25`), never a display
  name, and every PIM-referenced authentication context has at least one
  committed Conditional Access template enforcing it;
- every PIM `activation.maximumActivationDurationHours` is a true integer
  from 1 through 8 (a fractional value such as `2.5` fails in both Bash and
  PowerShell, not just against the JSON Schema);
- all of the above literal/enum comparisons (`All`, `mfa`, `c1`,
  `enabledForReportingButNotEnforced`, `eligible`, directory role and
  authentication-strength/-context ids, etc.) are **case-sensitive** in both
  the Bash and PowerShell validators, matching Microsoft Graph's
  case-sensitive literals — a mutated value such as `ALL`, `MFA`, or `C1`
  fails validation exactly like an unrecognized value would;
- in template mode only, no tenant-specific GUID (other than the public,
  well-known Microsoft constants in `identity/schema/known-entra-ids.json`)
  appears anywhere under `identity/`.
