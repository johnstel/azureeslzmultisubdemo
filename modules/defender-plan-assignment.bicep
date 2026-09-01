targetScope = 'managementGroup'

// Dedicated, narrow-purpose module for the Microsoft Defender for Cloud plan
// governance markers (REQ-DEF-02/03/04). These built-in policy definitions
// are DeployIfNotExists-capable and their only verified remediation role is
// Owner. This repository's shared RBAC modules deliberately refuse to grant
// Owner or User Access Administrator automatically (see
// modules/remediating-policy-assignment.bicep), and a single management-
// group-scoped identity inherited across every descendant subscription is
// too broad a blast radius to grant Owner to without a separately approved,
// time-bounded workflow that is out of scope for this demo template. So
// this module keeps these controls "manual-evidence" (see
// policy/control-catalog.json): the assignment's effect is always Disabled
// and it never creates a managed identity, meaning normal deployment of
// this template can never create or leave standing Owner access anywhere.
// Actually enabling a plan is an independent action a customer takes
// directly against Microsoft Defender for Cloud (Azure Portal or
// `az security pricing create`), entirely outside this template; that
// action, and any role grants Microsoft's own tooling then requires, remain
// the customer's responsibility.
//
// policyDefinitionId/definitionVersion are intentionally not accepted as
// free-text parameters. The `plan` parameter is restricted to the three
// verified built-in plans below so this module can never be pointed at an
// unverified definition or an unpinned version.

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

var selectedPlan = planDefinitions[plan]
var policyDefinitionId = tenantResourceId('Microsoft.Authorization/policyDefinitions', selectedPlan.definitionId)

resource assignment 'Microsoft.Authorization/policyAssignments@2025-03-01' = {
  name: validatedAssignmentName
  properties: {
    displayName: displayName
    description: description
    policyDefinitionId: policyDefinitionId
    definitionVersion: selectedPlan.definitionVersion
    enforcementMode: 'Default'
    parameters: {
      effect: {
        value: 'Disabled'
      }
    }
    metadata: metadata
  }
}

output policyAssignmentId string = assignment.id
