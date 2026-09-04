# Control scope and inheritance

This document explains **where** each v2 control is assigned and **what
inherits it**. It is the companion to the requirement-to-mechanism mapping in
[`docs/CONTROL-MATRIX.md`](CONTROL-MATRIX.md) and the machine-readable
[`policy/control-catalog.json`](../policy/control-catalog.json): the matrix
answers *what* implements a requirement, this document answers *where it
applies*.

Nothing here changes Azure. Scope decisions are made in `main.bicep` and are
visible in tenant-scope what-if before any deployment.

## The inheritance rule

Azure Policy inheritance works downward and cannot be cancelled by a child
scope:

- An assignment at a management group applies to that management group, every
  descendant management group, every subscription under it, and every resource
  group and resource in those subscriptions.
- A child scope can never make a parent assignment less strict. Only three
  mechanisms narrow an inherited assignment: `notScopes` on the assignment,
  a resource selector on the assignment, and a policy **exemption** at or below
  the assignment scope.
- Assignments stack. A resource in the Critical Infrastructure branch is
  evaluated by demo-root, Landing Zones, **and** Critical Infrastructure
  assignments at the same time, and the strictest effect wins.

If you know Active Directory, the demo root behaves like a top-level OU with a
linked GPO, and Critical Infrastructure behaves like a nested OU with an
additional, stricter GPO layered on top. Unlike Group Policy, there is no
"block inheritance"; the closest equivalent is a documented, expiring
exemption.

## The hierarchy

```text
Tenant root management group (existing; never receives a demo assignment)
└── <namePrefix>                      Demo root
    ├── <namePrefix>-platform         Platform
    │   └── <namePrefix>-connectivity Connectivity
    │       └── Connectivity sandbox subscription
    └── <namePrefix>-landingzones     Landing Zones
        ├── <namePrefix>-corp | <namePrefix>-online   Workload branch
        │   └── Workload sandbox subscription
        └── <namePrefix>-criticalinfra                Critical Infrastructure
            └── Critical-workload subscriptions (opt-in)
```

The Critical Infrastructure branch exists only when
`enableCriticalInfrastructure=true`, and it takes its subscriptions from
`criticalInfrastructureSubscriptionIds`. It is a **sibling** of the workload
branch under Landing Zones, not a child of it, so the workload-branch
assignments below do **not** reach critical subscriptions. Be precise about
what that means in the current implementation:

- The **private access** guardrails do have a dedicated critical copy
  (`Demo - critical private access guardrails`), created whenever
  `enableCriticalInfrastructure=true`.
- The **approved firewall route** guardrails have a critical copy only when
  `enableFirewallRouteGuardrails=true`; that switch is off by default.
- The **network ingress** guardrails (public SSH/RDP NSG rules, subnets without
  an NSG) have **no** ordinary critical copy. `Demo - workload network ingress
  guardrails` is assigned at the workload branch only. Critical subscriptions
  receive equivalent network-boundary coverage **only** through the NERC CIP
  technical overlay, which is off by default
  (`enableNercCipTechnicalOverlay=false`). If you enable the Critical
  Infrastructure branch without the overlay, critical subscriptions are **not**
  evaluated for public management ingress or missing subnet NSGs.

The tenant root management group is supplied only so the hierarchy can be
created beneath it and so teardown can move the subscriptions back. It never
receives a definition, assignment, exemption, or role assignment from this
project.

## Where custom definitions live

Every custom policy definition and initiative created by this project is
written at the **demo root** (`<namePrefix>`), never at the tenant root. Child
scopes then assign those demo-root definitions. This keeps one authoritative
definition per control while allowing different branches to assign it with
different parameters and effects — for example the workload and Critical
Infrastructure private-access assignments both reference the same demo-root
initiative.

Deleting the demo root therefore removes the definitions, which is why
teardown removes assignments first, then definitions, then the management
groups.

## Assignment scope map

Defaults below are the shipped safe defaults from
[`parameters/demo.parameters.template.json`](../parameters/demo.parameters.template.json).
`DoNotEnforce` means the assignment is evaluated and reports compliance but
never blocks or remediates.

### Demo root — applies to every branch and both subscriptions

| Assignment | Purpose | Default posture |
|---|---|---|
| `Demo - allowed continental-US locations` | Allowed locations | Deny in `DoNotEnforce` |
| `Demo - audit public IP resources` | Public-exposure signal | Audit |
| `Demo - block common expensive resources and VM SKUs` | Cost guardrail | Deny in `DoNotEnforce` |
| `Demo - root deployment restrictions` | Customer allowlists for locations, resource types, VM SKUs, managed disks, public IPs | Deny members in `DoNotEnforce`; audit members Audit |
| `Demo - Microsoft cloud security benchmark` | MCSB compliance signal | Enabled, `DoNotEnforce` |
| `Demo - CIS Microsoft Azure Foundations Benchmark v2.0.0` | Optional overlay | Opt-in, `DoNotEnforce` |
| `Demo - NIST SP 800-53 Rev. 5` | Optional overlay | Opt-in, `DoNotEnforce` |
| `Demo - Microsoft Defender CSPM (opt-in, paid)` | Paid CSPM/CIEM plan | Opt-in, effect `Disabled`, no identity |
| `Demo - export Activity Logs to Log Analytics` | Subscription Activity Log export | Effect `Disabled` |
| `Demo - export supported resource diagnostics` | Resource diagnostic export | Effect `Disabled` |

Demo root is used when a control must be true everywhere, including the
Platform and Connectivity branches. Anything assigned here is the widest blast
radius in the project, so promoting a demo-root deny assignment to `Default` is
the highest-risk enforcement change you can make.

### Platform — applies to Platform, Connectivity, and the connectivity subscription

| Assignment | Purpose | Default posture |
|---|---|---|
| `Demo - audit platform tags` | Audit `Owner` and `CostCenter` on taggable resources | Audit |

The Platform branch deliberately receives only a tag audit. Workload tagging,
network ingress, data protection, backup, and Defender workload plans are **not**
assigned here, so shared connectivity resources are never blocked or modified by
a workload-oriented control.

### Landing Zones — applies to the workload branch and Critical Infrastructure

| Assignment | Purpose | Default posture |
|---|---|---|
| `Demo - require resource group tags` | Six required resource-group tags | Initiative in `DoNotEnforce` |
| `Demo - inherit resource group tags` | `Modify` inheritance of the same six tags when missing | Opt-in, `DoNotEnforce`, no remediation task |
| `Demo - storage and Key Vault data-protection guardrails` | Storage/Key Vault posture and CMK readiness | Audit in `DoNotEnforce` |
| `Demo - backup coverage and vault posture` | Backup coverage and vault posture audits | Audit/`AuditIfNotExists` |
| `Demo - configure backup (<workload>)` | Remediation-capable backup configuration | Opt-in, no remediation task started |
| `Demo - Recovery Services vault diagnostics` | Vault diagnostic settings | Opt-in, `AuditIfNotExists` by default |
| `Demo - audit VM vulnerability assessment` | Free audit signal | Audit, always assigned |
| `Demo - audit Windows Azure Monitor Agent presence` | Free audit signal | Audit, always assigned |
| `Demo - audit Linux Azure Monitor Agent presence` | Free audit signal | Audit, always assigned |
| `Demo - Microsoft Defender for Servers (opt-in, paid)` | Paid plan | Opt-in, effect `Disabled`, no identity |
| `Demo - Microsoft Defender for Storage (opt-in, paid)` | Paid plan | Opt-in, effect `Disabled`, no identity |

Landing Zones is the correct scope for a control that must cover **all**
workloads, ordinary and critical, without touching Platform or Connectivity.
Because Critical Infrastructure sits under Landing Zones, every control in this
table is automatically inherited by critical subscriptions as a floor; the
Critical Infrastructure assignments below add to it rather than replace it.

### Workload branch (`corp` or `online`) — ordinary workloads only

| Assignment | Purpose | Default posture |
|---|---|---|
| `Demo - workload network ingress guardrails` | Public SSH/RDP NSG rules and subnets without an NSG | Audit in `DoNotEnforce` |
| `Demo - workload private access guardrails` | PaaS public network access and private-endpoint readiness | Audit |
| `Demo - workload approved firewall routes` | Route-table expectations for an approved firewall | Explicit opt-in, Audit |

These are assigned at the archetype management group rather than Landing Zones
so that Platform/Connectivity never inherits a workload-shaped network rule and
so the Critical Infrastructure branch can be governed with its own parameters.
Only the private-access and firewall-route controls actually have a critical
copy today; the network-ingress control does not, and is covered for critical
subscriptions only by the opt-in NERC CIP overlay.

### Critical Infrastructure — opt-in, stricter branch

| Assignment | Purpose | Default posture |
|---|---|---|
| `Demo - critical private access guardrails` | Critical PaaS public access and private-endpoint readiness | Audit |
| `Demo - critical approved firewall routes` | Critical route-table expectations | Requires the firewall opt-in, Audit |
| `Demo - NERC CIP technical overlay (critical only)` | Approved regions, network boundary, private access, data protection, diagnostics readiness, Defender readiness, backup posture | Opt-in, `DoNotEnforce` |

The NERC CIP technical overlay is assigned **only** here and never at the demo
root, Platform, Landing Zones, or the workload branch. It requires
`enableCriticalInfrastructure=true` and at least one entry in
`criticalInfrastructureSubscriptionIds`; the template fails validation rather
than assigning an overlay with no critical scope. Assigning the overlay
produces technical signal only and does not establish, claim, or certify NERC
CIP compliance — see [`docs/NERC-CIP-MATRIX.md`](NERC-CIP-MATRIX.md) for the
responsibility and evidence boundaries.

### Subscription and resource-group scope

Only three things are created below management-group scope, and all are
opt-in:

- ordinary RBAC role assignments on the connectivity and workload
  subscriptions (`deployRoleAssignments=true`);
- evidence resource groups and a small VNet/NSG (`deployEvidenceResources=true`);
- the optional customer-owned Recovery Services vault, its resource group, and
  its backup policy in the workload subscription
  (`deployRecoveryServicesVault=true`), and the optional central Log Analytics
  workspace in the connectivity subscription (`deployCentralLogAnalytics=true`).

Policy exemptions supplied through `policyExemptions` can target
management-group, subscription, or resource-group scope through
`exemptionScopeType`.

## Choosing a scope for a new control

Use the narrowest scope that satisfies the requirement:

1. Does it have to be true for Platform and Connectivity as well as workloads?
   If yes, assign at the **demo root**.
2. Does it apply to all workloads, ordinary and critical, but not to shared
   platform resources? Assign at **Landing Zones**.
3. Does it describe ordinary workload behaviour that critical workloads should
   answer differently? Assign at the **workload branch**, and add the stricter
   variant at **Critical Infrastructure**.
4. Is it a critical-only obligation? Assign at **Critical Infrastructure**
   only.

Define the policy or initiative at the demo root regardless of where it is
assigned, so a single definition can be assigned with different parameters at
different branches.

## Narrowing an inherited assignment

| Mechanism | Use it for | Tracked by |
|---|---|---|
| Resource selector | Phased rollout by resource type or location while the control stays assigned everywhere | Assignment definition in source control |
| `notScopes` | A scope that is permanently out of the control's intent | Assignment definition in source control |
| `DoNotEnforce` | Evaluating a control everywhere before any enforcement | `denyPolicyEnforcementMode` |
| Exemption | A specific deployed scope that needs a reviewed, ticketed, expiring exception | `policyExemptions`, with owner, justification, approver, and expiry |

Prefer selectors and `DoNotEnforce` for rollout, and reserve exemptions for
genuine exceptions. See
[`docs/ENFORCEMENT-AND-REMEDIATION.md`](ENFORCEMENT-AND-REMEDIATION.md) for the
full progression and rollback steps.

## Verifying scope after a deployment

```bash
az policy assignment list --scope "/providers/Microsoft.Management/managementGroups/<namePrefix>" --output table
az policy assignment list --scope "/providers/Microsoft.Management/managementGroups/<namePrefix>-criticalinfra" --output table
```

```powershell
az policy assignment list --scope "/providers/Microsoft.Management/managementGroups/<namePrefix>" --output table
az policy assignment list --scope "/providers/Microsoft.Management/managementGroups/<namePrefix>-criticalinfra" --output table
```

Add `--disable-scope-strict-match` to include assignments inherited from
ancestor scopes, which is the fastest way to confirm what a critical
subscription actually evaluates.
