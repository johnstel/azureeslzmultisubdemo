# PIM-ready Azure RBAC

This repository uses a group-based, time-bound eligible assignment as the
normal v2 pattern for subscription Owner. It does **not** create a permanent
Owner role assignment for the platform team, an individual user, a service
principal, or a managed identity.

The implementation has two deliberately separate parts:

- `modules/subscription-rbac.bicep` can create an eligible Owner schedule
  request with
  `Microsoft.Authorization/roleEligibilityScheduleRequests@2020-10-01`.
- `identity/azure-rbac/owner-activation-requirements.template.json` records the
  mandatory PIM activation baseline as a static, tenant-independent,
  report-only artifact.

Neither the static artifact nor either validator calls Microsoft Graph,
Microsoft Entra ID, or Azure. The guarded deployment scripts can submit the
Bicep schedule requests only after an operator explicitly enables them and
approves the normal preflight and what-if workflow.

## Safe defaults and scope

`deployEligibleOwnerRoleAssignments` defaults to `false`. The privileged group,
start date/time, and assignment justification default to empty strings in
`main.bicep`. The committed parameter templates contain only
`REPLACE_WITH_*` placeholders and also keep the feature disabled.

When explicitly enabled, the same existing security group receives one
time-bound **eligible** Owner assignment at each of the two sandbox
subscriptions. The request:

- uses `AdminAssign`, never an active role-assignment schedule;
- uses a finite `AfterDuration` schedule;
- accepts only `P30D`, `P90D`, `P180D`, or `P365D`;
- requires an RFC 3339 UTC start date/time and a business justification;
- remains inside the two subscriptions under the dedicated demo root.

`deployRoleAssignments` remains a separate opt-in. It controls the permanent,
group-based Management Group Contributor, Resource Policy Contributor, Reader,
Network Contributor, and workload Contributor assignments. Enabling ordinary
RBAC does not enable eligible Owner, and enabling eligible Owner does not
enable the ordinary assignments.

## Prerequisites

Before enabling `deployEligibleOwnerRoleAssignments`, verify all of the
following outside this repository:

1. Microsoft Entra PIM is available through Microsoft Entra ID P2 or Microsoft
   Entra ID Governance licensing, and every user who can activate through the
   group has the required license.
2. `subscriptionPrivilegedAccessGroupObjectId` identifies an existing
   Microsoft Entra **security group**. The offline validator checks only the
   parameter wiring and GUID shape; it deliberately does not query the
   directory. The schedule-request API infers the principal type from that
   object ID; its `principalType` field is response-only and is not written by
   Bicep.
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

Before submitting either eligibility request, configure the Owner role settings
at each subscription to match
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

## Bootstrap order before restriction policy

Use this order before enforcing any Azure Policy that restricts eligible or
time-bound role assignments:

1. Establish and test customer-managed emergency access outside the repository.
2. License eligible users and create the dedicated security group.
3. Configure and independently review Owner activation settings at both
   subscriptions.
4. Grant the deployment principal narrowly scoped, time-bound bootstrap
   authority.
5. Populate the PIM parameters locally, keeping
   `deployEligibleOwnerRoleAssignments=false`.
6. Run both offline validators, preflight, and tenant-scope what-if.
7. Set `deployEligibleOwnerRoleAssignments=true`, rerun validation and what-if,
   obtain approval, and use the guarded deployment path.
8. Verify both assignments appear as **Eligible time-bound**, test activation
   and approval, and inspect PIM audit history and notifications.
9. Remove temporary bootstrap access.
10. Only after the working eligibility path and emergency access have been
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

The validators compile Bicep locally and prove that:

- no permanent Owner `roleAssignments` resource exists;
- no active Owner schedule request exists;
- both eligible Owner artifacts are gated, finite, justified, and group-wired;
- both parameter templates default to disabled and contain no tenant values;
- the static activation baseline requires approval, MFA, justification,
  bounded duration, notifications, and external emergency-access handling;
- no PIM activation-policy resource is deployed by this repository.

## Update and teardown limitation

An eligibility schedule request is a PIM request record, not a normal permanent
role assignment. Changing the start date or duration of an existing eligibility
requires a separately reviewed PIM update operation. Removing it requires a
separately reviewed `AdminRemove` request against the resulting eligibility
schedule.

An incremental deployment of this v2 template also does not delete a permanent
Owner assignment created by an earlier repository version. Before upgrading,
inventory both subscriptions and plan that legacy assignment's removal as a
separate approved change. Establish the new eligible path and emergency
recovery first where Azure permits both assignments; if an existing active
assignment prevents creation of the eligibility, use separately approved,
time-bound bootstrap access to avoid a lockout during the staged replacement.
The offline validator cannot prove that live legacy assignments are gone.

The teardown scripts remove only the five ordinary demo role assignments. They
do not discover, infer, or automatically remove PIM eligibility. Remove and
verify both eligible Owner schedules separately before considering privileged
access teardown complete.

## Microsoft references

- [Eligible and time-bound role assignments in Azure RBAC](https://learn.microsoft.com/azure/role-based-access-control/pim-integration)
- [Assign Azure resource roles in PIM](https://learn.microsoft.com/entra/id-governance/privileged-identity-management/pim-resource-roles-assign-roles)
- [Configure Azure resource role settings in PIM](https://learn.microsoft.com/entra/id-governance/privileged-identity-management/pim-resource-roles-configure-role-settings)
- [`roleEligibilityScheduleRequests` Bicep reference](https://learn.microsoft.com/azure/templates/microsoft.authorization/roleeligibilityschedulerequests)
- [Manage emergency-access accounts](https://learn.microsoft.com/entra/identity/role-based-access-control/security-emergency-access)
