targetScope = 'managementGroup'

module invalidAssignmentName '../../modules/policy-assignment.bicep' = {
  name: 'invalid-policy-assignment-name'
  params: {
    assignmentName: '1234567890123456789012345'
    displayName: 'Invalid policy assignment name'
    description: 'This fixture must fail because a management-group assignment name cannot exceed 24 characters.'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/11111111-1111-1111-1111-111111111111'
  }
}
