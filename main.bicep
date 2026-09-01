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

@description('Effect for the Storage and Key Vault data-protection controls that support denial. Keep Audit until posture, exemptions, and customer-managed key dependencies are reviewed.')
@allowed([
  'Audit'
  'Deny'
  'Disabled'
])
param dataProtectionPolicyEffect string = 'Audit'

@description('Minimum TLS version audited on storage accounts.')
@allowed([
  'TLS1_0'
  'TLS1_1'
  'TLS1_2'
])
param storageMinimumTlsVersion string = 'TLS1_2'

@description('Customer-approved Key Vault URIs allowed to hold storage customer-managed keys. Leave empty to skip the approved-vault check; this never creates a Key Vault or grants key access.')
param approvedCustomerManagedKeyVaultUris array = []

@description('Customer-approved customer-managed key names. Leave empty to skip the approved-key-name check; this never creates or rotates a key.')
param approvedCustomerManagedKeyNames array = []

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
var dataProtectionAuditOnlyEffect = dataProtectionPolicyEffect == 'Disabled' ? 'Disabled' : 'Audit'
var dataProtectionAuditIfNotExistsEffect = dataProtectionPolicyEffect == 'Disabled' ? 'Disabled' : 'AuditIfNotExists'
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

module dataProtectionInitiative 'modules/policy-initiative.bicep' = {
  name: 'data-protection-initiative'
  scope: managementGroup(demoRootManagementGroupId)
  params: {
    initiativeName: '${namePrefix}-data-protection'
    initiativeDisplayName: 'Demo - storage and Key Vault data-protection guardrails'
    initiativeDescription: 'Audits storage secure transfer, minimum TLS, public and network access, shared-key posture, and Key Vault soft delete, deletion protection, RBAC authorization, network access, and diagnostics. Customer-managed key controls are service-specific and audit-first; nothing here creates a storage account, Key Vault, key, private endpoint, or managed identity.'
    initiativeCategory: 'Data Protection'
    initiativeVersion: '1.0.0'
    initiativeParameters: {
      effect: {
        type: 'String'
        metadata: {
          displayName: 'Data-protection effect'
          description: 'Audit is the safe default for the controls that support denial. Select Deny only after reviewing existing storage accounts, Key Vaults, and exemptions.'
        }
        allowedValues: [
          'Audit'
          'Deny'
          'Disabled'
        ]
        defaultValue: 'Audit'
      }
      auditOnlyEffect: {
        type: 'String'
        metadata: {
          displayName: 'Audit-only effect'
          description: 'Effect for controls whose verified built-in supports Audit or Disabled only, including the storage customer-managed key and Key Vault private-link readiness audits.'
        }
        allowedValues: [
          'Audit'
          'Disabled'
        ]
        defaultValue: 'Audit'
      }
      auditIfNotExistsEffect: {
        type: 'String'
        metadata: {
          displayName: 'AuditIfNotExists effect'
          description: 'Effect for the readiness controls whose verified built-in supports AuditIfNotExists or Disabled only. These controls never deploy a private endpoint or a diagnostic setting.'
        }
        allowedValues: [
          'AuditIfNotExists'
          'Disabled'
        ]
        defaultValue: 'AuditIfNotExists'
      }
      minimumTlsVersion: {
        type: 'String'
        metadata: {
          displayName: 'Storage minimum TLS version'
          description: 'Minimum TLS version audited on storage accounts.'
        }
        allowedValues: [
          'TLS1_0'
          'TLS1_1'
          'TLS1_2'
        ]
        defaultValue: 'TLS1_2'
      }
      approvedKeyVaultUris: {
        type: 'Array'
        metadata: {
          displayName: 'Approved Key Vault URIs'
          description: 'Customer-approved Key Vault URIs that may hold storage customer-managed keys. Empty (the default) skips the approved-vault check.'
        }
        defaultValue: []
      }
      approvedKeyNames: {
        type: 'Array'
        metadata: {
          displayName: 'Approved key names'
          description: 'Customer-approved customer-managed key names. Empty (the default) skips the approved-key-name check.'
        }
        defaultValue: []
      }
    }
    policyDefinitionGroups: [
      {
        name: 'storage-data-protection'
        displayName: 'Storage data protection'
        category: 'Data Protection'
        description: 'Transport security, encryption, and public/network exposure posture for storage accounts.'
      }
      {
        name: 'key-vault-data-protection'
        displayName: 'Key Vault data protection'
        category: 'Data Protection'
        description: 'Recoverability, authorization, network access, and diagnostics posture for Key Vault.'
      }
      {
        name: 'customer-managed-keys'
        displayName: 'Customer-managed keys'
        category: 'Data Protection'
        description: 'Service-specific, audit-first customer-managed key controls that depend on a customer-supplied Key Vault, key, and identity.'
      }
    ]
    policyDefinitionReferences: [
      {
        policyDefinitionId: tenantResourceId(
          'Microsoft.Authorization/policyDefinitions',
          '404c3081-a854-4457-ae30-26a93ef643f9'
        )
        definitionVersion: '2.*.*'
        policyDefinitionReferenceId: 'storage-secure-transfer'
        parameters: {
          effect: {
            value: '[parameters(\'effect\')]'
          }
        }
        groupNames: [
          'storage-data-protection'
        ]
      }
      {
        policyDefinitionId: tenantResourceId(
          'Microsoft.Authorization/policyDefinitions',
          'fe83a0eb-a853-422d-aac2-1bffd182c5d0'
        )
        definitionVersion: '1.*.*'
        policyDefinitionReferenceId: 'storage-minimum-tls'
        parameters: {
          effect: {
            value: '[parameters(\'effect\')]'
          }
          minimumTlsVersion: {
            value: '[parameters(\'minimumTlsVersion\')]'
          }
        }
        groupNames: [
          'storage-data-protection'
        ]
      }
      {
        policyDefinitionId: tenantResourceId(
          'Microsoft.Authorization/policyDefinitions',
          '4fa4b6c0-31ca-4c0d-b10d-24b96f62a751'
        )
        definitionVersion: '3.*.*'
        policyDefinitionReferenceId: 'storage-public-blob-access'
        parameters: {
          effect: {
            value: '[parameters(\'effect\')]'
          }
        }
        groupNames: [
          'storage-data-protection'
        ]
      }
      {
        policyDefinitionId: tenantResourceId(
          'Microsoft.Authorization/policyDefinitions',
          '34c877ad-507e-4c82-993e-3452a6e0ad3c'
        )
        definitionVersion: '1.*.*'
        policyDefinitionReferenceId: 'storage-network-access'
        parameters: {
          effect: {
            value: '[parameters(\'effect\')]'
          }
        }
        groupNames: [
          'storage-data-protection'
        ]
      }
      {
        policyDefinitionId: tenantResourceId(
          'Microsoft.Authorization/policyDefinitions',
          '8c6a50c6-9ffd-4ae7-986f-5fa6111f9a54'
        )
        definitionVersion: '2.*.*'
        policyDefinitionReferenceId: 'storage-shared-key-access'
        parameters: {
          effect: {
            value: '[parameters(\'effect\')]'
          }
        }
        groupNames: [
          'storage-data-protection'
        ]
      }
      {
        policyDefinitionId: tenantResourceId(
          'Microsoft.Authorization/policyDefinitions',
          '6edd7eda-6dd8-40f7-810d-67160c639cd9'
        )
        definitionVersion: '2.*.*'
        policyDefinitionReferenceId: 'storage-private-link-readiness'
        parameters: {
          effect: {
            value: '[parameters(\'auditIfNotExistsEffect\')]'
          }
        }
        groupNames: [
          'storage-data-protection'
        ]
      }
      {
        policyDefinitionId: tenantResourceId(
          'Microsoft.Authorization/policyDefinitions',
          '1e66c121-a66a-4b1f-9b83-0fd99bf0fc2d'
        )
        definitionVersion: '3.*.*'
        policyDefinitionReferenceId: 'key-vault-soft-delete'
        parameters: {
          effect: {
            value: '[parameters(\'effect\')]'
          }
        }
        groupNames: [
          'key-vault-data-protection'
        ]
      }
      {
        policyDefinitionId: tenantResourceId(
          'Microsoft.Authorization/policyDefinitions',
          '0b60c0b2-2dc2-4e1c-b5c9-abbed971de53'
        )
        definitionVersion: '2.*.*'
        policyDefinitionReferenceId: 'key-vault-deletion-protection'
        parameters: {
          effect: {
            value: '[parameters(\'effect\')]'
          }
        }
        groupNames: [
          'key-vault-data-protection'
        ]
      }
      {
        policyDefinitionId: tenantResourceId(
          'Microsoft.Authorization/policyDefinitions',
          '12d4fa5e-1f9f-4c21-97a9-b99b3c6611b5'
        )
        definitionVersion: '1.*.*'
        policyDefinitionReferenceId: 'key-vault-rbac-authorization'
        parameters: {
          effect: {
            value: '[parameters(\'effect\')]'
          }
        }
        groupNames: [
          'key-vault-data-protection'
        ]
      }
      {
        policyDefinitionId: tenantResourceId(
          'Microsoft.Authorization/policyDefinitions',
          '55615ac9-af46-4a59-874e-391cc3dfb490'
        )
        definitionVersion: '3.*.*'
        policyDefinitionReferenceId: 'key-vault-network-access'
        parameters: {
          effect: {
            value: '[parameters(\'effect\')]'
          }
        }
        groupNames: [
          'key-vault-data-protection'
        ]
      }
      {
        policyDefinitionId: tenantResourceId(
          'Microsoft.Authorization/policyDefinitions',
          'a6abeaec-4d90-4a02-805f-6b26c4d3fbe9'
        )
        definitionVersion: '1.*.*'
        policyDefinitionReferenceId: 'key-vault-private-link-readiness'
        parameters: {
          // This built-in evaluates audit_effect; its legacy effect parameter is deprecated and unused.
          audit_effect: {
            value: '[parameters(\'auditOnlyEffect\')]'
          }
        }
        groupNames: [
          'key-vault-data-protection'
        ]
      }
      {
        policyDefinitionId: tenantResourceId(
          'Microsoft.Authorization/policyDefinitions',
          'cf820ca0-f99e-4f3e-84fb-66e913812d21'
        )
        definitionVersion: '5.*.*'
        policyDefinitionReferenceId: 'key-vault-diagnostics-readiness'
        parameters: {
          effect: {
            value: '[parameters(\'auditIfNotExistsEffect\')]'
          }
        }
        groupNames: [
          'key-vault-data-protection'
        ]
      }
      {
        policyDefinitionId: tenantResourceId(
          'Microsoft.Authorization/policyDefinitions',
          '6fac406b-40ca-413b-bf8e-0bf964659c25'
        )
        definitionVersion: '1.*.*'
        policyDefinitionReferenceId: 'storage-customer-managed-key'
        parameters: {
          effect: {
            value: '[parameters(\'auditOnlyEffect\')]'
          }
        }
        groupNames: [
          'customer-managed-keys'
        ]
      }
      {
        policyDefinitionId: policyLibrary.outputs.storageCmkApprovedKeyPolicyDefinitionId
        policyDefinitionReferenceId: 'storage-approved-customer-managed-key'
        parameters: {
          effect: {
            value: '[parameters(\'effect\')]'
          }
          approvedKeyVaultUris: {
            value: '[parameters(\'approvedKeyVaultUris\')]'
          }
          approvedKeyNames: {
            value: '[parameters(\'approvedKeyNames\')]'
          }
        }
        groupNames: [
          'customer-managed-keys'
        ]
      }
    ]
  }
}

module dataProtectionAssignment 'modules/policy-assignment.bicep' = {
  name: 'assign-data-protection'
  scope: managementGroup(landingZonesManagementGroupId)
  params: {
    assignmentName: 'demo-data-protection'
    displayName: 'Demo - storage and Key Vault data-protection guardrails'
    description: 'Audits storage and Key Vault data-protection posture, including service-specific customer-managed key requirements, across the Landing Zones branch.'
    policyDefinitionId: dataProtectionInitiative.outputs.policySetDefinitionId
    enforcementMode: denyPolicyEnforcementMode
    parameters: {
      effect: {
        value: dataProtectionPolicyEffect
      }
      auditOnlyEffect: {
        value: dataProtectionAuditOnlyEffect
      }
      auditIfNotExistsEffect: {
        value: dataProtectionAuditIfNotExistsEffect
      }
      minimumTlsVersion: {
        value: storageMinimumTlsVersion
      }
      approvedKeyVaultUris: {
        value: approvedCustomerManagedKeyVaultUris
      }
      approvedKeyNames: {
        value: approvedCustomerManagedKeyNames
      }
    }
    nonComplianceMessages: [
      {
        message: 'Storage accounts must require secure transfer (HTTPS). Enable supportsHttpsTrafficOnly or obtain a governed exemption.'
        policyDefinitionReferenceId: 'storage-secure-transfer'
      }
      {
        message: 'Storage accounts must set the approved minimum TLS version (TLS1_2 by default).'
        policyDefinitionReferenceId: 'storage-minimum-tls'
      }
      {
        message: 'Public blob access must be disallowed on storage accounts. Use Entra ID authorization or a user delegation SAS instead of anonymous access.'
        policyDefinitionReferenceId: 'storage-public-blob-access'
      }
      {
        message: 'Storage account network access must be restricted to approved networks. This control audits the account firewall only; it does not deploy a private endpoint.'
        policyDefinitionReferenceId: 'storage-network-access'
      }
      {
        message: 'Storage accounts must reject Shared Key authorization and require Entra ID authorization. Migrate tooling that depends on account keys before enforcing.'
        policyDefinitionReferenceId: 'storage-shared-key-access'
      }
      {
        message: 'Storage private-link readiness is not met. This control audits readiness only; the customer owns private endpoint, DNS, and network deployment.'
        policyDefinitionReferenceId: 'storage-private-link-readiness'
      }
      {
        message: 'Key vaults must have soft delete enabled so deleted vaults and secrets stay recoverable.'
        policyDefinitionReferenceId: 'key-vault-soft-delete'
      }
      {
        message: 'Key vaults must have deletion (purge) protection enabled in addition to soft delete. Purge protection must never be disabled once enabled.'
        policyDefinitionReferenceId: 'key-vault-deletion-protection'
      }
      {
        message: 'Key vaults must use the Azure RBAC permission model for data-plane authorization instead of vault access policies.'
        policyDefinitionReferenceId: 'key-vault-rbac-authorization'
      }
      {
        message: 'Key vaults must enable the vault firewall or disable public network access. This control audits network configuration only; it does not deploy a private endpoint.'
        policyDefinitionReferenceId: 'key-vault-network-access'
      }
      {
        message: 'Key Vault private-link readiness is not met. This control audits readiness only; the customer owns private endpoint, DNS, and network deployment.'
        policyDefinitionReferenceId: 'key-vault-private-link-readiness'
      }
      {
        message: 'Key Vault resource logs are not configured. This control audits diagnostics readiness only; it does not create a diagnostic setting or a Log Analytics workspace.'
        policyDefinitionReferenceId: 'key-vault-diagnostics-readiness'
      }
      {
        message: 'Storage accounts in scope for customer-managed keys must encrypt with a key from a customer-supplied Key Vault. The customer owns the key, its identity access, rotation, availability, and recovery.'
        policyDefinitionReferenceId: 'storage-customer-managed-key'
      }
      {
        message: 'The storage customer-managed key is outside the approved Key Vault or key-name list. Update the approved inputs or move the account to an approved key.'
        policyDefinitionReferenceId: 'storage-approved-customer-managed-key'
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
output dataProtectionPolicyEffect string = dataProtectionPolicyEffect
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
