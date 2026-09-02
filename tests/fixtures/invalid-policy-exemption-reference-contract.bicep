targetScope = 'tenant'

module invalidReferenceContract '../../modules/policy-exemption.bicep' = {
  name: 'invalid-policy-exemption-reference-contract'
  params: {
    exemptionName: 'invalid-reference-contract'
    exemptionScopeType: 'resourceGroup'
    subscriptionId: '44444444-4444-4444-4444-444444444444'
    resourceGroupName: 'rg-demo-app'
    policyAssignmentId: '/subscriptions/44444444-4444-4444-4444-444444444444/resourceGroups/rg-demo-app/providers/Microsoft.Authorization/policyAssignments/network-ingress-initiative'
    displayName: 'Invalid reference contract exemption'
    description: 'Fails because policyDefinitionReferenceIds are outside explicit allowlist.'
    exemptionCategory: 'Waiver'
    owner: 'workload-owner@contoso.com'
    justification: 'Testing validation.'
    expiresOn: '2026-10-31T23:59:59Z'
    ticketReference: 'TASK-9993'
    allowedPolicyDefinitionReferenceIds: [
      'public-management-ingress'
    ]
    policyDefinitionReferenceIds: [
      'public-management-ingress'
      'require-subnet-nsg'
    ]
    approver: 'architecture-board@contoso.com'
    createdOn: '2026-03-10T00:00:00Z'
    reviewedOn: '2026-08-10T00:00:00Z'
  }
}
