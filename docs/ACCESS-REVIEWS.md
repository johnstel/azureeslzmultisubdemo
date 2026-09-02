# Service-principal and privileged access reviews

Excessive standing permissions are governed here by evidence and human
decision, not by automation. This repository provides a read-only inventory
that surfaces candidates, a configurable criteria file that decides what is
surfaced, and the procedures below that decide what happens next. Nothing in
this repository removes a role assignment, creates a Microsoft Entra access
review, or enables Microsoft Defender CSPM.

## What the inventory does

`scripts/review-privileged-access.sh` and
`scripts/review-privileged-access.ps1` produce the same report from Azure role
assignments. Both are read-only: the only Azure calls are `az account show`
and `az role assignment list`.

Both require explicit runtime context. There is no implicit tenant, no
implicit subscription, and no whole-tenant enumeration:

```bash
./scripts/review-privileged-access.sh \
  --tenant-id <tenant-guid> \
  --subscription-id <connectivity-subscription-guid> \
  --subscription-id <workload-subscription-guid> \
  --management-group <demo-root-management-group-id>
```

```powershell
.\scripts\review-privileged-access.ps1 `
  -TenantId <tenant-guid> `
  -SubscriptionId <connectivity-subscription-guid>, <workload-subscription-guid> `
  -ManagementGroupId <demo-root-management-group-id>
```

The signed-in tenant must match `--tenant-id`/`-TenantId`, otherwise the run
fails before reading anything.

Each run writes a JSON report and a Markdown report to `.access-reviews/`
(override with `--output-dir`/`-OutputDirectory`). That directory is ignored
by source control. Reports contain directory identifiers, so keep them in the
customer's evidence store and never commit them. The reports contain no
secrets, no credentials, and no display names or user principal names: only
object IDs, principal types, role names, and scopes.

To classify an assignment export that was captured elsewhere, without making
any Azure call at all, use `--assignments-file`/`-AssignmentsFile` with a JSON
array (or an `az`-style object with a `value` array) of objects containing
`principalId`, `principalType`, `roleDefinitionName`, `scope`, and optionally
`id`. That offline mode is what the repository tests exercise.

## What the inventory surfaces

Each assignment is evaluated against `policy/access-review-criteria.json` and
is reported as a finding when any of the following holds:

- the role is in `highPrivilegeRoleNames` (Owner, User Access Administrator,
  and Role Based Access Control Administrator by default);
- the role is in `elevatedRoleNames` and the scope is broad
  (`tenantRoot`, `managementGroup`, or `subscription` by default);
- the principal type is in `nonHumanPrincipalTypes` (`ServicePrincipal` and
  `MSI`, which covers app registrations, workload identities, and managed
  identities) and the scope is broad.

Severity is `high` when a high-privilege role is held either at a broad scope
or directly by a service principal or managed identity, `medium` for the
remaining high-privilege or broad-scope non-human grants, and `low` otherwise.
Every finding carries `reviewAction: manual-review-required` and the reasons
that produced it. Severity is a triage order for reviewers. **No score,
severity, or reason means the code has determined that a grant is
unnecessary.** Business necessity is decided only by the reviewers named
below.

The report also counts distinct Owner principals per subscription and flags
subscriptions above `maxOwnersPerSubscription`. Owner assignments inherited
from a management group appear as separate management-group-scoped findings
and must be added to the per-subscription total by the reviewer.

## Configurable review criteria

`policy/access-review-criteria.json` is the tunable part. Change it when the
customer's role model differs; do not hard-code customer role names into the
scripts:

| Field | Meaning |
| --- | --- |
| `criteriaVersion` | Version stamped into every report for evidence. |
| `reviewCadenceDays` | Documented maximum interval between reviews. |
| `maxOwnersPerSubscription` | Owner-count threshold for the review below. |
| `broadScopeTypes` | Scope types treated as broad. |
| `nonHumanPrincipalTypes` | Principal types treated as workload identities. |
| `highPrivilegeRoleNames` | Roles that are always surfaced. |
| `elevatedRoleNames` | Roles surfaced when held at a broad scope. |

A supplied criteria file must define a non-empty `criteriaVersion`, integer
`reviewCadenceDays` and `maxOwnersPerSubscription` of at least one, and
non-empty string arrays for the four lists. Invalid files fail the run.

## Subscription Owner-count review

Run the inventory at least every `reviewCadenceDays` days, and additionally
after any privileged-access incident or bootstrap change.

1. Compare `summary.subscriptionOwnerCounts` with the customer's approved
   Owner roster, including the emergency-access accounts described in
   [PIM-ready Azure RBAC](AZURE-RBAC-PIM.md).
2. Add every management-group-scoped Owner finding to the affected
   subscriptions before judging the count.
3. For each subscription in `summary.subscriptionsExceedingOwnerThreshold`,
   record for every Owner principal whether it stays, is replaced by an
   eligible time-bound assignment, or is removed.
4. Treat any service-principal or managed-identity Owner or User Access
   Administrator grant as an exception that needs a named owner, a written
   justification, and a re-review date, even when the count is within
   threshold.

## Entra access-review cadence and ownership

Microsoft Entra access reviews (Microsoft Entra ID Governance licensed) are
the recurring control that this repository documents but never creates.
Configure them separately, and record the configuration as evidence:

| Review | Cadence | Reviewer | Escalation |
| --- | --- | --- | --- |
| Subscription and management-group Owner / User Access Administrator | Quarterly, and after any incident | Platform owner, with the security lead as fallback reviewer | Named accountable executive |
| Service principals and managed identities with broad or high-privilege scope | Quarterly | Application owner recorded on the workload | Platform owner |
| Groups used for the demo RBAC assignments | Semi-annually | Group owner | Platform owner |
| Emergency-access accounts | Semi-annually, review only | Security lead | Named accountable executive |

Recommended settings for each review: no self-review, reviewers must supply a
justification, "no response" must not auto-approve for privileged scopes, and
results must be exportable.

Reviewer ownership rules:

- Every privileged assignment has exactly one accountable reviewer, and no
  reviewer approves their own access.
- A workload identity is reviewed by the owner of the workload it serves, not
  by the platform team that created it.
- An assignment whose reviewer cannot be identified is escalated, not renewed.

## Evidence retention

For each review cycle, retain the following in the customer's evidence store
for at least the compliance retention period (12 months minimum, or longer
where NERC CIP or another obligation requires it):

- the JSON and Markdown reports produced by the inventory, including their
  `generatedOn`, `criteriaVersion`, and mode;
- the criteria file used, when it differs from the committed default;
- the reviewer decision for every finding, with justification and decision
  date;
- the exported Microsoft Entra access-review results;
- the change records for any assignment that was reduced or removed.

Reports are ignored by source control precisely so that directory inventory is
never committed to this repository.

## Remediation decision workflow

1. **Collect.** Run the inventory read-only for the explicit tenant,
   subscriptions, and management groups in scope.
2. **Attribute.** For every finding, identify the accountable owner and the
   business purpose. An unattributable privileged grant is escalated.
3. **Decide.** Choose exactly one outcome per finding: keep as is; reduce the
   scope; replace with a time-bound eligible assignment; or remove.
4. **Approve.** Record the decision, the approver, and the date. Decisions are
   made by people; the report is input, not authority.
5. **Change.** Implement the approved change through the customer's normal
   change process, outside this repository. No script here removes an
   assignment.
6. **Verify.** Re-run the inventory after the change window and confirm the
   finding is gone or the accepted exception is documented with a re-review
   date.

## Defender CSPM CIEM

When Microsoft Defender Cloud Security Posture Management is licensed and
enabled (see the opt-in Defender plan parameters in `main.bicep`), its cloud
infrastructure entitlement management (CIEM) recommendations complement this
inventory. The inventory reports what is assigned; CIEM adds permission-usage
signal, for example over-provisioned identities and unused high-privilege
permissions.

Use both together:

- Take the assignment truth, scope hierarchy, and Owner counts from the
  inventory, which works without a Defender licence.
- Take usage-based evidence, such as "permissions granted but not used", from
  the CIEM recommendations in Microsoft Defender for Cloud.
- Reconcile them during the review: a high-severity finding that CIEM also
  reports as unused is the strongest candidate for reduction; a finding that
  CIEM reports as actively used still needs a documented justification.

This repository never enables CIEM, never queries Defender, and does not
require a Defender licence for the inventory or the reviews above.

## Offline validation

The repository tests cover the inventory using fixtures only, with no tenant
access:

```bash
./tests/test.sh
```

```powershell
.\tests\test.ps1
```

## Microsoft references

- [List Azure role assignments](https://learn.microsoft.com/azure/role-based-access-control/role-assignments-list-cli)
- [Best practices for Azure RBAC](https://learn.microsoft.com/azure/role-based-access-control/best-practices)
- [Create an access review of Azure resource and Microsoft Entra roles in PIM](https://learn.microsoft.com/entra/id-governance/privileged-identity-management/pim-create-roles-and-resource-roles-review)
- [Review access of service principals and workload identities](https://learn.microsoft.com/entra/id-governance/create-access-review-workload-identities)
- [Permissions management (CIEM) in Defender for Cloud](https://learn.microsoft.com/azure/defender-for-cloud/permissions-management)
