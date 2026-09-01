targetScope = 'managementGroup'

// Dedicated, narrow-purpose module for optional Microsoft Defender for Cloud
// plan assignments (REQ-DEF-02/03/04). These built-in policy definitions are
// DeployIfNotExists-capable, so Azure Policy requires the assignment to carry
// a managed identity even while the safe default keeps the resolved effect
// at Disabled. The verified built-in role each definition requires for
// remediation (Owner) is intentionally excluded from this repository's
// automatic RBAC granting (see modules/remediating-policy-assignment.bicep),
// so this module never assigns any role to the identity it creates. A
// customer who explicitly opts in to a paid plan must manually grant the
// Owner role to the identity's principal ID (exposed as an output) before
// the DeployIfNotExists effect can successfully remediate.

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

@sys.description('Full resource ID of a built-in Microsoft Defender for Cloud plan policy definition.')
@minLength(1)
param policyDefinitionId string

@sys.description('Non-global Azure region used to store the policy assignment and its managed identity.')
@minLength(1)
param location string

@sys.description('Set true only after reviewing Microsoft Defender for Cloud licensing/cost and manually granting the identity the required built-in role. Defaults to false, which keeps the plan Disabled and requires no role grant.')
param enablePlan bool = false

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

resource assignment 'Microsoft.Authorization/policyAssignments@2025-03-01' = {
  name: validatedAssignmentName
  location: validatedLocation
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: displayName
    description: description
    policyDefinitionId: policyDefinitionId
    enforcementMode: 'Default'
    parameters: {
      effect: {
        value: enablePlan ? 'DeployIfNotExists' : 'Disabled'
      }
    }
    metadata: metadata
  }
}

output policyAssignmentId string = assignment.id
output identityPrincipalId string = assignment.identity.principalId
output planEnabled bool = enablePlan
