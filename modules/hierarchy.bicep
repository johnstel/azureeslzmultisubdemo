targetScope = 'tenant'

param tenantRootManagementGroupId string
param demoRootManagementGroupId string
param demoRootDisplayName string
param platformManagementGroupId string
param connectivityManagementGroupId string
param landingZonesManagementGroupId string
param workloadManagementGroupId string
param workloadArchetype string
param connectivitySubscriptionId string
param workloadSubscriptionId string

@description('Set true to create the opt-in Critical Infrastructure management group under Landing Zones.')
param enableCriticalInfrastructure bool = false

@description('Management group ID for the Critical Infrastructure branch, used only when enableCriticalInfrastructure is true.')
param criticalInfrastructureManagementGroupId string

@description('Existing critical-workload subscription IDs to associate with the Critical Infrastructure branch, used only when enableCriticalInfrastructure is true.')
param criticalInfrastructureSubscriptionIds array = []

var normalizedCriticalInfrastructureSubscriptionIds = [for subscriptionId in criticalInfrastructureSubscriptionIds: toLower(subscriptionId)]
var hasDuplicateCriticalInfrastructureSubscriptionIds = length(normalizedCriticalInfrastructureSubscriptionIds) != length(union(normalizedCriticalInfrastructureSubscriptionIds, []))
var criticalInfrastructureSubscriptionIdsOverlapRequiredSubscriptions = contains(normalizedCriticalInfrastructureSubscriptionIds, toLower(connectivitySubscriptionId)) || contains(normalizedCriticalInfrastructureSubscriptionIds, toLower(workloadSubscriptionId))
var criticalInfrastructureManagementGroupIdValidated = !enableCriticalInfrastructure
  ? criticalInfrastructureManagementGroupId
  : (hasDuplicateCriticalInfrastructureSubscriptionIds
      ? fail('criticalInfrastructureSubscriptionIds must not contain duplicate subscription IDs.')
      : (criticalInfrastructureSubscriptionIdsOverlapRequiredSubscriptions
          ? fail('criticalInfrastructureSubscriptionIds must not overlap with connectivitySubscriptionId or workloadSubscriptionId.')
          : criticalInfrastructureManagementGroupId))

resource demoRoot 'Microsoft.Management/managementGroups@2023-04-01' = {
  name: demoRootManagementGroupId
  properties: {
    displayName: demoRootDisplayName
    details: {
      parent: {
        id: tenantResourceId('Microsoft.Management/managementGroups', tenantRootManagementGroupId)
      }
    }
  }
}

resource platform 'Microsoft.Management/managementGroups@2023-04-01' = {
  name: platformManagementGroupId
  properties: {
    displayName: 'Platform'
    details: {
      parent: {
        id: demoRoot.id
      }
    }
  }
}

resource connectivity 'Microsoft.Management/managementGroups@2023-04-01' = {
  name: connectivityManagementGroupId
  properties: {
    displayName: 'Connectivity'
    details: {
      parent: {
        id: platform.id
      }
    }
  }
}

resource landingZones 'Microsoft.Management/managementGroups@2023-04-01' = {
  name: landingZonesManagementGroupId
  properties: {
    displayName: 'Landing Zones'
    details: {
      parent: {
        id: demoRoot.id
      }
    }
  }
}

resource workload 'Microsoft.Management/managementGroups@2023-04-01' = {
  name: workloadManagementGroupId
  properties: {
    displayName: workloadArchetype == 'corp' ? 'Corp' : 'Online'
    details: {
      parent: {
        id: landingZones.id
      }
    }
  }
}

resource connectivitySubscription 'Microsoft.Management/managementGroups/subscriptions@2023-04-01' = {
  parent: connectivity
  name: connectivitySubscriptionId
}

resource workloadSubscription 'Microsoft.Management/managementGroups/subscriptions@2023-04-01' = {
  parent: workload
  name: workloadSubscriptionId
}

resource criticalInfrastructure 'Microsoft.Management/managementGroups@2023-04-01' = if (enableCriticalInfrastructure) {
  name: criticalInfrastructureManagementGroupIdValidated
  properties: {
    displayName: 'Critical Infrastructure'
    details: {
      parent: {
        id: landingZones.id
      }
    }
  }
}

resource criticalInfrastructureSubscriptions 'Microsoft.Management/managementGroups/subscriptions@2023-04-01' = [for subscriptionId in criticalInfrastructureSubscriptionIds: if (enableCriticalInfrastructure) {
  parent: criticalInfrastructure
  name: subscriptionId
}]

output demoRootManagementGroupId string = demoRoot.name
output platformManagementGroupId string = platform.name
output connectivityManagementGroupId string = connectivity.name
output landingZonesManagementGroupId string = landingZones.name
output workloadManagementGroupId string = workload.name
output criticalInfrastructureManagementGroupId string = enableCriticalInfrastructure ? criticalInfrastructure.name : ''
