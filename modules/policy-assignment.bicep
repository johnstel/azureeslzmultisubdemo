targetScope = 'managementGroup'

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
@maxLength(64)
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

var normalizedPolicyDefinitionId = toLower(trim(policyDefinitionId))
var isPolicyDefinitionId = contains(normalizedPolicyDefinitionId, '/providers/microsoft.authorization/policydefinitions/')
var isPolicySetDefinitionId = contains(normalizedPolicyDefinitionId, '/providers/microsoft.authorization/policysetdefinitions/')
var isSupportedPolicyDefinitionId = policyDefinitionId == trim(policyDefinitionId) && (isPolicyDefinitionId || isPolicySetDefinitionId)
var validatedPolicyDefinitionId = isSupportedPolicyDefinitionId
  ? policyDefinitionId
  : fail('policyDefinitionId must be the full resource ID of a policy definition or policy set definition.')

var validatedDefinitionVersion = empty(definitionVersion) || definitionVersion == trim(definitionVersion)
  ? definitionVersion
  : fail('definitionVersion must not contain leading or trailing whitespace.')

var invalidNonComplianceMessageReferences = filter(nonComplianceMessages, message => contains(message, 'policyDefinitionReferenceId') && empty(trim(message.?policyDefinitionReferenceId ?? '')))
var validatedNonComplianceMessages = empty(invalidNonComplianceMessageReferences)
  ? nonComplianceMessages
  : fail('policyDefinitionReferenceId must be non-empty when supplied in a non-compliance message.')

var invalidNotScopes = filter(notScopes, notScope => empty(trim(notScope)))
var validatedNotScopes = empty(invalidNotScopes)
  ? notScopes
  : fail('notScopes must contain only non-empty resource IDs.')

var resourceSelectorNames = [for resourceSelector in resourceSelectors: resourceSelector.name]
var hasDuplicateResourceSelectorNames = length(resourceSelectorNames) != length(union(resourceSelectorNames, resourceSelectorNames))
var resourceSelectorsWithDuplicateKinds = filter(resourceSelectors, resourceSelector => length(map(resourceSelector.selectors, selector => selector.kind)) != length(union(map(resourceSelector.selectors, selector => selector.kind), map(resourceSelector.selectors, selector => selector.kind))))
var resourceSelectorsWithLocationConflict = filter(resourceSelectors, resourceSelector => contains(map(resourceSelector.selectors, selector => selector.kind), 'resourceLocation') && contains(map(resourceSelector.selectors, selector => selector.kind), 'resourceWithoutLocation'))
var invalidSelectorExpressions = flatten(map(resourceSelectors, resourceSelector => filter(resourceSelector.selectors, selector => contains(selector, 'in') == contains(selector, 'notIn') || (contains(selector, 'in') && (empty(selector.?in) || length(selector.?in ?? []) > 50)) || (contains(selector, 'notIn') && (empty(selector.?notIn) || length(selector.?notIn ?? []) > 50)))))
var validatedResourceSelectors = hasDuplicateResourceSelectorNames
  ? fail('resourceSelectors must use unique names.')
  : !empty(resourceSelectorsWithDuplicateKinds)
    ? fail('Each selector kind can be used only once within a resource selector.')
    : !empty(resourceSelectorsWithLocationConflict)
      ? fail('resourceLocation and resourceWithoutLocation cannot be used in the same resource selector.')
  : !empty(invalidSelectorExpressions)
    ? fail('Each resource selector expression must provide one non-empty in or notIn array containing no more than 50 values.')
    : resourceSelectors

resource assignment 'Microsoft.Authorization/policyAssignments@2025-03-01' = {
  name: assignmentName
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
