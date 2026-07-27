targetScope = 'resourceGroup'

param namePrefix string
param location string
param tags object

resource networkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2025-05-01' = {
  name: 'nsg-${namePrefix}-shared'
  location: location
  tags: tags
  properties: {
    securityRules: []
  }
}

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2025-05-01' = {
  name: 'vnet-${namePrefix}-shared'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.20.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'snet-demo'
        properties: {
          addressPrefix: '10.20.1.0/24'
          networkSecurityGroup: {
            id: networkSecurityGroup.id
          }
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

output virtualNetworkId string = virtualNetwork.id
