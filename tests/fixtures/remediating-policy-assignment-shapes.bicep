targetScope = 'managementGroup'

module systemAssigned '../../modules/remediating-policy-assignment.bicep' = {
  name: 'example-system-remediation'
  params: {
    assignmentName: 'example-system-remed'
    displayName: 'Example system-assigned remediation policy'
    description: 'Exercises the safe defaults for a system-assigned remediation identity.'
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

module userAssigned '../../modules/remediating-policy-assignment.bicep' = {
  name: 'example-user-remediation'
  params: {
    assignmentName: 'example-user-remed'
    displayName: 'Example user-assigned remediation initiative'
    description: 'Exercises every assignment property with a supplied user-assigned remediation identity.'
    policyDefinitionId: '/providers/Microsoft.Authorization/policySetDefinitions/33333333-3333-3333-3333-333333333333'
    location: 'westus2'
    identity: {
      type: 'UserAssigned'
      resourceId: '/subscriptions/44444444-4444-4444-4444-444444444444/resourceGroups/identities/providers/Microsoft.ManagedIdentity/userAssignedIdentities/policy-remediation'
    }
    verifiedRoleDefinitionIds: [
      '66666666-6666-6666-6666-666666666666'
      '77777777-7777-7777-7777-777777777777'
    ]
    definitionVersion: '1.2.*'
    enforcementMode: 'Default'
    parameters: {
      effect: {
        value: 'Modify'
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
    ]
  }
}
