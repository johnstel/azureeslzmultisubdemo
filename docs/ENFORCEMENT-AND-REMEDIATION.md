# Enforcement and remediation runbook

This runbook describes how to move a control from a reporting posture to an
enforcing one without breaking a workload, and how to reverse the change. It
covers the full progression: audit and `DoNotEnforce`, canary rollout with
resource selectors, remediation of existing resources, promotion to deny,
rollback, and exemptions.

> **Risk notice — read before executing anything on this page.**
>
> - Promoting `denyPolicyEnforcementMode` to `Default` can **block
>   deployments** across every scope that inherits a deny assignment,
>   including deployments made by people and pipelines that are not part of
>   this demo.
> - Starting a remediation task **changes existing resources**. Tag
>   inheritance writes tags; backup configuration creates protected items and
>   backup storage, which is **metered**; diagnostic-settings remediation
>   writes to a Log Analytics workspace, and ingestion and retention are
>   **metered**.
> - `DeployIfNotExists` with `enforcementMode = Default` also acts on new and
>   updated resources automatically, without any remediation task.
> - Every step below is reversible except the resource changes a remediation
>   task has already made. Plan the rollback before the promotion.

Everything in this repository ships non-enforcing. Nothing on this page happens
by itself; each stage requires a separate, explicit operator decision.

## Stage 0 — Know the current posture

`denyPolicyEnforcementMode` defaults to `DoNotEnforce`, so deny-capable
assignments are evaluated and report compliance but never block. Audit-only
controls report immediately. Remediation-capable assignments
(`Modify`/`DeployIfNotExists`) default to `Disabled` or `AuditIfNotExists`, and
this project never starts a remediation task for you.

Confirm what is actually assigned and what it currently reports:

```bash
az policy assignment list \
  --scope "/providers/Microsoft.Management/managementGroups/<namePrefix>" \
  --disable-scope-strict-match --output table
az policy state summarize \
  --management-group "<namePrefix>"
```

```powershell
az policy assignment list `
  --scope "/providers/Microsoft.Management/managementGroups/<namePrefix>" `
  --disable-scope-strict-match --output table
az policy state summarize `
  --management-group "<namePrefix>"
```

Compliance data is not instant. Allow up to about 30 minutes after a new
assignment before treating an empty result as "compliant", and trigger an
on-demand scan if you need results sooner.

## Stage 1 — Audit and `DoNotEnforce` (the default, and the baseline evidence)

Leave every control in its shipped posture until you can answer three
questions from real compliance data:

1. How many existing resources are non-compliant, and in which subscriptions?
2. Which of those are legitimate exceptions rather than defects?
3. Who owns each remaining non-compliant resource?

Export the evidence before changing anything, because it is the "before"
record you will compare the rollout against:

```bash
az policy state list \
  --management-group "<namePrefix>" \
  --filter "ComplianceState eq 'NonCompliant'" \
  --query "[].{policy:policyDefinitionName, resource:resourceId}" \
  --output tsv
```

Do not promote a control while the answer to any of those three questions is
unknown. `DoNotEnforce` costs nothing and can stay in place indefinitely.

## Stage 2 — Canary rollout with resource selectors

A resource selector keeps one assignment in place while limiting **which
resources it evaluates**, so a control can be enforced for a narrow slice
before it applies everywhere. `modules/policy-assignment.bicep` and
`modules/remediating-policy-assignment.bicep` accept a `resourceSelectors`
array. Each selector has a name and up to ten expressions; each expression uses
one selector kind (`resourceLocation`, `resourceType`, or
`resourceWithoutLocation`) with exactly one non-empty `in` **or** `notIn` array
of at most 50 values. A selector kind can be used only once per selector, and
`resourceLocation` cannot be combined with `resourceWithoutLocation` in the
same selector.

Selectors are not exposed as a parameter-file value. Adding one is a reviewed
source change to the assignment in `main.bicep`, which is deliberate: a canary
boundary should be visible in version control and in what-if, not set ad hoc at
deployment time.

A typical canary narrows a control to a single non-production region first:

```bicep
resourceSelectors: [
  {
    name: 'canary-eastus2'
    selectors: [
      {
        kind: 'resourceLocation'
        in: [
          'eastus2'
        ]
      }
    ]
  }
]
```

Widen the selector in reviewed increments — one region, then the remaining
regions, then remove the selector entirely — running what-if before each
change:

```bash
./scripts/what-if.sh parameters/demo.parameters.json
```

```powershell
.\scripts\what-if.ps1 -ParameterFile .\parameters\demo.parameters.json
```

Prefer a selector over an exemption for phased rollout. A selector is a
reviewed change in source control that applies to a class of resources; an
exemption is an exception for a specific scope and must carry an owner and an
expiry.

## Stage 3 — Remediate existing resources

Existing resources are never fixed by an assignment alone. Two remediation
paths exist in this project, and both are separate, confirmed operator
actions.

### Resource tags

After an approved deployment with `enableTagInheritance=true`, the
`tagInheritanceRemediation` output exposes the assignment ID and the six
definition reference IDs. Preview first; preview performs no Azure change:

```bash
./scripts/remediate-resource-tags.sh parameters/demo.parameters.json
```

```powershell
.\scripts\remediate-resource-tags.ps1 -ParameterFile .\parameters\demo.parameters.json
```

The scripts revalidate the live assignment ID, the exact Landing Zones scope,
the initiative, the system-assigned identity, a non-global identity location,
and the exact six built-in references before showing the preview. Only after
reviewing that preview:

```bash
export ESLZ_TAG_REMEDIATION_CONFIRMATION="REMEDIATE-MISSING-RESOURCE-TAGS"
./scripts/remediate-resource-tags.sh parameters/demo.parameters.json --execute
```

```powershell
$env:ESLZ_TAG_REMEDIATION_CONFIRMATION = "REMEDIATE-MISSING-RESOURCE-TAGS"
.\scripts\remediate-resource-tags.ps1 -ParameterFile .\parameters\demo.parameters.json -Execute
```

Both workflows then require typing the validated tenant, scope, and assignment
before revalidating the live controls and creating six tasks. These tasks only
add a missing tag whose resource-group value is non-empty; an existing resource
value always wins, so a customer-supplied tag is never overwritten.

### Backup and diagnostics

Backup configuration (`enableVmBackupRemediation=true` with
`vmBackupConfigurationEffect='DeployIfNotExists'`) and vault diagnostics
(`enableVaultDiagnostics=true` with `vaultDiagnosticsEffect='DeployIfNotExists'`)
create a system-assigned identity and the least-privilege roles documented in
the README's required-permissions section. This project starts **no**
remediation task for them. Protecting a pre-existing virtual machine requires a
deliberately started task, and every protected instance and its backup storage
are metered. With `denyPolicyEnforcementMode='Default'`, a `DeployIfNotExists`
backup assignment additionally protects matching virtual machines as they are
created or updated — a cost decision, not only a governance one. See
[`docs/SHARED-SERVICES-AND-COST.md`](SHARED-SERVICES-AND-COST.md).

Remediation identities are never granted Owner or User Access Administrator by
this project. An opt-in Defender plan therefore fails closed: the identity
exists but holds no role until a customer separately and temporarily authorizes
it outside this template.

## Stage 4 — Promote to deny

Only promote after Stages 1–3 show a stable, understood compliance picture and
every intended exception is either selector-scoped or covered by an approved
exemption.

1. Re-verify built-in definition versions. Built-ins — MCSB in particular — are
   updated in place; a promotion is the wrong moment to discover a new member.
2. Change `denyPolicyEnforcementMode` from `DoNotEnforce` to `Default` in your
   local parameter file. Change nothing else in the same deployment.
3. Run preflight and what-if and read the policy impact:

   ```bash
   ./scripts/preflight.sh parameters/demo.parameters.json
   ./scripts/what-if.sh parameters/demo.parameters.json
   ```

   ```powershell
   .\scripts\preflight.ps1 -ParameterFile .\parameters\demo.parameters.json
   .\scripts\what-if.ps1 -ParameterFile .\parameters\demo.parameters.json
   ```

4. Deploy with the explicit confirmation, during a change window, with the
   rollback below already agreed:

   ```bash
   export ESLZ_DEPLOY_CONFIRMATION="DEPLOY-ESLZ-DEMO"
   ./scripts/deploy.sh parameters/demo.parameters.json
   ```

   ```powershell
   $env:ESLZ_DEPLOY_CONFIRMATION = "DEPLOY-ESLZ-DEMO"
   .\scripts\deploy.ps1 -ParameterFile .\parameters\demo.parameters.json
   ```

5. Immediately test one intentionally non-compliant deployment in a sandbox
   scope and confirm it is denied for the expected reason, then test one
   compliant deployment and confirm it succeeds.

Promote in scope order — the narrowest branch first. Promoting a demo-root deny
assignment affects Platform and Connectivity as well as workloads, and is the
largest blast radius available in this project.

`denyPolicyEnforcementMode` is a single switch shared by the deny-capable
assignments. If you need one control enforced and another still reporting, keep
the switch at `DoNotEnforce` and use a resource selector, or split the
promotion across separate reviewed changes rather than flipping the switch
early.

## Stage 5 — Rollback

Rollback is a redeployment, not a deletion:

1. Set `denyPolicyEnforcementMode` back to `DoNotEnforce` and redeploy with the
   same confirmed workflow. The assignments remain and keep reporting; they
   stop blocking. This is the fastest and safest reversal and should be the
   default response to an unexpected block.
2. If a specific control is at fault, narrow it with a resource selector or set
   its own effect parameter (for example `networkIngressPolicyEffect`,
   `dataProtectionPolicyEffect`, or `vaultDiagnosticsEffect`) to `Audit` or
   `Disabled` and redeploy.
3. Use an exemption only for a scope that must keep operating while the
   underlying defect is fixed, and give it a short expiry.
4. Remediation tasks cannot be rolled back by changing a parameter. Tags
   already written stay written, protected items stay protected until backup is
   deliberately removed, and diagnostic settings already created keep sending
   data until deleted. Decide before Stage 3 who reverses these and how.
5. Teardown is not a rollback mechanism. It removes the hierarchy and is
   documented separately in the README.

Record what was rolled back, why, and which control is being fixed. A rollback
without a follow-up owner becomes a permanent silent gap.

## Exemptions

An exemption suppresses evaluation of an assignment for a specific scope. Use
it for a reviewed, ticketed, time-bound exception — never as an untracked
replacement for remediation, a selector-based rollout, or a `DoNotEnforce`
pilot.

`policyExemptions` is an empty array by default. Each record is validated by
`modules/policy-exemption.bicep` and must supply:

| Field | Meaning |
|---|---|
| `exemptionScopeType` | `managementGroup`, `subscription`, or `resourceGroup`, with the matching scope input |
| `policyAssignmentId` | The exact assignment being exempted |
| `exemptionCategory` | `Mitigated` when compensating controls exist, `Waiver` when accepting temporary risk |
| `owner` | The accountable person or team |
| `justification` | Why the exception is acceptable |
| `expiresOn` | Canonical RFC3339 UTC timestamp with a valid calendar date |
| `ticketReference` | The approval or evidence reference |
| `approver`, `createdOn`, `reviewedOn`, `governanceOwner` | Recorded in exemption metadata |

Initiative-specific exemptions may set `policyDefinitionReferenceIds`, and must
then also supply an explicit `allowedPolicyDefinitionReferenceIds` allowlist so
a typo cannot silently exempt more than was approved.
`permittedAncestorAssignmentScopeIds` constrains which ancestor assignment
scopes are acceptable.

The module enforces the timestamp format and calendar validity. It does **not**
check that the expiry is in the future at execution time; approval workflow and
operator preflight own that. Review exemptions on the same cadence as access
reviews and let expired records lapse rather than renewing them by default.

Use placeholder values such as `REPLACE_WITH_...` in shared files. Never commit
a real ticket system credential, a customer principal ID, or any secret in an
exemption record.

## Choosing between the mechanisms

| Situation | Use |
|---|---|
| Control is new and the impact is unknown | `DoNotEnforce` / audit effect |
| Control is understood and you want to enforce a slice first | Resource selector |
| Existing resources are non-compliant and must be fixed | Remediation task, previewed and confirmed |
| A scope is permanently outside the control's intent | `notScopes` on the assignment |
| A specific scope needs a reviewed, expiring exception | Policy exemption |
| Enforcement broke something | Roll back to `DoNotEnforce`, then fix forward |

## Related documents

- [Control scope and inheritance](CONTROL-SCOPE-AND-INHERITANCE.md)
- [Requirement-to-control matrix](CONTROL-MATRIX.md)
- [Shared services and cost](SHARED-SERVICES-AND-COST.md)
- [Identity governance runbook](IDENTITY-GOVERNANCE-RUNBOOK.md)
