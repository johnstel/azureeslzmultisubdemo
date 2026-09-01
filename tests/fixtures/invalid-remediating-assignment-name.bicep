targetScope = 'managementGroup'

module invalid '../../modules/remediating-policy-assignment.bicep' = {
  name: 'invalid-remediation-name'
  params: {
    assignmentName: 'this-name-is-over-24-chars'
    displayName: 'Invalid remediation assignment name'
    description: 'This fixture must fail the management-group policy assignment name limit.'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/11111111-1111-1111-1111-111111111111'
    location: 'eastus2'
    identity: {
      type: 'SystemAssigned'
    }
    verifiedRoleDefinitionIds: [
      '22222222-2222-2222-2222-222222222222'
    ]
  }
}
