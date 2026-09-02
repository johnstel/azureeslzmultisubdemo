targetScope = 'tenant'

module invalidExpiry '../../modules/policy-exemption.bicep' = {
  name: 'invalid-policy-exemption-expiry'
  params: {
    exemptionName: 'invalid-expiry'
    exemptionScopeType: 'managementGroup'
    managementGroupName: 'demo-root'
    policyAssignmentId: '/providers/Microsoft.Management/managementGroups/demo-root/providers/Microsoft.Authorization/policyAssignments/deny-public-ingress'
    displayName: 'Invalid expiry exemption'
    description: 'Fails because expiresOn is empty.'
    exemptionCategory: 'Waiver'
    owner: 'platform-owner@contoso.com'
    justification: 'Testing validation.'
    expiresOn: ''
    ticketReference: 'CHG-9999'
    approver: 'governance-board@contoso.com'
    createdOn: '2026-01-15T00:00:00Z'
    reviewedOn: '2026-06-15T00:00:00Z'
  }
}
