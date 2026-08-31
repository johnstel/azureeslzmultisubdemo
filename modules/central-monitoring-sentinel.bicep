targetScope = 'resourceGroup'

@description('Name of an existing customer-owned Log Analytics workspace, in this resource group, to onboard to Microsoft Sentinel.')
param workspaceName string

resource existingWorkspace 'Microsoft.OperationalInsights/workspaces@2025-02-01' existing = {
  name: workspaceName
}

resource sentinelOnboarding 'Microsoft.SecurityInsights/onboardingStates@2024-09-01' = {
  scope: existingWorkspace
  name: 'default'
  properties: {}
}
