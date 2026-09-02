targetScope = 'tenant'

module invalidTimestampFormat '../../modules/policy-exemption.bicep' = {
  name: 'invalid-policy-exemption-timestamp-format'
  params: {
    exemptionName: 'invalid-time-format'
    exemptionScopeType: 'managementGroup'
    managementGroupName: 'demo-root'
    policyAssignmentId: '/providers/Microsoft.Management/managementGroups/demo-root/providers/Microsoft.Authorization/policyAssignments/deny-public-ingress'
    displayName: 'Invalid timestamp format exemption'
    description: 'Fails because expiresOn is not canonical RFC3339 UTC.'
    exemptionCategory: 'Waiver'
    owner: 'platform-owner@contoso.com'
    justification: 'Testing validation.'
    expiresOn: '2026-12-31TZ'
    ticketReference: 'CHG-9996'
    approver: 'governance-board@contoso.com'
    createdOn: '2026-01-15T00:00:00Z'
    reviewedOn: '2026-06-15T00:00:00Z'
  }
}
