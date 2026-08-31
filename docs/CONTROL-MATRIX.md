# v2.0 Customer Requirement-to-Control Matrix

This document is the human-readable companion to the machine-readable [`policy/control-catalog.json`](../policy/control-catalog.json). It maps every customer requirement identified for v2.0 to its implementation mechanism, before any new policy code is written. Regenerate this document whenever the JSON catalog changes so the two stay consistent.

- **Catalog version:** `1.0.0`
- **Generated on:** `2026-08-31`
- **Source issue:** https://github.com/johnstel/azureeslzmultisubdemo/issues/3
- **Total control records:** 53

## Scope and safety

This catalog only **documents** implementation mechanisms. It does not create, assign, or deploy any Azure Policy definition, initiative, assignment, Microsoft Entra identity, or Azure resource, and it does not query or change a customer tenant. Every built-in identifier below was verified against a public source; no policy ID was invented.

## Important caveats

- Azure service security baselines (for example, the Storage, Key Vault, or Compute security baselines) are Microsoft Learn guidance mapped into individual service controls; they are not one universal assignable Azure Policy initiative. See REQ-BASE-04.
- NERC CIP has no single turnkey built-in Azure Policy initiative. Compliance requires customer-owned evidence, a registered-entity applicability decision, and procedural controls outside Azure Policy. See REQ-CIP-01 and REQ-CIP-02. This catalog and repository do not claim NERC CIP certification or compliance.
- The Microsoft cloud security benchmark (REQ-BASE-01) initiative GUID is updated in place very frequently; always re-fetch the current metadata.version immediately before assignment rather than relying on the version recorded here.
- Entries with mechanism.verificationMethod of 'secondary-source' were corroborated by multiple public references but could not be confirmed by directly fetching the built-in's raw JSON in this research session; re-confirm with `az policy definition show` / `az policy set-definition show` before assignment.

## Classification legend

| Classification | Meaning |
|---|---|
| `azure-policy` | Implemented (or implementable) with an Azure Policy definition or initiative. |
| `entra-pim` | Requires a Microsoft Entra Conditional Access or Privileged Identity Management artifact; not expressible as Azure Policy. |
| `defender-cspm-ciem` | Provided by a Microsoft Defender for Cloud CSPM/CIEM plan or feature; paid, disabled by default. |
| `shared-service-architecture` | Depends on a shared architecture pattern or customer-supplied dependency (for example, an existing Key Vault, firewall, or vault) rather than a single self-contained control. |
| `manual-evidence` | Requires a customer process, documentation, or manually collected evidence; not automatable by this repository. |

## Identity (Entra Conditional Access, PIM, access review)

| ID | Customer requirement | Scope | Classification | Mechanism | Built-in ID | Version | Effects | Enforcement phase |
|---|---|---|---|---|---|---|---|---|
| REQ-ID-01 | Require phishing-resistant MFA for privileged Entra roles. | tenant (Entra ID) | entra-pim | Conditional Access: privileged-role phishing-resistant MFA (report-only template) (built-in: No) | `—` | — | reportOnly, enabledEnforced | manual-evidence |
| REQ-ID-02 | Require MFA for any access to Azure management (Azure Resource Manager). | tenant (Entra ID) | entra-pim | Conditional Access: require MFA for Azure Management (report-only template) (built-in: No) | `—` | — | reportOnly, enabledEnforced | manual-evidence |
| REQ-ID-03 | Block legacy (basic) authentication protocols. | tenant (Entra ID) | entra-pim | Conditional Access: block legacy authentication (report-only template) (built-in: No) | `—` | — | reportOnly, enabledEnforced | manual-evidence |
| REQ-ID-04 | Replace permanent subscription Owner with eligible, time-bound, PIM-compatible privileged access. | subscription | entra-pim | PIM-ready eligible role assignment inputs (Microsoft.Authorization roleEligibilityScheduleRequests) (built-in: No) | `—` | — | eligible, activeTimeBound | manual-evidence |
| REQ-ID-05 | Detect and periodically review excessive service-principal and managed-identity role assignments, and review subscription Owner counts. | subscription | manual-evidence | Read-only Azure role-assignment inventory report (Bash/PowerShell) (built-in: No) | `—` | — | report | manual-evidence |
| REQ-ID-06 | Use Defender for Cloud CIEM (Cloud Infrastructure Entitlement Management) findings to complement manual identity review. | subscription | defender-cspm-ciem | Microsoft Defender CSPM (Permissions Management / CIEM entitlement insights) (built-in: Yes) | `72f8cee7-2937-403d-84a1-a4e3e57f3c21` | n/a | DeployIfNotExists, Disabled | manual-evidence |

## Deployment restrictions

| ID | Customer requirement | Scope | Classification | Mechanism | Built-in ID | Version | Effects | Enforcement phase |
|---|---|---|---|---|---|---|---|---|
| REQ-DEPLOY-01 | Restrict resource deployment to an approved set of Azure regions. | demo-root | azure-policy | Allowed locations (built-in: Yes) | `e56962a6-4747-49cd-b67b-bf8b01975c4c` | 1.1.0 | Deny | deny-do-not-enforce |
| REQ-DEPLOY-02 | Restrict deployment to an approved allowlist of Azure resource types. | demo-root | azure-policy | Allowed resource types (built-in: Yes) | `a08ec900-254a-4555-9bf5-e42af04b5c5c` | 1.1.0 | Audit, Deny, Disabled | deny-do-not-enforce |
| REQ-DEPLOY-03 | Block deployment of an explicit denylist of Azure resource types. | demo-root | azure-policy | Not allowed resource types (built-in: Yes) | `6c112d4e-5bc7-47ae-a041-ea2d9dccd749` | 2.0.0 | Audit, Deny, Disabled | deny-do-not-enforce |
| REQ-DEPLOY-04 | Restrict virtual machine deployment to an approved allowlist of VM size SKUs. | landingzones | azure-policy | Allowed virtual machine size SKUs (built-in: Yes) | `cccc23c7-8427-4f53-ad12-b6a63eb452b3` | 1.0.1 | Deny | deny-do-not-enforce |
| REQ-DEPLOY-05 | Require managed disks for virtual machines. | landingzones | azure-policy | Audit VMs that do not use managed disks (built-in: Yes) | `06a78e20-9358-41c9-923c-fb736d382a4d` | 1.0.0 | Audit | audit-only |
| REQ-DEPLOY-06 | Audit creation of public IP address resources as a public-exposure signal. | demo-root | azure-policy | Demo - audit public IP address resources (built-in: No) | `${namePrefix}-audit-public-ip` | 1.0.0 | audit | audit-only |

## Tagging

| ID | Customer requirement | Scope | Classification | Mechanism | Built-in ID | Version | Effects | Enforcement phase |
|---|---|---|---|---|---|---|---|---|
| REQ-TAG-01 | Require the 'CostCenter' tag on every resource group. | landingzones | azure-policy | Require a tag on resource groups (built-in: Yes) | `96670d01-0a4d-4649-9c89-2d3abc0a5025` | 1.0.0 | Deny | deny-do-not-enforce |
| REQ-TAG-02 | Require the 'ApplicationName' tag on every resource group. | landingzones | azure-policy | Require a tag on resource groups (built-in: Yes) | `96670d01-0a4d-4649-9c89-2d3abc0a5025` | 1.0.0 | Deny | deny-do-not-enforce |
| REQ-TAG-03 | Require the 'Owner' tag on every resource group. | landingzones | azure-policy | Require a tag on resource groups (built-in: Yes) | `96670d01-0a4d-4649-9c89-2d3abc0a5025` | 1.0.0 | Deny | deny-do-not-enforce |
| REQ-TAG-04 | Require the 'Environment' tag on every resource group. | landingzones | azure-policy | Require a tag on resource groups (built-in: Yes) | `96670d01-0a4d-4649-9c89-2d3abc0a5025` | 1.0.0 | Deny | deny-do-not-enforce |
| REQ-TAG-05 | Require the 'DataClassification' tag on every resource group. | landingzones | azure-policy | Require a tag on resource groups (built-in: Yes) | `96670d01-0a4d-4649-9c89-2d3abc0a5025` | 1.0.0 | Deny | deny-do-not-enforce |
| REQ-TAG-06 | Require the 'SSP-ID' tag on every resource group. | landingzones | azure-policy | Require a tag on resource groups (built-in: Yes) | `96670d01-0a4d-4649-9c89-2d3abc0a5025` | 1.0.0 | Deny | deny-do-not-enforce |
| REQ-TAG-07 | Inherit the 'CostCenter' tag from the resource group to taggable child resources when missing, without overwriting existing values. | landingzones | azure-policy | Inherit a tag from the resource group if missing (built-in: Yes) | `ea3f2387-9b95-492a-a190-fcdc54f7b070` | 1.0.0 | Modify | deployifnotexists-opt-in |
| REQ-TAG-08 | Inherit the 'ApplicationName' tag from the resource group to taggable child resources when missing, without overwriting existing values. | landingzones | azure-policy | Inherit a tag from the resource group if missing (built-in: Yes) | `ea3f2387-9b95-492a-a190-fcdc54f7b070` | 1.0.0 | Modify | deployifnotexists-opt-in |
| REQ-TAG-09 | Inherit the 'Owner' tag from the resource group to taggable child resources when missing, without overwriting existing values. | landingzones | azure-policy | Inherit a tag from the resource group if missing (built-in: Yes) | `ea3f2387-9b95-492a-a190-fcdc54f7b070` | 1.0.0 | Modify | deployifnotexists-opt-in |
| REQ-TAG-10 | Inherit the 'Environment' tag from the resource group to taggable child resources when missing, without overwriting existing values. | landingzones | azure-policy | Inherit a tag from the resource group if missing (built-in: Yes) | `ea3f2387-9b95-492a-a190-fcdc54f7b070` | 1.0.0 | Modify | deployifnotexists-opt-in |
| REQ-TAG-11 | Inherit the 'DataClassification' tag from the resource group to taggable child resources when missing, without overwriting existing values. | landingzones | azure-policy | Inherit a tag from the resource group if missing (built-in: Yes) | `ea3f2387-9b95-492a-a190-fcdc54f7b070` | 1.0.0 | Modify | deployifnotexists-opt-in |
| REQ-TAG-12 | Inherit the 'SSP-ID' tag from the resource group to taggable child resources when missing, without overwriting existing values. | landingzones | azure-policy | Inherit a tag from the resource group if missing (built-in: Yes) | `ea3f2387-9b95-492a-a190-fcdc54f7b070` | 1.0.0 | Modify | deployifnotexists-opt-in |

## Network security

| ID | Customer requirement | Scope | Classification | Mechanism | Built-in ID | Version | Effects | Enforcement phase |
|---|---|---|---|---|---|---|---|---|
| REQ-NET-01 | Detect open management ports (RDP/SSH) on virtual machines. | landingzones | azure-policy | Management ports should be closed on your virtual machines (built-in: Yes) | `22730e10-96f6-4aac-ad84-9383d35b5917` | 3.0.0 | AuditIfNotExists, Disabled | audit-only |
| REQ-NET-02 | Require subnets to be associated with a Network Security Group. | connectivity | azure-policy | Subnets should be associated with a Network Security Group (built-in: Yes) | `e71308d3-144b-4262-b144-efdc3cc90517` | 3.0.0 | AuditIfNotExists, Disabled | audit-only |
| REQ-NET-03 | Protect non-internet-facing virtual machines with a Network Security Group. | landingzones | azure-policy | Non-internet-facing virtual machines should be protected with network security groups (built-in: Yes) | `bb91dfba-c30d-4263-9add-9c2384e659a6` | 3.0.0 | AuditIfNotExists, Disabled | audit-only |
| REQ-NET-04 | Audit private-link/private-endpoint readiness for storage accounts. | landingzones | azure-policy | Storage accounts should use private link (built-in: Yes) | `6edd7eda-6dd8-40f7-810d-67160c639cd9` | 2.0.0 | AuditIfNotExists, Disabled | audit-only |
| REQ-NET-05 | Audit private-link/private-endpoint readiness for Key Vault. | landingzones | azure-policy | Azure Key Vaults should use private link (built-in: Yes) | `a6abeaec-4d90-4a02-805f-6b26c4d3fbe9` | 1.2.1 | Audit, Disabled | audit-only |
| REQ-NET-06 | Validate that Internet-bound traffic from production/critical subnets routes through an approved Azure Firewall. | landingzones | azure-policy | [Preview]: All Internet traffic should be routed via your deployed Azure Firewall (built-in: Yes) | `fc5e4038-4584-4632-8c85-c0448d374b2c` | 3.0.0-preview | AuditIfNotExists, Disabled | manual-evidence |

## Logging

| ID | Customer requirement | Scope | Classification | Mechanism | Built-in ID | Version | Effects | Enforcement phase |
|---|---|---|---|---|---|---|---|---|
| REQ-LOG-01 | Export subscription Activity Logs to the effective central Log Analytics workspace. | demo-root | azure-policy | Configure Azure Activity logs to stream to specified Log Analytics workspace (built-in: Yes) | `2465583e-4e78-4c15-b6be-a36cbc7c8b0f` | 1.0.0 | DeployIfNotExists, Disabled | deployifnotexists-opt-in |
| REQ-LOG-02 | Export supported resource-level diagnostic logs to the effective central Log Analytics workspace. | demo-root | azure-policy | Enable allLogs category group resource logging for supported resources to Log Analytics (built-in: Yes) | `0884adba-2312-4468-abeb-5422caed1038` | unknown | DeployIfNotExists, Disabled | deployifnotexists-opt-in |

## Data protection

| ID | Customer requirement | Scope | Classification | Mechanism | Built-in ID | Version | Effects | Enforcement phase |
|---|---|---|---|---|---|---|---|---|
| REQ-DATA-01 | Require secure transfer (HTTPS) for storage accounts. | landingzones | azure-policy | Secure transfer to storage accounts should be enabled (built-in: Yes) | `404c3081-a854-4457-ae30-26a93ef643f9` | 2.0.0 | Audit, Deny, Disabled | audit-only |
| REQ-DATA-02 | Disallow public blob access on storage accounts. | landingzones | azure-policy | Storage account public access should be disallowed (built-in: Yes) | `4fa4b6c0-31ca-4c0d-b10d-24b96f62a751` | 3.1.1 | Audit, Deny, Disabled | audit-only |
| REQ-DATA-03 | Restrict storage account network access to approved networks. | landingzones | azure-policy | Storage accounts should restrict network access (built-in: Yes) | `34c877ad-507e-4c82-993e-3452a6e0ad3c` | 1.1.1 | Audit, Deny, Disabled | audit-only |
| REQ-DATA-04 | Require a minimum TLS version for storage accounts. | landingzones | azure-policy | Storage accounts should have the specified minimum TLS version (built-in: Yes) | `fe83a0eb-a853-422d-aac2-1bffd182c5d0` | 1.0.0 | Audit, Deny, Disabled | audit-only |
| REQ-DATA-05 | Require Key Vault soft delete. | landingzones | azure-policy | Key vaults should have soft delete enabled (built-in: Yes) | `1e66c121-a66a-4b1f-9b83-0fd99bf0fc2d` | 3.1.0 | Audit, Deny, Disabled | audit-only |
| REQ-DATA-06 | Require Key Vault purge protection in addition to soft delete (never disabled). | landingzones | azure-policy | Key vaults should have deletion protection enabled (built-in: Yes) | `0b60c0b2-2dc2-4e1c-b5c9-abbed971de53` | 2.1.0 | Audit, Deny, Disabled | audit-only |
| REQ-DATA-07 | Require Key Vault to use Azure RBAC for data-plane authorization instead of access policies. | landingzones | azure-policy | Azure Key Vault should use RBAC permission model (built-in: Yes) | `12d4fa5e-1f9f-4c21-97a9-b99b3c6611b5` | 1.0.1 | Audit, Deny, Disabled | audit-only |
| REQ-DATA-08 | Use customer-managed keys (CMK) for encryption at rest on eligible services, where the customer supplies a Key Vault and key. | landingzones | shared-service-architecture | Service-specific CMK audit built-ins (for example, storage/SQL/Cosmos DB 'should use customer-managed key' policies) (built-in: Yes) | `—` | n/a | Audit, Disabled | manual-evidence |

## MCSB / CIS / NIST / service baselines

| ID | Customer requirement | Scope | Classification | Mechanism | Built-in ID | Version | Effects | Enforcement phase |
|---|---|---|---|---|---|---|---|---|
| REQ-BASE-01 | Assign the current stable Microsoft Cloud Security Benchmark (MCSB) as the default security baseline. | demo-root | azure-policy | Microsoft cloud security benchmark (built-in: Yes) | `1f3afdf9-d0c9-4c3d-847f-89da613e70a8` | 57.58.0 | Audit, AuditIfNotExists, DeployIfNotExists, Disabled | audit-only |
| REQ-BASE-02 | Optionally assign the CIS Microsoft Azure Foundations Benchmark as an overlay. | demo-root | azure-policy | CIS Microsoft Azure Foundations Benchmark v2.0.0 (built-in: Yes) | `06f19060-9e68-4070-92ca-f15cc126059e` | 1.10.0 | Audit, AuditIfNotExists, DeployIfNotExists, Disabled | audit-only |
| REQ-BASE-03 | Optionally assign the NIST SP 800-53 Rev. 5 initiative as an overlay. | demo-root | azure-policy | NIST SP 800-53 Rev. 5 (built-in: Yes) | `179d1daa-458f-4e47-8086-2a68d0d6c38f` | 14.20.0 | Audit, AuditIfNotExists, DeployIfNotExists, Disabled | audit-only |
| REQ-BASE-04 | Apply Azure per-service security baseline guidance (for example, the Storage, Key Vault, and Compute security baselines) where relevant. | landingzones | manual-evidence | Azure security baselines (per-service Microsoft Learn guidance, not a single assignable initiative) (built-in: No) | `—` | — | n/a | manual-evidence |

## Defender for Cloud

| ID | Customer requirement | Scope | Classification | Mechanism | Built-in ID | Version | Effects | Enforcement phase |
|---|---|---|---|---|---|---|---|---|
| REQ-DEF-01 | Provide a single explicit assignment point for configuring Microsoft Defender for Cloud plans. | demo-root | azure-policy | Configure Microsoft Defender for Cloud plans (built-in: Yes) | `f08c57cd-dbd6-49a4-a85e-9ae77ac959b0` | 1.1.0 | DeployIfNotExists | manual-evidence |
| REQ-DEF-02 | Optionally enable Microsoft Defender CSPM (Cloud Security Posture Management). | demo-root | defender-cspm-ciem | Configure Microsoft Defender CSPM plan (built-in: Yes) | `72f8cee7-2937-403d-84a1-a4e3e57f3c21` | n/a | DeployIfNotExists, Disabled | manual-evidence |
| REQ-DEF-03 | Optionally enable Microsoft Defender for Servers. | landingzones | defender-cspm-ciem | Configure Microsoft Defender for Servers plan (built-in: Yes) | `5eb6d64a-4086-4d7a-92da-ec51aed0332d` | n/a | DeployIfNotExists, Disabled | manual-evidence |
| REQ-DEF-04 | Optionally enable Microsoft Defender for Storage. | landingzones | defender-cspm-ciem | Configure Microsoft Defender for Storage plan (built-in: Yes) | `cfdc5972-75b3-4418-8ae1-7f5c36839390` | n/a | DeployIfNotExists, Disabled | manual-evidence |
| REQ-DEF-05 | Do not depend on the deprecated Log Analytics (MMA) monitoring agent for auto-provisioning. | demo-root | azure-policy | [Deprecated]: Auto provisioning of the Log Analytics agent should be enabled on your subscription (built-in: Yes) | `475aae12-b88a-4572-8b36-9b712b2b3a17` | 1.1.0-deprecated | AuditIfNotExists, Disabled | manual-evidence |

## Backup

| ID | Customer requirement | Scope | Classification | Mechanism | Built-in ID | Version | Effects | Enforcement phase |
|---|---|---|---|---|---|---|---|---|
| REQ-BKP-01 | Audit that virtual machines have Azure Backup coverage. | landingzones | azure-policy | Azure Backup should be enabled for Virtual Machines (built-in: Yes) | `013e242c-8828-4970-87b3-ab247555486d` | 3.0.0 | AuditIfNotExists, Disabled | audit-only |
| REQ-BKP-02 | Configure backup on tagged virtual machines to an approved, existing Recovery Services vault and backup policy. | landingzones | azure-policy | Configure backup on virtual machines with a given tag to an existing recovery services vault in the same location (built-in: Yes) | `345fa903-145c-4fe1-8bcd-93ec2adccde8` | 9.6.1 | AuditIfNotExists, DeployIfNotExists, Disabled | deployifnotexists-opt-in |

## NERC CIP

| ID | Customer requirement | Scope | Classification | Mechanism | Built-in ID | Version | Effects | Enforcement phase |
|---|---|---|---|---|---|---|---|---|
| REQ-CIP-01 | Compose an opt-in, stricter technical control overlay for subscriptions under the Critical Infrastructure management-group branch. | critical-infrastructure | shared-service-architecture | Demo - NERC CIP technical overlay (to be composed from existing verified controls) (built-in: No) | `—` | n/a | Audit, Deny, DeployIfNotExists, Disabled | manual-evidence |
| REQ-CIP-02 | Document the responsibility and evidence matrix for NERC CIP technical requirements not fully covered by Azure Policy. | critical-infrastructure | manual-evidence | NERC CIP responsibility and evidence matrix (docs/NERC-CIP-MATRIX.md, to be authored) (built-in: No) | `—` | — | n/a | manual-evidence |

## Overlap notes (avoid duplicate enforcement)

- **Storage and Key Vault data-protection controls:** REQ-DATA-01 through REQ-DATA-07 are already member policies of the Microsoft cloud security benchmark (REQ-BASE-01) and, where selected, the CIS (REQ-BASE-02) and NIST (REQ-BASE-03) overlays. Assign them once as the authoritative source of truth and do not create duplicate custom definitions for the same control intent.
- **Management-port and NSG audits:** REQ-NET-01 and REQ-NET-03 rely on Microsoft Defender for Cloud security assessments, which are also surfaced through the MCSB initiative (REQ-BASE-01) and the Defender for Cloud plan configuration (REQ-DEF-01). Enabling Defender plans populates compliance data for these audits; it does not require a second, separate custom rule.
- **Tag requirement vs. tag inheritance:** REQ-TAG-01..06 (require tag on resource group) and REQ-TAG-07..12 (inherit tag to child resources) are complementary, not duplicative: the first establishes the source of truth at the resource-group scope, and the second propagates it without overwriting existing values.

## Verification methodology

Each control record's `mechanism.sourceUrl` and `mechanism.verificationMethod` field in `policy/control-catalog.json` records how the identifier was confirmed:

- `raw-json` / `initiative-json-member`: confirmed by fetching the current built-in definition or initiative JSON directly from the public `Azure/azure-policy` GitHub repository.
- `secondary-source`: corroborated by multiple public secondary references (for example, Azure Policy documentation mirrors), but the authoritative raw JSON file could not be located in this research session. These records include an explicit re-confirmation instruction (for example, `az policy definition show`) before assignment.
- `documentation-pattern` / `internal-design` / `not-yet-selected` / `not-yet-created`: non-Policy mechanisms (Entra/PIM, manual evidence, or future work items) that have no Azure Policy GUID to verify.

No `git diff --check` whitespace issues, no fabricated GUIDs, and no tenant credentials were used to produce this document.

