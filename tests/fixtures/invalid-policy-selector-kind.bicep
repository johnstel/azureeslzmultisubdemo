targetScope = 'managementGroup'

module invalidSelectorKind '../../modules/policy-assignment.bicep' = {
  name: 'invalid-policy-selector-kind'
  params: {
    assignmentName: 'invalid-selector-kind'
    displayName: 'Invalid resource selector kind'
    description: 'This fixture must fail because policyDefinitionReferenceId is not a resource selector kind.'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/11111111-1111-1111-1111-111111111111'
    resourceSelectors: [
      {
        name: 'invalid-kind'
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
