targetScope = 'tenant'

module invalidAssignmentAncestry '../../modules/policy-exemption.bicep' = {
  name: 'invalid-policy-exemption-assignment-ancestry'
  params: {
    exemptionName: 'invalid-assignment-ancestry'
    exemptionScopeType: 'subscription'
    subscriptionId: '33333333-3333-3333-3333-333333333333'
    policyAssignmentId: '/subscriptions/44444444-4444-4444-4444-444444444444/providers/Microsoft.Authorization/policyAssignments/require-tags'
    displayName: 'Invalid assignment ancestry exemption'
    description: 'Fails because policyAssignmentId ancestry does not match target subscription.'
    exemptionCategory: 'Mitigated'
    owner: 'subscription-owner@contoso.com'
    justification: 'Testing validation.'
    expiresOn: '2026-11-30T23:59:59Z'
    ticketReference: 'INC-9994'
    approver: 'risk-committee@contoso.com'
    createdOn: '2026-02-01T00:00:00Z'
    reviewedOn: '2026-07-01T00:00:00Z'
  }
}
