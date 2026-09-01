targetScope = 'managementGroup'

// Dedicated, narrow-purpose module for the Microsoft Defender for Cloud plan
// controls (REQ-DEF-02/03/04). Each of these built-in policy definitions is
// DeployIfNotExists-capable and its own verified remediation role is Owner
// (reproduced in policy/control-catalog.json from the built-in's raw source
// JSON). Per issue #20 this module exposes an explicit, independent,
// safe-by-default (`enablePlan = false`) opt-in per plan; per issue #8 it
// never auto-grants any role, so normal deployment of this template -- with
// or without a plan opted in -- can never create or leave standing Owner
// access anywhere:
//
// - When `enablePlan` is false (the safe default), the assignment's
//   `effect` is `Disabled` and its `identity.type` is `None`: no managed
//   identity is created at all, so there is nothing to grant a role to.
// - When `enablePlan` is true, `effect` becomes `DeployIfNotExists` and a
//   `SystemAssigned` identity is created (required by Azure Policy for any
//   DeployIfNotExists assignment), but this module still never assigns a
//   role to it. This repository's shared RBAC module also deliberately
//   refuses to grant Owner or User Access Administrator to any identity
//   (see modules/remediating-policy-assignment.bicep) -- a single
//   management-group-scoped identity inherited across every descendant
//   subscription is too broad a blast radius for a standing grant. Fail
//   closed instead: without a role, the built-in's own remediation task
//   simply cannot act, so opting in only ever creates a compliance
//   evaluation, never an unattended privilege escalation.
//
// To actually remediate, grant `outputs.identityPrincipalId` Owner only
// through your organization's own separately approved, time-bounded
// process at precisely the descendant subscription(s) being remediated --
// for example, the same fail-closed, PIM-eligible pattern this repository
// already implements for platform-team Owner in the identity/azure-rbac
// one-shot Owner eligibility Bicep artifact (see its own file for the
// exact path -- deliberately not named here so lifecycle-guard scans of
// this module tree cannot mistake this comment for an invocation) and
// docs/AZURE-RBAC-PIM.md (eligibility, not standing assignment; approval
// and MFA required; a bounded activation window; removed immediately after
// the remediation task completes). This module cannot do that itself: the
// identity here belongs to a policy assignment, not the Entra security
// group that workflow targets, and requesting PIM eligibility for it is a
// separate, explicitly confirmed action outside this template. Never grant
// standing Owner as a substitute.
//
// policyDefinitionId/definitionVersion are intentionally not accepted as
// free-text parameters. The `plan` parameter is restricted to the three
// verified built-in plans below so this module can never be pointed at an
// unverified definition or an unpinned version.
//
// Each of these built-ins also exposes its own extension parameters beyond
// `effect` (for example Servers' `subPlan`/agentless-scanning toggle, or
// CSPM's Entra Permissions Management/CIEM toggle). Rather than omitting
// those from the assignment and silently inheriting whatever the built-in's
// own default happens to be, this module accepts an explicit, documented
// parameter for every one of them (defaulting to the built-in's own
// verified default so behavior is unchanged) and maps each verified `plan`
// value to its own parameter object below (see `planParameters`).

var planDefinitions = {
  cspm: {
    definitionId: '72f8cee7-2937-403d-84a1-a4e3e57f3c21'
    definitionVersion: '1.*.*'
  }
  servers: {
    definitionId: '5eb6d64a-4086-4d7a-92da-ec51aed0332d'
    definitionVersion: '1.*.*'
  }
  storage: {
    definitionId: 'cfdc5972-75b3-4418-8ae1-7f5c36839390'
    definitionVersion: '1.*.*'
  }
}

var controlCharacterEncodings = [
  '%00'
  '%01'
  '%02'
  '%03'
  '%04'
  '%05'
  '%06'
  '%07'
  '%08'
  '%09'
  '%0a'
  '%0b'
  '%0c'
  '%0d'
  '%0e'
  '%0f'
  '%10'
  '%11'
  '%12'
  '%13'
  '%14'
  '%15'
  '%16'
  '%17'
  '%18'
  '%19'
  '%1a'
  '%1b'
  '%1c'
  '%1d'
  '%1e'
  '%1f'
  '%7f'
]

@sys.description('Policy assignment resource name.')
@minLength(1)
@maxLength(24)
param assignmentName string

@sys.description('Policy assignment display name.')
@minLength(1)
@maxLength(128)
param displayName string

@sys.description('Policy assignment description.')
@minLength(1)
@maxLength(512)
param description string

@sys.description('Which verified Microsoft Defender for Cloud plan this assignment tracks. Restricted to the plans this module has independently verified against the control catalog (policy/control-catalog.json); no other policyDefinitionId can be supplied.')
param plan 'cspm' | 'servers' | 'storage'

@sys.description('Explicit, independent opt-in for this paid plan. Defaults to false (effect stays Disabled, no managed identity is created). Setting true switches effect to DeployIfNotExists and creates a SystemAssigned identity, but this module never grants that identity any role.')
param enablePlan bool = false

@sys.description('CSPM plan only. Enables the built-in\'s sensitive-data-discovery extension. Defaults to true, matching the built-in\'s own verified default (ASC_Azure_Defender_CSPM_Full_Features_DINE.json).')
param cspmSensitiveDataDiscoveryEnabled bool = true

@sys.description('CSPM plan only. Enables the built-in\'s container-registries vulnerability-assessment extension. Defaults to true, matching the built-in\'s own verified default.')
param cspmContainerRegistriesVulnerabilityAssessmentsEnabled bool = true

@sys.description('CSPM plan only. Enables the built-in\'s agentless discovery for Kubernetes extension. Defaults to true, matching the built-in\'s own verified default.')
param cspmAgentlessDiscoveryForKubernetesEnabled bool = true

@sys.description('CSPM plan only. Enables the built-in\'s agentless VM scanning extension. Defaults to true, matching the built-in\'s own verified default.')
param cspmAgentlessVmScanningEnabled bool = true

@sys.description('CSPM plan only. Enables the built-in\'s Entra Permissions Management (CIEM) extension -- this is the CIEM feature scoped by issue #20. Defaults to true, matching the built-in\'s own verified default.')
param cspmEntraPermissionsManagementEnabled bool = true

@sys.description('Servers plan only. Explicit sub-plan choice passed to the built-in; it defaults to P2 (matching the built-in\'s own verified default), which is not the same as P1. Override to P1 if the customer wants the lower-cost sub-plan instead.')
@allowed([
  'P1'
  'P2'
])
param serversSubPlan string = 'P2'

@sys.description('Servers plan only. Enables the built-in\'s agentless VM scanning extension; only takes effect when serversSubPlan is P2, per the built-in\'s own existence condition. Defaults to true, matching the built-in\'s own verified default.')
param serversAgentlessVmScanningEnabled bool = true

@sys.description('Servers plan only. Enables the built-in\'s MDE-designated-subscription setting. Defaults to false, matching the built-in\'s own verified default.')
param serversMdeDesignatedSubscriptionEnabled bool = false

@sys.description('Storage plan only. Enables the built-in\'s on-upload malware-scanning extension. Defaults to true, matching the built-in\'s own verified default.')
param storageOnUploadMalwareScanningEnabled bool = true

@sys.description('Storage plan only. Monthly GB cap per storage account for the built-in\'s malware-scanning extension. Defaults to 10000, matching the built-in\'s own verified default.')
param storageCapGBPerMonthPerStorageAccount int = 10000

@sys.description('Storage plan only. Enables the built-in\'s sensitive-data-discovery extension. Defaults to true, matching the built-in\'s own verified default.')
param storageSensitiveDataDiscoveryEnabled bool = true

@sys.description('Non-global Azure region used to store the policy assignment and its managed identity when enablePlan is true.')
@minLength(1)
param location string

@sys.description('Open-ended policy assignment metadata.')
param metadata object = {
  category: 'Demo Landing Zone'
  source: 'Bicep'
}

var assignmentNameContainsInvalidCharacter = contains(assignmentName, '#') || contains(assignmentName, '<') || contains(assignmentName, '>') || contains(assignmentName, '%') || contains(assignmentName, '&') || contains(assignmentName, ':') || contains(assignmentName, '\\') || contains(assignmentName, '?') || contains(assignmentName, '/')
var assignmentNameContainsControlCharacter = !empty(filter(controlCharacterEncodings, encoding => contains(toLower(uriComponent(assignmentName)), encoding)))
var validatedAssignmentName = !assignmentNameContainsInvalidCharacter && !assignmentNameContainsControlCharacter && !endsWith(assignmentName, '.') && !endsWith(assignmentName, ' ')
  ? assignmentName
  : fail('assignmentName contains a character that is invalid for an Azure Policy assignment or ends with a period or space.')

var validatedLocation = !empty(trim(location)) && toLower(trim(location)) != 'global'
  ? trim(location)
  : fail('location must be a non-global Azure region.')

var selectedPlan = planDefinitions[plan]
var policyDefinitionId = tenantResourceId('Microsoft.Authorization/policyDefinitions', selectedPlan.definitionId)

// Every built-in below exposes extension parameters beyond "effect". Rather
// than silently accepting whatever the built-in's own defaults are when
// those parameters are simply omitted from an assignment, this module maps
// each verified `plan` value to its own explicit parameter object -- so the
// compiled ARM template always shows a named, documented value for every
// choice the built-in supports (issue #20), even when that value matches
// the built-in's own verified default.
var planParameters = {
  cspm: {
    isSensitiveDataDiscoveryEnabled: {
      value: cspmSensitiveDataDiscoveryEnabled ? 'true' : 'false'
    }
    isContainerRegistriesVulnerabilityAssessmentsEnabled: {
      value: cspmContainerRegistriesVulnerabilityAssessmentsEnabled ? 'true' : 'false'
    }
    isAgentlessDiscoveryForKubernetesEnabled: {
      value: cspmAgentlessDiscoveryForKubernetesEnabled ? 'true' : 'false'
    }
    isAgentlessVmScanningEnabled: {
      value: cspmAgentlessVmScanningEnabled ? 'true' : 'false'
    }
    isEntraPermissionsManagementEnabled: {
      value: cspmEntraPermissionsManagementEnabled ? 'true' : 'false'
    }
  }
  servers: {
    subPlan: {
      value: serversSubPlan
    }
    isAgentlessVmScanningEnabled: {
      value: serversAgentlessVmScanningEnabled ? 'true' : 'false'
    }
    isMdeDesignatedSubscriptionEnabled: {
      value: serversMdeDesignatedSubscriptionEnabled ? 'true' : 'false'
    }
  }
  storage: {
    isOnUploadMalwareScanningEnabled: {
      value: storageOnUploadMalwareScanningEnabled ? 'true' : 'false'
    }
    capGBPerMonthPerStorageAccount: {
      value: storageCapGBPerMonthPerStorageAccount
    }
    isSensitiveDataDiscoveryEnabled: {
      value: storageSensitiveDataDiscoveryEnabled ? 'true' : 'false'
    }
  }
}

resource assignment 'Microsoft.Authorization/policyAssignments@2025-03-01' = {
  name: validatedAssignmentName
  location: validatedLocation
  identity: {
    type: enablePlan ? 'SystemAssigned' : 'None'
  }
  properties: {
    displayName: displayName
    description: description
    policyDefinitionId: policyDefinitionId
    definitionVersion: selectedPlan.definitionVersion
    enforcementMode: 'Default'
    parameters: union(
      {
        effect: {
          value: enablePlan ? 'DeployIfNotExists' : 'Disabled'
        }
      },
      planParameters[plan]
    )
    metadata: metadata
  }
}

output policyAssignmentId string = assignment.id
output identityPrincipalId string = enablePlan ? assignment.identity.principalId : ''
