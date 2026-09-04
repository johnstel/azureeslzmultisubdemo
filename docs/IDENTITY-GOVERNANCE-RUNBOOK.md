# Identity governance runbook

This runbook sequences the identity work for a v2 deployment: PIM-ready Azure
RBAC, the report-only Conditional Access rollout, break-glass review, recurring
access reviews, and service-principal / CIEM review. It is the entry point; the
detailed reference for each stage lives in its own document.

| Stage | Detail document |
|---|---|
| PIM-ready Azure RBAC and eligible Owner | [`docs/AZURE-RBAC-PIM.md`](AZURE-RBAC-PIM.md) |
| Conditional Access and PIM activation artifacts | [`docs/ENTRA-CONDITIONAL-ACCESS-PIM.md`](ENTRA-CONDITIONAL-ACCESS-PIM.md) |
| Privileged access and service-principal review | [`docs/ACCESS-REVIEWS.md`](ACCESS-REVIEWS.md) |
| Requirement mapping (REQ-ID-01 … REQ-ID-06) | [`docs/CONTROL-MATRIX.md`](CONTROL-MATRIX.md) |

> **Boundary.** Azure Policy cannot require MFA, block legacy authentication,
> or govern privileged-role activation. Everything in this runbook is
> identity-plane work that sits **outside** the policy deployment.
>
> **This repository never modifies Microsoft Entra ID.** It creates no user,
> group, service principal, Conditional Access policy, or PIM role setting.
> Every identity artifact here is report-only or a separately invoked,
> confirmation-gated request. The only Entra read performed anywhere is one
> read-only group lookup inside the isolated Owner eligibility workflow;
> normal deployment and the offline validators do not contact Entra at all.

## Prerequisites

1. Four existing Entra **security groups** for the baseline roles. Bicep does
   not create identities; the deployment consumes object IDs only.
2. A separate group (or groups) intended to hold eligible subscription Owner.
   Never reuse an ordinary workload group for privileged access.
3. At least two cloud-only, non-federated, non-PIM-managed emergency-access
   (break-glass) accounts that already exist and are already monitored.
4. Licensing confirmed for the Entra features you intend to use — see the
   licensing section of the Conditional Access runbook. Report-only evaluation
   and PIM both have licensing prerequisites.
5. Named owners for each stage below. An unowned identity control decays.

## Stage 1 — Baseline group RBAC (no Owner, no PIM required)

`deployRoleAssignments` is `false` by default. When enabled, the deployment
creates exactly these ordinary assignments:

| Group parameter | Assignment |
|---|---|
| `governanceAdminsGroupObjectId` | Management Group Contributor and Resource Policy Contributor at the demo root |
| `networkOperatorsGroupObjectId` | Network Contributor on the connectivity subscription |
| `workloadContributorsGroupObjectId` | Contributor on the workload subscription |
| `readOnlyAuditorsGroupObjectId` | Reader at the demo root |

Enabling ordinary RBAC never grants Owner or User Access Administrator, and
`main.bicep` contains no Owner eligibility request, so a routine redeployment
cannot replay a one-time privileged request. The deployment principal must
already hold enough access to create these assignments; the template never
bootstraps its own authority.

Validate the artifacts offline before deploying:

```bash
./scripts/validate-rbac-artifacts.sh
```

```powershell
.\scripts\validate-rbac-artifacts.ps1
```

## Stage 2 — Review break-glass before any restriction

Do this **before** Conditional Access or PIM work, not after. A Conditional
Access or PIM misconfiguration with no valid exclusion can lock every
administrator out of the tenant.

Confirm, and record as evidence:

- at least two emergency-access accounts exist, are cloud-only, non-federated,
  and are **not** PIM-managed;
- they are excluded from every Conditional Access policy you intend to apply;
- their credentials are stored under a documented custody process, and their
  sign-ins raise an alert;
- their exclusion group object ID is the value you will substitute for the
  `REPLACE_WITH_*` emergency-access placeholder.

Every template in `identity/conditional-access/` and `identity/pim/` declares an
`emergencyAccessExclusion` with `required: true` and an unpopulated
placeholder. The validators enforce this: a Conditional Access template fails
unless the emergency-access placeholder is the **only** entry in
`conditions.users.excludeGroups`, so the exclusion cannot be quietly broadened
or diluted, and any apply workflow must refuse a template whose placeholder
still starts with `REPLACE_WITH_`.

For Azure RBAC, emergency access stays entirely customer-managed and outside
this repository. No permanent Owner assignment is created here.

## Stage 3 — Conditional Access, report-only first

The report-only templates in `identity/conditional-access/` cover REQ-ID-01
through REQ-ID-03:

| Template | Intent |
|---|---|
| `ca-privileged-role-mfa.template.json` | Phishing-resistant MFA for privileged Entra roles |
| `ca-azure-mgmt-mfa.template.json` | MFA for any access to Azure Resource Manager |
| `ca-block-legacy-auth.template.json` | Block legacy (basic) authentication |
| `ca-pim-activation-mfa.template.json` | MFA at PIM activation |

Rollout sequence:

1. Validate the artifacts offline. This contacts no tenant:

   ```bash
   ./scripts/validate-identity-artifacts.sh
   ```

   ```powershell
   .\scripts\validate-identity-artifacts.ps1
   ```

2. Replace the emergency-access placeholder with the real exclusion group
   object ID from Stage 2, and re-run validation in populated mode.
3. Create each policy in **report-only** state. Report-only evaluates and logs
   the outcome without blocking any sign-in.
4. Leave it in report-only long enough to cover a full business cycle,
   including month-end and any batch or service workload that only runs
   periodically. A week that excludes your rarest workload is not enough.
5. Review report-only results in sign-in logs. Investigate every would-be
   block: legacy-authentication clients, unmanaged service accounts, and
   automation using password grants are the usual findings.
6. Enable one policy at a time, starting with the narrowest audience, and
   verify break-glass sign-in still works after each change.
7. Roll back by returning the single policy to report-only — not by deleting
   it — so the evidence trail stays intact.

Workload identities need separate treatment; see the workload-identity section
of the Conditional Access runbook. Do not sweep service principals into a
user-shaped policy.

## Stage 4 — PIM-ready eligible Owner

Standing subscription Owner is what this project is trying to remove
(REQ-ID-04). The eligible-Owner request is a **separately invoked, one-shot**
operator workflow in `scripts/owner-eligibility-request.*`. It is never called
by `main.bicep`, and direct use of the backing Bicep artifact is unsupported.

The workflow requires a fresh caller-supplied request GUID and a finite
schedule, verifies that the supplied object is an existing security-enabled
group, checks current eligibility and pending requests, and runs what-if before
stopping by default. Submission requires layered explicit confirmation.

```bash
./scripts/owner-eligibility-request.sh \
  --subscription-id <subscription-guid> \
  --parameter-file parameters/demo.parameters.json
```

```powershell
.\scripts\owner-eligibility-request.ps1 `
  -SubscriptionId <subscription-guid> `
  -ParameterFile .\parameters\demo.parameters.json
```

The default mode performs read-only preflight checks and an Azure what-if and
submits nothing. Submission additionally requires `--execute` / `-Execute`,
`ESLZ_OWNER_ELIGIBILITY_CONFIRMATION=SUBMIT-OWNER-ELIGIBILITY`, and a typed
request-ID confirmation after the what-if.

Approval, MFA, activation justification, the four-hour activation duration, and
notification expectations are a static report-only contract in
`identity/azure-rbac/owner-activation-requirements.template.json`. Configure and
verify those PIM role settings separately, at **both** subscriptions, before
opting in — an eligible assignment without an activation policy is standing
access with extra steps.

Order matters: establish eligible Owner and confirm activation works **before**
promoting any restrictive policy to enforcing, so a locked-out operator can
still act. See the bootstrap-order section of the PIM-ready Azure RBAC
document.

## Stage 5 — Recurring privileged access review

Standing privileged permissions are reviewed with evidence, not silently
removed by automation.

```bash
./scripts/review-privileged-access.sh \
  --tenant-id <tenant-guid> \
  --subscription-id <subscription-guid>
```

```powershell
.\scripts\review-privileged-access.ps1 `
  -TenantId <tenant-guid> `
  -SubscriptionId <subscription-guid>
```

Add `--management-group` / `-ManagementGroupId` to include inherited grants, and
`--criteria-file` / `-CriteriaFile` to supply review criteria other than
`policy/access-review-criteria.json`.

The inventory is read-only. It changes nothing, never calls Microsoft Graph,
and never concludes that a grant is excessive. It highlights Owner, User Access
Administrator, and other high-privilege roles, broad management-group or
subscription scopes, and every direct service-principal or managed-identity
grant, and it counts Owner principals per subscription including Owners
inherited from a management group. Results from inherited queries are
deduplicated by role-assignment ID while recording which requested
subscriptions observed each grant.

Reports are written to the source-control-ignored `.access-reviews/` directory,
contain no secrets or display names, and belong in the customer's evidence
store — not in this repository.

Human judgement, cadence, reviewer ownership, retention, and the remediation
decision workflow are defined in
[`docs/ACCESS-REVIEWS.md`](ACCESS-REVIEWS.md). Run the inventory on the cadence
recorded there, and pair it with Entra access reviews for group membership,
which this inventory does not cover.

## Stage 6 — Service-principal and CIEM review

Direct service-principal and managed-identity role assignments are the grants
most likely to be over-privileged and least likely to be reviewed. For each one
the inventory surfaces, record the owning application, why the scope is
necessary, and when it was last used.

Where Defender for Cloud CSPM is licensed and enabled, its CIEM findings
(REQ-ID-06) complement the inventory with permission-usage analysis that
role-assignment data alone cannot provide. That plan is **paid and disabled by
default** (`enableDefenderCspm=false`, with `enableDefenderCiem` controlling the
CIEM extension when CSPM is enabled). Enabling it is a cost decision — see
[`docs/SHARED-SERVICES-AND-COST.md`](SHARED-SERVICES-AND-COST.md).

Remediation identities created by this project are deliberately never granted
Owner or User Access Administrator. An opt-in Defender plan therefore fails
closed with a role-less identity until a customer separately, temporarily, and
outside this template authorizes it. Include those temporary authorizations in
this review; they are the ones most likely to be forgotten.

## Evidence to retain

| Stage | Evidence |
|---|---|
| Break-glass | Account inventory, exclusion group ID, alert configuration, custody record |
| Conditional Access | Report-only findings, enablement approvals, per-policy state history |
| PIM | Activation policy settings at both subscriptions, eligibility request records, activation logs |
| Access review | `.access-reviews/` report, reviewer decision, action taken or accepted risk |
| Service principal / CIEM | Owning application, justification, last-used date, CIEM findings disposition |

Store this evidence in the customer's system of record. Reports here are
inputs to that process, not the record itself. Nothing in this repository
asserts, claims, or certifies compliance with any regulatory framework.

## Safe stopping points

- After Stage 1 you have least-privilege group RBAC and no privileged change.
- After Stage 3, step 3, every Conditional Access policy is report-only and
  blocks nothing.
- After Stage 5 you have an evidence report and have changed nothing in Azure
  or Entra.

Each of these is a defensible place to pause indefinitely.
