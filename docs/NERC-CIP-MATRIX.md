# v2.0 NERC CIP responsibility and evidence matrix

This document maps v2 technical controls to NERC CIP-aligned technical responsibilities and evidence expectations. It is documentation support only; it is **not** legal advice and does **not** claim certification or full compliance.

The registered entity remains responsible for its own NERC CIP applicability determination, implementation, evidence quality, and ongoing compliance outcomes.

## Scope boundaries

- This matrix covers technical controls implemented or documented in v2 for the opt-in Critical Infrastructure branch (`REQ-CIP-01` dependencies).
- It does not implement customer personnel, physical security, legal interpretation, incident command, or exercise execution controls.
- Azure Policy results are control signals, not final compliance determinations.

## BES Cyber System (BCS) / BCSI assumptions and applicability decision

Assumptions used by this repository:

1. The customer has identified candidate BES Cyber System Information (BCSI), BES Cyber Systems (BCS), and associated assets outside this repository.
2. The customer maps those assets to subscriptions/management groups before assigning the Critical Infrastructure overlay.
3. `DataClassification` and `SSP-ID` tags are used as routing metadata only; they are not a substitute for formal CIP scoping.

**Required customer applicability decision (must be recorded outside this repository):**

- Determine and approve which assets in scope are Low/Medium/High Impact BES Cyber Systems, associated BCSI, and which CIP requirements are applicable to each.
- Record the accountable approver, date, and review interval for that decision.

## Responsibility model

- **Azure/Microsoft:** platform operation, attestation material, and service control implementation details documented in Microsoft compliance material.
- **Customer:** asset classification, policy assignment decisions, procedural controls, evidence retention, and audit responses.
- **Shared:** technical signal generation by Azure controls + customer interpretation and process evidence.

## Control and evidence matrix

| NERC CIP requirement/family | v2 technical control mapping | Responsibility | Policy/service evidence | Evidence location | Evidence owner | Collection method | Review cadence | Known manual gap |
|---|---|---|---|---|---|---|---|---|
| CIP-002 BES Cyber System categorization | REQ-TAG-05/06 (`DataClassification`, `SSP-ID` required); REQ-CIP-01 overlay scope gate | Customer | Tag compliance results and assignment scope metadata | Azure Policy compliance export; customer asset register | Customer compliance owner | Export policy compliance + reconcile to asset inventory | Quarterly and on asset changes | Formal BCS/BCSI impact categorization and applicability approval are manual/customer-owned |
| CIP-003 security management controls (technical governance evidence) | REQ-CIP-02 (this matrix), REQ-CIP-01 dependency mapping | Shared | Approved control mapping, control owner list, review records | `docs/NERC-CIP-MATRIX.md`; customer GRC/control library | Customer compliance owner | Review matrix and owner assignments; store signed review evidence | Quarterly | Governance approvals and compliance program operation are outside Azure Policy |
| CIP-005 Electronic Security Perimeter / Electronic Access Points | REQ-NET-04/05 private-access readiness; REQ-NET-06 approved firewall-route audit | Shared | Policy compliance state for private access and approved route expectations | Azure Policy compliance export; route table and firewall design records | Network/security owner | Export policy results; attach route-table/firewall architecture evidence | Monthly | Actual path validation, private DNS resolution, and exception approvals are manual |
| CIP-005 interactive remote access monitoring | REQ-LOG-01/02 activity/resource logging; optional Defender/Sentinel telemetry controls | Shared | Logging assignment state and log-ingestion proof | Azure Policy compliance export; Log Analytics/Sentinel retention records | SOC/platform owner | Validate diagnostics to approved workspace; retain query/report evidence | Monthly | Session monitoring procedures and alert triage remain customer process controls |
| CIP-007 system hardening (ports/services exposure) | REQ-NET-01/02/03 management-port and NSG controls; REQ-DEPLOY-04 VM size allowlist | Shared | NSG and VM governance compliance findings | Azure Policy compliance export | Platform/network owner | Export control compliance and approved exception list | Monthly | OS/service configuration baselines and host firewall settings are outside this repo |
| CIP-007 vulnerability management signal | REQ-DEF-06 vulnerability assessment audit; optional Defender plan controls (REQ-DEF-02/03) | Shared | Defender/assessment policy compliance and plan state | Azure Policy compliance export; Defender findings export | Security operations owner | Export policy + Defender findings and track remediation tickets | Weekly for findings, monthly for control status | Scanner operation, remediation SLA governance, and risk acceptance are manual |
| CIP-010 configuration change governance | REQ-DEPLOY-01/02/03 deployment restrictions; policy exemptions module/process | Shared | Assignment history, exemption records, and parameter/version baselines | Git history, policy assignment exports, customer change system | Platform owner + change manager | Capture change records linked to assignment updates and exemptions | Per change + monthly reconciliation | Formal approval workflow, segregation of duties, and CAB evidence are customer-owned |
| CIP-011 information protection (at rest/in transit baseline) | REQ-DATA-01..07, REQ-DATA-10/11, REQ-BKP-05 (CMK), REQ-BKP-06 (immutability) | Shared | Data protection control compliance signals | Azure Policy compliance export; key/vault lifecycle records | Data protection owner | Export compliance and collect key-management evidence | Monthly | Key custodianship, cryptoperiod decisions, and BCSI handling procedures are manual |
| CIP-011 information disposal/recovery protection signal | REQ-DATA-05/06 (soft delete/purge protection), REQ-BKP-08/09 (soft delete/MUA audits) | Shared | Vault posture compliance findings | Azure Policy compliance export; vault configuration records | Backup/security owner | Export compliance; retain exception approvals | Monthly | Disposal authorization workflow and recovery evidence sign-off are customer process controls |
| CIP-008 incident detection/response technical telemetry | REQ-LOG-01/02, optional REQ-DEF-04 Sentinel onboarding controls | Shared | Central logging and Sentinel onboarding control state | Azure Policy compliance export; SOC runbooks and case records | SOC owner | Validate telemetry pipeline + retain incident case evidence | Monthly for control, per incident for process evidence | Incident response command, reporting timelines, and exercise evidence are manual |
| CIP-009 recovery capability technical baseline | REQ-BKP-01..09 backup governance and vault posture controls | Shared | Backup policy, vault posture, diagnostics, and approved-vault mapping evidence | Azure Policy compliance export; backup job/test-restore records | Backup service owner | Export compliance and archive restore-test artifacts | Monthly + after major changes | Recovery exercises, RTO/RPO acceptance, and business approvals are customer-owned |
| CIP-004/CIP-006/CIP-013 adjacent dependencies | No direct v2 technical automation beyond supporting signals above | Customer | N/A from Azure Policy | Customer HR/physical/supply-chain systems | Customer compliance owner | Maintain separate procedural evidence and cross-reference this matrix | Per internal policy | Entire requirement families remain outside repository automation |

## Audit-readiness checklist (technical evidence package)

Use this checklist when preparing an audit package; keep evidence in the customer evidence store, not in this repository.

- [ ] Regions: approved region list and assignment parameters for deployment restrictions.
- [ ] Asset tags: `DataClassification`, `SSP-ID`, and owner tags present and reconciled to asset inventory.
- [ ] Access: privileged-access review reports, owner-count review decisions, and exception re-review dates.
- [ ] Encryption: storage/Key Vault/vault encryption control states and key lifecycle records.
- [ ] Logs: Activity Log and resource diagnostics export evidence to the approved workspace.
- [ ] Defender/Sentinel: explicit enablement decisions, plan state, and findings disposition records.
- [ ] Network paths: private-endpoint readiness, route-table/firewall expectation results, and approved exceptions.
- [ ] Backup: approved vault mapping, immutability/MUA/soft-delete posture, and restore-test evidence.
- [ ] Exceptions: active policy exemptions with owner, justification, expiry, and compensating controls.
- [ ] Change records: ticket/change references for assignment, parameter, exemption, and scope modifications.

## Related artifacts

- NERC overlay composition dependency issue: https://github.com/johnstel/azureeslzmultisubdemo/issues/22
- NERC technical control-matrix dependency issue: https://github.com/johnstel/azureeslzmultisubdemo/issues/21
- NERC responsibility/evidence matrix issue (this document): https://github.com/johnstel/azureeslzmultisubdemo/issues/23
- v2 control catalog: [`docs/CONTROL-MATRIX.md`](./CONTROL-MATRIX.md)
- Privileged-access evidence process: [`docs/ACCESS-REVIEWS.md`](./ACCESS-REVIEWS.md)

## Official references

- Microsoft compliance offering for NERC CIP: https://learn.microsoft.com/en-us/compliance/regulatory/offering-nerc-cip
- Microsoft cloud shared responsibility guidance: https://learn.microsoft.com/en-us/azure/security/fundamentals/shared-responsibility
- NERC CIP standards landing page: https://www.nerc.com/pa/Stand/Pages/CIPStandards.aspx
