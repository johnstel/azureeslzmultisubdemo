targetScope = 'managementGroup'

@sys.description('Runtime principal ID of the policy assignment managed identity.')
param principalId string

@sys.description('Verified built-in role definition IDs required by the assigned policy or initiative.')
param roleDefinitionIds string[]

resource remediationRoleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for roleDefinitionId in roleDefinitionIds: {
  name: guid(managementGroup().id, principalId, roleDefinitionId)
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: tenantResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
  }
}]

output roleAssignmentIds string[] = [for index in range(0, length(roleDefinitionIds)): remediationRoleAssignments[index].id]
