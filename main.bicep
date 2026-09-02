targetScope = 'tenant'

func stripDigits(value string) string => replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(value, '0', ''), '1', ''), '2', ''), '3', ''), '4', ''), '5', ''), '6', ''), '7', ''), '8', ''), '9', '')
func stripHex(value string) string => replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(toLower(value), '0', ''), '1', ''), '2', ''), '3', ''), '4', ''), '5', ''), '6', ''), '7', ''), '8', ''), '9', ''), 'a', ''), 'b', ''), 'c', ''), 'd', ''), 'e', ''), 'f', '')
func isGuid(value string) bool => length(value) == 36 ? substring(value, 8, 1) == '-' && substring(value, 13, 1) == '-' && substring(value, 18, 1) == '-' && substring(value, 23, 1) == '-' && length(replace(value, '-', '')) == 32 && empty(stripHex(replace(value, '-', ''))) : false
func isIpv4(value string) bool => length(split(value, '.')) == 4 && value == trim(value) && !empty(value) && empty(filter(split(value, '.'), octet => empty(octet) || !empty(stripDigits(octet)) || int(octet) > 255))
func isIpv4Cidr(value string) bool => length(split(value, '/')) == 2 && isIpv4(first(split(value, '/'))) && !empty(last(split(value, '/'))) && empty(stripDigits(last(split(value, '/')))) && int(last(split(value, '/'))) >= 0 && int(last(split(value, '/'))) <= 32
func isResourceId(value string, resourceType string) bool => length(split(value, '/')) == 9 && toLower(split(value, '/')[1]) == 'subscriptions' && isGuid(split(value, '/')[2]) && toLower(split(value, '/')[3]) == 'resourcegroups' && !empty(trim(split(value, '/')[4])) && toLower(split(value, '/')[5]) == 'providers' && toLower(split(value, '/')[6]) == 'microsoft.network' && toLower(split(value, '/')[7]) == toLower(resourceType) && !empty(trim(split(value, '/')[8])) && value == trim(value)

@description('Azure region used only to store tenant deployment metadata.')
param deploymentLocation string = 'eastus'

@description('Existing tenant-root management group ID. The demo root is created below it.')
@minLength(1)
param tenantRootManagementGroupId string

@description('Unique lowercase prefix used for every demo management group.')
@minLength(3)
@maxLength(24)
param namePrefix string

@description('Display name for the dedicated demo root management group.')
@minLength(3)
param demoRootDisplayName string = 'Enterprise-Scale Demo'

@description('Select the workload landing-zone archetype.')
@allowed([
  'corp'
  'online'
])
param workloadArchetype string = 'corp'

@description('Existing sandbox subscription placed under Platform/Connectivity.')
param connectivitySubscriptionId string

@description('Existing sandbox subscription placed under Landing Zones/Corp or Online.')
param workloadSubscriptionId string

@description('Object ID of an existing Entra security group for governance administrators.')
param governanceAdminsGroupObjectId string

@description('Object ID of an existing Entra security group for network operators.')
param networkOperatorsGroupObjectId string

@description('Object ID of an existing Entra security group for workload contributors.')
param workloadContributorsGroupObjectId string

@description('Object ID of an existing Entra security group for read-only auditors.')
param readOnlyAuditorsGroupObjectId string

@description('Enforcement mode for deny policy assignments. Keep DoNotEnforce for first deployment.')
@allowed([
  'Default'
  'DoNotEnforce'
])
param denyPolicyEnforcementMode string = 'DoNotEnforce'

@description('Effect for workload public-management-ingress and subnet-NSG controls. Keep Audit until policy impact and exemptions are reviewed.')
@allowed([
  'Audit'
  'Deny'
  'Disabled'
])
param networkIngressPolicyEffect string = 'Audit'

@description('Effect for selected PaaS public-network-access controls. Keep Audit until private endpoint and DNS dependencies are verified.')
@allowed([
  'Audit'
  'Deny'
  'Disabled'
])
param privateAccessPublicNetworkPolicyEffect string = 'Audit'

@description('PaaS service categories evaluated for private access. Supported values: Storage and KeyVault.')
param privateAccessServiceCategories array = [
  'Storage'
  'KeyVault'
]

@description('Set true only after supplying approved firewall and route-table architecture inputs. This enables audit-only route validation.')
param enableFirewallRouteGuardrails bool = false

@description('Resource ID of the customer-approved Azure Firewall. Required when enableFirewallRouteGuardrails is true; no value is inferred.')
param approvedFirewallResourceId string = ''

@description('Private IP of the customer-approved Azure Firewall virtual appliance. Required when enableFirewallRouteGuardrails is true.')
param approvedFirewallPrivateIp string = ''

@description('Resource IDs of route tables to validate. Required when enableFirewallRouteGuardrails is true.')
param approvedRouteTableResourceIds array = []

@description('CIDR prefixes that approved route tables must direct to the approved firewall private IP. Required when enableFirewallRouteGuardrails is true.')
param approvedRouteTablePrefixes array = []

@description('Continental-US Azure regions allowed by the demo policy.')
param allowedLocations array = [
  'centralus'
  'eastus'
  'eastus2'
  'northcentralus'
  'southcentralus'
  'westcentralus'
  'westus'
  'westus2'
  'westus3'
]

@description('Change-controlled customer-control region allowlist. This does not replace the broader safe demo allowedLocations profile.')
param customerAllowedLocations array = [
  'eastus'
  'eastus2'
]

@description('Change-controlled customer-control resource-type allowlist. Keep required diagnostics, extensions, private endpoint, backup, and policy-remediation child types before enforcement.')
param customerAllowedResourceTypes array = [
  'Microsoft.Authorization/policyDefinitions'
  'Microsoft.Authorization/policyExemptions'
  'Microsoft.Authorization/policyAssignments'
  'Microsoft.Authorization/policySetDefinitions'
  'Microsoft.Authorization/roleAssignments'
  'Microsoft.Compute/disks'
  'Microsoft.Compute/virtualMachines'
  'Microsoft.Compute/virtualMachines/extensions'
  'Microsoft.Insights/diagnosticSettings'
  'Microsoft.ManagedIdentity/userAssignedIdentities'
  'Microsoft.Network/networkInterfaces'
  'Microsoft.Network/networkSecurityGroups'
  'Microsoft.Network/privateDnsZones'
  'Microsoft.Network/privateDnsZones/virtualNetworkLinks'
  'Microsoft.Network/privateEndpoints'
  'Microsoft.Network/privateEndpoints/privateDnsZoneGroups'
  'Microsoft.Network/publicIPAddresses'
  'Microsoft.Network/virtualNetworks'
  'Microsoft.Network/virtualNetworks/subnets'
  'Microsoft.OperationalInsights/workspaces'
  'Microsoft.OperationsManagement/solutions'
  'Microsoft.PolicyInsights/remediations'
  'Microsoft.RecoveryServices/vaults'
  'Microsoft.RecoveryServices/vaults/backupFabrics'
  'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers'
  'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/protectedItems'
  'Microsoft.RecoveryServices/vaults/backupPolicies'
  'Microsoft.Resources/deployments'
  'Microsoft.Resources/resourceGroups'
  'Microsoft.SecurityInsights/onboardingStates'
]

@description('Change-controlled customer-control virtual machine size SKU allowlist.')
param customerAllowedVmSkus array = [
  'Standard_B1ls'
  'Standard_B1s'
  'Standard_B1ms'
  'Standard_B2s'
  'Standard_B2ms'
]

@description('Set true only after reviewing the RBAC matrix and what-if.')
param deployRoleAssignments bool = false

@description('Set true to create no-hourly-charge evidence resource groups, a VNet, and an NSG.')
param deployEvidenceResources bool = false

@description('Region for optional VNet/NSG evidence resources.')
@allowed([
  'centralus'
  'eastus'
  'eastus2'
  'northcentralus'
  'southcentralus'
  'westcentralus'
  'westus'
  'westus2'
  'westus3'
])
param evidenceLocation string = 'eastus2'

@description('Set true to create a new central Log Analytics workspace in the connectivity subscription. Leave false (default); supply an existing workspace via existingLogAnalyticsWorkspaceResourceId instead. Creating a workspace introduces ongoing data-ingestion and retention charges.')
param deployCentralLogAnalytics bool = false

@description('Set true to enable Microsoft Sentinel on the effective central monitoring workspace. Sentinel adds per-GB analysis charges on top of Log Analytics ingestion cost.')
param deploySentinel bool = false

@description('Resource ID of an existing customer-owned Log Analytics workspace to reuse as the effective monitoring workspace. This is the default integration path and must not be set at the same time as deployCentralLogAnalytics=true.')
param existingLogAnalyticsWorkspaceResourceId string = ''

@description('Region for a newly created central Log Analytics workspace, restricted to the same continental-US allowlist as evidenceLocation to stay within this demo policy and cost scope. Ignored when reusing an existing workspace.')
@allowed([
  'centralus'
  'eastus'
  'eastus2'
  'northcentralus'
  'southcentralus'
  'westcentralus'
  'westus'
  'westus2'
  'westus3'
])
param centralMonitoringLocation string = 'eastus2'

@description('Data retention in days for a newly created central Log Analytics workspace. Longer retention increases storage cost.')
@minValue(30)
@maxValue(730)
param centralLogAnalyticsRetentionInDays int = 30

@description('Daily ingestion cap in GB for a newly created central Log Analytics workspace. -1 disables the cap (cost risk); set a small positive value to bound demo ingestion cost.')
param centralLogAnalyticsDailyQuotaGb int = -1

@description('Set true to create the opt-in Critical Infrastructure management group under Landing Zones.')
param enableCriticalInfrastructure bool = false

@description('Existing critical-workload subscription IDs to associate with the Critical Infrastructure branch. Only used when enableCriticalInfrastructure is true.')
param criticalInfrastructureSubscriptionIds array = []

var invalidPrivateAccessServiceCategories = filter(privateAccessServiceCategories, serviceCategory => !(serviceCategory == 'Storage' || serviceCategory == 'KeyVault'))
var validatedPrivateAccessServiceCategories = empty(privateAccessServiceCategories) || !empty(invalidPrivateAccessServiceCategories) || length(privateAccessServiceCategories) != length(union(privateAccessServiceCategories, []))
  ? fail('privateAccessServiceCategories must contain non-empty, uniquely cased Storage and/or KeyVault values.')
  : privateAccessServiceCategories
var invalidApprovedRouteTableResourceIds = filter(approvedRouteTableResourceIds, routeTableResourceId => !isResourceId(routeTableResourceId, 'routeTables'))
var normalizedApprovedRouteTableResourceIds = [for routeTableResourceId in approvedRouteTableResourceIds: toLower(routeTableResourceId)]
var invalidApprovedRouteTablePrefixes = filter(approvedRouteTablePrefixes, routeTablePrefix => !isIpv4Cidr(routeTablePrefix))
var normalizedApprovedRouteTablePrefixes = [for routeTablePrefix in approvedRouteTablePrefixes: toLower(routeTablePrefix)]
var firewallRouteInputsValid = isResourceId(approvedFirewallResourceId, 'azureFirewalls') && isIpv4(approvedFirewallPrivateIp) && !empty(approvedRouteTableResourceIds) && empty(invalidApprovedRouteTableResourceIds) && length(normalizedApprovedRouteTableResourceIds) == length(union(normalizedApprovedRouteTableResourceIds, [])) && !empty(approvedRouteTablePrefixes) && empty(invalidApprovedRouteTablePrefixes) && length(normalizedApprovedRouteTablePrefixes) == length(union(normalizedApprovedRouteTablePrefixes, []))
var validatedFirewallRouteInputs = enableFirewallRouteGuardrails && !firewallRouteInputsValid
  ? fail('approvedFirewallResourceId must be an Azure Firewall resource ID, approvedFirewallPrivateIp must be an IPv4 address, and approvedRouteTableResourceIds and approvedRouteTablePrefixes must contain non-empty, valid, case-insensitively unique route-table IDs and IPv4 CIDRs when enableFirewallRouteGuardrails is true.')
  : true

@description('Assign the stable Microsoft cloud security benchmark (MCSB) initiative at the demo root. Enabled by default for the customer-control profile. The separate Microsoft cloud security benchmark v2 preview initiative is never assigned by this template.')
param enableMicrosoftCloudSecurityBenchmark bool = true

@description('Set true to add the optional CIS Microsoft Azure Foundations Benchmark v2.0.0 overlay at the demo root. Independent of the MCSB and NIST switches; assignment alone does not establish CIS compliance.')
param enableCisAzureFoundationsBenchmark bool = false

@description('Set true to add the optional NIST SP 800-53 Rev. 5 overlay at the demo root. This initiative contains four fixed Guest Configuration DeployIfNotExists/Modify members, so the assignment needs a system-assigned identity with the Contributor role; assignment alone does not establish NIST compliance.')
param enableNistSp80053Rev5 bool = false

@description('Set true to opt in to Microsoft Defender CSPM (REQ-DEF-02), including CIEM findings. Paid Defender plan with its own licensing cost. Defaults to false: effect stays Disabled and no managed identity is created. Setting true creates a SystemAssigned identity but this template never grants it a role; see modules/defender-plan-assignment.bicep and docs/CONTROL-MATRIX.md for the fail-closed, no-standing-Owner remediation workflow required before the built-in policy can actually remediate anything.')
param enableDefenderCspm bool = false

@description('Only applies when enableDefenderCspm is true. Explicit toggle for the Defender CSPM plan\'s Entra Permissions Management (CIEM) extension, called out by name in issue #20. Defaults to true, matching the built-in\'s own verified default; set false to opt the CSPM plan in without CIEM.')
param enableDefenderCiem bool = true

@description('Set true to opt in to Microsoft Defender for Servers (REQ-DEF-03) on the Landing Zones branch. Paid Defender plan with its own licensing cost. Defaults to false: effect stays Disabled and no managed identity is created. Setting true creates a SystemAssigned identity but this template never grants it a role. This assignment explicitly configures the sub-plan and agentless-scanning extension via defenderForServersSubPlan/defenderForServersAgentlessVmScanningEnabled below rather than silently inheriting the built-in\'s own defaults. See the unconditional Azure Monitor Agent audit assignments below (REQ-DEF-07/08) for a free, no-identity audit of current (non-deprecated) agent presence.')
param enableDefenderForServers bool = false

@description('Only applies when enableDefenderForServers is true. Explicit Defender for Servers sub-plan choice (P1 or P2) passed to the built-in. Defaults to P2, matching the built-in\'s own verified default; P1 is the lower-cost sub-plan and does not support agentless VM scanning.')
@allowed([
  'P1'
  'P2'
])
param defenderForServersSubPlan string = 'P2'

@description('Only applies when enableDefenderForServers is true and defenderForServersSubPlan is P2, per the built-in\'s own existence condition. Explicit toggle for the Defender for Servers plan\'s agentless VM scanning extension. Defaults to true, matching the built-in\'s own verified default.')
param defenderForServersAgentlessVmScanningEnabled bool = true

@description('Set true to opt in to Microsoft Defender for Storage (REQ-DEF-04) on the Landing Zones branch. Paid Defender plan with its own licensing cost. Defaults to false: effect stays Disabled and no managed identity is created. Setting true creates a SystemAssigned identity but this template never grants it a role.')
param enableDefenderForStorage bool = false

@description('Only applies when enableDefenderForStorage is true. Explicit, separate opt-in for the Defender for Storage plan\'s on-upload malware-scanning extension -- an additional metered, per-GB feature distinct from the base plan\'s own cost. Defaults to false (disabled) even though the built-in\'s own verified default is true, so enabling the Storage plan alone never silently enables this additional metered feature; a customer must separately approve it here.')
param enableDefenderStorageMalwareScanning bool = false

@description('Only applies when enableDefenderStorage is true and enableDefenderStorageMalwareScanning is true. Monthly GB cap per storage account for the malware-scanning extension. Defaults to 10000, matching the built-in\'s own verified default; only meaningful once malware scanning is separately approved above.')
param defenderStorageMalwareScanningCapGBPerMonthPerStorageAccount int = 10000



var demoRootManagementGroupId = namePrefix
var platformManagementGroupId = '${namePrefix}-platform'
var connectivityManagementGroupId = '${namePrefix}-connectivity'
var landingZonesManagementGroupId = '${namePrefix}-landingzones'
var workloadManagementGroupId = '${namePrefix}-${workloadArchetype}'
var criticalInfrastructureManagementGroupId = '${namePrefix}-criticalinfra'
var requireResourceGroupTagPolicyDefinitionId = tenantResourceId(
  'Microsoft.Authorization/policyDefinitions',
  '96670d01-0a4d-4649-9c89-2d3abc0a5025'
)
var microsoftCloudSecurityBenchmarkPolicySetDefinitionId = tenantResourceId(
  'Microsoft.Authorization/policySetDefinitions',
  '1f3afdf9-d0c9-4c3d-847f-89da613e70a8'
)
var cisAzureFoundationsPolicySetDefinitionId = tenantResourceId(
  'Microsoft.Authorization/policySetDefinitions',
  '06f19060-9e68-4070-92ca-f15cc126059e'
)
var nistSp80053Rev5PolicySetDefinitionId = tenantResourceId(
  'Microsoft.Authorization/policySetDefinitions',
  '179d1daa-458f-4e47-8086-2a68d0d6c38f'
)
var contributorRoleDefinitionId = 'b24988ac-6180-42a0-ab88-20f7382dd24c'

module hierarchy 'modules/hierarchy.bicep' = {
  name: 'hierarchy-${uniqueString(namePrefix)}'
  params: {
    tenantRootManagementGroupId: tenantRootManagementGroupId
    demoRootManagementGroupId: demoRootManagementGroupId
    demoRootDisplayName: demoRootDisplayName
    platformManagementGroupId: platformManagementGroupId
    connectivityManagementGroupId: connectivityManagementGroupId
    landingZonesManagementGroupId: landingZonesManagementGroupId
    workloadManagementGroupId: workloadManagementGroupId
    workloadArchetype: workloadArchetype
    connectivitySubscriptionId: connectivitySubscriptionId
    workloadSubscriptionId: workloadSubscriptionId
    enableCriticalInfrastructure: enableCriticalInfrastructure
    criticalInfrastructureManagementGroupId: criticalInfrastructureManagementGroupId
    criticalInfrastructureSubscriptionIds: criticalInfrastructureSubscriptionIds
  }
}

module policyLibrary 'modules/policy-library.bicep' = {
  name: 'policy-library-${uniqueString(namePrefix)}'
  scope: managementGroup(demoRootManagementGroupId)
  params: {
    namePrefix: namePrefix
  }
  dependsOn: [
    hierarchy
  ]
}

module resourceGroupTagsInitiative 'modules/policy-initiative.bicep' = {
  name: 'resource-group-tags-initiative'
  scope: managementGroup(demoRootManagementGroupId)
  params: {
    initiativeName: '${namePrefix}-required-rg-tags'
    initiativeDisplayName: 'Demo - required resource group tags'
    initiativeDescription: 'Requires the six customer governance tags on resource groups.'
    initiativeCategory: 'Tags'
    initiativeVersion: '2.0.0'
    policyDefinitionReferences: [
      {
        policyDefinitionId: requireResourceGroupTagPolicyDefinitionId
        definitionVersion: '1.*.*'
        policyDefinitionReferenceId: 'require-cost-center'
        parameters: {
          tagName: {
            value: 'CostCenter'
          }
        }
        groupNames: []
      }
      {
        policyDefinitionId: requireResourceGroupTagPolicyDefinitionId
        definitionVersion: '1.*.*'
        policyDefinitionReferenceId: 'require-application-name'
        parameters: {
          tagName: {
            value: 'ApplicationName'
          }
        }
        groupNames: []
      }
      {
        policyDefinitionId: requireResourceGroupTagPolicyDefinitionId
        definitionVersion: '1.*.*'
        policyDefinitionReferenceId: 'require-owner'
        parameters: {
          tagName: {
            value: 'Owner'
          }
        }
        groupNames: []
      }
      {
        policyDefinitionId: requireResourceGroupTagPolicyDefinitionId
        definitionVersion: '1.*.*'
        policyDefinitionReferenceId: 'require-environment'
        parameters: {
          tagName: {
            value: 'Environment'
          }
        }
        groupNames: []
      }
      {
        policyDefinitionId: requireResourceGroupTagPolicyDefinitionId
        definitionVersion: '1.*.*'
        policyDefinitionReferenceId: 'require-data-classification'
        parameters: {
          tagName: {
            value: 'DataClassification'
          }
        }
        groupNames: []
      }
      {
        policyDefinitionId: requireResourceGroupTagPolicyDefinitionId
        definitionVersion: '1.*.*'
        policyDefinitionReferenceId: 'require-ssp-id'
        parameters: {
          tagName: {
            value: 'SSP-ID'
          }
        }
        groupNames: []
      }
    ]
  }
  dependsOn: [
    hierarchy
  ]
}

module allowedLocationsAssignment 'modules/policy-assignment.bicep' = {
  name: 'assign-allowed-locations'
  scope: managementGroup(demoRootManagementGroupId)
  params: {
    assignmentName: 'demo-allowed-us-locs'
    displayName: 'Demo - allowed continental-US locations'
    description: 'Restricts regional resources to the approved continental-US list while safely allowing global resources.'
    policyDefinitionId: policyLibrary.outputs.allowedLocationsPolicyDefinitionId
    enforcementMode: denyPolicyEnforcementMode
    parameters: {
      allowedLocations: {
        value: allowedLocations
      }
    }
  }
}

module auditPublicIpAssignment 'modules/policy-assignment.bicep' = {
  name: 'assign-audit-public-ip'
  scope: managementGroup(demoRootManagementGroupId)
  params: {
    assignmentName: 'demo-audit-public-ip'
    displayName: 'Demo - audit public IP resources'
    description: 'Audits public IP address resources anywhere in the demo hierarchy.'
    policyDefinitionId: policyLibrary.outputs.auditPublicIpPolicyDefinitionId
    enforcementMode: 'Default'
    parameters: {}
  }
}

module rootDeploymentRestrictions 'modules/root-deployment-restrictions.bicep' = {
  name: 'root-deployment-restrictions'
  scope: managementGroup(demoRootManagementGroupId)
  params: {
    namePrefix: namePrefix
    auditPublicIpPolicyDefinitionId: policyLibrary.outputs.auditPublicIpPolicyDefinitionId
    allowedResourceTypesPolicyDefinitionId: policyLibrary.outputs.allowedResourceTypesAllPolicyDefinitionId
    allowedLocations: customerAllowedLocations
    allowedResourceTypes: customerAllowedResourceTypes
    allowedVmSkus: customerAllowedVmSkus
    enforcementMode: denyPolicyEnforcementMode
  }
}

module networkIngressInitiative 'modules/policy-initiative.bicep' = {
  name: 'network-ingress-initiative'
  scope: managementGroup(demoRootManagementGroupId)
  params: {
    initiativeName: '${namePrefix}-network-ingress'
    initiativeDisplayName: 'Demo - workload network ingress guardrails'
    initiativeDescription: 'Audits public RDP/SSH NSG rules and workload subnets without NSGs; deny remains opt-in and non-enforcing by default.'
    initiativeCategory: 'Network'
    initiativeVersion: '1.0.0'
    initiativeParameters: {
      effect: {
        type: 'String'
        metadata: {
          displayName: 'Network ingress effect'
          description: 'Audit is the safe default. Select Deny only after reviewing approved management paths and exemptions.'
        }
        allowedValues: [
          'Audit'
          'Deny'
          'Disabled'
        ]
        defaultValue: 'Audit'
      }
    }
    policyDefinitionGroups: [
      {
        name: 'workload-boundary'
        displayName: 'Workload boundary'
        category: 'Network'
        description: 'Controls applied only to the selected Corp or Online workload branch.'
      }
    ]
    policyDefinitionReferences: [
      {
        policyDefinitionId: policyLibrary.outputs.publicManagementIngressPolicyDefinitionId
        policyDefinitionReferenceId: 'public-management-ingress'
        parameters: {
          effect: {
            value: '[parameters(\'effect\')]'
          }
        }
        groupNames: [
          'workload-boundary'
        ]
      }
      {
        policyDefinitionId: policyLibrary.outputs.requireSubnetNsgPolicyDefinitionId
        policyDefinitionReferenceId: 'require-subnet-nsg'
        parameters: {
          effect: {
            value: '[parameters(\'effect\')]'
          }
        }
        groupNames: [
          'workload-boundary'
        ]
      }
    ]
  }
}

module networkIngressAssignment 'modules/policy-assignment.bicep' = {
  name: 'assign-network-ingress'
  scope: managementGroup(workloadManagementGroupId)
  params: {
    assignmentName: 'demo-network-ingress'
    displayName: 'Demo - workload network ingress guardrails'
    description: 'Audits public management ingress and missing subnet NSGs in the selected workload branch.'
    policyDefinitionId: networkIngressInitiative.outputs.policySetDefinitionId
    enforcementMode: denyPolicyEnforcementMode
    parameters: {
      effect: {
        value: networkIngressPolicyEffect
      }
    }
    nonComplianceMessages: [
      {
        message: 'Public inbound TCP access to SSH (22) or RDP (3389) is not approved. Use a private approved management path or obtain a governed exemption.'
        policyDefinitionReferenceId: 'public-management-ingress'
      }
      {
        message: 'Workload subnets require an NSG association. Document platform constraints and obtain a governed exemption when an NSG is unsupported.'
        policyDefinitionReferenceId: 'require-subnet-nsg'
      }
    ]
  }
  dependsOn: [
    hierarchy
  ]
}

module privateAccessInitiative 'modules/policy-initiative.bicep' = {
  name: 'private-access-initiative'
  scope: managementGroup(demoRootManagementGroupId)
  params: {
    initiativeName: '${namePrefix}-private-access'
    initiativeDisplayName: 'Demo - workload private access guardrails'
    initiativeDescription: 'Audits selected PaaS public network access and private endpoint readiness; public access denial is an explicit later option.'
    initiativeCategory: 'Network'
    initiativeVersion: '1.0.0'
    initiativeParameters: {
      publicNetworkAccessEffect: {
        type: 'String'
        metadata: {
          displayName: 'Public network access effect'
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
        }
        defaultValue: [
          'Storage'
          'KeyVault'
        ]
      }
    }
    policyDefinitionGroups: [
      {
        name: 'private-access'
        displayName: 'Private access'
        category: 'Network'
        description: 'Workload and critical-infrastructure private access posture.'
      }
    ]
    policyDefinitionReferences: [
      {
        policyDefinitionId: policyLibrary.outputs.privateAccessPublicNetworkPolicyDefinitionId
        policyDefinitionReferenceId: 'paas-public-network-access'
        parameters: {
          effect: {
            value: '[parameters(\'publicNetworkAccessEffect\')]'
          }
          serviceCategories: {
            value: '[parameters(\'serviceCategories\')]'
          }
        }
        groupNames: [
          'private-access'
        ]
      }
      {
        policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/6edd7eda-6dd8-40f7-810d-67160c639cd9'
        policyDefinitionReferenceId: 'storage-private-link'
        definitionVersion: '2.*.*'
        parameters: {}
        groupNames: [
          'private-access'
        ]
      }
      {
        policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/a6abeaec-4d90-4a02-805f-6b26c4d3fbe9'
        policyDefinitionReferenceId: 'key-vault-private-link'
        definitionVersion: '1.*.*'
        parameters: {
          audit_effect: {
            value: 'Audit'
          }
        }
        groupNames: [
          'private-access'
        ]
      }
    ]
  }
}

module privateAccessWorkloadAssignment 'modules/policy-assignment.bicep' = {
  name: 'assign-private-access-workload'
  scope: managementGroup(workloadManagementGroupId)
  params: {
    assignmentName: 'demo-private-access'
    displayName: 'Demo - workload private access guardrails'
    description: 'Audits workload PaaS public access and private endpoint readiness.'
    policyDefinitionId: privateAccessInitiative.outputs.policySetDefinitionId
    enforcementMode: denyPolicyEnforcementMode
    parameters: {
      publicNetworkAccessEffect: {
        value: privateAccessPublicNetworkPolicyEffect
      }
      serviceCategories: {
        value: validatedPrivateAccessServiceCategories
      }
    }
  }
  dependsOn: [
    hierarchy
  ]
}

module privateAccessCriticalAssignment 'modules/policy-assignment.bicep' = if (enableCriticalInfrastructure) {
  name: 'assign-private-access-critical'
  scope: managementGroup(criticalInfrastructureManagementGroupId)
  params: {
    assignmentName: 'demo-critical-private'
    displayName: 'Demo - critical private access guardrails'
    description: 'Audits critical PaaS public access and private endpoint readiness.'
    policyDefinitionId: privateAccessInitiative.outputs.policySetDefinitionId
    enforcementMode: denyPolicyEnforcementMode
    parameters: {
      publicNetworkAccessEffect: {
        value: privateAccessPublicNetworkPolicyEffect
      }
      serviceCategories: {
        value: validatedPrivateAccessServiceCategories
      }
    }
  }
  dependsOn: [
    hierarchy
  ]
}

module firewallRouteWorkloadAssignment 'modules/policy-assignment.bicep' = if (enableFirewallRouteGuardrails) {
  name: 'assign-firewall-routes-workload'
  scope: managementGroup(workloadManagementGroupId)
  params: {
    assignmentName: 'demo-firewall-routes'
    displayName: 'Demo - workload approved firewall routes'
    description: 'Audits supplied workload route-table expectations against the approved firewall private IP.'
    policyDefinitionId: policyLibrary.outputs.approvedFirewallRoutesPolicyDefinitionId
    enforcementMode: 'Default'
    parameters: {
      approvedFirewallPrivateIp: {
        value: validatedFirewallRouteInputs ? approvedFirewallPrivateIp : approvedFirewallPrivateIp
      }
      approvedFirewallResourceId: {
        value: approvedFirewallResourceId
      }
      approvedRouteTableResourceIds: {
        value: approvedRouteTableResourceIds
      }
      approvedRouteTablePrefixes: {
        value: approvedRouteTablePrefixes
      }
    }
  }
  dependsOn: [
    hierarchy
  ]
}

module firewallRouteCriticalAssignment 'modules/policy-assignment.bicep' = if (enableFirewallRouteGuardrails && enableCriticalInfrastructure) {
  name: 'assign-firewall-routes-critical'
  scope: managementGroup(criticalInfrastructureManagementGroupId)
  params: {
    assignmentName: 'demo-critical-fw-routes'
    displayName: 'Demo - critical approved firewall routes'
    description: 'Audits supplied critical route-table expectations against the approved firewall private IP.'
    policyDefinitionId: policyLibrary.outputs.approvedFirewallRoutesPolicyDefinitionId
    enforcementMode: 'Default'
    parameters: {
      approvedFirewallPrivateIp: {
        value: validatedFirewallRouteInputs ? approvedFirewallPrivateIp : approvedFirewallPrivateIp
      }
      approvedFirewallResourceId: {
        value: approvedFirewallResourceId
      }
      approvedRouteTableResourceIds: {
        value: approvedRouteTableResourceIds
      }
      approvedRouteTablePrefixes: {
        value: approvedRouteTablePrefixes
      }
    }
  }
  dependsOn: [
    hierarchy
  ]
}

module expensiveResourcesAssignment 'modules/policy-assignment.bicep' = {
  name: 'assign-expensive-resources'
  scope: managementGroup(demoRootManagementGroupId)
  params: {
    assignmentName: 'demo-block-expensive'
    displayName: 'Demo - block common expensive resources and VM SKUs'
    description: 'Blocks selected high-cost service types and restricts VM sizes to a small demo allowlist.'
    policyDefinitionId: policyLibrary.outputs.expensiveResourcesPolicyDefinitionId
    enforcementMode: denyPolicyEnforcementMode
    parameters: {}
  }
}

module platformTagsAssignment 'modules/policy-assignment.bicep' = {
  name: 'assign-platform-tags'
  scope: managementGroup(platformManagementGroupId)
  params: {
    assignmentName: 'demo-audit-platform-tags'
    displayName: 'Demo - audit platform tags'
    description: 'Audits Owner and CostCenter tags on taggable resources in the Platform branch.'
    policyDefinitionId: policyLibrary.outputs.platformTagsPolicyDefinitionId
    enforcementMode: 'Default'
    parameters: {}
  }
  dependsOn: [
    hierarchy
  ]
}

module resourceGroupTagsAssignment 'modules/policy-assignment.bicep' = {
  name: 'assign-resource-group-tags'
  scope: managementGroup(landingZonesManagementGroupId)
  params: {
    assignmentName: 'demo-require-rg-tags'
    displayName: 'Demo - require resource group tags'
    description: 'Requires CostCenter, ApplicationName, Owner, Environment, DataClassification, and SSP-ID tags on landing-zone resource groups.'
    policyDefinitionId: resourceGroupTagsInitiative.outputs.policySetDefinitionId
    enforcementMode: denyPolicyEnforcementMode
    parameters: {}
    nonComplianceMessages: [
      {
        message: 'Resource groups must include the CostCenter tag.'
        policyDefinitionReferenceId: 'require-cost-center'
      }
      {
        message: 'Resource groups must include the ApplicationName tag.'
        policyDefinitionReferenceId: 'require-application-name'
      }
      {
        message: 'Resource groups must include the Owner tag.'
        policyDefinitionReferenceId: 'require-owner'
      }
      {
        message: 'Resource groups must include the Environment tag.'
        policyDefinitionReferenceId: 'require-environment'
      }
      {
        message: 'Resource groups must include the DataClassification tag.'
        policyDefinitionReferenceId: 'require-data-classification'
      }
      {
        message: 'Resource groups must include the SSP-ID tag.'
        policyDefinitionReferenceId: 'require-ssp-id'
      }
    ]
  }
  dependsOn: [
    hierarchy
  ]
}

// REQ-DEF-02/03/04 (Microsoft Defender CSPM, for Servers, and for Storage)
// are independent, explicit, safe-by-default (false) opt-ins per issue #20.
// Their only verified remediation role is Owner, and a single management-
// group-scoped identity inherited across every descendant subscription is
// too broad a blast radius for a standing grant (this repository's shared
// RBAC modules never auto-grant Owner/User Access Administrator; see
// modules/remediating-policy-assignment.bicep). modules/defender-plan-
// assignment.bicep therefore never assigns a role to the identity it
// creates when a plan is opted in: fail closed instead, so normal
// deployment of this template -- opted in or not -- can never create or
// leave standing Owner access anywhere. See modules/defender-plan-
// assignment.bicep and docs/CONTROL-MATRIX.md for the fail-closed,
// time-bounded remediation workflow a customer must run separately, outside
// this template, before the built-in policy can actually remediate.
var vulnerabilityAssessmentAuditPolicyDefinitionId = tenantResourceId('Microsoft.Authorization/policyDefinitions', '501541f7-f7e7-4cd6-868c-4190fdad3ac9')
var windowsAmaAuditPolicyDefinitionId = tenantResourceId('Microsoft.Authorization/policyDefinitions', 'c02729e5-e5e7-4458-97fa-2b5ad0661f28')
var linuxAmaAuditPolicyDefinitionId = tenantResourceId('Microsoft.Authorization/policyDefinitions', '1afdc4b6-581a-45fb-b630-f1e6051e3e7a')

module defenderCspmAssignment 'modules/defender-plan-assignment.bicep' = {
  name: 'assign-defender-cspm'
  scope: managementGroup(demoRootManagementGroupId)
  params: {
    assignmentName: 'demo-defender-cspm'
    displayName: 'Demo - Microsoft Defender CSPM (opt-in, paid)'
    description: 'Microsoft Defender CSPM (REQ-DEF-02), including CIEM findings. Defaults Disabled with no managed identity; enableDefenderCspm opts in per plan. This template never grants the resulting identity any role -- remediation requires a separate, customer-run, time-bounded authorization outside this template. The plan\'s Entra Permissions Management (CIEM) extension is explicitly wired to enableDefenderCiem rather than silently inheriting the built-in\'s own default.'
    plan: 'cspm'
    enablePlan: enableDefenderCspm
    cspmEntraPermissionsManagementEnabled: enableDefenderCiem
    location: deploymentLocation
  }
  dependsOn: [
    hierarchy
  ]
}

module defenderForServersAssignment 'modules/defender-plan-assignment.bicep' = {
  name: 'assign-defender-servers'
  scope: managementGroup(landingZonesManagementGroupId)
  params: {
    assignmentName: 'demo-defender-servers'
    displayName: 'Demo - Microsoft Defender for Servers (opt-in, paid)'
    description: 'Microsoft Defender for Servers (REQ-DEF-03) on the Landing Zones branch. Defaults Disabled, no managed identity; enableDefenderForServers opts in. Never grants the resulting identity a role. Explicitly configures the sub-plan (defenderForServersSubPlan, default P2) and agentless VM scanning extension (defenderForServersAgentlessVmScanningEnabled, default true) rather than silently inheriting the built-in\'s own defaults. See REQ-DEF-07/08 for a free, no-identity audit of current agent presence.'
    plan: 'servers'
    enablePlan: enableDefenderForServers
    serversSubPlan: defenderForServersSubPlan
    serversAgentlessVmScanningEnabled: defenderForServersAgentlessVmScanningEnabled
    location: deploymentLocation
  }
  dependsOn: [
    hierarchy
  ]
}

module defenderForStorageAssignment 'modules/defender-plan-assignment.bicep' = {
  name: 'assign-defender-storage'
  scope: managementGroup(landingZonesManagementGroupId)
  params: {
    assignmentName: 'demo-defender-storage'
    displayName: 'Demo - Microsoft Defender for Storage (opt-in, paid)'
    description: 'Microsoft Defender for Storage (REQ-DEF-04) on the Landing Zones branch. Defaults Disabled with no managed identity; enableDefenderForStorage opts in. Never grants the resulting identity any role -- remediation requires a separate, time-bounded authorization outside this template. On-upload malware scanning, an additional metered extension, requires its own separate enableDefenderStorageMalwareScanning opt-in (default false).'
    plan: 'storage'
    enablePlan: enableDefenderForStorage
    storageOnUploadMalwareScanningEnabled: enableDefenderStorageMalwareScanning
    storageCapGBPerMonthPerStorageAccount: defenderStorageMalwareScanningCapGBPerMonthPerStorageAccount
    location: deploymentLocation
  }
  dependsOn: [
    hierarchy
  ]
}

module vulnerabilityAssessmentAuditAssignment 'modules/policy-assignment.bicep' = {
  name: 'assign-vuln-assessment-audit'
  scope: managementGroup(landingZonesManagementGroupId)
  params: {
    assignmentName: 'demo-audit-vuln-assess'
    displayName: 'Demo - audit VM vulnerability assessment'
    description: 'Audits that virtual machines have a supported vulnerability assessment solution enabled (REQ-DEF-06), independent of any paid Defender plan. No-cost audit signal populated by the free, configurable Foundational CSPM tier.'
    policyDefinitionId: vulnerabilityAssessmentAuditPolicyDefinitionId
    definitionVersion: '3.*.*'
    enforcementMode: 'Default'
    parameters: {
      effect: {
        value: 'AuditIfNotExists'
      }
    }
  }
  dependsOn: [
    hierarchy
  ]
}

module defenderAmaAuditWindowsAssignment 'modules/policy-assignment.bicep' = {
  name: 'assign-defender-ama-audit-windows'
  scope: managementGroup(landingZonesManagementGroupId)
  params: {
    assignmentName: 'demo-audit-ama-windows'
    displayName: 'Demo - audit Windows Azure Monitor Agent presence'
    description: 'Audits that Windows virtual machines have the current, supported Azure Monitor Agent installed (REQ-DEF-07), independent of any paid Defender plan and never the deprecated Log Analytics (MMA) agent (REQ-DEF-05). No-cost, no-identity audit signal; creates no managed identity and deploys nothing.'
    policyDefinitionId: windowsAmaAuditPolicyDefinitionId
    definitionVersion: '3.*.*'
    enforcementMode: 'Default'
    parameters: {
      effect: {
        value: 'AuditIfNotExists'
      }
    }
  }
  dependsOn: [
    hierarchy
  ]
}

module defenderAmaAuditLinuxAssignment 'modules/policy-assignment.bicep' = {
  name: 'assign-defender-ama-audit-linux'
  scope: managementGroup(landingZonesManagementGroupId)
  params: {
    assignmentName: 'demo-audit-ama-linux'
    displayName: 'Demo - audit Linux Azure Monitor Agent presence'
    description: 'Audits that Linux virtual machines have the current, supported Azure Monitor Agent installed (REQ-DEF-08), independent of any paid Defender plan and never the deprecated Log Analytics (MMA) agent (REQ-DEF-05). No-cost, no-identity audit signal; creates no managed identity and deploys nothing.'
    policyDefinitionId: linuxAmaAuditPolicyDefinitionId
    definitionVersion: '3.*.*'
    enforcementMode: 'Default'
    parameters: {
      effect: {
        value: 'AuditIfNotExists'
      }
    }
  }
  dependsOn: [
    hierarchy
  ]
}

module microsoftCloudSecurityBenchmarkAssignment 'modules/policy-assignment.bicep' = if (enableMicrosoftCloudSecurityBenchmark) {
  name: 'assign-mcsb-baseline'
  scope: managementGroup(demoRootManagementGroupId)
  params: {
    assignmentName: 'demo-mcsb-baseline'
    displayName: 'Demo - Microsoft cloud security benchmark'
    description: 'Assigns the stable Microsoft cloud security benchmark initiative as the default security baseline for the demo hierarchy. Assignment alone does not establish regulatory compliance.'
    policyDefinitionId: microsoftCloudSecurityBenchmarkPolicySetDefinitionId
    definitionVersion: '57.*.*'
    enforcementMode: denyPolicyEnforcementMode
    parameters: {}
  }
  dependsOn: [
    hierarchy
  ]
}

module cisAzureFoundationsAssignment 'modules/policy-assignment.bicep' = if (enableCisAzureFoundationsBenchmark) {
  name: 'assign-cis-foundations'
  scope: managementGroup(demoRootManagementGroupId)
  params: {
    assignmentName: 'demo-cis-foundations'
    displayName: 'Demo - CIS Microsoft Azure Foundations Benchmark v2.0.0'
    description: 'Optional CIS Azure Foundations overlay. Overlaps heavily with the Microsoft cloud security benchmark; assignment alone does not establish CIS compliance.'
    policyDefinitionId: cisAzureFoundationsPolicySetDefinitionId
    definitionVersion: '1.*.*'
    enforcementMode: denyPolicyEnforcementMode
    parameters: {}
  }
  dependsOn: [
    hierarchy
  ]
}

module nistSp80053Rev5Assignment 'modules/remediating-policy-assignment.bicep' = if (enableNistSp80053Rev5) {
  name: 'assign-nist-sp-800-53-r5'
  scope: managementGroup(demoRootManagementGroupId)
  params: {
    assignmentName: 'demo-nist-800-53-r5'
    displayName: 'Demo - NIST SP 800-53 Rev. 5'
    description: 'Optional NIST SP 800-53 Rev. 5 overlay. Four fixed Guest Configuration members are remediation-capable, so a system-assigned identity with the Contributor role is required. Assignment alone does not establish NIST or NERC CIP compliance.'
    policyDefinitionId: nistSp80053Rev5PolicySetDefinitionId
    definitionVersion: '14.*.*'
    location: deploymentLocation
    identity: {
      type: 'SystemAssigned'
    }
    verifiedRoleDefinitionIds: [
      contributorRoleDefinitionId
    ]
    enforcementMode: denyPolicyEnforcementMode
    parameters: {}
  }
  dependsOn: [
    hierarchy
  ]
}

module managementGroupRbac 'modules/management-group-rbac.bicep' = if (deployRoleAssignments) {
  name: 'management-group-rbac'
  scope: managementGroup(demoRootManagementGroupId)
  params: {
    governanceAdminsGroupObjectId: governanceAdminsGroupObjectId
    readOnlyAuditorsGroupObjectId: readOnlyAuditorsGroupObjectId
  }
  dependsOn: [
    hierarchy
  ]
}

module connectivityRbac 'modules/subscription-rbac.bicep' = if (deployRoleAssignments) {
  name: 'connectivity-subscription-rbac'
  scope: subscription(connectivitySubscriptionId)
  params: {
    deployOperatorRoleAssignment: deployRoleAssignments
    operatorGroupObjectId: networkOperatorsGroupObjectId
    operatorRoleDefinitionId: '4d97b98b-1d4f-4787-a291-c67834d212e7'
  }
  dependsOn: [
    hierarchy
  ]
}

module workloadRbac 'modules/subscription-rbac.bicep' = if (deployRoleAssignments) {
  name: 'workload-subscription-rbac'
  scope: subscription(workloadSubscriptionId)
  params: {
    deployOperatorRoleAssignment: deployRoleAssignments
    operatorGroupObjectId: workloadContributorsGroupObjectId
    operatorRoleDefinitionId: 'b24988ac-6180-42a0-ab88-20f7382dd24c'
  }
  dependsOn: [
    hierarchy
  ]
}

module connectivityEvidence 'modules/evidence-connectivity.bicep' = if (deployEvidenceResources) {
  name: 'connectivity-evidence'
  scope: subscription(connectivitySubscriptionId)
  params: {
    namePrefix: namePrefix
    location: evidenceLocation
  }
  dependsOn: [
    hierarchy
    platformTagsAssignment
  ]
}

module workloadEvidence 'modules/evidence-workload.bicep' = if (deployEvidenceResources) {
  name: 'workload-evidence'
  scope: subscription(workloadSubscriptionId)
  params: {
    namePrefix: namePrefix
    location: evidenceLocation
    workloadArchetype: workloadArchetype
  }
  dependsOn: [
    hierarchy
    resourceGroupTagsAssignment
  ]
}

module centralMonitoring 'modules/central-monitoring.bicep' = {
  name: 'central-monitoring'
  scope: subscription(connectivitySubscriptionId)
  params: {
    namePrefix: namePrefix
    location: centralMonitoringLocation
    deployCentralLogAnalytics: deployCentralLogAnalytics
    deploySentinel: deploySentinel
    existingLogAnalyticsWorkspaceResourceId: existingLogAnalyticsWorkspaceResourceId
    retentionInDays: centralLogAnalyticsRetentionInDays
    dailyQuotaGb: centralLogAnalyticsDailyQuotaGb
    tags: {
      Owner: 'Platform Team'
      CostCenter: 'Demo'
      Environment: 'Sandbox'
      Purpose: 'Central Monitoring'
    }
  }
  dependsOn: [
    hierarchy
  ]
}

output hierarchy object = {
  demoRoot: demoRootManagementGroupId
  platform: platformManagementGroupId
  connectivity: connectivityManagementGroupId
  landingZones: landingZonesManagementGroupId
  workload: workloadManagementGroupId
  criticalInfrastructure: hierarchy.outputs.criticalInfrastructureManagementGroupId
}
output denyPolicyEnforcementMode string = denyPolicyEnforcementMode
output roleAssignmentsEnabled bool = deployRoleAssignments
output evidenceResourcesEnabled bool = deployEvidenceResources
output criticalInfrastructureEnabled bool = enableCriticalInfrastructure
output securityBenchmarkAssignments object = {
  microsoftCloudSecurityBenchmark: enableMicrosoftCloudSecurityBenchmark
  cisAzureFoundationsBenchmark: enableCisAzureFoundationsBenchmark
  nistSp80053Rev5: enableNistSp80053Rev5
}
output deploymentRegion string = deploymentLocation
output centralMonitoringEffectiveWorkspaceId string = centralMonitoring.outputs.effectiveLogAnalyticsWorkspaceResourceId
output centralMonitoringConflictingInputs bool = centralMonitoring.outputs.conflictingMonitoringInputs
output centralMonitoringSentinelEnabled bool = centralMonitoring.outputs.sentinelEnabled
output defenderCspmPolicyAssignmentId string = defenderCspmAssignment.outputs.policyAssignmentId
output defenderCspmIdentityPrincipalId string = defenderCspmAssignment.outputs.identityPrincipalId
output defenderForServersPolicyAssignmentId string = defenderForServersAssignment.outputs.policyAssignmentId
output defenderForServersIdentityPrincipalId string = defenderForServersAssignment.outputs.identityPrincipalId
output defenderForStoragePolicyAssignmentId string = defenderForStorageAssignment.outputs.policyAssignmentId
output defenderForStorageIdentityPrincipalId string = defenderForStorageAssignment.outputs.identityPrincipalId
output defenderAmaAuditWindowsPolicyAssignmentId string = defenderAmaAuditWindowsAssignment.outputs.policyAssignmentId
output defenderAmaAuditLinuxPolicyAssignmentId string = defenderAmaAuditLinuxAssignment.outputs.policyAssignmentId
