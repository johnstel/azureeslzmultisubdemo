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

var ownerRoleDefinitionId = '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
var targetScheduleInputIsValid = requestType == 'AdminAssign'
  ? empty(targetRoleEligibilityScheduleId)
  : !empty(targetRoleEligibilityScheduleId)
var scheduleInputIsValid = requestType == 'AdminRemove' || !empty(trim(eligibleOwnerAssignmentStartDateTime))
var executionInputsAreValid = !submitEligibilityRequest || (targetScheduleInputIsValid && scheduleInputIsValid && !empty(trim(eligibleOwnerAssignmentJustification)))
var validatedPrincipalId = executionInputsAreValid
  ? subscriptionPrivilegedAccessGroupObjectId
  : fail('AdminAssign requires no target schedule ID; AdminUpdate/AdminRemove require one. AdminAssign/AdminUpdate also require a UTC start, and every operation requires justification.')
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
