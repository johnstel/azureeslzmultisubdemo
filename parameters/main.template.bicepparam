using '../main.bicep'

param deploymentLocation = 'eastus'
param tenantRootManagementGroupId = 'REPLACE_WITH_TENANT_ROOT_MANAGEMENT_GROUP_ID'
param namePrefix = 'eslz-demo'
param demoRootDisplayName = 'Enterprise-Scale Sandbox Demo'
param workloadArchetype = 'corp'
param connectivitySubscriptionId = 'REPLACE_WITH_CONNECTIVITY_SUBSCRIPTION_GUID'
param workloadSubscriptionId = 'REPLACE_WITH_WORKLOAD_SUBSCRIPTION_GUID'
param governanceAdminsGroupObjectId = 'REPLACE_WITH_GOVERNANCE_ADMINS_GROUP_OBJECT_GUID'
param subscriptionOwnersGroupObjectId = 'REPLACE_WITH_SUBSCRIPTION_OWNERS_GROUP_OBJECT_GUID'
param networkOperatorsGroupObjectId = 'REPLACE_WITH_NETWORK_OPERATORS_GROUP_OBJECT_GUID'
param workloadContributorsGroupObjectId = 'REPLACE_WITH_WORKLOAD_CONTRIBUTORS_GROUP_OBJECT_GUID'
param readOnlyAuditorsGroupObjectId = 'REPLACE_WITH_READ_ONLY_AUDITORS_GROUP_OBJECT_GUID'
param denyPolicyEnforcementMode = 'DoNotEnforce'
param networkIngressPolicyEffect = 'Audit'
param deployRoleAssignments = false
param deployEvidenceResources = false
param evidenceLocation = 'eastus2'
param deployCentralLogAnalytics = false
param deploySentinel = false
param existingLogAnalyticsWorkspaceResourceId = ''
param centralMonitoringLocation = 'eastus2'
param centralLogAnalyticsRetentionInDays = 30
param centralLogAnalyticsDailyQuotaGb = -1
param enableCriticalInfrastructure = false
param criticalInfrastructureSubscriptionIds = []
