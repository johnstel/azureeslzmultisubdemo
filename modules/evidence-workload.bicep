targetScope = 'subscription'

param namePrefix string
param location string
param workloadArchetype string

resource workloadResourceGroup 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: 'rg-${namePrefix}-${workloadArchetype}-demo'
  location: location
  tags: {
    ApplicationName: 'Landing Zone Demo'
    Environment: 'Sandbox'
    Owner: 'Workload Team'
    CostCenter: 'Demo'
    DataClassification: 'Non-sensitive'
    'SSP-ID': 'Demo'
    ESLZLifecycleOwner: namePrefix
  }
}

output resourceGroupName string = workloadResourceGroup.name
