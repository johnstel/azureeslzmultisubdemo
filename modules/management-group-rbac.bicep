targetScope = 'managementGroup'

param governanceAdminsGroupObjectId string
param readOnlyAuditorsGroupObjectId string

var managementGroupContributorRoleDefinitionId = '5d58bcaf-24a5-4b20-bdb6-eed9f69fbe4c'
var resourcePolicyContributorRoleDefinitionId = '36243c78-bf99-498c-9df9-86d9f8d28608'
var readerRoleDefinitionId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'

resource governanceManagementGroupContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(managementGroup().id, governanceAdminsGroupObjectId, managementGroupContributorRoleDefinitionId)
  properties: {
    principalId: governanceAdminsGroupObjectId
    principalType: 'Group'
    roleDefinitionId: tenantResourceId('Microsoft.Authorization/roleDefinitions', managementGroupContributorRoleDefinitionId)
  }
}

resource governancePolicyContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(managementGroup().id, governanceAdminsGroupObjectId, resourcePolicyContributorRoleDefinitionId)
  properties: {
    principalId: governanceAdminsGroupObjectId
    principalType: 'Group'
    roleDefinitionId: tenantResourceId('Microsoft.Authorization/roleDefinitions', resourcePolicyContributorRoleDefinitionId)
  }
}

resource auditorsReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(managementGroup().id, readOnlyAuditorsGroupObjectId, readerRoleDefinitionId)
  properties: {
    principalId: readOnlyAuditorsGroupObjectId
    principalType: 'Group'
    roleDefinitionId: tenantResourceId('Microsoft.Authorization/roleDefinitions', readerRoleDefinitionId)
  }
}

