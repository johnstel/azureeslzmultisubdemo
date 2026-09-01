targetScope = 'resourceGroup'

@sys.description('Destination Log Analytics workspace name.')
@minLength(4)
param workspaceName string

@sys.description('Runtime principal ID of the policy assignment managed identity.')
param principalId string

@sys.description('Verified built-in role definition IDs required at the destination workspace scope.')
param roleDefinitionIds string[]

resource workspace 'Microsoft.OperationalInsights/workspaces@2025-02-01' existing = {
  name: workspaceName
}

resource remediationRoleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for roleDefinitionId in roleDefinitionIds: {
  name: guid(workspace.id, principalId, roleDefinitionId)
  scope: workspace
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: tenantResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
  }
}]

output roleAssignmentIds string[] = [for index in range(0, length(roleDefinitionIds)): remediationRoleAssignments[index].id]
