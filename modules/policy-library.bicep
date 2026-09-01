targetScope = 'managementGroup'

param namePrefix string

resource allowedLocations 'Microsoft.Authorization/policyDefinitions@2025-03-01' = {
  name: '${namePrefix}-allowed-us-locations'
  properties: {
    displayName: 'Demo - allowed continental-US Azure locations'
    description: 'Restricts taggable regional resources to a clear continental-US allowlist, while allowing global resources and excluding B2C directories.'
    mode: 'Indexed'
    metadata: {
      category: 'Demo Landing Zone'
      version: '1.0.0'
    }
    parameters: {
      allowedLocations: {
        type: 'Array'
        metadata: {
          displayName: 'Allowed locations'
          description: 'Continental-US Azure region names allowed by this assignment.'
        }
      }
    }
    policyRule: {
      if: {
        allOf: [
          {
            field: 'location'
            notIn: '[parameters(\'allowedLocations\')]'
          }
          {
            field: 'location'
            notEquals: 'global'
          }
          {
            field: 'type'
            notEquals: 'Microsoft.AzureActiveDirectory/b2cDirectories'
          }
        ]
      }
      then: {
        effect: 'deny'
      }
    }
  }
}

resource allowedResourceTypesAll 'Microsoft.Authorization/policyDefinitions@2025-03-01' = {
  name: '${namePrefix}-allowed-resource-types-all'
  properties: {
    displayName: 'Demo - allowed resource types (all resources)'
    description: 'Restricts every resource to a change-controlled type allowlist, including child and locationless resources.'
    mode: 'All'
    metadata: {
      category: 'Demo Landing Zone'
      version: '1.0.0'
    }
    parameters: {
      allowedResourceTypes: {
        type: 'Array'
        metadata: {
          displayName: 'Allowed resource types'
          description: 'Resource types allowed by this assignment.'
        }
      }
    }
    policyRule: {
      if: {
        field: 'type'
        notIn: '[parameters(\'allowedResourceTypes\')]'
      }
      then: {
        effect: 'deny'
      }
    }
  }
}

resource auditPublicIp 'Microsoft.Authorization/policyDefinitions@2025-03-01' = {
  name: '${namePrefix}-audit-public-ip'
  properties: {
    displayName: 'Demo - audit public IP address resources'
    description: 'Audits the creation of Microsoft.Network/publicIPAddresses as a simple public-exposure signal.'
    mode: 'All'
    metadata: {
      category: 'Network'
      version: '1.0.0'
    }
    policyRule: {
      if: {
        field: 'type'
        equals: 'Microsoft.Network/publicIPAddresses'
      }
      then: {
        effect: 'audit'
      }
    }
  }
}

resource expensiveResources 'Microsoft.Authorization/policyDefinitions@2025-03-01' = {
  name: '${namePrefix}-block-expensive'
  properties: {
    displayName: 'Demo - block common expensive resources and VM SKUs'
    description: 'Blocks selected commonly expensive always-on service types and denies virtual machine SKUs outside a small demo allowlist.'
    mode: 'All'
    metadata: {
      category: 'Cost'
      version: '1.0.0'
    }
    policyRule: {
      if: {
        anyOf: [
          {
            field: 'type'
            in: [
              'Microsoft.AnalysisServices/servers'
              'Microsoft.ContainerService/managedClusters'
              'Microsoft.Databricks/workspaces'
              'Microsoft.Network/azureFirewalls'
              'Microsoft.Network/bastionHosts'
              'Microsoft.Network/natGateways'
              'Microsoft.Network/virtualNetworkGateways'
              'Microsoft.Synapse/workspaces'
            ]
          }
          {
            allOf: [
              {
                field: 'type'
                equals: 'Microsoft.Compute/virtualMachines'
              }
              {
                field: 'Microsoft.Compute/virtualMachines/sku.name'
                notIn: [
                  'Standard_B1ls'
                  'Standard_B1s'
                  'Standard_B1ms'
                  'Standard_B2s'
                  'Standard_B2ms'
                ]
              }
            ]
          }
        ]
      }
      then: {
        effect: 'deny'
      }
    }
  }
}

resource platformTags 'Microsoft.Authorization/policyDefinitions@2025-03-01' = {
  name: '${namePrefix}-audit-platform-tags'
  properties: {
    displayName: 'Demo - audit Owner and CostCenter tags'
    description: 'Audits taggable Platform resources that are missing Owner or CostCenter.'
    mode: 'Indexed'
    metadata: {
      category: 'Tags'
      version: '1.0.0'
    }
    policyRule: {
      if: {
        anyOf: [
          {
            field: 'tags[Owner]'
            exists: 'false'
          }
          {
            field: 'tags[CostCenter]'
            exists: 'false'
          }
        ]
      }
      then: {
        effect: 'audit'
      }
    }
  }
}

resource workloadResourceGroupTags 'Microsoft.Authorization/policyDefinitions@2025-03-01' = {
  name: '${namePrefix}-require-workload-rg-tags'
  properties: {
    displayName: 'Demo - require workload resource group tags'
    description: 'Requires Application, Environment, and Owner tags on workload resource groups.'
    mode: 'All'
    metadata: {
      category: 'Tags'
      version: '1.0.0'
    }
    policyRule: {
      if: {
        allOf: [
          {
            field: 'type'
            equals: 'Microsoft.Resources/subscriptions/resourceGroups'
          }
          {
            anyOf: [
              {
                field: 'tags[Application]'
                exists: 'false'
              }
              {
                field: 'tags[Environment]'
                exists: 'false'
              }
              {
                field: 'tags[Owner]'
                exists: 'false'
              }
            ]
          }
        ]
      }
      then: {
        effect: 'deny'
      }
    }
  }
}

output allowedLocationsPolicyDefinitionId string = allowedLocations.id
output allowedResourceTypesAllPolicyDefinitionId string = allowedResourceTypesAll.id
output auditPublicIpPolicyDefinitionId string = auditPublicIp.id
output expensiveResourcesPolicyDefinitionId string = expensiveResources.id
output platformTagsPolicyDefinitionId string = platformTags.id
output workloadResourceGroupTagsPolicyDefinitionId string = workloadResourceGroupTags.id
