targetScope = 'managementGroup'

@maxLength(64)
param assignmentName string
param displayName string
param description string
param policyDefinitionId string
@allowed([
  'Default'
  'DoNotEnforce'
])
param enforcementMode string
param parameters object

resource assignment 'Microsoft.Authorization/policyAssignments@2025-03-01' = {
  name: assignmentName
  properties: {
    displayName: displayName
    description: description
    policyDefinitionId: policyDefinitionId
    enforcementMode: enforcementMode
    parameters: parameters
    metadata: {
      category: 'Demo Landing Zone'
      source: 'Bicep'
    }
  }
}

output policyAssignmentId string = assignment.id
