targetScope = 'managementGroup'

module invalid '../../modules/remediating-policy-assignment.bicep' = {
  name: 'invalid-missing-location'
  params: {
    assignmentName: 'missing-location'
    displayName: 'Missing location'
    description: 'This fixture must fail because no remediation assignment location is supplied.'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/11111111-1111-1111-1111-111111111111'
    identityType: 'SystemAssigned'
    verifiedRoleDefinitionIds: [
      '22222222-2222-2222-2222-222222222222'
    ]
  }
}
