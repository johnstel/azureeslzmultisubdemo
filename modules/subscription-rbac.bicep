targetScope = 'subscription'

@description('Set true to create the permanent, lower-privilege operator role assignment.')
param deployOperatorRoleAssignment bool = false

param operatorGroupObjectId string
param operatorRoleDefinitionId string

resource subscriptionOperators 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployOperatorRoleAssignment) {
  name: guid(subscription().id, operatorGroupObjectId, operatorRoleDefinitionId)
  properties: {
    principalId: operatorGroupObjectId
    principalType: 'Group'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', operatorRoleDefinitionId)
  }
}
