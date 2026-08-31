targetScope = 'resourceGroup'

@description('Unique lowercase prefix used to name the new Log Analytics workspace.')
param namePrefix string

@description('Azure region for the new Log Analytics workspace.')
param location string

@description('Log Analytics workspace SKU. PerGB2018 is the modern consumption-based tier.')
param sku string

@description('Daily ingestion cap in GB. -1 disables the cap; a positive value bounds ingestion cost.')
param dailyQuotaGb int

@description('Data retention in days. Longer retention increases storage cost.')
param retentionInDays int

@description('Required tags applied to the new workspace.')
param tags object

@description('Set true to enable Microsoft Sentinel on this newly created workspace. Adds per-GB Sentinel analysis charges.')
param deploySentinel bool

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2025-02-01' = {
  name: 'log-${namePrefix}-central'
  location: location
  tags: tags
  properties: {
    sku: {
      name: sku
    }
    retentionInDays: retentionInDays
    workspaceCapping: {
      dailyQuotaGb: dailyQuotaGb
    }
  }
}

resource sentinelOnboarding 'Microsoft.SecurityInsights/onboardingStates@2024-09-01' = if (deploySentinel) {
  scope: logAnalyticsWorkspace
  name: 'default'
  properties: {}
}

output workspaceResourceId string = logAnalyticsWorkspace.id
output workspaceName string = logAnalyticsWorkspace.name
