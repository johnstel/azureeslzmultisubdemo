targetScope = 'tenant'

module invalidTimestampDate '../../modules/policy-exemption.bicep' = {
  name: 'invalid-policy-exemption-timestamp-date'
  params: {
    exemptionName: 'invalid-time-date'
    exemptionScopeType: 'managementGroup'
    managementGroupName: 'demo-root'
    policyAssignmentId: '/providers/Microsoft.Management/managementGroups/demo-root/providers/Microsoft.Authorization/policyAssignments/deny-public-ingress'
    displayName: 'Invalid timestamp calendar date exemption'
    description: 'Fails because expiresOn has an impossible calendar date.'
    exemptionCategory: 'Waiver'
    owner: 'platform-owner@contoso.com'
    justification: 'Testing validation.'
    expiresOn: '2026-02-30T23:59:59Z'
    ticketReference: 'CHG-9995'
    approver: 'governance-board@contoso.com'
    createdOn: '2026-01-15T00:00:00Z'
    reviewedOn: '2026-06-15T00:00:00Z'
  }
}

module invalidTimestampYearZero '../../modules/policy-exemption.bicep' = {
  name: 'invalid-policy-exemption-timestamp-year-zero'
  params: {
    exemptionName: 'invalid-time-year-zero'
    exemptionScopeType: 'managementGroup'
    managementGroupName: 'demo-root'
    policyAssignmentId: '/providers/Microsoft.Management/managementGroups/demo-root/providers/Microsoft.Authorization/policyAssignments/deny-public-ingress'
    displayName: 'Invalid timestamp year zero exemption'
    description: 'Fails because RFC3339 year 0000 is rejected.'
    exemptionCategory: 'Waiver'
    owner: 'platform-owner@contoso.com'
    justification: 'Testing validation.'
    expiresOn: '0000-02-29T23:59:59Z'
    ticketReference: 'CHG-9995'
    approver: 'governance-board@contoso.com'
    createdOn: '2026-01-15T00:00:00Z'
    reviewedOn: '2026-06-15T00:00:00Z'
  }
}
