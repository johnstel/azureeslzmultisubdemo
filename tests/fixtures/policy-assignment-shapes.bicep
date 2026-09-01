targetScope = 'managementGroup'

module policyAssignment '../../modules/policy-assignment.bicep' = {
  name: 'example-policy-assignment'
  params: {
    assignmentName: 'example-audit-policy'
    displayName: 'Example audit policy assignment'
    description: 'Exercises safe defaults and omitted optional properties for a policy definition.'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/11111111-1111-1111-1111-111111111111'
  }
}

module initiativeAssignment '../../modules/policy-assignment.bicep' = {
  name: 'example-initiative-assignment'
  params: {
    assignmentName: 'example-initiative'
    displayName: 'Example initiative assignment'
    description: 'Exercises every supported non-remediating property for a policy set definition.'
    policyDefinitionId: '/providers/Microsoft.Authorization/policySetDefinitions/22222222-2222-2222-2222-222222222222'
    definitionVersion: '1.2.*'
    enforcementMode: 'Default'
    parameters: {
      effect: {
        value: 'Audit'
      }
    }
    metadata: {
      category: 'Test'
      owner: 'Platform Team'
    }
    nonComplianceMessages: [
      {
        message: 'The assigned initiative requirements must be satisfied.'
      }
      {
        message: 'The audit reference requirement must be satisfied.'
        policyDefinitionReferenceId: 'audit-reference'
      }
    ]
    notScopes: [
      '/providers/Microsoft.Management/managementGroups/excluded'
    ]
    resourceSelectors: [
      {
        name: 'locations'
        selectors: [
          {
            kind: 'resourceLocation'
            in: [
              'eastus2'
              'westus2'
            ]
          }
        ]
      }
      {
        name: 'resource-types'
        selectors: [
          {
            kind: 'resourceType'
            notIn: [
              'Microsoft.Compute/virtualMachines'
            ]
          }
        ]
      }
    ]
  }
}
