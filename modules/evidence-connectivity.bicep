targetScope = 'subscription'

param namePrefix string
param location string

var resourceGroupName = 'rg-${namePrefix}-connectivity'
var commonTags = {
  Owner: 'Platform Team'
  CostCenter: 'Demo'
  ApplicationName: 'Connectivity Evidence'
  Environment: 'Sandbox'
  DataClassification: 'Non-sensitive'
  'SSP-ID': 'Demo'
  Purpose: 'Landing Zone Evidence'
}

resource connectivityResourceGroup 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: resourceGroupName
  location: location
  tags: commonTags
}

module networkEvidence 'evidence-network.bicep' = {
  name: 'network-evidence'
  scope: resourceGroup(connectivityResourceGroup.name)
  params: {
    namePrefix: namePrefix
    location: location
    tags: commonTags
  }
}

output resourceGroupName string = connectivityResourceGroup.name
output virtualNetworkId string = networkEvidence.outputs.virtualNetworkId
