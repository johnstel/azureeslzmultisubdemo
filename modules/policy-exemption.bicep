targetScope = 'tenant'

func stripHex(value string) string => replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(toLower(value), '0', ''), '1', ''), '2', ''), '3', ''), '4', ''), '5', ''), '6', ''), '7', ''), '8', ''), '9', ''), 'a', ''), 'b', ''), 'c', ''), 'd', ''), 'e', ''), 'f', '')
func isGuid(value string) bool => length(value) == 36 ? substring(value, 8, 1) == '-' && substring(value, 13, 1) == '-' && substring(value, 18, 1) == '-' && substring(value, 23, 1) == '-' && length(replace(value, '-', '')) == 32 && empty(stripHex(replace(value, '-', ''))) : false

@sys.description('Policy exemption resource name.')
@minLength(1)
@maxLength(64)
param exemptionName string

@sys.description('Scope kind for the exemption deployment.')
param exemptionScopeType 'managementGroup' | 'subscription' | 'resourceGroup'

@sys.description('Management-group name when exemptionScopeType is managementGroup.')
param managementGroupName string = ''

@sys.description('Subscription GUID when exemptionScopeType is subscription or resourceGroup.')
param subscriptionId string = ''

@sys.description('Resource-group name when exemptionScopeType is resourceGroup.')
param resourceGroupName string = ''

@sys.description('Full resource ID of the target policy assignment.')
@minLength(1)
param policyAssignmentId string

@sys.description('Policy exemption display name.')
@minLength(1)
@maxLength(128)
param displayName string

@sys.description('Policy exemption description.')
@minLength(1)
@maxLength(512)
param description string

@sys.description('Policy exemption category.')
param exemptionCategory 'Waiver' | 'Mitigated'

@sys.description('Accountable exemption owner.')
@minLength(1)
@maxLength(128)
param owner string

@sys.description('Documented business or technical justification.')
@minLength(1)
@maxLength(1024)
param justification string

@sys.description('Expiry timestamp in UTC (for example 2026-12-31T23:59:59Z).')
@minLength(1)
param expiresOn string

@sys.description('Ticket or evidence reference backing the exemption.')
@minLength(1)
@maxLength(256)
param ticketReference string

@sys.description('Optional initiative policyDefinitionReferenceIds for targeted exemptions.')
param policyDefinitionReferenceIds string[] = []

@sys.description('Metadata source for traceability.')
@minLength(1)
@maxLength(64)
param source string = 'Bicep'

@sys.description('Approver identity recorded for governance traceability.')
@minLength(1)
@maxLength(128)
param approver string

@sys.description('Creation timestamp metadata in UTC.')
@minLength(1)
param createdOn string

@sys.description('Last review timestamp metadata in UTC.')
@minLength(1)
param reviewedOn string

@sys.description('v2 governance ownership metadata.')
@minLength(1)
@maxLength(128)
param governanceOwner string = 'eslz-v2-governance'

var validatedPolicyAssignmentId = startsWith(policyAssignmentId, '/') && policyAssignmentId == trim(policyAssignmentId) && !endsWith(policyAssignmentId, '/') && contains(toLower(policyAssignmentId), '/providers/microsoft.authorization/policyassignments/')
  ? policyAssignmentId
  : fail('policyAssignmentId must be an exact Azure Policy assignment resource ID.')

var validatedExpiresOn = expiresOn == trim(expiresOn) && contains(expiresOn, 'T') && endsWith(expiresOn, 'Z')
  ? expiresOn
  : fail('expiresOn must be a non-empty UTC timestamp such as 2026-12-31T23:59:59Z.')
var validatedCreatedOn = createdOn == trim(createdOn) && contains(createdOn, 'T') && endsWith(createdOn, 'Z')
  ? createdOn
  : fail('createdOn must be a non-empty UTC timestamp such as 2026-01-01T00:00:00Z.')
var validatedReviewedOn = reviewedOn == trim(reviewedOn) && contains(reviewedOn, 'T') && endsWith(reviewedOn, 'Z')
  ? reviewedOn
  : fail('reviewedOn must be a non-empty UTC timestamp such as 2026-06-30T00:00:00Z.')

var validatedScopeType = exemptionScopeType == 'managementGroup'
  ? !empty(trim(managementGroupName)) && empty(subscriptionId) && empty(resourceGroupName)
    ? exemptionScopeType
    : fail('managementGroup exemptions require managementGroupName and must not include subscriptionId or resourceGroupName.')
  : exemptionScopeType == 'subscription'
    ? isGuid(subscriptionId) && empty(managementGroupName) && empty(resourceGroupName)
      ? exemptionScopeType
      : fail('subscription exemptions require a valid subscriptionId and must not include managementGroupName or resourceGroupName.')
    : isGuid(subscriptionId) && !empty(trim(resourceGroupName)) && resourceGroupName == trim(resourceGroupName) && empty(managementGroupName)
      ? exemptionScopeType
      : fail('resourceGroup exemptions require valid subscriptionId and resourceGroupName and must not include managementGroupName.')

var invalidPolicyDefinitionReferenceIds = filter(policyDefinitionReferenceIds, policyDefinitionReferenceId => empty(trim(policyDefinitionReferenceId)))
var normalizedPolicyDefinitionReferenceIds = [for policyDefinitionReferenceId in policyDefinitionReferenceIds: toLower(policyDefinitionReferenceId)]
var hasDuplicatePolicyDefinitionReferenceIds = length(normalizedPolicyDefinitionReferenceIds) != length(union(normalizedPolicyDefinitionReferenceIds, normalizedPolicyDefinitionReferenceIds))
var validatedPolicyDefinitionReferenceIds = empty(invalidPolicyDefinitionReferenceIds)
  ? !hasDuplicatePolicyDefinitionReferenceIds
    ? policyDefinitionReferenceIds
    : fail('policyDefinitionReferenceIds must be case-insensitively unique when supplied.')
  : fail('policyDefinitionReferenceIds cannot include empty values.')

module managementGroupExemption './policy-exemption-at-management-group.bicep' = if (validatedScopeType == 'managementGroup') {
  name: 'policy-exemption-mg'
  scope: managementGroup(managementGroupName)
  params: {
    exemptionName: exemptionName
    displayName: displayName
    description: description
    exemptionCategory: exemptionCategory
    policyAssignmentId: validatedPolicyAssignmentId
    expiresOn: validatedExpiresOn
    owner: owner
    justification: justification
    ticketReference: ticketReference
    policyDefinitionReferenceIds: validatedPolicyDefinitionReferenceIds
    source: source
    approver: approver
    createdOn: validatedCreatedOn
    reviewedOn: validatedReviewedOn
    governanceOwner: governanceOwner
  }
}

module subscriptionExemption './policy-exemption-at-subscription.bicep' = if (validatedScopeType == 'subscription') {
  name: 'policy-exemption-sub'
  scope: subscription(subscriptionId)
  params: {
    exemptionName: exemptionName
    displayName: displayName
    description: description
    exemptionCategory: exemptionCategory
    policyAssignmentId: validatedPolicyAssignmentId
    expiresOn: validatedExpiresOn
    owner: owner
    justification: justification
    ticketReference: ticketReference
    policyDefinitionReferenceIds: validatedPolicyDefinitionReferenceIds
    source: source
    approver: approver
    createdOn: validatedCreatedOn
    reviewedOn: validatedReviewedOn
    governanceOwner: governanceOwner
  }
}

module resourceGroupExemption './policy-exemption-at-resource-group.bicep' = if (validatedScopeType == 'resourceGroup') {
  name: 'policy-exemption-rg'
  scope: resourceGroup(subscriptionId, resourceGroupName)
  params: {
    exemptionName: exemptionName
    displayName: displayName
    description: description
    exemptionCategory: exemptionCategory
    policyAssignmentId: validatedPolicyAssignmentId
    expiresOn: validatedExpiresOn
    owner: owner
    justification: justification
    ticketReference: ticketReference
    policyDefinitionReferenceIds: validatedPolicyDefinitionReferenceIds
    source: source
    approver: approver
    createdOn: validatedCreatedOn
    reviewedOn: validatedReviewedOn
    governanceOwner: governanceOwner
  }
}
