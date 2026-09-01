using '../main.bicep'

param deploymentLocation = 'eastus'
param tenantRootManagementGroupId = 'REPLACE_WITH_TENANT_ROOT_MANAGEMENT_GROUP_ID'
param namePrefix = 'eslz-demo'
param demoRootDisplayName = 'Enterprise-Scale Sandbox Demo'
param workloadArchetype = 'corp'
param connectivitySubscriptionId = 'REPLACE_WITH_CONNECTIVITY_SUBSCRIPTION_GUID'
param workloadSubscriptionId = 'REPLACE_WITH_WORKLOAD_SUBSCRIPTION_GUID'
param governanceAdminsGroupObjectId = 'REPLACE_WITH_GOVERNANCE_ADMINS_GROUP_OBJECT_GUID'
param networkOperatorsGroupObjectId = 'REPLACE_WITH_NETWORK_OPERATORS_GROUP_OBJECT_GUID'
param workloadContributorsGroupObjectId = 'REPLACE_WITH_WORKLOAD_CONTRIBUTORS_GROUP_OBJECT_GUID'
param readOnlyAuditorsGroupObjectId = 'REPLACE_WITH_READ_ONLY_AUDITORS_GROUP_OBJECT_GUID'
param denyPolicyEnforcementMode = 'DoNotEnforce'
param customerAllowedLocations = [
  'eastus'
  'eastus2'
]
param customerAllowedResourceTypes = [
  'Microsoft.Authorization/policyDefinitions'
  'Microsoft.Authorization/policyExemptions'
  'Microsoft.Authorization/policyAssignments'
  'Microsoft.Authorization/policySetDefinitions'
  'Microsoft.Authorization/roleAssignments'
  'Microsoft.Compute/disks'
  'Microsoft.Compute/virtualMachines'
  'Microsoft.Compute/virtualMachines/extensions'
  'Microsoft.Insights/diagnosticSettings'
  'Microsoft.ManagedIdentity/userAssignedIdentities'
  'Microsoft.Network/networkInterfaces'
  'Microsoft.Network/networkSecurityGroups'
  'Microsoft.Network/privateDnsZones'
  'Microsoft.Network/privateDnsZones/virtualNetworkLinks'
  'Microsoft.Network/privateEndpoints'
  'Microsoft.Network/privateEndpoints/privateDnsZoneGroups'
  'Microsoft.Network/publicIPAddresses'
  'Microsoft.Network/virtualNetworks'
  'Microsoft.Network/virtualNetworks/subnets'
  'Microsoft.OperationalInsights/workspaces'
  'Microsoft.OperationsManagement/solutions'
  'Microsoft.PolicyInsights/remediations'
  'Microsoft.RecoveryServices/vaults'
  'Microsoft.RecoveryServices/vaults/backupFabrics'
  'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers'
  'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/protectedItems'
  'Microsoft.RecoveryServices/vaults/backupPolicies'
  'Microsoft.Resources/deployments'
  'Microsoft.Resources/resourceGroups'
  'Microsoft.SecurityInsights/onboardingStates'
]
param customerAllowedVmSkus = [
  'Standard_B1ls'
  'Standard_B1s'
  'Standard_B1ms'
  'Standard_B2s'
  'Standard_B2ms'
]
param networkIngressPolicyEffect = 'Audit'
param deployRoleAssignments = false
param deployEvidenceResources = false
param enableTagInheritance = false
param evidenceLocation = 'eastus2'
param deployCentralLogAnalytics = false
param deploySentinel = false
param existingLogAnalyticsWorkspaceResourceId = ''
param centralMonitoringLocation = 'eastus2'
param centralLogAnalyticsRetentionInDays = 30
param centralLogAnalyticsDailyQuotaGb = -1
param enableCriticalInfrastructure = false
param criticalInfrastructureSubscriptionIds = []
param enableMicrosoftCloudSecurityBenchmark = true
param enableCisAzureFoundationsBenchmark = false
param enableNistSp80053Rev5 = false
