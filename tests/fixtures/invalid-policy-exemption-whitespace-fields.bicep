targetScope = 'tenant'

module invalidWhitespace '../../modules/policy-exemption.bicep' = {
  name: 'invalid-policy-exemption-whitespace-fields'
  params: {
    exemptionName: 'invalid-whitespace'
    exemptionScopeType: 'managementGroup'
    managementGroupName: 'demo-root'
    policyAssignmentId: '/providers/Microsoft.Management/managementGroups/demo-root/providers/Microsoft.Authorization/policyAssignments/deny-public-ingress'
    displayName: '   '
    description: 'valid description'
    exemptionCategory: 'Waiver'
    owner: 'platform-owner@contoso.com'
    justification: 'Testing validation.'
    expiresOn: '2026-12-31T23:59:59Z'
    ticketReference: 'CHG-9997'
    approver: 'governance-board@contoso.com'
    createdOn: '2026-01-15T00:00:00Z'
    reviewedOn: '2026-06-15T00:00:00Z'
  }
}
