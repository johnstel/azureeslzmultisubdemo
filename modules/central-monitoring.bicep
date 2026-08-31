targetScope = 'subscription'

@description('Set true to create a new central Log Analytics workspace in this subscription. Leave false (default) so no metered workspace is created; supply an existing workspace via existingLogAnalyticsWorkspaceResourceId instead. Creating a workspace introduces ongoing data-ingestion and retention charges.')
param deployCentralLogAnalytics bool = false

@description('Set true to enable Microsoft Sentinel on the effective workspace (new or existing). Sentinel adds per-GB analysis charges on top of Log Analytics ingestion cost. Requires either deployCentralLogAnalytics=true or an existingLogAnalyticsWorkspaceResourceId.')
param deploySentinel bool = false

@description('Resource ID of an existing customer-owned Log Analytics workspace to reuse as the effective monitoring workspace. This is the default integration path. Leave empty only when deployCentralLogAnalytics is true. Must not be set at the same time as deployCentralLogAnalytics=true.')
param existingLogAnalyticsWorkspaceResourceId string = ''

@description('Azure region for a newly created Log Analytics workspace. Ignored when reusing an existing workspace.')
param location string

@description('Log Analytics workspace SKU. PerGB2018 is the modern consumption-based tier.')
@allowed([
  'PerGB2018'
])
param logAnalyticsSku string = 'PerGB2018'

@description('Daily ingestion cap in GB for a newly created workspace. -1 disables the cap (cost risk); set a small positive value to bound demo ingestion cost.')
param dailyQuotaGb int = -1

@description('Data retention in days for a newly created workspace. Longer retention increases storage cost.')
@minValue(30)
@maxValue(730)
param retentionInDays int = 30

@description('Unique lowercase prefix used to name any newly created monitoring resources.')
@minLength(3)
@maxLength(24)
param namePrefix string

@description('Required tags applied to any newly created monitoring resources.')
param tags object

// Explicit opt-in is required before any metered resource is declared. Requesting a new
// workspace while also supplying an existing workspace resource ID is a conflicting
// configuration. Enabling Sentinel without any effective workspace is an incomplete
// configuration. Both cases must fail the deployment explicitly rather than silently
// deploying nothing, so a deliberately unresolvable resource type is used as a guard:
// it is never registered as an Azure resource provider, so Azure Resource Manager
// rejects the deployment before any billable resource is created, and the resource
// name below surfaces the specific configuration error in the deployment failure.
var newWorkspaceRequested = deployCentralLogAnalytics
var existingWorkspaceSupplied = !empty(existingLogAnalyticsWorkspaceResourceId)
var conflictingMonitoringInputs = newWorkspaceRequested && existingWorkspaceSupplied
var sentinelRequiresEffectiveWorkspace = deploySentinel && !newWorkspaceRequested && !existingWorkspaceSupplied
var hasMonitoringConfigurationError = conflictingMonitoringInputs || sentinelRequiresEffectiveWorkspace
var createNewWorkspace = newWorkspaceRequested && !hasMonitoringConfigurationError
var useExistingWorkspace = existingWorkspaceSupplied && !hasMonitoringConfigurationError
var resourceGroupName = 'rg-${namePrefix}-monitoring'

resource conflictingMonitoringInputsGuard 'Microsoft.CentralMonitoringGuard/configurationError@2024-01-01' = if (conflictingMonitoringInputs) {
  name: 'deployCentralLogAnalytics-and-existingLogAnalyticsWorkspaceResourceId-are-mutually-exclusive-set-only-one'
}

resource sentinelRequiresWorkspaceGuard 'Microsoft.CentralMonitoringGuard/configurationError@2024-01-01' = if (sentinelRequiresEffectiveWorkspace) {
  name: 'deploySentinel-requires-deployCentralLogAnalytics-true-or-a-non-empty-existingLogAnalyticsWorkspaceResourceId'
}

resource monitoringResourceGroup 'Microsoft.Resources/resourceGroups@2025-04-01' = if (createNewWorkspace) {
  name: resourceGroupName
  location: location
  tags: tags
}

module newWorkspace 'central-monitoring-workspace.bicep' = if (createNewWorkspace) {
  name: 'central-log-analytics-workspace'
  scope: resourceGroup(resourceGroupName)
  params: {
    namePrefix: namePrefix
    location: location
    sku: logAnalyticsSku
    dailyQuotaGb: dailyQuotaGb
    retentionInDays: retentionInDays
    tags: tags
    deploySentinel: deploySentinel && !hasMonitoringConfigurationError
  }
  dependsOn: [
    monitoringResourceGroup
  ]
}

// A resource ID always has this shape: /subscriptions/<sub>/resourceGroups/<rg>/providers/<ns>/<type>/<name>
// Split against a placeholder of the same shape when no existing workspace is supplied so the
// array always has a stable, indexable length regardless of user input.
var placeholderWorkspaceResourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/placeholder/providers/Microsoft.OperationalInsights/workspaces/placeholder'
var existingWorkspaceIdParts = split(existingWorkspaceSupplied ? existingLogAnalyticsWorkspaceResourceId : placeholderWorkspaceResourceId, '/')
var existingWorkspaceSubscriptionId = length(existingWorkspaceIdParts) > 2 ? existingWorkspaceIdParts[2] : ''
var existingWorkspaceResourceGroupName = length(existingWorkspaceIdParts) > 4 ? existingWorkspaceIdParts[4] : ''
var existingWorkspaceName = length(existingWorkspaceIdParts) > 8 ? existingWorkspaceIdParts[8] : ''

module existingWorkspaceSentinel 'central-monitoring-sentinel.bicep' = if (useExistingWorkspace && deploySentinel) {
  name: 'central-sentinel-existing-workspace'
  scope: resourceGroup(existingWorkspaceSubscriptionId, existingWorkspaceResourceGroupName)
  params: {
    workspaceName: existingWorkspaceName
  }
}

@description('Deterministic resource ID of the effective monitoring workspace, or empty when no valid workspace input is configured.')
output effectiveLogAnalyticsWorkspaceResourceId string = createNewWorkspace
  ? newWorkspace.outputs.workspaceResourceId
  : (useExistingWorkspace ? existingLogAnalyticsWorkspaceResourceId : '')

@description('Always false when the deployment succeeds: true only describes the error state that the configuration-error guard resource used to fail the deployment before this output could ever be observed. Retained for documentation of the validation contract, not for runtime error handling by callers.')
output conflictingMonitoringInputs bool = conflictingMonitoringInputs

@description('Always false when the deployment succeeds: true only describes the error state that the configuration-error guard resource used to fail the deployment before this output could ever be observed. Retained for documentation of the validation contract, not for runtime error handling by callers.')
output sentinelRequiresEffectiveWorkspace bool = sentinelRequiresEffectiveWorkspace

@description('True when Microsoft Sentinel is enabled on the effective workspace.')
output sentinelEnabled bool = (createNewWorkspace || useExistingWorkspace) && deploySentinel

@description('Name of the resource group created for a new workspace, or empty when reusing an existing workspace.')
output monitoringResourceGroupName string = createNewWorkspace ? resourceGroupName : ''
