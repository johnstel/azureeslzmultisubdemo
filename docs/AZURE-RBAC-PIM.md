# PIM-ready Azure RBAC

This repository uses a group-based, time-bound eligible assignment as the
normal v2 pattern for subscription Owner. The repeatable `main.bicep`
deployment creates neither permanent Owner nor a PIM eligibility request for
the platform team, an individual user, a service principal, or a managed
identity.

The implementation has two deliberately separate parts:

- `identity/azure-rbac/owner-eligibility-request.bicep` is an explicit,
  subscription-scoped, one-shot lifecycle artifact for
  `Microsoft.Authorization/roleEligibilityScheduleRequests@2020-10-01`. It is
  not referenced by `main.bicep` or any normal deployment script.
- `identity/azure-rbac/owner-activation-requirements.template.json` records the
  mandatory PIM activation baseline as a static, tenant-independent,
  report-only artifact.

Neither artifact nor either validator calls Microsoft Graph, Microsoft Entra
ID, or Azure. An authorized operator may submit the one-shot artifact only
through a separately reviewed subscription deployment after completing the
precheck and approval workflow below.

## Safe defaults and scope

The normal main parameter templates contain no Owner eligibility parameters.
Therefore safe demo defaults, ordinary redeployments, and the guarded main
deployment scripts cannot submit or replay a PIM request.

The separate parameter template keeps `submitEligibilityRequest=false` and
contains only `REPLACE_WITH_*` placeholders. The Bicep artifact also requires a
caller-supplied 36-character request GUID and a lifecycle action with no
default. One invocation targets one subscription and one operation. For
`AdminAssign` and `AdminUpdate`, it uses a finite `AfterDuration` schedule of
`P30D`, `P90D`, `P180D`, or `P365D`. It never creates an active
`roleAssignmentScheduleRequests` resource.

`deployRoleAssignments` remains a separate opt-in. It controls the permanent,
group-based Management Group Contributor, Resource Policy Contributor, Reader,
Network Contributor, and workload Contributor assignments. Enabling or
redeploying ordinary RBAC cannot submit eligible Owner.

## Prerequisites

Before preparing a one-shot request, verify all of the following outside this
repository:

1. Microsoft Entra PIM is available through Microsoft Entra ID P2 or Microsoft
   Entra ID Governance licensing, and every user who can activate through the
   group has the required license.
2. `subscriptionPrivilegedAccessGroupObjectId` identifies an existing
   Microsoft Entra **security group**. The offline validator checks only
   parameter wiring; it deliberately does not query the directory. The
   schedule-request API infers the principal type from that object ID; its
   `principalType` field is response-only and is not written by Bicep.
3. Owner role settings are configured and reviewed independently at **both**
   subscriptions. Role settings are per role and per resource and do not
   inherit from the subscription to child scopes.
4. Customer emergency-access capability has already been established, tested,
   monitored, and approved. This repository neither assumes that emergency
   accounts exist nor creates or assigns them.
5. The deployment principal has the existing Azure authorization needed to
   create role eligibility schedule requests. Microsoft documents Owner or
   User Access Administrator for managing Azure resource PIM role settings and
   assignments. The principal also needs the tenant- and management-group-scope
   permissions already documented for the landing-zone deployment.

Do not solve a bootstrap failure by granting broad permanent Owner at the
tenant root. Grant the deployment principal only the narrow, temporary access
and scope required for the reviewed operation, then remove it according to the
customer access-governance process.

## Mandatory activation baseline

The Bicep schedule request creates eligibility; it does **not** apply PIM role
settings. Applying `roleManagementPolicies`, Conditional Access, or Microsoft
Graph configuration is out of scope.

Before submitting any eligibility request, configure the Owner role settings at
each subscription to match
`identity/azure-rbac/owner-activation-requirements.template.json`:

- approval is required, with at least two reviewed approvers recommended;
- MFA or a reviewed Conditional Access authentication context is required;
- business justification is required for every activation;
- activation is limited to four hours (the repository baseline, within its
  enforced 1–8 hour range);
- administrators, approvers, and the assignee receive the relevant activation
  notifications;
- permanent eligible and permanent active assignment are not the normal
  platform-team pattern.

PIM role settings and the time-bound eligibility window are different controls.
The eligibility window says when the group may request activation. The maximum
activation duration says how long an approved activation remains active.

## One-shot request workflow

Treat every `roleEligibilityScheduleRequests` resource as an immutable request
record, not an idempotent desired-state resource. A request name is consumed by
one operation. Generate a **fresh request GUID** for each subscription and each
`AdminAssign`, `AdminUpdate`, or `AdminRemove` operation. **Never reuse** a
request GUID for redeployment, retry, another action, or another subscription.

1. In Microsoft Entra PIM for the target Azure subscription, inspect **existing
   eligibility** for the privileged group and Owner role. Use the portal or an
   independently approved read-only inventory process. Do not submit
   `AdminAssign` if a matching eligibility or pending request already exists.
2. Record the existing `roleEligibilityScheduleId` when updating or removing
   eligibility. This schedule ID is not the prior request ID.
3. Copy
   `identity/azure-rbac/owner-eligibility-request.parameters.template.json` to
   a gitignored `*.local.json` file.
4. Replace every placeholder, generate a new GUID outside Bicep, select the
   lifecycle action, and keep `submitEligibilityRequest=false` during local
   preparation.
5. Build the Bicep locally and run both offline validators.
6. Set `submitEligibilityRequest=true` only in the prepared local file and run
   a subscription-scope what-if against exactly one intended sandbox
   subscription. What-if does not submit the request. Confirm the preview
   contains one eligible Owner request and no active or permanent Owner
   assignment.
7. Obtain approval from that exact preview, then submit the unchanged reviewed
   request exactly once through a separately controlled subscription
   deployment. Use a unique deployment name as well as the fresh request GUID.
8. Verify the resulting PIM state and audit record. If the deployment result is
   ambiguous, repeat the existing-eligibility precheck before deciding what to
   do; do not retry with the same request GUID.

The lifecycle actions are:

| Action | When to use it | Target schedule ID | Schedule fields |
|---|---|---|---|
| `AdminAssign` | Create eligibility only after confirming none exists | Must be empty | Required and finite |
| `AdminUpdate` | Change the time-bound window of an existing eligibility | Required | Required and finite |
| `AdminRemove` | Remove an existing eligibility | Required | Omitted by the artifact |

For the two sandbox subscriptions, complete this workflow twice with distinct
request GUIDs. Do not add the artifact to `main.bicep`.

## Bootstrap order before restriction policy

Use this order before enforcing any Azure Policy that restricts eligible or
time-bound role assignments:

1. Establish and test customer-managed emergency access outside the repository.
2. License eligible users and create the dedicated security group.
3. Configure and independently review Owner activation settings at both
   subscriptions.
4. Grant the deployment principal narrowly scoped, time-bound bootstrap
   authority.
5. Complete the existing-eligibility precheck at each subscription.
6. Prepare separate local one-shot parameter files with
   `submitEligibilityRequest=false` and a fresh request GUID for each
   subscription.
7. Run both offline validators, then set `submitEligibilityRequest=true` in
   each local file and run a subscription-scope what-if for each request.
8. Obtain approval from each exact preview, submit the unchanged request once,
   and verify both assignments appear as **Eligible time-bound**.
9. Test activation and approval, and inspect PIM audit history and
   notifications.
10. Remove temporary bootstrap access.
11. Only after the working eligibility path and emergency access have been
    verified, enforce the separately managed role-assignment restriction
    policy.

Enforcing the restriction policy earlier can block the very schedule requests
needed to establish the approved PIM path.

## Emergency access

Standing Owner access is reserved solely for the customer's explicitly
approved emergency-access design. It is never represented by
`subscriptionPrivilegedAccessGroupObjectId`, never created by this repository,
and never encoded with an account or group object ID in a committed file.

Follow Microsoft's emergency-access guidance: use at least two cloud-only,
non-federated accounts, keep them outside normal PIM activation dependencies,
protect their credentials, test them regularly, and alert on every sign-in.
The customer decides whether Azure subscription access is part of that design
and owns its creation, review, and removal.

## Offline validation

Windows PowerShell:

```powershell
.\scripts\validate-rbac-artifacts.ps1
```

macOS or Linux:

```bash
./scripts/validate-rbac-artifacts.sh
```

The validators compile both Bicep entry points locally and prove that:

- no permanent Owner `roleAssignments` resource exists;
- no active Owner schedule request exists;
- repeatable `main.bicep` contains no eligibility schedule request or PIM
  request parameter;
- the one-shot artifact requires explicit opt-in, a caller-supplied request
  GUID, a lifecycle action, a group, justification, and a finite schedule for
  assignment or update;
- the separate parameter template defaults to disabled and contains no tenant
  values;
- the static activation baseline requires approval, MFA, justification,
  bounded duration, notifications, and external emergency-access handling;
- no PIM activation-policy resource is deployed by this repository.

## Update and teardown limitation

Changing the start date or duration of an existing eligibility requires a
separately reviewed `AdminUpdate` operation with its schedule ID and a fresh
request GUID. Removing it requires a separately reviewed `AdminRemove`
operation with its schedule ID and another fresh request GUID.

An incremental deployment of this v2 template also does not delete a permanent
Owner assignment created by an earlier repository version. Before upgrading,
inventory both subscriptions and plan that legacy assignment's removal as a
separate approved change. Establish the new eligible path and emergency
recovery first where Azure permits both assignments; if an existing active
assignment prevents creation of the eligibility, use separately approved,
time-bound bootstrap access to avoid a lockout during the staged replacement.
The offline validator cannot prove that live legacy assignments are gone.

The teardown scripts remove only the five ordinary demo role assignments. They
do not discover, infer, or automatically remove PIM eligibility. Use separate
one-shot `AdminRemove` requests and verify both eligible Owner schedules are
gone before considering privileged-access teardown complete.

## Microsoft references

- [Eligible and time-bound role assignments in Azure RBAC](https://learn.microsoft.com/azure/role-based-access-control/pim-integration)
- [Assign Azure resource roles in PIM](https://learn.microsoft.com/entra/id-governance/privileged-identity-management/pim-resource-roles-assign-roles)
- [Configure Azure resource role settings in PIM](https://learn.microsoft.com/entra/id-governance/privileged-identity-management/pim-resource-roles-configure-role-settings)
- [`roleEligibilityScheduleRequests` Bicep reference](https://learn.microsoft.com/azure/templates/microsoft.authorization/roleeligibilityschedulerequests)
- [Manage emergency-access accounts](https://learn.microsoft.com/entra/identity/role-based-access-control/security-emergency-access)
