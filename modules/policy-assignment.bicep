targetScope = 'managementGroup'

func stripDigits(value string) string => replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(value, '0', ''), '1', ''), '2', ''), '3', ''), '4', ''), '5', ''), '6', ''), '7', ''), '8', ''), '9', '')
func stripHex(value string) string => replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(toLower(value), '0', ''), '1', ''), '2', ''), '3', ''), '4', ''), '5', ''), '6', ''), '7', ''), '8', ''), '9', ''), 'a', ''), 'b', ''), 'c', ''), 'd', ''), 'e', ''), 'f', '')
func isVersionNumber(value string) bool => !empty(value) && (value == '0' || !startsWith(value, '0')) && empty(stripDigits(value))
func isGuid(value string) bool => length(value) == 36 ? substring(value, 8, 1) == '-' && substring(value, 13, 1) == '-' && substring(value, 18, 1) == '-' && substring(value, 23, 1) == '-' && length(replace(value, '-', '')) == 32 && empty(stripHex(replace(value, '-', ''))) : false
func hasValidResourceIdSegments(value string) bool => startsWith(value, '/') && !endsWith(value, '/') && length(filter(skip(split(value, '/'), 1), segment => empty(segment) || segment != trim(segment))) == 0
func isManagementGroupScopeId(value string) bool => length(split(value, '/')) == 5 ? toLower(split(value, '/')[1]) == 'providers' && toLower(split(value, '/')[2]) == 'microsoft.management' && toLower(split(value, '/')[3]) == 'managementgroups' && hasValidResourceIdSegments(value) : false
func isSubscriptionDescendantId(value string) bool => length(split(value, '/')) >= 3 ? toLower(split(value, '/')[1]) == 'subscriptions' && isGuid(split(value, '/')[2]) && hasValidResourceIdSegments(value) && (length(split(value, '/')) == 3 ? true : length(split(value, '/')) == 5 ? toLower(split(value, '/')[3]) == 'resourcegroups' : length(split(value, '/')) >= 7 && length(split(value, '/')) % 2 == 1 ? toLower(split(value, '/')[3]) == 'providers' || (length(split(value, '/')) >= 9 ? toLower(split(value, '/')[3]) == 'resourcegroups' && toLower(split(value, '/')[5]) == 'providers' : false) : false) : false

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

var controlCharacterEncodings = [
  '%00'
  '%01'
  '%02'
  '%03'
  '%04'
  '%05'
  '%06'
  '%07'
  '%08'
  '%09'
  '%0a'
  '%0b'
  '%0c'
  '%0d'
  '%0e'
  '%0f'
  '%10'
  '%11'
  '%12'
  '%13'
  '%14'
  '%15'
  '%16'
  '%17'
  '%18'
  '%19'
  '%1a'
  '%1b'
  '%1c'
  '%1d'
  '%1e'
  '%1f'
  '%7f'
  '%c2%80'
  '%c2%81'
  '%c2%82'
  '%c2%83'
  '%c2%84'
  '%c2%85'
  '%c2%86'
  '%c2%87'
  '%c2%88'
  '%c2%89'
  '%c2%8a'
  '%c2%8b'
  '%c2%8c'
  '%c2%8d'
  '%c2%8e'
  '%c2%8f'
  '%c2%90'
  '%c2%91'
  '%c2%92'
  '%c2%93'
  '%c2%94'
  '%c2%95'
  '%c2%96'
  '%c2%97'
  '%c2%98'
  '%c2%99'
  '%c2%9a'
  '%c2%9b'
  '%c2%9c'
  '%c2%9d'
  '%c2%9e'
  '%c2%9f'
]
var assignmentNameContainsInvalidCharacter = contains(assignmentName, '#') || contains(assignmentName, '<') || contains(assignmentName, '>') || contains(assignmentName, '%') || contains(assignmentName, '&') || contains(assignmentName, ':') || contains(assignmentName, '\\') || contains(assignmentName, '?') || contains(assignmentName, '/')
var assignmentNameContainsControlCharacter = !empty(filter(controlCharacterEncodings, encoding => contains(toLower(uriComponent(assignmentName)), encoding)))
var validatedAssignmentName = !assignmentNameContainsInvalidCharacter && !assignmentNameContainsControlCharacter && !endsWith(assignmentName, '.') && !endsWith(assignmentName, ' ')
  ? assignmentName
  : fail('assignmentName contains a character that is invalid for an Azure Policy assignment or ends with a period or space.')

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

var invalidNonComplianceMessageReferences = filter(nonComplianceMessages, message => contains(message, 'policyDefinitionReferenceId') && empty(trim(message.?policyDefinitionReferenceId ?? '')))
var validatedNonComplianceMessages = empty(invalidNonComplianceMessageReferences)
  ? nonComplianceMessages
  : fail('policyDefinitionReferenceId must be non-empty when supplied in a non-compliance message.')

var invalidNotScopes = filter(notScopes, notScope => toLower(notScope) == toLower(managementGroup().id) || !(isManagementGroupScopeId(notScope) || isSubscriptionDescendantId(notScope)))
var validatedNotScopes = empty(invalidNotScopes)
  ? notScopes
  : fail('notScopes must contain only valid descendant management-group, subscription, resource-group, or resource IDs.')

var resourceSelectorNames = [for resourceSelector in resourceSelectors: resourceSelector.name]
var hasDuplicateResourceSelectorNames = length(resourceSelectorNames) != length(union(resourceSelectorNames, resourceSelectorNames))
var resourceSelectorsWithDuplicateKinds = filter(resourceSelectors, resourceSelector => length(map(resourceSelector.selectors, selector => selector.kind)) != length(union(map(resourceSelector.selectors, selector => selector.kind), map(resourceSelector.selectors, selector => selector.kind))))
var resourceSelectorsWithLocationConflict = filter(resourceSelectors, resourceSelector => contains(map(resourceSelector.selectors, selector => selector.kind), 'resourceLocation') && contains(map(resourceSelector.selectors, selector => selector.kind), 'resourceWithoutLocation'))
var invalidResourceWithoutLocationSelectors = flatten(map(resourceSelectors, resourceSelector => filter(resourceSelector.selectors, selector => selector.kind == 'resourceWithoutLocation' && (length(concat(selector.?in ?? [], selector.?notIn ?? [])) != 1 || !contains(concat(selector.?in ?? [], selector.?notIn ?? []), 'subscriptionLevelResources')))))
var invalidSelectorExpressions = flatten(map(resourceSelectors, resourceSelector => filter(resourceSelector.selectors, selector => contains(selector, 'in') == contains(selector, 'notIn') || (contains(selector, 'in') && (empty(selector.?in) || length(selector.?in ?? []) > 50)) || (contains(selector, 'notIn') && (empty(selector.?notIn) || length(selector.?notIn ?? []) > 50)))))
var validatedResourceSelectors = hasDuplicateResourceSelectorNames
  ? fail('resourceSelectors must use unique names.')
  : !empty(resourceSelectorsWithDuplicateKinds)
    ? fail('Each selector kind can be used only once within a resource selector.')
    : !empty(resourceSelectorsWithLocationConflict)
      ? fail('resourceLocation and resourceWithoutLocation cannot be used in the same resource selector.')
      : !empty(invalidResourceWithoutLocationSelectors)
        ? fail('resourceWithoutLocation must use the single supported value subscriptionLevelResources.')
        : !empty(invalidSelectorExpressions)
          ? fail('Each resource selector expression must provide one non-empty in or notIn array containing no more than 50 values.')
          : resourceSelectors

resource assignment 'Microsoft.Authorization/policyAssignments@2025-03-01' = {
  name: validatedAssignmentName
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
      nonComplianceMessages: validatedNonComplianceMessages
    } : {})
    ...(!empty(notScopes) ? {
      notScopes: validatedNotScopes
    } : {})
    ...(!empty(resourceSelectors) ? {
      resourceSelectors: validatedResourceSelectors
    } : {})
  }
}

output policyAssignmentId string = assignment.id
