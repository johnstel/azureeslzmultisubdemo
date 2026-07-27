targetScope = 'subscription'

param subscriptionOwnersGroupObjectId string
param operatorGroupObjectId string
param operatorRoleDefinitionId string

var ownerRoleDefinitionId = '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'

resource subscriptionOwners 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, subscriptionOwnersGroupObjectId, ownerRoleDefinitionId)
  properties: {
    principalId: subscriptionOwnersGroupObjectId
    principalType: 'Group'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', ownerRoleDefinitionId)
  }
}

resource subscriptionOperators 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, operatorGroupObjectId, operatorRoleDefinitionId)
  properties: {
    principalId: operatorGroupObjectId
    principalType: 'Group'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', operatorRoleDefinitionId)
  }
}

