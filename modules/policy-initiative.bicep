targetScope = 'managementGroup'

@sealed()
type policyDefinitionReference = {
  @minLength(1)
  policyDefinitionId: string

  @minLength(1)
  policyDefinitionReferenceId: string

  definitionVersion: string?

  parameters: object
  groupNames: string[]
}

@sealed()
type policyDefinitionGroup = {
  @minLength(1)
  name: string

  @minLength(1)
  displayName: string

  @minLength(1)
  category: string

  description: string
}

@description('Stable resource name for the custom initiative.')
@minLength(1)
@maxLength(64)
param initiativeName string

@description('Operator-facing display name for the custom initiative.')
@minLength(1)
param initiativeDisplayName string

@description('Operator-facing description of the custom initiative.')
@minLength(1)
param initiativeDescription string

@description('Metadata category used to group the initiative in Azure Policy.')
@minLength(1)
param initiativeCategory string

@description('Semantic version recorded in both initiative properties and metadata.')
@minLength(5)
param initiativeVersion string

@description('Initiative-level parameter definitions passed through to referenced policies.')
param initiativeParameters object = {}

@description('Optional metadata groups that policy definition references can join by name.')
param policyDefinitionGroups policyDefinitionGroup[] = []

@description('Policy definition references with stable unique IDs, parameter mappings, and optional group memberships.')
@minLength(1)
param policyDefinitionReferences policyDefinitionReference[]

var normalizedPolicyDefinitionReferenceIds = [
  for policyDefinitionReference in policyDefinitionReferences: toLower(policyDefinitionReference.policyDefinitionReferenceId)
]
var hasDuplicatePolicyDefinitionReferenceIds = length(normalizedPolicyDefinitionReferenceIds) != length(union(normalizedPolicyDefinitionReferenceIds, []))
var validatedPolicyDefinitionReferences = hasDuplicatePolicyDefinitionReferenceIds
  ? fail('policyDefinitionReferences must use non-empty, case-insensitively unique policyDefinitionReferenceId values.')
  : policyDefinitionReferences

resource initiative 'Microsoft.Authorization/policySetDefinitions@2025-03-01' = {
  name: initiativeName
  properties: {
    policyType: 'Custom'
    displayName: initiativeDisplayName
    description: initiativeDescription
    metadata: {
      category: initiativeCategory
      version: initiativeVersion
      governanceVersion: '2.0'
      managedBy: 'Bicep'
    }
    version: initiativeVersion
    parameters: initiativeParameters
    policyDefinitionGroups: policyDefinitionGroups
    policyDefinitions: [
      for policyDefinitionReference in validatedPolicyDefinitionReferences: {
        policyDefinitionId: policyDefinitionReference.policyDefinitionId
        policyDefinitionReferenceId: policyDefinitionReference.policyDefinitionReferenceId
        ...(!empty(policyDefinitionReference.?definitionVersion ?? '') ? {
          definitionVersion: policyDefinitionReference.?definitionVersion
        } : {})
        parameters: policyDefinitionReference.parameters
        groupNames: policyDefinitionReference.groupNames
      }
    ]
  }
}

output policySetDefinitionId string = initiative.id
output policySetDefinitionName string = initiative.name
output policyDefinitionReferenceIds string[] = [
  for policyDefinitionReference in validatedPolicyDefinitionReferences: policyDefinitionReference.policyDefinitionReferenceId
]
