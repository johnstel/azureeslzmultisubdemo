targetScope = 'subscription'

@description('Explicit safety gate. Set true only for one reviewed request after checking current Owner eligibility at this subscription.')
param submitEligibilityRequest bool = false

@description('New caller-generated GUID for this one request. Never reuse it for a redeployment, retry, update, removal, or another subscription.')
@minLength(36)
@maxLength(36)
param requestId string

@description('PIM lifecycle operation. AdminAssign creates eligibility; AdminUpdate changes an existing schedule; AdminRemove removes it.')
@allowed([
  'AdminAssign'
  'AdminUpdate'
  'AdminRemove'
])
param requestType string

@description('Object ID of the existing Microsoft Entra security group that owns the eligible assignment.')
@minLength(1)
param subscriptionPrivilegedAccessGroupObjectId string

@description('Existing role eligibility schedule ID. Leave empty for AdminAssign; required for AdminUpdate and AdminRemove.')
param targetRoleEligibilityScheduleId string = ''

@description('UTC start date and time in RFC 3339 format. Used by AdminAssign and AdminUpdate.')
param eligibleOwnerAssignmentStartDateTime string = ''

@description('Finite ISO 8601 eligibility duration. Used by AdminAssign and AdminUpdate.')
@allowed([
  'P30D'
  'P90D'
  'P180D'
  'P365D'
])
param eligibleOwnerAssignmentDuration string = 'P90D'

@description('Auditable business justification for this eligibility lifecycle request.')
@minLength(1)
param eligibleOwnerAssignmentJustification string

@description('Non-security marker supplied by the supported operator workflow after live read-only verification. The marker does not prove principal type; direct raw Bicep use is unsupported.')
@secure()
param operatorWorkflowVerificationToken string

var ownerRoleDefinitionId = '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
var requestIdResidualCharacters = replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(toLower(requestId), '-', ''), '0', ''), '1', ''), '2', ''), '3', ''), '4', ''), '5', ''), '6', ''), '7', ''), '8', ''), '9', ''), 'a', ''), 'b', ''), 'c', ''), 'd', ''), 'e', ''), 'f', '')
var requestIdInputIsValid = length(requestId) == 36 && requestId == '${take(requestId, 8)}-${take(skip(requestId, 9), 4)}-${take(skip(requestId, 14), 4)}-${take(skip(requestId, 19), 4)}-${take(skip(requestId, 24), 12)}' && empty(requestIdResidualCharacters)
var principalResidualCharacters = replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(toLower(subscriptionPrivilegedAccessGroupObjectId), '-', ''), '0', ''), '1', ''), '2', ''), '3', ''), '4', ''), '5', ''), '6', ''), '7', ''), '8', ''), '9', ''), 'a', ''), 'b', ''), 'c', ''), 'd', ''), 'e', ''), 'f', '')
var principalInputIsValid = length(subscriptionPrivilegedAccessGroupObjectId) == 36 && subscriptionPrivilegedAccessGroupObjectId == '${take(subscriptionPrivilegedAccessGroupObjectId, 8)}-${take(skip(subscriptionPrivilegedAccessGroupObjectId, 9), 4)}-${take(skip(subscriptionPrivilegedAccessGroupObjectId, 14), 4)}-${take(skip(subscriptionPrivilegedAccessGroupObjectId, 19), 4)}-${take(skip(subscriptionPrivilegedAccessGroupObjectId, 24), 12)}' && empty(principalResidualCharacters)
var targetScheduleResidualCharacters = replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(toLower(targetRoleEligibilityScheduleId), '-', ''), '0', ''), '1', ''), '2', ''), '3', ''), '4', ''), '5', ''), '6', ''), '7', ''), '8', ''), '9', ''), 'a', ''), 'b', ''), 'c', ''), 'd', ''), 'e', ''), 'f', '')
var targetScheduleGuidIsCanonical = length(targetRoleEligibilityScheduleId) == 36 && targetRoleEligibilityScheduleId == '${take(targetRoleEligibilityScheduleId, 8)}-${take(skip(targetRoleEligibilityScheduleId, 9), 4)}-${take(skip(targetRoleEligibilityScheduleId, 14), 4)}-${take(skip(targetRoleEligibilityScheduleId, 19), 4)}-${take(skip(targetRoleEligibilityScheduleId, 24), 12)}' && empty(targetScheduleResidualCharacters)
var targetScheduleInputIsValid = requestType == 'AdminAssign'
  ? empty(targetRoleEligibilityScheduleId)
  : targetScheduleGuidIsCanonical
var startTimeBase = take(eligibleOwnerAssignmentStartDateTime, 19)
var startTimeSuffix = skip(eligibleOwnerAssignmentStartDateTime, 19)
var startTimeBaseResidualCharacters = replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(startTimeBase, '-', ''), 'T', ''), ':', ''), '0', ''), '1', ''), '2', ''), '3', ''), '4', ''), '5', ''), '6', ''), '7', ''), '8', ''), '9', '')
var startTimeSuffixResidualCharacters = replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(startTimeSuffix, '.', ''), 'Z', ''), '0', ''), '1', ''), '2', ''), '3', ''), '4', ''), '5', ''), '6', ''), '7', ''), '8', ''), '9', '')
var startTimeInputIsRfc3339Utc = length(eligibleOwnerAssignmentStartDateTime) >= 20 && startTimeBase == '${take(eligibleOwnerAssignmentStartDateTime, 4)}-${take(skip(eligibleOwnerAssignmentStartDateTime, 5), 2)}-${take(skip(eligibleOwnerAssignmentStartDateTime, 8), 2)}T${take(skip(eligibleOwnerAssignmentStartDateTime, 11), 2)}:${take(skip(eligibleOwnerAssignmentStartDateTime, 14), 2)}:${take(skip(eligibleOwnerAssignmentStartDateTime, 17), 2)}' && empty(startTimeBaseResidualCharacters) && (startTimeSuffix == 'Z' || (startsWith(startTimeSuffix, '.') && endsWith(startTimeSuffix, 'Z') && length(replace(replace(startTimeSuffix, '.', ''), 'Z', '')) > 0 && empty(startTimeSuffixResidualCharacters)))
var scheduleInputIsValid = requestType == 'AdminRemove'
  ? empty(eligibleOwnerAssignmentStartDateTime)
  : startTimeInputIsRfc3339Utc
var expectedOperatorWorkflowVerificationToken = 'verified:${requestId}:${subscriptionPrivilegedAccessGroupObjectId}:${requestType}:${subscription().subscriptionId}'
var workflowMarkerIsValid = operatorWorkflowVerificationToken == expectedOperatorWorkflowVerificationToken
var executionInputsAreValid = !submitEligibilityRequest || (requestIdInputIsValid && principalInputIsValid && targetScheduleInputIsValid && scheduleInputIsValid && !empty(trim(eligibleOwnerAssignmentJustification)) && workflowMarkerIsValid)
var validatedPrincipalId = executionInputsAreValid
  ? subscriptionPrivilegedAccessGroupObjectId
  : fail('Owner eligibility request inputs are invalid or were not supplied through the verified operator workflow.')
var baseRequestProperties = {
  principalId: validatedPrincipalId
  roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', ownerRoleDefinitionId)
  requestType: requestType
  justification: eligibleOwnerAssignmentJustification
}
var scheduleProperties = requestType == 'AdminRemove'
  ? {}
  : {
      scheduleInfo: {
        startDateTime: eligibleOwnerAssignmentStartDateTime
        expiration: {
          type: 'AfterDuration'
          duration: eligibleOwnerAssignmentDuration
        }
      }
    }
var targetScheduleProperties = requestType == 'AdminAssign'
  ? {}
  : {
      targetRoleEligibilityScheduleId: targetRoleEligibilityScheduleId
    }

resource ownerEligibilityRequest 'Microsoft.Authorization/roleEligibilityScheduleRequests@2020-10-01' = if (submitEligibilityRequest) {
  name: requestId
  properties: union(baseRequestProperties, scheduleProperties, targetScheduleProperties)
}
