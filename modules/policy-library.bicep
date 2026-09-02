targetScope = 'managementGroup'

param namePrefix string

var managementPorts = [
  '22'
  '3389'
]
var nonPublicIpv4Ranges = [
  '0.0.0.0/8'
  '10.0.0.0/8'
  '100.64.0.0/10'
  '127.0.0.0/8'
  '169.254.0.0/16'
  '172.16.0.0/12'
  '192.0.0.0/24'
  '192.0.2.0/24'
  '192.88.99.0/24'
  '192.168.0.0/16'
  '198.18.0.0/15'
  '198.51.100.0/24'
  '203.0.113.0/24'
  '224.0.0.0/4'
  '240.0.0.0/4'
]

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

resource publicManagementIngress 'Microsoft.Authorization/policyDefinitions@2025-03-01' = {
  name: '${namePrefix}-public-mgmt-ingress'
  properties: {
    displayName: 'Demo - block public RDP and SSH NSG rules'
    description: 'Audits or denies inbound NSG rules that allow TCP RDP or SSH from any public IPv4 host, CIDR, Internet, or wildcard source.'
    mode: 'All'
    metadata: {
      category: 'Network'
      version: '1.0.0'
    }
    parameters: {
      effect: {
        type: 'String'
        metadata: {
          displayName: 'Effect'
          description: 'Audit is the safe default. Deny requires a reviewed assignment and enforcement-mode change.'
        }
        allowedValues: [
          'Audit'
          'Deny'
          'Disabled'
        ]
        defaultValue: 'Audit'
      }
    }
    policyRule: {
      if: {
        anyOf: [
          {
            allOf: [
              {
                field: 'type'
                equals: 'Microsoft.Network/networkSecurityGroups/securityRules'
              }
              {
                field: 'Microsoft.Network/networkSecurityGroups/securityRules/access'
                equals: 'Allow'
              }
              {
                field: 'Microsoft.Network/networkSecurityGroups/securityRules/direction'
                equals: 'Inbound'
              }
              {
                field: 'Microsoft.Network/networkSecurityGroups/securityRules/protocol'
                in: [
                  '*'
                  'Tcp'
                ]
              }
              {
                anyOf: [
                  {
                    field: 'Microsoft.Network/networkSecurityGroups/securityRules/sourceAddressPrefix'
                    in: [
                      '*'
                      'Internet'
                      '0.0.0.0/0'
                    ]
                  }
                  {
                    allOf: [
                      {
                        value: '[if(or(empty(field(\'Microsoft.Network/networkSecurityGroups/securityRules/sourceAddressPrefix\')), greaterOrEquals(first(field(\'Microsoft.Network/networkSecurityGroups/securityRules/sourceAddressPrefix\')), \'A\')), false, ipRangeContains(\'0.0.0.0/0\', field(\'Microsoft.Network/networkSecurityGroups/securityRules/sourceAddressPrefix\')))]'
                        equals: true
                      }
                      {
                        count: {
                          value: nonPublicIpv4Ranges
                          name: 'nonPublicIpv4Range'
                          where: {
                            value: '[ipRangeContains(current(\'nonPublicIpv4Range\'), field(\'Microsoft.Network/networkSecurityGroups/securityRules/sourceAddressPrefix\'))]'
                            equals: false
                          }
                        }
                        equals: length(nonPublicIpv4Ranges)
                      }
                    ]
                  }
                  {
                    count: {
                      field: 'Microsoft.Network/networkSecurityGroups/securityRules/sourceAddressPrefixes[*]'
                      where: {
                        anyOf: [
                          {
                            field: 'Microsoft.Network/networkSecurityGroups/securityRules/sourceAddressPrefixes[*]'
                            in: [
                              '*'
                              'Internet'
                              '0.0.0.0/0'
                            ]
                          }
                          {
                            allOf: [
                              {
                                value: '[if(or(empty(current(\'Microsoft.Network/networkSecurityGroups/securityRules/sourceAddressPrefixes[*]\')), greaterOrEquals(first(current(\'Microsoft.Network/networkSecurityGroups/securityRules/sourceAddressPrefixes[*]\')), \'A\')), false, ipRangeContains(\'0.0.0.0/0\', current(\'Microsoft.Network/networkSecurityGroups/securityRules/sourceAddressPrefixes[*]\')))]'
                                equals: true
                              }
                              {
                                count: {
                                  value: nonPublicIpv4Ranges
                                  name: 'nonPublicIpv4Range'
                                  where: {
                                    value: '[ipRangeContains(current(\'nonPublicIpv4Range\'), current(\'Microsoft.Network/networkSecurityGroups/securityRules/sourceAddressPrefixes[*]\'))]'
                                    equals: false
                                  }
                                }
                                equals: length(nonPublicIpv4Ranges)
                              }
                            ]
                          }
                        ]
                      }
                    }
                    greater: 0
                  }
                ]
              }
              {
                count: {
                  value: managementPorts
                  name: 'managementPort'
                  where: {
                    anyOf: [
                      {
                        value: '[if(or(empty(field(\'Microsoft.Network/networkSecurityGroups/securityRules/destinationPortRange\')), greaterOrEquals(first(field(\'Microsoft.Network/networkSecurityGroups/securityRules/destinationPortRange\')), \'A\')), false, if(equals(field(\'Microsoft.Network/networkSecurityGroups/securityRules/destinationPortRange\'), \'*\'), true, and(lessOrEquals(int(first(split(field(\'Microsoft.Network/networkSecurityGroups/securityRules/destinationPortRange\'), \'-\'))), int(current(\'managementPort\'))), greaterOrEquals(int(last(split(field(\'Microsoft.Network/networkSecurityGroups/securityRules/destinationPortRange\'), \'-\'))), int(current(\'managementPort\')))))))]'
                        equals: true
                      }
                      {
                        count: {
                          field: 'Microsoft.Network/networkSecurityGroups/securityRules/destinationPortRanges[*]'
                          where: {
                            value: '[if(or(empty(current(\'Microsoft.Network/networkSecurityGroups/securityRules/destinationPortRanges[*]\')), greaterOrEquals(first(current(\'Microsoft.Network/networkSecurityGroups/securityRules/destinationPortRanges[*]\')), \'A\')), false, if(equals(current(\'Microsoft.Network/networkSecurityGroups/securityRules/destinationPortRanges[*]\'), \'*\'), true, and(lessOrEquals(int(first(split(current(\'Microsoft.Network/networkSecurityGroups/securityRules/destinationPortRanges[*]\'), \'-\'))), int(current(\'managementPort\'))), greaterOrEquals(int(last(split(current(\'Microsoft.Network/networkSecurityGroups/securityRules/destinationPortRanges[*]\'), \'-\'))), int(current(\'managementPort\')))))))]'
                            equals: true
                          }
                        }
                        greater: 0
                      }
                    ]
                  }
                }
                greater: 0
              }
            ]
          }
          {
            allOf: [
              {
                field: 'type'
                equals: 'Microsoft.Network/networkSecurityGroups'
              }
              {
                count: {
                  field: 'Microsoft.Network/networkSecurityGroups/securityRules[*]'
                  where: {
                    allOf: [
                      {
                        field: 'Microsoft.Network/networkSecurityGroups/securityRules[*].access'
                        equals: 'Allow'
                      }
                      {
                        field: 'Microsoft.Network/networkSecurityGroups/securityRules[*].direction'
                        equals: 'Inbound'
                      }
                      {
                        field: 'Microsoft.Network/networkSecurityGroups/securityRules[*].protocol'
                        in: [
                          '*'
                          'Tcp'
                        ]
                      }
                      {
                        anyOf: [
                          {
                            field: 'Microsoft.Network/networkSecurityGroups/securityRules[*].sourceAddressPrefix'
                            in: [
                              '*'
                              'Internet'
                              '0.0.0.0/0'
                            ]
                          }
                          {
                            allOf: [
                              {
                                value: '[if(or(empty(current(\'Microsoft.Network/networkSecurityGroups/securityRules[*].sourceAddressPrefix\')), greaterOrEquals(first(current(\'Microsoft.Network/networkSecurityGroups/securityRules[*].sourceAddressPrefix\')), \'A\')), false, ipRangeContains(\'0.0.0.0/0\', current(\'Microsoft.Network/networkSecurityGroups/securityRules[*].sourceAddressPrefix\')))]'
                                equals: true
                              }
                              {
                                count: {
                                  value: nonPublicIpv4Ranges
                                  name: 'nonPublicIpv4Range'
                                  where: {
                                    value: '[ipRangeContains(current(\'nonPublicIpv4Range\'), current(\'Microsoft.Network/networkSecurityGroups/securityRules[*].sourceAddressPrefix\'))]'
                                    equals: false
                                  }
                                }
                                equals: length(nonPublicIpv4Ranges)
                              }
                            ]
                          }
                          {
                            count: {
                              field: 'Microsoft.Network/networkSecurityGroups/securityRules[*].sourceAddressPrefixes[*]'
                              where: {
                                anyOf: [
                                  {
                                    field: 'Microsoft.Network/networkSecurityGroups/securityRules[*].sourceAddressPrefixes[*]'
                                    in: [
                                      '*'
                                      'Internet'
                                      '0.0.0.0/0'
                                    ]
                                  }
                                  {
                                    allOf: [
                                      {
                                        value: '[if(or(empty(current(\'Microsoft.Network/networkSecurityGroups/securityRules[*].sourceAddressPrefixes[*]\')), greaterOrEquals(first(current(\'Microsoft.Network/networkSecurityGroups/securityRules[*].sourceAddressPrefixes[*]\')), \'A\')), false, ipRangeContains(\'0.0.0.0/0\', current(\'Microsoft.Network/networkSecurityGroups/securityRules[*].sourceAddressPrefixes[*]\')))]'
                                        equals: true
                                      }
                                      {
                                        count: {
                                          value: nonPublicIpv4Ranges
                                          name: 'nonPublicIpv4Range'
                                          where: {
                                            value: '[ipRangeContains(current(\'nonPublicIpv4Range\'), current(\'Microsoft.Network/networkSecurityGroups/securityRules[*].sourceAddressPrefixes[*]\'))]'
                                            equals: false
                                          }
                                        }
                                        equals: length(nonPublicIpv4Ranges)
                                      }
                                    ]
                                  }
                                ]
                              }
                            }
                            greater: 0
                          }
                        ]
                      }
                      {
                        count: {
                          value: managementPorts
                          name: 'managementPort'
                          where: {
                            anyOf: [
                              {
                                value: '[if(or(empty(current(\'Microsoft.Network/networkSecurityGroups/securityRules[*].destinationPortRange\')), greaterOrEquals(first(current(\'Microsoft.Network/networkSecurityGroups/securityRules[*].destinationPortRange\')), \'A\')), false, if(equals(current(\'Microsoft.Network/networkSecurityGroups/securityRules[*].destinationPortRange\'), \'*\'), true, and(lessOrEquals(int(first(split(current(\'Microsoft.Network/networkSecurityGroups/securityRules[*].destinationPortRange\'), \'-\'))), int(current(\'managementPort\'))), greaterOrEquals(int(last(split(current(\'Microsoft.Network/networkSecurityGroups/securityRules[*].destinationPortRange\'), \'-\'))), int(current(\'managementPort\')))))))]'
                                equals: true
                              }
                              {
                                count: {
                                  field: 'Microsoft.Network/networkSecurityGroups/securityRules[*].destinationPortRanges[*]'
                                  where: {
                                    value: '[if(or(empty(current(\'Microsoft.Network/networkSecurityGroups/securityRules[*].destinationPortRanges[*]\')), greaterOrEquals(first(current(\'Microsoft.Network/networkSecurityGroups/securityRules[*].destinationPortRanges[*]\')), \'A\')), false, if(equals(current(\'Microsoft.Network/networkSecurityGroups/securityRules[*].destinationPortRanges[*]\'), \'*\'), true, and(lessOrEquals(int(first(split(current(\'Microsoft.Network/networkSecurityGroups/securityRules[*].destinationPortRanges[*]\'), \'-\'))), int(current(\'managementPort\'))), greaterOrEquals(int(last(split(current(\'Microsoft.Network/networkSecurityGroups/securityRules[*].destinationPortRanges[*]\'), \'-\'))), int(current(\'managementPort\')))))))]'
                                    equals: true
                                  }
                                }
                                greater: 0
                              }
                            ]
                          }
                        }
                        greater: 0
                      }
                    ]
                  }
                }
                greater: 0
              }
            ]
          }
        ]
      }
      then: {
        effect: '[parameters(\'effect\')]'
      }
    }
  }
}

resource requireSubnetNsg 'Microsoft.Authorization/policyDefinitions@2025-03-01' = {
  name: '${namePrefix}-require-subnet-nsg'
  properties: {
    displayName: 'Demo - require NSGs on workload subnets'
    description: 'Audits or denies workload subnets that do not have a network security group association.'
    mode: 'All'
    metadata: {
      category: 'Network'
      version: '1.0.0'
    }
    parameters: {
      effect: {
        type: 'String'
        metadata: {
          displayName: 'Effect'
          description: 'Audit is the safe default. Deny requires a reviewed assignment and enforcement-mode change.'
        }
        allowedValues: [
          'Audit'
          'Deny'
          'Disabled'
        ]
        defaultValue: 'Audit'
      }
    }
    policyRule: {
      if: {
        anyOf: [
          {
            allOf: [
              {
                field: 'type'
                equals: 'Microsoft.Network/virtualNetworks/subnets'
              }
              {
                field: 'Microsoft.Network/virtualNetworks/subnets/networkSecurityGroup.id'
                exists: 'false'
              }
            ]
          }
          {
            allOf: [
              {
                field: 'type'
                equals: 'Microsoft.Network/virtualNetworks'
              }
              {
                count: {
                  field: 'Microsoft.Network/virtualNetworks/subnets[*]'
                  where: {
                    field: 'Microsoft.Network/virtualNetworks/subnets[*].networkSecurityGroup.id'
                    exists: 'false'
                  }
                }
                greater: 0
              }
            ]
          }
        ]
      }
      then: {
        effect: '[parameters(\'effect\')]'
      }
    }
  }
}

resource privateAccessPublicNetwork 'Microsoft.Authorization/policyDefinitions@2025-03-01' = {
  name: '${namePrefix}-audit-paas-public-network'
  properties: {
    displayName: 'Demo - audit selected PaaS public network access'
    description: 'Audits selected PaaS services that permit public network access. Deny is an explicit later-enforcement option.'
    mode: 'Indexed'
    metadata: {
      category: 'Network'
      version: '1.0.0'
    }
    parameters: {
      effect: {
        type: 'String'
        metadata: {
          displayName: 'Effect'
          description: 'Audit is the safe default. Deny requires confirmed private endpoints, DNS, routing, and approved exemptions.'
        }
        allowedValues: [
          'Audit'
          'Deny'
          'Disabled'
        ]
        defaultValue: 'Audit'
      }
      serviceCategories: {
        type: 'Array'
        metadata: {
          displayName: 'PaaS service categories'
          description: 'Categories whose public network access posture is evaluated.'
        }
        defaultValue: [
          'Storage'
          'KeyVault'
        ]
      }
    }
    policyRule: {
      if: {
        anyOf: [
          {
            allOf: [
              {
                value: '[contains(parameters(\'serviceCategories\'), \'Storage\')]'
                equals: true
              }
              {
                field: 'type'
                equals: 'Microsoft.Storage/storageAccounts'
              }
              {
                field: 'Microsoft.Storage/storageAccounts/publicNetworkAccess'
                notEquals: 'Disabled'
              }
            ]
          }
          {
            allOf: [
              {
                value: '[contains(parameters(\'serviceCategories\'), \'KeyVault\')]'
                equals: true
              }
              {
                field: 'type'
                equals: 'Microsoft.KeyVault/vaults'
              }
              {
                field: 'Microsoft.KeyVault/vaults/publicNetworkAccess'
                notEquals: 'Disabled'
              }
            ]
          }
        ]
      }
      then: {
        effect: '[parameters(\'effect\')]'
      }
    }
  }
}

resource approvedFirewallRoutes 'Microsoft.Authorization/policyDefinitions@2025-03-01' = {
  name: '${namePrefix}-audit-approved-firewall-routes'
  properties: {
    displayName: 'Demo - audit approved firewall route expectations'
    description: 'Audits specified route tables when expected prefixes do not use the supplied approved virtual-appliance private IP.'
    mode: 'All'
    metadata: {
      category: 'Network'
      version: '1.0.0'
    }
    parameters: {
      approvedFirewallPrivateIp: {
        type: 'String'
        metadata: {
          displayName: 'Approved firewall private IP'
        }
      }
      approvedFirewallResourceId: {
        type: 'String'
        metadata: {
          displayName: 'Approved firewall resource ID'
        }
      }
      approvedRouteTableResourceIds: {
        type: 'Array'
        metadata: {
          displayName: 'Approved route table resource IDs'
        }
      }
      approvedRouteTablePrefixes: {
        type: 'Array'
        metadata: {
          displayName: 'Approved route prefixes'
        }
      }
    }
    policyRule: {
      if: {
        allOf: [
          {
            field: 'type'
            equals: 'Microsoft.Network/routeTables'
          }
          {
            field: 'id'
            in: '[parameters(\'approvedRouteTableResourceIds\')]'
          }
          {
            count: {
              value: '[parameters(\'approvedRouteTablePrefixes\')]'
              name: 'approvedRouteTablePrefix'
              where: {
                count: {
                  field: 'Microsoft.Network/routeTables/routes[*]'
                  where: {
                    allOf: [
                      {
                        field: 'Microsoft.Network/routeTables/routes[*].addressPrefix'
                        equals: '[current(\'approvedRouteTablePrefix\')]'
                      }
                      {
                        field: 'Microsoft.Network/routeTables/routes[*].nextHopType'
                        equals: 'VirtualAppliance'
                      }
                      {
                        field: 'Microsoft.Network/routeTables/routes[*].nextHopIpAddress'
                        equals: '[parameters(\'approvedFirewallPrivateIp\')]'
                      }
                    ]
                  }
                }
                equals: 0
              }
            }
            greater: 0
          }
        ]
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

resource storageCmkApprovedKey 'Microsoft.Authorization/policyDefinitions@2025-03-01' = {
  name: '${namePrefix}-audit-storage-cmk-approved-key'
  properties: {
    displayName: 'Demo - audit storage customer-managed keys against approved Key Vaults and keys'
    description: 'Audits storage accounts encrypted with a customer-managed key whose Key Vault URI or key name is outside the customer-approved lists. Each list is only evaluated when it is non-empty, so the safe default reports nothing and no key, vault, or identity is created.'
    mode: 'Indexed'
    metadata: {
      category: 'Storage'
      version: '1.0.0'
    }
    parameters: {
      effect: {
        type: 'String'
        metadata: {
          displayName: 'Effect'
          description: 'Audit is the safe default. Deny requires an approved key inventory, a reviewed assignment, and an enforcement-mode change.'
        }
        allowedValues: [
          'Audit'
          'Deny'
          'Disabled'
        ]
        defaultValue: 'Audit'
      }
      approvedKeyVaultUris: {
        type: 'Array'
        metadata: {
          displayName: 'Approved Key Vault URIs'
          description: 'Customer-approved Key Vault URIs (the vault URI shown on the Key Vault overview, including the trailing slash) that may hold storage encryption keys. Leave empty to skip the vault check.'
        }
        defaultValue: []
      }
      approvedKeyNames: {
        type: 'Array'
        metadata: {
          displayName: 'Approved key names'
          description: 'Customer-approved encryption key names. Leave empty to skip the key-name check.'
        }
        defaultValue: []
      }
    }
    policyRule: {
      if: {
        allOf: [
          {
            field: 'type'
            equals: 'Microsoft.Storage/storageAccounts'
          }
          {
            field: 'Microsoft.Storage/storageAccounts/encryption.keySource'
            equals: 'Microsoft.Keyvault'
          }
          {
            anyOf: [
              {
                allOf: [
                  {
                    value: '[length(parameters(\'approvedKeyVaultUris\'))]'
                    greater: 0
                  }
                  {
                    field: 'Microsoft.Storage/storageAccounts/encryption.keyvaultproperties.keyvaulturi'
                    notIn: '[parameters(\'approvedKeyVaultUris\')]'
                  }
                ]
              }
              {
                allOf: [
                  {
                    value: '[length(parameters(\'approvedKeyNames\'))]'
                    greater: 0
                  }
                  {
                    field: 'Microsoft.Storage/storageAccounts/encryption.keyvaultproperties.keyname'
                    notIn: '[parameters(\'approvedKeyNames\')]'
                  }
                ]
              }
            ]
          }
        ]
      }
      then: {
        effect: '[parameters(\'effect\')]'
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

output allowedLocationsPolicyDefinitionId string = allowedLocations.id
output allowedResourceTypesAllPolicyDefinitionId string = allowedResourceTypesAll.id
output auditPublicIpPolicyDefinitionId string = auditPublicIp.id
output publicManagementIngressPolicyDefinitionId string = publicManagementIngress.id
output requireSubnetNsgPolicyDefinitionId string = requireSubnetNsg.id
output privateAccessPublicNetworkPolicyDefinitionId string = privateAccessPublicNetwork.id
output approvedFirewallRoutesPolicyDefinitionId string = approvedFirewallRoutes.id
output expensiveResourcesPolicyDefinitionId string = expensiveResources.id
output storageCmkApprovedKeyPolicyDefinitionId string = storageCmkApprovedKey.id
output platformTagsPolicyDefinitionId string = platformTags.id
