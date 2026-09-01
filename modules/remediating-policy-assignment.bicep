targetScope = 'managementGroup'

func stripDigits(value string) string => replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(value, '0', ''), '1', ''), '2', ''), '3', ''), '4', ''), '5', ''), '6', ''), '7', ''), '8', ''), '9', '')
func stripHex(value string) string => replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(toLower(value), '0', ''), '1', ''), '2', ''), '3', ''), '4', ''), '5', ''), '6', ''), '7', ''), '8', ''), '9', ''), 'a', ''), 'b', ''), 'c', ''), 'd', ''), 'e', ''), 'f', '')
func isVersionNumber(value string) bool => !empty(value) && (value == '0' || !startsWith(value, '0')) && empty(stripDigits(value))
func isGuid(value string) bool => length(value) == 36 ? substring(value, 8, 1) == '-' && substring(value, 13, 1) == '-' && substring(value, 18, 1) == '-' && substring(value, 23, 1) == '-' && length(replace(value, '-', '')) == 32 && empty(stripHex(replace(value, '-', ''))) : false
func hasValidResourceIdSegments(value string) bool => startsWith(value, '/') && !endsWith(value, '/') && length(filter(skip(split(value, '/'), 1), segment => empty(segment) || segment != trim(segment))) == 0

@sealed()
type NonComplianceMessage = {
  @minLength(1)
  @maxLength(500)
  message: string
  policyDefinitionReferenceId: string?
}

@sealed()
type Selector = {
  kind: 'resourceLocation' | 'resourceType' | 'resourceWithoutLocation'
  in: string[]?
  notIn: string[]?
}

@sealed()
type ResourceSelector = {
  @minLength(1)
  @maxLength(64)
  name: string
  @minLength(1)
  @maxLength(10)
  selectors: Selector[]
}

@sys.description('Policy assignment resource name.')
@minLength(1)
@maxLength(24)
param assignmentName string

@sys.description('Policy assignment display name.')
@minLength(1)
@maxLength(128)
param displayName string

@sys.description('Policy assignment description.')
@minLength(1)
@maxLength(512)
param description string

@sys.description('Full resource ID of a policy definition or policy set definition.')
@minLength(1)
param policyDefinitionId string

@sys.description('Non-global Azure region used to store the policy assignment and its managed identity.')
@minLength(1)
param location string

@sys.description('Managed identity type for remediation. UserAssigned requires both user-assigned identity values.')
param identityType 'SystemAssigned' | 'UserAssigned'

@sys.description('Full resource ID of the supplied user-assigned managed identity. Must be empty for SystemAssigned.')
param userAssignedIdentityResourceId string = ''

@sys.description('Principal ID of the supplied user-assigned managed identity. Must be empty for SystemAssigned.')
param userAssignedIdentityPrincipalId string = ''

@sys.description('Verified built-in role definition IDs required by the assigned policy or initiative.')
@minLength(1)
param verifiedRoleDefinitionIds string[]

@sys.description('Optional policy or initiative definition version. An empty value leaves the definition unpinned.')
param definitionVersion string = ''

@sys.description('Policy assignment enforcement mode. Defaults to a safe non-enforcing posture.')
param enforcementMode 'Default' | 'DoNotEnforce' = 'DoNotEnforce'

@sys.description('Values for parameters declared by the policy or initiative definition.')
param parameters object = {}

@sys.description('Open-ended policy assignment metadata.')
param metadata object = {
  category: 'Demo Landing Zone'
  source: 'Bicep'
}

@sys.description('Messages shown for non-compliant resources. Initiative messages can target a policy definition reference ID.')
param nonComplianceMessages NonComplianceMessage[] = []

@sys.description('Resource IDs excluded from the assignment scope.')
param notScopes string[] = []

@sys.description('Selectors that restrict policy evaluation by resource property.')
@maxLength(10)
param resourceSelectors ResourceSelector[] = []

var policyDefinitionIdParts = split(policyDefinitionId, '/')
var isBuiltInDefinitionId = length(policyDefinitionIdParts) == 5 ? toLower(policyDefinitionIdParts[1]) == 'providers' && toLower(policyDefinitionIdParts[2]) == 'microsoft.authorization' && (toLower(policyDefinitionIdParts[3]) == 'policydefinitions' || toLower(policyDefinitionIdParts[3]) == 'policysetdefinitions') && hasValidResourceIdSegments(policyDefinitionId) : false
var isManagementGroupDefinitionId = length(policyDefinitionIdParts) == 9 ? toLower(policyDefinitionIdParts[1]) == 'providers' && toLower(policyDefinitionIdParts[2]) == 'microsoft.management' && toLower(policyDefinitionIdParts[3]) == 'managementgroups' && toLower(policyDefinitionIdParts[5]) == 'providers' && toLower(policyDefinitionIdParts[6]) == 'microsoft.authorization' && (toLower(policyDefinitionIdParts[7]) == 'policydefinitions' || toLower(policyDefinitionIdParts[7]) == 'policysetdefinitions') && hasValidResourceIdSegments(policyDefinitionId) : false
var isSupportedPolicyDefinitionId = policyDefinitionId == trim(policyDefinitionId) && (isBuiltInDefinitionId || isManagementGroupDefinitionId)
var validatedPolicyDefinitionId = isSupportedPolicyDefinitionId
  ? policyDefinitionId
  : fail('policyDefinitionId must be an exact built-in or management-group policy definition or policy set definition resource ID.')

var rawDefinitionVersionParts = split(definitionVersion, '.')
var definitionVersionParts = concat(rawDefinitionVersionParts, [
  ''
  ''
  ''
])
var hasValidDefinitionVersionFormat = length(rawDefinitionVersionParts) == 3 && isVersionNumber(definitionVersionParts[0]) && definitionVersionParts[2] == '*' && (definitionVersionParts[1] == '*' || isVersionNumber(definitionVersionParts[1]))
var validatedDefinitionVersion = empty(definitionVersion) || (isBuiltInDefinitionId && hasValidDefinitionVersionFormat)
  ? definitionVersion
  : fail('definitionVersion is supported only for built-in definitions and must use N.*.* or N.N.* format.')

var validatedLocation = !empty(trim(location)) && toLower(trim(location)) != 'global'
  ? trim(location)
  : fail('location must be a non-global Azure region.')

var userAssignedIdentityParts = split(userAssignedIdentityResourceId, '/')
var validUserAssignedIdentityResourceId = length(userAssignedIdentityParts) == 9 ? toLower(userAssignedIdentityParts[1]) == 'subscriptions' && isGuid(userAssignedIdentityParts[2]) && toLower(userAssignedIdentityParts[3]) == 'resourcegroups' && toLower(userAssignedIdentityParts[5]) == 'providers' && toLower(userAssignedIdentityParts[6]) == 'microsoft.managedidentity' && toLower(userAssignedIdentityParts[7]) == 'userassignedidentities' && hasValidResourceIdSegments(userAssignedIdentityResourceId) : false
var hasValidSystemAssignedConfiguration = identityType == 'SystemAssigned' && empty(userAssignedIdentityResourceId) && empty(userAssignedIdentityPrincipalId)
var hasValidUserAssignedConfiguration = identityType == 'UserAssigned' && validUserAssignedIdentityResourceId && isGuid(userAssignedIdentityPrincipalId)
var validatedUserAssignedIdentityResourceId = hasValidSystemAssignedConfiguration || hasValidUserAssignedConfiguration
  ? userAssignedIdentityResourceId
  : fail('Identity configuration must be SystemAssigned with no user-assigned values, or UserAssigned with a valid identity resource ID and principal ID.')
var validatedIdentityPrincipalId = identityType == 'UserAssigned'
  ? userAssignedIdentityPrincipalId
  : assignment.identity.principalId

var ownerRoleDefinitionId = '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
var userAccessAdministratorRoleDefinitionId = '18d7d88d-5c7c-48f3-befd-73a015c7e944'
var normalizedRoleDefinitionIds = map(verifiedRoleDefinitionIds, roleDefinitionId => toLower(roleDefinitionId))
var invalidRoleDefinitionIds = filter(normalizedRoleDefinitionIds, roleDefinitionId => !isGuid(roleDefinitionId) || roleDefinitionId == ownerRoleDefinitionId || roleDefinitionId == userAccessAdministratorRoleDefinitionId)
var hasDuplicateRoleDefinitionIds = length(normalizedRoleDefinitionIds) != length(union(normalizedRoleDefinitionIds, normalizedRoleDefinitionIds))
var validatedRoleDefinitionIds = !empty(invalidRoleDefinitionIds)
  ? fail('verifiedRoleDefinitionIds must contain valid built-in role definition IDs and must not contain Owner or User Access Administrator.')
  : hasDuplicateRoleDefinitionIds
    ? fail('verifiedRoleDefinitionIds must not contain duplicates.')
    : normalizedRoleDefinitionIds
var roleAssignmentPrincipalSeed = identityType == 'UserAssigned' ? userAssignedIdentityPrincipalId : assignment.id

resource assignment 'Microsoft.Authorization/policyAssignments@2025-03-01' = {
  name: assignmentName
  location: validatedLocation
  identity: {
    type: identityType
    ...((identityType == 'UserAssigned') ? {
      userAssignedIdentities: {
        '${validatedUserAssignedIdentityResourceId}': {}
      }
    } : {})
  }
  properties: {
    displayName: displayName
    description: description
    policyDefinitionId: validatedPolicyDefinitionId
    enforcementMode: enforcementMode
    ...(!empty(definitionVersion) ? {
      definitionVersion: validatedDefinitionVersion
    } : {})
    ...(!empty(parameters) ? {
      parameters: parameters
    } : {})
    ...(!empty(metadata) ? {
      metadata: metadata
    } : {})
    ...(!empty(nonComplianceMessages) ? {
      nonComplianceMessages: nonComplianceMessages
    } : {})
    ...(!empty(notScopes) ? {
      notScopes: notScopes
    } : {})
    ...(!empty(resourceSelectors) ? {
      resourceSelectors: resourceSelectors
    } : {})
  }
}

resource remediationRoleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for roleDefinitionId in validatedRoleDefinitionIds: {
  name: guid(managementGroup().id, roleAssignmentPrincipalSeed, roleDefinitionId)
  properties: {
    principalId: validatedIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: tenantResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
  }
}]

output policyAssignmentId string = assignment.id
output identityPrincipalId string = validatedIdentityPrincipalId
output identityResourceId string = identityType == 'UserAssigned' ? validatedUserAssignedIdentityResourceId : assignment.id
output roleAssignmentIds string[] = [for index in range(0, length(validatedRoleDefinitionIds)): remediationRoleAssignments[index].id]
