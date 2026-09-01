targetScope = 'managementGroup'

module invalid '../../modules/remediating-policy-assignment.bicep' = {
  name: 'invalid-user-identity'
  params: {
    assignmentName: 'incomplete-user-id'
    displayName: 'Incomplete user identity'
    description: 'This fixture must fail because the user-assigned identity has no resource ID.'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/11111111-1111-1111-1111-111111111111'
    location: 'eastus2'
    identity: {
      type: 'UserAssigned'
    }
    verifiedRoleDefinitionIds: [
      '22222222-2222-2222-2222-222222222222'
    ]
  }
}
