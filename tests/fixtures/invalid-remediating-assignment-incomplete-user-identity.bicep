targetScope = 'managementGroup'

module invalid '../../modules/remediating-policy-assignment.bicep' = {
  name: 'invalid-user-identity'
  params: {
    assignmentName: 'incomplete-user-id'
    displayName: 'Incomplete user identity'
    description: 'This fixture must fail because the user-assigned identity has no principal ID.'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/11111111-1111-1111-1111-111111111111'
    location: 'eastus2'
    identity: {
      type: 'UserAssigned'
      resourceId: '/subscriptions/44444444-4444-4444-4444-444444444444/resourceGroups/identities/providers/Microsoft.ManagedIdentity/userAssignedIdentities/policy-remediation'
    }
    verifiedRoleDefinitionIds: [
      '22222222-2222-2222-2222-222222222222'
    ]
  }
}
