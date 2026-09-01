targetScope = 'tenant'

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

@description('Set true only after approving the tag-inheritance assignment, its managed identity, and its built-in-required remediation RBAC. This does not start remediation tasks.')
param enableTagInheritance bool = false

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

@description('Assign the stable Microsoft cloud security benchmark (MCSB) initiative at the demo root. Enabled by default for the customer-control profile. The separate Microsoft cloud security benchmark v2 preview initiative is never assigned by this template.')
param enableMicrosoftCloudSecurityBenchmark bool = true

@description('Set true to add the optional CIS Microsoft Azure Foundations Benchmark v2.0.0 overlay at the demo root. Independent of the MCSB and NIST switches; assignment alone does not establish CIS compliance.')
param enableCisAzureFoundationsBenchmark bool = false

@description('Set true to add the optional NIST SP 800-53 Rev. 5 overlay at the demo root. This initiative contains four fixed Guest Configuration DeployIfNotExists/Modify members, so the assignment needs a system-assigned identity with the Contributor role; assignment alone does not establish NIST compliance.')
param enableNistSp80053Rev5 bool = false

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
var inheritResourceGroupTagPolicyDefinitionId = tenantResourceId(
  'Microsoft.Authorization/policyDefinitions',
  'ea3f2387-9b95-492a-a190-fcdc54f7b070'
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

module tagInheritanceInitiative 'modules/policy-initiative.bicep' = {
  name: 'tag-inheritance-initiative'
  scope: managementGroup(demoRootManagementGroupId)
  params: {
    initiativeName: '${namePrefix}-inherit-rg-tags'
    initiativeDisplayName: 'Demo - inherit resource group tags'
    initiativeDescription: 'Inherits the six customer governance tags from resource groups to taggable child resources when missing.'
    initiativeCategory: 'Tags'
    initiativeVersion: '2.0.0'
    policyDefinitionReferences: [
      {
        policyDefinitionId: inheritResourceGroupTagPolicyDefinitionId
        definitionVersion: '1.*.*'
        policyDefinitionReferenceId: 'inherit-cost-center'
        parameters: {
          tagName: {
            value: 'CostCenter'
          }
        }
        groupNames: []
      }
      {
        policyDefinitionId: inheritResourceGroupTagPolicyDefinitionId
        definitionVersion: '1.*.*'
        policyDefinitionReferenceId: 'inherit-application-name'
        parameters: {
          tagName: {
            value: 'ApplicationName'
          }
        }
        groupNames: []
      }
      {
        policyDefinitionId: inheritResourceGroupTagPolicyDefinitionId
        definitionVersion: '1.*.*'
        policyDefinitionReferenceId: 'inherit-owner'
        parameters: {
          tagName: {
            value: 'Owner'
          }
        }
        groupNames: []
      }
      {
        policyDefinitionId: inheritResourceGroupTagPolicyDefinitionId
        definitionVersion: '1.*.*'
        policyDefinitionReferenceId: 'inherit-environment'
        parameters: {
          tagName: {
            value: 'Environment'
          }
        }
        groupNames: []
      }
      {
        policyDefinitionId: inheritResourceGroupTagPolicyDefinitionId
        definitionVersion: '1.*.*'
        policyDefinitionReferenceId: 'inherit-data-classification'
        parameters: {
          tagName: {
            value: 'DataClassification'
          }
        }
        groupNames: []
      }
      {
        policyDefinitionId: inheritResourceGroupTagPolicyDefinitionId
        definitionVersion: '1.*.*'
        policyDefinitionReferenceId: 'inherit-ssp-id'
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

module tagInheritanceAssignment 'modules/remediating-policy-assignment.bicep' = if (enableTagInheritance) {
  name: 'assign-tag-inheritance'
  scope: managementGroup(landingZonesManagementGroupId)
  params: {
    assignmentName: 'demo-inherit-rg-tags'
    displayName: 'Demo - inherit resource group tags'
    description: 'Inherits missing customer governance tags from resource groups without replacing existing resource tag values. Existing resources require a deliberate remediation task.'
    policyDefinitionId: tagInheritanceInitiative.outputs.policySetDefinitionId
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
output tagInheritanceRemediation object = {
  enabled: enableTagInheritance
  policyAssignmentId: tagInheritanceAssignment.?outputs.?policyAssignmentId ?? ''
  policyDefinitionReferenceIds: tagInheritanceInitiative.outputs.policyDefinitionReferenceIds
  remediationStarted: false
}
