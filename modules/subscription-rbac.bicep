targetScope = 'subscription'

@description('Set true only after the Owner activation policy and emergency-access prerequisites have been reviewed for this subscription.')
param deployEligibleOwnerRoleAssignment bool = false

@description('Object ID of an existing Microsoft Entra security group that will receive time-bound eligible Owner access.')
param subscriptionPrivilegedAccessGroupObjectId string = ''

@description('UTC start date and time for the eligible Owner assignment, in RFC 3339 format.')
param eligibleOwnerAssignmentStartDateTime string = ''

@description('Finite ISO 8601 duration for the eligible Owner assignment.')
@allowed([
  'P30D'
  'P90D'
  'P180D'
  'P365D'
])
param eligibleOwnerAssignmentDuration string = 'P90D'

@description('Auditable business justification for creating the eligible Owner assignment.')
param eligibleOwnerAssignmentJustification string = ''

@description('Set true to create the permanent, lower-privilege operator role assignment.')
param deployOperatorRoleAssignment bool = false

param operatorGroupObjectId string
param operatorRoleDefinitionId string

var ownerRoleDefinitionId = '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
var eligibleOwnerInputsAreValid = !deployEligibleOwnerRoleAssignment || (!empty(subscriptionPrivilegedAccessGroupObjectId) && !empty(eligibleOwnerAssignmentStartDateTime) && !empty(trim(eligibleOwnerAssignmentJustification)))
var validatedPrivilegedAccessGroupObjectId = eligibleOwnerInputsAreValid
  ? subscriptionPrivilegedAccessGroupObjectId
  : fail('Eligible Owner assignment requires an existing group object ID, a UTC start date/time, and a business justification.')

resource eligibleSubscriptionOwners 'Microsoft.Authorization/roleEligibilityScheduleRequests@2020-10-01' = if (deployEligibleOwnerRoleAssignment) {
  name: guid(subscription().id, validatedPrivilegedAccessGroupObjectId, ownerRoleDefinitionId, 'eligible-owner')
  properties: {
    // principalType is response-only for this API; ARM resolves Group from the supplied existing object ID.
    principalId: validatedPrivilegedAccessGroupObjectId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', ownerRoleDefinitionId)
    requestType: 'AdminAssign'
    justification: eligibleOwnerAssignmentJustification
    scheduleInfo: {
      startDateTime: eligibleOwnerAssignmentStartDateTime
      expiration: {
        type: 'AfterDuration'
        duration: eligibleOwnerAssignmentDuration
      }
    }
  }
}

resource subscriptionOperators 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployOperatorRoleAssignment) {
  name: guid(subscription().id, operatorGroupObjectId, operatorRoleDefinitionId)
  properties: {
    principalId: operatorGroupObjectId
    principalType: 'Group'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', operatorRoleDefinitionId)
  }
}
