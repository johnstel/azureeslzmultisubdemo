targetScope = 'tenant'

module invalidScope '../../modules/policy-exemption.bicep' = {
  name: 'invalid-policy-exemption-scope'
  params: {
    exemptionName: 'invalid-scope'
    exemptionScopeType: 'tenant'
    subscriptionId: '44444444-4444-4444-4444-444444444444'
    policyAssignmentId: '/subscriptions/44444444-4444-4444-4444-444444444444/resourceGroups/rg-demo-app/providers/Microsoft.Authorization/policyAssignments/network-ingress-initiative'
    displayName: 'Invalid scope exemption'
    description: 'Fails because exemptionScopeType must be managementGroup, subscription, or resourceGroup.'
    exemptionCategory: 'Mitigated'
    owner: 'workload-owner@contoso.com'
    justification: 'Testing validation.'
    expiresOn: '2026-10-31T23:59:59Z'
    ticketReference: 'TASK-9999'
    approver: 'architecture-board@contoso.com'
    createdOn: '2026-03-10T00:00:00Z'
    reviewedOn: '2026-08-10T00:00:00Z'
  }
}
