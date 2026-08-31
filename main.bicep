targetScope = 'tenant'

@description('Azure region used only to store tenant deployment metadata.')
param deploymentLocation string = 'eastus'

@description('Existing tenant-root management group ID. The demo root is created below it.')
@minLength(1)
param tenantRootManagementGroupId string

@description('Unique lowercase prefix used for every demo management group.')
@minLength(3)
@maxLength(24)
param namePrefix string

@description('Display name for the dedicated demo root management group.')
@minLength(3)
param demoRootDisplayName string = 'Enterprise-Scale Demo'

@description('Select the workload landing-zone archetype.')
@allowed([
  'corp'
  'online'
])
param workloadArchetype string = 'corp'

@description('Existing sandbox subscription placed under Platform/Connectivity.')
param connectivitySubscriptionId string

@description('Existing sandbox subscription placed under Landing Zones/Corp or Online.')
param workloadSubscriptionId string

@description('Object ID of an existing Entra security group for governance administrators.')
param governanceAdminsGroupObjectId string

@description('Object ID of an existing Entra security group for subscription owners.')
param subscriptionOwnersGroupObjectId string

@description('Object ID of an existing Entra security group for network operators.')
param networkOperatorsGroupObjectId string

@description('Object ID of an existing Entra security group for workload contributors.')
param workloadContributorsGroupObjectId string

@description('Object ID of an existing Entra security group for read-only auditors.')
param readOnlyAuditorsGroupObjectId string

@description('Enforcement mode for deny policy assignments. Keep DoNotEnforce for first deployment.')
@allowed([
  'Default'
  'DoNotEnforce'
])
param denyPolicyEnforcementMode string = 'DoNotEnforce'

@description('Continental-US Azure regions allowed by the demo policy.')
param allowedLocations array = [
  'centralus'
  'eastus'
  'eastus2'
  'northcentralus'
  'southcentralus'
  'westcentralus'
  'westus'
  'westus2'
  'westus3'
]

@description('Set true only after reviewing the RBAC matrix and what-if.')
param deployRoleAssignments bool = false

@description('Set true to create no-hourly-charge evidence resource groups, a VNet, and an NSG.')
param deployEvidenceResources bool = false

@description('Region for optional VNet/NSG evidence resources.')
@allowed([
  'centralus'
  'eastus'
  'eastus2'
  'northcentralus'
  'southcentralus'
  'westcentralus'
  'westus'
  'westus2'
  'westus3'
])
param evidenceLocation string = 'eastus2'

@description('Set true to create a new central Log Analytics workspace in the connectivity subscription. Leave false (default); supply an existing workspace via existingLogAnalyticsWorkspaceResourceId instead. Creating a workspace introduces ongoing data-ingestion and retention charges.')
param deployCentralLogAnalytics bool = false

@description('Set true to enable Microsoft Sentinel on the effective central monitoring workspace. Sentinel adds per-GB analysis charges on top of Log Analytics ingestion cost.')
param deploySentinel bool = false

@description('Resource ID of an existing customer-owned Log Analytics workspace to reuse as the effective monitoring workspace. This is the default integration path and must not be set at the same time as deployCentralLogAnalytics=true.')
param existingLogAnalyticsWorkspaceResourceId string = ''

@description('Region for a newly created central Log Analytics workspace, restricted to the same continental-US allowlist as evidenceLocation to stay within this demo policy and cost scope. Ignored when reusing an existing workspace.')
@allowed([
  'centralus'
  'eastus'
  'eastus2'
  'northcentralus'
  'southcentralus'
  'westcentralus'
  'westus'
  'westus2'
  'westus3'
])
param centralMonitoringLocation string = 'eastus2'

@description('Data retention in days for a newly created central Log Analytics workspace. Longer retention increases storage cost.')
@minValue(30)
@maxValue(730)
param centralLogAnalyticsRetentionInDays int = 30

@description('Daily ingestion cap in GB for a newly created central Log Analytics workspace. -1 disables the cap (cost risk); set a small positive value to bound demo ingestion cost.')
param centralLogAnalyticsDailyQuotaGb int = -1

var demoRootManagementGroupId = namePrefix
var platformManagementGroupId = '${namePrefix}-platform'
var connectivityManagementGroupId = '${namePrefix}-connectivity'
var landingZonesManagementGroupId = '${namePrefix}-landingzones'
var workloadManagementGroupId = '${namePrefix}-${workloadArchetype}'

module hierarchy 'modules/hierarchy.bicep' = {
  name: 'hierarchy-${uniqueString(namePrefix)}'
  params: {
    tenantRootManagementGroupId: tenantRootManagementGroupId
    demoRootManagementGroupId: demoRootManagementGroupId
    demoRootDisplayName: demoRootDisplayName
    platformManagementGroupId: platformManagementGroupId
    connectivityManagementGroupId: connectivityManagementGroupId
    landingZonesManagementGroupId: landingZonesManagementGroupId
    workloadManagementGroupId: workloadManagementGroupId
    workloadArchetype: workloadArchetype
    connectivitySubscriptionId: connectivitySubscriptionId
    workloadSubscriptionId: workloadSubscriptionId
  }
}

module policyLibrary 'modules/policy-library.bicep' = {
  name: 'policy-library-${uniqueString(namePrefix)}'
  scope: managementGroup(demoRootManagementGroupId)
  params: {
    namePrefix: namePrefix
  }
  dependsOn: [
    hierarchy
  ]
}

module allowedLocationsAssignment 'modules/policy-assignment.bicep' = {
  name: 'assign-allowed-locations'
  scope: managementGroup(demoRootManagementGroupId)
  params: {
    assignmentName: 'demo-allowed-us-locations'
    displayName: 'Demo - allowed continental-US locations'
    description: 'Restricts regional resources to the approved continental-US list while safely allowing global resources.'
    policyDefinitionId: policyLibrary.outputs.allowedLocationsPolicyDefinitionId
    enforcementMode: denyPolicyEnforcementMode
    parameters: {
      allowedLocations: {
        value: allowedLocations
      }
    }
  }
}

module auditPublicIpAssignment 'modules/policy-assignment.bicep' = {
  name: 'assign-audit-public-ip'
  scope: managementGroup(demoRootManagementGroupId)
  params: {
    assignmentName: 'demo-audit-public-ip'
    displayName: 'Demo - audit public IP resources'
    description: 'Audits public IP address resources anywhere in the demo hierarchy.'
    policyDefinitionId: policyLibrary.outputs.auditPublicIpPolicyDefinitionId
    enforcementMode: 'Default'
    parameters: {}
  }
}

module expensiveResourcesAssignment 'modules/policy-assignment.bicep' = {
  name: 'assign-expensive-resources'
  scope: managementGroup(demoRootManagementGroupId)
  params: {
    assignmentName: 'demo-block-expensive'
    displayName: 'Demo - block common expensive resources and VM SKUs'
    description: 'Blocks selected high-cost service types and restricts VM sizes to a small demo allowlist.'
    policyDefinitionId: policyLibrary.outputs.expensiveResourcesPolicyDefinitionId
    enforcementMode: denyPolicyEnforcementMode
    parameters: {}
  }
}

module platformTagsAssignment 'modules/policy-assignment.bicep' = {
  name: 'assign-platform-tags'
  scope: managementGroup(platformManagementGroupId)
  params: {
    assignmentName: 'demo-audit-platform-tags'
    displayName: 'Demo - audit platform tags'
    description: 'Audits Owner and CostCenter tags on taggable resources in the Platform branch.'
    policyDefinitionId: policyLibrary.outputs.platformTagsPolicyDefinitionId
    enforcementMode: 'Default'
    parameters: {}
  }
  dependsOn: [
    hierarchy
  ]
}

module workloadResourceGroupTagsAssignment 'modules/policy-assignment.bicep' = {
  name: 'assign-workload-rg-tags'
  scope: managementGroup(workloadManagementGroupId)
  params: {
    assignmentName: 'demo-require-workload-rg-tags'
    displayName: 'Demo - require workload resource group tags'
    description: 'Requires Application, Environment, and Owner tags on workload resource groups.'
    policyDefinitionId: policyLibrary.outputs.workloadResourceGroupTagsPolicyDefinitionId
    enforcementMode: denyPolicyEnforcementMode
    parameters: {}
  }
  dependsOn: [
    hierarchy
  ]
}

module managementGroupRbac 'modules/management-group-rbac.bicep' = if (deployRoleAssignments) {
  name: 'management-group-rbac'
  scope: managementGroup(demoRootManagementGroupId)
  params: {
    governanceAdminsGroupObjectId: governanceAdminsGroupObjectId
    readOnlyAuditorsGroupObjectId: readOnlyAuditorsGroupObjectId
  }
  dependsOn: [
    hierarchy
  ]
}

module connectivityRbac 'modules/subscription-rbac.bicep' = if (deployRoleAssignments) {
  name: 'connectivity-subscription-rbac'
  scope: subscription(connectivitySubscriptionId)
  params: {
    subscriptionOwnersGroupObjectId: subscriptionOwnersGroupObjectId
    operatorGroupObjectId: networkOperatorsGroupObjectId
    operatorRoleDefinitionId: '4d97b98b-1d4f-4787-a291-c67834d212e7'
  }
  dependsOn: [
    hierarchy
  ]
}

module workloadRbac 'modules/subscription-rbac.bicep' = if (deployRoleAssignments) {
  name: 'workload-subscription-rbac'
  scope: subscription(workloadSubscriptionId)
  params: {
    subscriptionOwnersGroupObjectId: subscriptionOwnersGroupObjectId
    operatorGroupObjectId: workloadContributorsGroupObjectId
    operatorRoleDefinitionId: 'b24988ac-6180-42a0-ab88-20f7382dd24c'
  }
  dependsOn: [
    hierarchy
  ]
}

module connectivityEvidence 'modules/evidence-connectivity.bicep' = if (deployEvidenceResources) {
  name: 'connectivity-evidence'
  scope: subscription(connectivitySubscriptionId)
  params: {
    namePrefix: namePrefix
    location: evidenceLocation
  }
  dependsOn: [
    hierarchy
    platformTagsAssignment
  ]
}

module workloadEvidence 'modules/evidence-workload.bicep' = if (deployEvidenceResources) {
  name: 'workload-evidence'
  scope: subscription(workloadSubscriptionId)
  params: {
    namePrefix: namePrefix
    location: evidenceLocation
    workloadArchetype: workloadArchetype
  }
  dependsOn: [
    hierarchy
    workloadResourceGroupTagsAssignment
  ]
}

module centralMonitoring 'modules/central-monitoring.bicep' = {
  name: 'central-monitoring'
  scope: subscription(connectivitySubscriptionId)
  params: {
    namePrefix: namePrefix
    location: centralMonitoringLocation
    deployCentralLogAnalytics: deployCentralLogAnalytics
    deploySentinel: deploySentinel
    existingLogAnalyticsWorkspaceResourceId: existingLogAnalyticsWorkspaceResourceId
    retentionInDays: centralLogAnalyticsRetentionInDays
    dailyQuotaGb: centralLogAnalyticsDailyQuotaGb
    tags: {
      Owner: 'Platform Team'
      CostCenter: 'Demo'
      Environment: 'Sandbox'
      Purpose: 'Central Monitoring'
    }
  }
  dependsOn: [
    hierarchy
  ]
}

output hierarchy object = {
  demoRoot: demoRootManagementGroupId
  platform: platformManagementGroupId
  connectivity: connectivityManagementGroupId
  landingZones: landingZonesManagementGroupId
  workload: workloadManagementGroupId
}
output denyPolicyEnforcementMode string = denyPolicyEnforcementMode
output roleAssignmentsEnabled bool = deployRoleAssignments
output evidenceResourcesEnabled bool = deployEvidenceResources
output deploymentRegion string = deploymentLocation
output centralMonitoringEffectiveWorkspaceId string = centralMonitoring.outputs.effectiveLogAnalyticsWorkspaceResourceId
output centralMonitoringConflictingInputs bool = centralMonitoring.outputs.conflictingMonitoringInputs
output centralMonitoringSentinelEnabled bool = centralMonitoring.outputs.sentinelEnabled

