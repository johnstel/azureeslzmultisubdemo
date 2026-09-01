targetScope = 'managementGroup'

module invalid '../../modules/remediating-policy-assignment.bicep' = {
  name: 'invalid-remediation-selector'
  params: {
    assignmentName: 'invalid-selector'
    displayName: 'Invalid remediation selector'
    description: 'This fixture must fail because policyDefinitionReferenceId is not a resource selector kind.'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/11111111-1111-1111-1111-111111111111'
    location: 'eastus2'
    identity: {
      type: 'SystemAssigned'
    }
    verifiedRoleDefinitionIds: [
      '22222222-2222-2222-2222-222222222222'
    ]
    resourceSelectors: [
      {
        name: 'invalid'
        selectors: [
          {
            kind: 'policyDefinitionReferenceId'
            in: [
              'reference'
            ]
          }
        ]
      }
    ]
  }
}
