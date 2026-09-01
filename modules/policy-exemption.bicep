targetScope = 'tenant'

func stripDigits(value string) string => replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(value, '0', ''), '1', ''), '2', ''), '3', ''), '4', ''), '5', ''), '6', ''), '7', ''), '8', ''), '9', '')
func stripHex(value string) string => replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(toLower(value), '0', ''), '1', ''), '2', ''), '3', ''), '4', ''), '5', ''), '6', ''), '7', ''), '8', ''), '9', ''), 'a', ''), 'b', ''), 'c', ''), 'd', ''), 'e', ''), 'f', '')
func isGuid(value string) bool => length(value) == 36 ? substring(value, 8, 1) == '-' && substring(value, 13, 1) == '-' && substring(value, 18, 1) == '-' && substring(value, 23, 1) == '-' && length(replace(value, '-', '')) == 32 && empty(stripHex(replace(value, '-', ''))) : false
func isTrimmedNonEmpty(value string) bool => !empty(trim(value)) && value == trim(value)
func hasValidResourceIdSegments(value string) bool => startsWith(value, '/') && !endsWith(value, '/') && length(filter(skip(split(value, '/'), 1), segment => empty(segment) || segment != trim(segment))) == 0
func isLeapYear(year int) bool => (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
func isCanonicalDate(value string) bool => length(value) == 10 && substring(value, 4, 1) == '-' && substring(value, 7, 1) == '-' && empty(stripDigits(substring(value, 0, 4))) && empty(stripDigits(substring(value, 5, 2))) && empty(stripDigits(substring(value, 8, 2)))
  ? int(substring(value, 5, 2)) >= 1 && int(substring(value, 5, 2)) <= 12 && int(substring(value, 8, 2)) >= 1 && int(substring(value, 8, 2)) <= (int(substring(value, 5, 2)) == 2 ? (isLeapYear(int(substring(value, 0, 4))) ? 29 : 28) : (contains([4, 6, 9, 11], int(substring(value, 5, 2))) ? 30 : 31))
  : false
func isCanonicalRfc3339Utc(value string) bool => length(value) == 20 && substring(value, 10, 1) == 'T' && substring(value, 13, 1) == ':' && substring(value, 16, 1) == ':' && endsWith(value, 'Z') && isCanonicalDate(substring(value, 0, 10)) && empty(stripDigits(substring(value, 11, 2))) && empty(stripDigits(substring(value, 14, 2))) && empty(stripDigits(substring(value, 17, 2)))
  ? int(substring(value, 11, 2)) <= 23 && int(substring(value, 14, 2)) <= 59 && int(substring(value, 17, 2)) <= 59
  : false

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

@sys.description('Expiry timestamp in canonical RFC3339 UTC format (for example 2026-12-31T23:59:59Z).')
@minLength(1)
param expiresOn string

@sys.description('Ticket or evidence reference backing the exemption.')
@minLength(1)
@maxLength(256)
param ticketReference string

@sys.description('Optional initiative policyDefinitionReferenceIds for targeted exemptions.')
param policyDefinitionReferenceIds string[] = []

@sys.description('Explicit allowlist for policyDefinitionReferenceIds. Required when policyDefinitionReferenceIds are supplied.')
param allowedPolicyDefinitionReferenceIds string[] = []

@sys.description('Metadata source for traceability.')
@minLength(1)
@maxLength(64)
param source string = 'Bicep'

@sys.description('Approver identity recorded for governance traceability.')
@minLength(1)
@maxLength(128)
param approver string

@sys.description('Creation timestamp metadata in canonical RFC3339 UTC format.')
@minLength(1)
param createdOn string

@sys.description('Last review timestamp metadata in canonical RFC3339 UTC format.')
@minLength(1)
param reviewedOn string

@sys.description('v2 governance ownership metadata.')
@minLength(1)
@maxLength(128)
param governanceOwner string = 'eslz-v2-governance'

var validatedExemptionName = isTrimmedNonEmpty(exemptionName)
  ? exemptionName
  : fail('exemptionName must be non-empty and cannot include leading or trailing whitespace.')
var validatedDisplayName = isTrimmedNonEmpty(displayName)
  ? displayName
  : fail('displayName must be non-empty and cannot include leading or trailing whitespace.')
var validatedDescription = isTrimmedNonEmpty(description)
  ? description
  : fail('description must be non-empty and cannot include leading or trailing whitespace.')
var validatedOwner = isTrimmedNonEmpty(owner)
  ? owner
  : fail('owner must be non-empty and cannot include leading or trailing whitespace.')
var validatedJustification = isTrimmedNonEmpty(justification)
  ? justification
  : fail('justification must be non-empty and cannot include leading or trailing whitespace.')
var validatedTicketReference = isTrimmedNonEmpty(ticketReference)
  ? ticketReference
  : fail('ticketReference must be non-empty and cannot include leading or trailing whitespace.')
var validatedSource = isTrimmedNonEmpty(source)
  ? source
  : fail('source must be non-empty and cannot include leading or trailing whitespace.')
var validatedApprover = isTrimmedNonEmpty(approver)
  ? approver
  : fail('approver must be non-empty and cannot include leading or trailing whitespace.')
var validatedGovernanceOwner = isTrimmedNonEmpty(governanceOwner)
  ? governanceOwner
  : fail('governanceOwner must be non-empty and cannot include leading or trailing whitespace.')

var validatedManagementGroupName = isTrimmedNonEmpty(managementGroupName)
  ? managementGroupName
  : ''
var validatedSubscriptionId = subscriptionId == trim(subscriptionId) && isGuid(subscriptionId)
  ? subscriptionId
  : ''
var validatedResourceGroupName = isTrimmedNonEmpty(resourceGroupName)
  ? resourceGroupName
  : ''

var validatedExpiresOn = isCanonicalRfc3339Utc(expiresOn)
  ? expiresOn
  : fail('expiresOn must be a canonical RFC3339 UTC timestamp with a valid calendar date (for example 2026-12-31T23:59:59Z).')
var validatedCreatedOn = isCanonicalRfc3339Utc(createdOn)
  ? createdOn
  : fail('createdOn must be a canonical RFC3339 UTC timestamp with a valid calendar date (for example 2026-01-01T00:00:00Z).')
var validatedReviewedOn = isCanonicalRfc3339Utc(reviewedOn)
  ? reviewedOn
  : fail('reviewedOn must be a canonical RFC3339 UTC timestamp with a valid calendar date (for example 2026-06-30T00:00:00Z).')

var validatedScopeType = exemptionScopeType == 'managementGroup'
  ? !empty(validatedManagementGroupName) && empty(subscriptionId) && empty(resourceGroupName)
    ? exemptionScopeType
    : fail('managementGroup exemptions require managementGroupName and must not include subscriptionId or resourceGroupName.')
  : exemptionScopeType == 'subscription'
    ? !empty(validatedSubscriptionId) && empty(managementGroupName) && empty(resourceGroupName)
      ? exemptionScopeType
      : fail('subscription exemptions require a valid subscriptionId and must not include managementGroupName or resourceGroupName.')
    : !empty(validatedSubscriptionId) && !empty(validatedResourceGroupName) && empty(managementGroupName)
      ? exemptionScopeType
      : fail('resourceGroup exemptions require valid subscriptionId and resourceGroupName and must not include managementGroupName.')

var validatedPolicyAssignmentId = hasValidResourceIdSegments(policyAssignmentId)
  ? policyAssignmentId
  : fail('policyAssignmentId must be an exact Azure Policy assignment resource ID without trailing separators or whitespace.')

var policyAssignmentIdParts = split(validatedPolicyAssignmentId, '/')
var policyAssignmentName = last(policyAssignmentIdParts)
var isManagementGroupAssignmentId = length(policyAssignmentIdParts) == 9 && toLower(policyAssignmentIdParts[1]) == 'providers' && toLower(policyAssignmentIdParts[2]) == 'microsoft.management' && toLower(policyAssignmentIdParts[3]) == 'managementgroups' && toLower(policyAssignmentIdParts[5]) == 'providers' && toLower(policyAssignmentIdParts[6]) == 'microsoft.authorization' && toLower(policyAssignmentIdParts[7]) == 'policyassignments' && isTrimmedNonEmpty(policyAssignmentName)
var isSubscriptionAssignmentId = length(policyAssignmentIdParts) == 7 && toLower(policyAssignmentIdParts[1]) == 'subscriptions' && isGuid(policyAssignmentIdParts[2]) && toLower(policyAssignmentIdParts[3]) == 'providers' && toLower(policyAssignmentIdParts[4]) == 'microsoft.authorization' && toLower(policyAssignmentIdParts[5]) == 'policyassignments' && isTrimmedNonEmpty(policyAssignmentName)
var isResourceGroupAssignmentId = length(policyAssignmentIdParts) == 9 && toLower(policyAssignmentIdParts[1]) == 'subscriptions' && isGuid(policyAssignmentIdParts[2]) && toLower(policyAssignmentIdParts[3]) == 'resourcegroups' && isTrimmedNonEmpty(policyAssignmentIdParts[4]) && toLower(policyAssignmentIdParts[5]) == 'providers' && toLower(policyAssignmentIdParts[6]) == 'microsoft.authorization' && toLower(policyAssignmentIdParts[7]) == 'policyassignments' && isTrimmedNonEmpty(policyAssignmentName)

var validatedScopedPolicyAssignmentId = validatedScopeType == 'managementGroup'
  ? isManagementGroupAssignmentId && toLower(policyAssignmentIdParts[4]) == toLower(validatedManagementGroupName)
    ? validatedPolicyAssignmentId
    : fail('managementGroup exemptions require policyAssignmentId at the same management-group scope.')
  : validatedScopeType == 'subscription'
    ? isSubscriptionAssignmentId && toLower(policyAssignmentIdParts[2]) == toLower(validatedSubscriptionId)
      ? validatedPolicyAssignmentId
      : fail('subscription exemptions require policyAssignmentId at the same subscription scope.')
    : isResourceGroupAssignmentId && toLower(policyAssignmentIdParts[2]) == toLower(validatedSubscriptionId) && toLower(policyAssignmentIdParts[4]) == toLower(validatedResourceGroupName)
      ? validatedPolicyAssignmentId
      : fail('resourceGroup exemptions require policyAssignmentId at the same subscription and resource-group scope.')

var normalizedAllowedPolicyDefinitionReferenceIds = [for policyDefinitionReferenceId in allowedPolicyDefinitionReferenceIds: toLower(trim(policyDefinitionReferenceId))]
var invalidAllowedPolicyDefinitionReferenceIds = filter(normalizedAllowedPolicyDefinitionReferenceIds, policyDefinitionReferenceId => empty(policyDefinitionReferenceId))
var hasDuplicateAllowedPolicyDefinitionReferenceIds = length(normalizedAllowedPolicyDefinitionReferenceIds) != length(union(normalizedAllowedPolicyDefinitionReferenceIds, normalizedAllowedPolicyDefinitionReferenceIds))
var validatedAllowedPolicyDefinitionReferenceIds = empty(invalidAllowedPolicyDefinitionReferenceIds)
  ? !hasDuplicateAllowedPolicyDefinitionReferenceIds
    ? normalizedAllowedPolicyDefinitionReferenceIds
    : fail('allowedPolicyDefinitionReferenceIds must be case-insensitively unique when supplied.')
  : fail('allowedPolicyDefinitionReferenceIds cannot include empty values.')

var trimmedPolicyDefinitionReferenceIds = [for policyDefinitionReferenceId in policyDefinitionReferenceIds: trim(policyDefinitionReferenceId)]
var normalizedPolicyDefinitionReferenceIds = [for policyDefinitionReferenceId in trimmedPolicyDefinitionReferenceIds: toLower(policyDefinitionReferenceId)]
var invalidPolicyDefinitionReferenceIds = filter(normalizedPolicyDefinitionReferenceIds, policyDefinitionReferenceId => empty(policyDefinitionReferenceId))
var hasDuplicatePolicyDefinitionReferenceIds = length(normalizedPolicyDefinitionReferenceIds) != length(union(normalizedPolicyDefinitionReferenceIds, normalizedPolicyDefinitionReferenceIds))
var disallowedPolicyDefinitionReferenceIds = filter(normalizedPolicyDefinitionReferenceIds, policyDefinitionReferenceId => !contains(validatedAllowedPolicyDefinitionReferenceIds, policyDefinitionReferenceId))
var validatedPolicyDefinitionReferenceIds = empty(policyDefinitionReferenceIds)
  ? []
  : empty(validatedAllowedPolicyDefinitionReferenceIds)
    ? fail('allowedPolicyDefinitionReferenceIds must be provided when policyDefinitionReferenceIds are supplied.')
    : !empty(invalidPolicyDefinitionReferenceIds)
      ? fail('policyDefinitionReferenceIds cannot include empty or whitespace-only values.')
      : hasDuplicatePolicyDefinitionReferenceIds
        ? fail('policyDefinitionReferenceIds must be case-insensitively unique when supplied.')
        : !empty(disallowedPolicyDefinitionReferenceIds)
          ? fail('policyDefinitionReferenceIds must be present in allowedPolicyDefinitionReferenceIds.')
          : trimmedPolicyDefinitionReferenceIds

var managementGroupDeploymentName = 'policy-exemption-mg-${uniqueString(deployment().name, validatedExemptionName, validatedManagementGroupName)}'
var subscriptionDeploymentName = 'policy-exemption-sub-${uniqueString(deployment().name, validatedExemptionName, validatedSubscriptionId)}'
var resourceGroupDeploymentName = 'policy-exemption-rg-${uniqueString(deployment().name, validatedExemptionName, format('{0}/{1}', validatedSubscriptionId, validatedResourceGroupName))}'

module managementGroupExemption './policy-exemption-at-management-group.bicep' = if (validatedScopeType == 'managementGroup') {
  name: managementGroupDeploymentName
  scope: managementGroup(validatedManagementGroupName)
  params: {
    exemptionName: validatedExemptionName
    displayName: validatedDisplayName
    description: validatedDescription
    exemptionCategory: exemptionCategory
    policyAssignmentId: validatedScopedPolicyAssignmentId
    expiresOn: validatedExpiresOn
    owner: validatedOwner
    justification: validatedJustification
    ticketReference: validatedTicketReference
    policyDefinitionReferenceIds: validatedPolicyDefinitionReferenceIds
    source: validatedSource
    approver: validatedApprover
    createdOn: validatedCreatedOn
    reviewedOn: validatedReviewedOn
    governanceOwner: validatedGovernanceOwner
  }
}

module subscriptionExemption './policy-exemption-at-subscription.bicep' = if (validatedScopeType == 'subscription') {
  name: subscriptionDeploymentName
  scope: subscription(validatedSubscriptionId)
  params: {
    exemptionName: validatedExemptionName
    displayName: validatedDisplayName
    description: validatedDescription
    exemptionCategory: exemptionCategory
    policyAssignmentId: validatedScopedPolicyAssignmentId
    expiresOn: validatedExpiresOn
    owner: validatedOwner
    justification: validatedJustification
    ticketReference: validatedTicketReference
    policyDefinitionReferenceIds: validatedPolicyDefinitionReferenceIds
    source: validatedSource
    approver: validatedApprover
    createdOn: validatedCreatedOn
    reviewedOn: validatedReviewedOn
    governanceOwner: validatedGovernanceOwner
  }
}

module resourceGroupExemption './policy-exemption-at-resource-group.bicep' = if (validatedScopeType == 'resourceGroup') {
  name: resourceGroupDeploymentName
  scope: resourceGroup(validatedSubscriptionId, validatedResourceGroupName)
  params: {
    exemptionName: validatedExemptionName
    displayName: validatedDisplayName
    description: validatedDescription
    exemptionCategory: exemptionCategory
    policyAssignmentId: validatedScopedPolicyAssignmentId
    expiresOn: validatedExpiresOn
    owner: validatedOwner
    justification: validatedJustification
    ticketReference: validatedTicketReference
    policyDefinitionReferenceIds: validatedPolicyDefinitionReferenceIds
    source: validatedSource
    approver: validatedApprover
    createdOn: validatedCreatedOn
    reviewedOn: validatedReviewedOn
    governanceOwner: validatedGovernanceOwner
  }
}
