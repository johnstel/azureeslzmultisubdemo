targetScope = 'tenant'

module managementGroupExemption '../../modules/policy-exemption.bicep' = {
  name: 'example-management-group-exemption'
  params: {
    exemptionName: 'demo-mg-exemption'
    exemptionScopeType: 'managementGroup'
    managementGroupName: 'demo-root'
    policyAssignmentId: '/providers/Microsoft.Management/managementGroups/demo-root/providers/Microsoft.Authorization/policyAssignments/deny-public-ingress'
    displayName: 'Demo management-group exemption'
    description: 'Demonstrates a time-bound exemption at management-group scope.'
    exemptionCategory: 'Waiver'
    owner: 'platform-owner@contoso.com'
    justification: 'Temporary path required while private connectivity is being remediated.'
    expiresOn: '2026-12-31T23:59:59Z'
    ticketReference: 'CHG-1001'
    approver: 'governance-board@contoso.com'
    createdOn: '2026-01-15T00:00:00Z'
    reviewedOn: '2026-06-15T00:00:00Z'
  }
}

module subscriptionExemption '../../modules/policy-exemption.bicep' = {
  name: 'example-subscription-exemption'
  params: {
    exemptionName: 'demo-sub-exemption'
    exemptionScopeType: 'subscription'
    subscriptionId: '33333333-3333-3333-3333-333333333333'
    policyAssignmentId: '/subscriptions/33333333-3333-3333-3333-333333333333/providers/Microsoft.Authorization/policyAssignments/require-tags'
    displayName: 'Demo subscription exemption'
    description: 'Demonstrates a time-bound exemption at subscription scope.'
    exemptionCategory: 'Mitigated'
    owner: 'subscription-owner@contoso.com'
    justification: 'Compensating controls are in place during migration.'
    expiresOn: '2026-11-30T23:59:59Z'
    ticketReference: 'INC-2002'
    approver: 'risk-committee@contoso.com'
    createdOn: '2026-02-01T00:00:00Z'
    reviewedOn: '2026-07-01T00:00:00Z'
  }
}

module resourceGroupExemption '../../modules/policy-exemption.bicep' = {
  name: 'example-resource-group-exemption'
  params: {
    exemptionName: 'demo-rg-exemption'
    exemptionScopeType: 'resourceGroup'
    subscriptionId: '44444444-4444-4444-4444-444444444444'
    resourceGroupName: 'rg-demo-app'
    policyAssignmentId: '/subscriptions/44444444-4444-4444-4444-444444444444/resourceGroups/rg-demo-app/providers/Microsoft.Authorization/policyAssignments/network-ingress-initiative'
    displayName: 'Demo resource-group exemption'
    description: 'Demonstrates reference-specific initiative exemptions at resource-group scope.'
    exemptionCategory: 'Waiver'
    owner: 'workload-owner@contoso.com'
    justification: 'Exception is needed while the approved replacement service is onboarded.'
    expiresOn: '2026-10-31T23:59:59Z'
    ticketReference: 'TASK-3003'
    allowedPolicyDefinitionReferenceIds: [
      'public-management-ingress'
      'require-subnet-nsg'
    ]
    policyDefinitionReferenceIds: [
      'public-management-ingress'
      'require-subnet-nsg'
    ]
    approver: 'architecture-board@contoso.com'
    createdOn: '2026-03-10T00:00:00Z'
    reviewedOn: '2026-08-10T00:00:00Z'
    source: 'eslz-v2-governance'
    governanceOwner: 'platform-governance'
  }
}
