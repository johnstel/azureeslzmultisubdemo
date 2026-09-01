targetScope = 'managementGroup'

module invalid '../../modules/remediating-policy-assignment.bicep' = {
  name: 'invalid-missing-identity'
  params: {
    assignmentName: 'missing-identity'
    displayName: 'Missing identity'
    description: 'This fixture must fail because no remediation identity type is supplied.'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/11111111-1111-1111-1111-111111111111'
    location: 'eastus2'
    verifiedRoleDefinitionIds: [
      '22222222-2222-2222-2222-222222222222'
    ]
  }
}
