targetScope = 'resourceGroup'

@sys.description('Runtime principal ID of the diagnostics policy assignment managed identity.')
@minLength(1)
param principalId string

@sys.description('Verified built-in role definition IDs granted to the diagnostics identity at the workspace scope.')
@minLength(1)
param roleDefinitionIds string[]

@sys.description('Name of the effective Log Analytics workspace that receives the diagnostic settings.')
@minLength(4)
param workspaceName string

resource workspace 'Microsoft.OperationalInsights/workspaces@2025-02-01' existing = {
  name: workspaceName
}

// Least privilege: the diagnostics identity is granted only the verified role definitions supplied
// by the caller, and only on the single workspace that receives the diagnostic settings.
resource diagnosticsRoleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for roleDefinitionId in roleDefinitionIds: {
    name: guid(workspace.id, principalId, roleDefinitionId)
    scope: workspace
    properties: {
      principalId: principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: tenantResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
    }
  }
]

@sys.description('Resource IDs of the role assignments created at the effective workspace scope.')
output roleAssignmentIds string[] = [
  for index in range(0, length(roleDefinitionIds)): diagnosticsRoleAssignments[index].id
]

@sys.description('Resource ID of the effective workspace that the diagnostics identity can write to.')
output workspaceResourceId string = workspace.id
