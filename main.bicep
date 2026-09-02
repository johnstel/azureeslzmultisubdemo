targetScope = 'tenant'

func stripDigits(value string) string => replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(value, '0', ''), '1', ''), '2', ''), '3', ''), '4', ''), '5', ''), '6', ''), '7', ''), '8', ''), '9', '')
func stripHex(value string) string => replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(toLower(value), '0', ''), '1', ''), '2', ''), '3', ''), '4', ''), '5', ''), '6', ''), '7', ''), '8', ''), '9', ''), 'a', ''), 'b', ''), 'c', ''), 'd', ''), 'e', ''), 'f', '')
func isGuid(value string) bool => length(value) == 36 ? substring(value, 8, 1) == '-' && substring(value, 13, 1) == '-' && substring(value, 18, 1) == '-' && substring(value, 23, 1) == '-' && length(replace(value, '-', '')) == 32 && empty(stripHex(replace(value, '-', ''))) : false
func isIpv4(value string) bool => length(split(value, '.')) == 4 && value == trim(value) && !empty(value) && empty(filter(split(value, '.'), octet => empty(octet) || !empty(stripDigits(octet)) || int(octet) > 255))
func isIpv4Cidr(value string) bool => length(split(value, '/')) == 2 && isIpv4(first(split(value, '/'))) && !empty(last(split(value, '/'))) && empty(stripDigits(last(split(value, '/')))) && int(last(split(value, '/'))) >= 0 && int(last(split(value, '/'))) <= 32
func hasCanonicalArmIdSegments(value string) bool => startsWith(value, '/') && !endsWith(value, '/') && value == trim(value) && length(filter(skip(split(value, '/'), 1), segment => empty(segment) || segment != trim(segment))) == 0
func stripAlpha(value string) string => replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(toLower(value), 'a', ''), 'b', ''), 'c', ''), 'd', ''), 'e', ''), 'f', ''), 'g', ''), 'h', ''), 'i', ''), 'j', ''), 'k', ''), 'l', ''), 'm', ''), 'n', ''), 'o', ''), 'p', ''), 'q', ''), 'r', ''), 's', ''), 't', ''), 'u', ''), 'v', ''), 'w', ''), 'x', ''), 'y', ''), 'z', '')
func stripAlphaNumeric(value string) string => stripAlpha(stripDigits(value))
func hasDisallowedResourceGroupAsciiChars(value string) bool => contains(value, ' ') || contains(value, '!') || contains(value, '"') || contains(value, '#') || contains(value, '$') || contains(value, '%') || contains(value, '&') || contains(value, '*') || contains(value, '+') || contains(value, ',') || contains(value, '/') || contains(value, ':') || contains(value, ';') || contains(value, '<') || contains(value, '=') || contains(value, '>') || contains(value, '?') || contains(value, '@') || contains(value, '[') || contains(value, ']') || contains(value, '^') || contains(value, '`') || contains(value, '{') || contains(value, '|') || contains(value, '}') || contains(value, '~')
func isResourceGroupName(value string) bool => !empty(value) && length(value) <= 90 && value == trim(value) && !endsWith(value, '.') && !hasDisallowedResourceGroupAsciiChars(value)
func isLogAnalyticsWorkspaceName(value string) bool => length(value) >= 4 && length(value) <= 63 && value == trim(value) && !startsWith(value, '-') && !endsWith(value, '-') && empty(stripAlphaNumeric(replace(value, '-', '')))
func isResourceId(value string, resourceType string) bool => length(split(value, '/')) == 9 && toLower(split(value, '/')[1]) == 'subscriptions' && isGuid(split(value, '/')[2]) && toLower(split(value, '/')[3]) == 'resourcegroups' && !empty(trim(split(value, '/')[4])) && toLower(split(value, '/')[5]) == 'providers' && toLower(split(value, '/')[6]) == 'microsoft.network' && toLower(split(value, '/')[7]) == toLower(resourceType) && !empty(trim(split(value, '/')[8])) && value == trim(value)
func isWorkspaceResourceId(value string) bool => length(split(value, '/')) == 9 && hasCanonicalArmIdSegments(value) && toLower(split(value, '/')[1]) == 'subscriptions' && isGuid(split(value, '/')[2]) && toLower(split(value, '/')[3]) == 'resourcegroups' && isResourceGroupName(split(value, '/')[4]) && toLower(split(value, '/')[5]) == 'providers' && toLower(split(value, '/')[6]) == 'microsoft.operationalinsights' && toLower(split(value, '/')[7]) == 'workspaces' && isLogAnalyticsWorkspaceName(split(value, '/')[8])

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

@description('Effect for the Activity Log export assignment. Keep Disabled until the effective workspace input and rollout are approved.')
@allowed([
  'DeployIfNotExists'
  'Disabled'
])
param activityLogExportPolicyEffect string = 'Disabled'

@description('Whether Activity Log categories are enabled when the Activity Log export assignment runs.')
@allowed([
  'True'
  'False'
])
param activityLogExportLogsEnabled string = 'True'

@description('Effect for supported-resource diagnostics. Keep AuditIfNotExists until remediation rollout is approved.')
@allowed([
  'DeployIfNotExists'
  'AuditIfNotExists'
  'Disabled'
])
param resourceDiagnosticsPolicyEffect string = 'AuditIfNotExists'

@description('Supported-resource diagnostic category-group profile. audit is the safe default; allLogs is explicit opt-in.')
@allowed([
  'audit'
  'allLogs'
])
param resourceDiagnosticsCategoryGroup string = 'audit'

@description('Set true only when you intentionally want policy-assignment identities to receive remediation RBAC grants for logging exports. Requires deployRoleAssignments=true.')
param deployLoggingRemediationRoleAssignments bool = false

var demoRootManagementGroupId = namePrefix
var platformManagementGroupId = '${namePrefix}-platform'
var connectivityManagementGroupId = '${namePrefix}-connectivity'
var landingZonesManagementGroupId = '${namePrefix}-landingzones'
var workloadManagementGroupId = '${namePrefix}-${workloadArchetype}'
var criticalInfrastructureManagementGroupId = '${namePrefix}-criticalinfra'
var dataProtectionAuditOnlyEffect = dataProtectionPolicyEffect == 'Disabled' ? 'Disabled' : 'Audit'
// Key Vault purge protection must never be turned off, so a global Disabled
// selection is mapped back to Audit instead of being propagated.
var dataProtectionPurgeProtectionEffect = dataProtectionPolicyEffect == 'Deny' ? 'Deny' : 'Audit'
var dataProtectionAuditIfNotExistsEffect = dataProtectionPolicyEffect == 'Disabled' ? 'Disabled' : 'AuditIfNotExists'
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
var activityLogExportPolicyDefinitionId = tenantResourceId(
  'Microsoft.Authorization/policyDefinitions',
  '2465583e-4e78-4c15-b6be-a36cbc7c8b0f'
)
var resourceDiagnosticsAuditPolicySetDefinitionId = tenantResourceId(
  'Microsoft.Authorization/policySetDefinitions',
  'f5b29bc4-feca-4cc6-a58a-772dd5e290a5'
)
var resourceDiagnosticsAllLogsPolicySetDefinitionId = tenantResourceId(
  'Microsoft.Authorization/policySetDefinitions',
  '0884adba-2312-4468-abeb-5422caed1038'
)
var resourceDiagnosticsPolicySetDefinitionId = resourceDiagnosticsCategoryGroup == 'allLogs'
  ? resourceDiagnosticsAllLogsPolicySetDefinitionId
  : resourceDiagnosticsAuditPolicySetDefinitionId
var contributorRoleDefinitionId = 'b24988ac-6180-42a0-ab88-20f7382dd24c'
var monitoringContributorRoleDefinitionId = '749f88d5-cbae-40b8-bcfc-e573ddc772fa'
var logAnalyticsContributorRoleDefinitionId = '92aaf0da-9dab-42b6-94a3-d43ce8d16293'
var placeholderWorkspaceResourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/placeholder/providers/Microsoft.OperationalInsights/workspaces/placeholder'
var existingWorkspaceResourceIdParts = split(!empty(existingLogAnalyticsWorkspaceResourceId) ? existingLogAnalyticsWorkspaceResourceId : placeholderWorkspaceResourceId, '/')
var effectiveMonitoringWorkspaceResourceId = centralMonitoring.outputs.effectiveLogAnalyticsWorkspaceResourceId
var loggingAssignmentsRequireWorkspace = activityLogExportPolicyEffect == 'DeployIfNotExists' || resourceDiagnosticsPolicyEffect == 'DeployIfNotExists' || resourceDiagnosticsPolicyEffect == 'AuditIfNotExists'
var effectiveMonitoringWorkspaceIdIsValid = isWorkspaceResourceId(effectiveMonitoringWorkspaceResourceId)
var loggingPoliciesRequireWorkspace = loggingAssignmentsRequireWorkspace && !effectiveMonitoringWorkspaceIdIsValid
var validatedLoggingWorkspaceResourceId = loggingPoliciesRequireWorkspace
  ? fail('Activity Log and supported-resource diagnostics assignments require a valid effective Log Analytics workspace resource ID in the exact form /subscriptions/<guid>/resourceGroups/<name>/providers/Microsoft.OperationalInsights/workspaces/<name>. Set existingLogAnalyticsWorkspaceResourceId or deployCentralLogAnalytics=true before enabling these effects.')
  : effectiveMonitoringWorkspaceResourceId
var activityLogRemediationDeployRequested = activityLogExportPolicyEffect == 'DeployIfNotExists'
var resourceDiagnosticsRemediationDeployRequested = resourceDiagnosticsPolicyEffect == 'DeployIfNotExists'
var deployActivityLogRemediationRoleAssignments = deployRoleAssignments && deployLoggingRemediationRoleAssignments && activityLogRemediationDeployRequested
var deployResourceDiagnosticsRemediationRoleAssignments = deployRoleAssignments && deployLoggingRemediationRoleAssignments && resourceDiagnosticsRemediationDeployRequested
var loggingWorkspaceSubscriptionId = deployCentralLogAnalytics ? connectivitySubscriptionId : existingWorkspaceResourceIdParts[2]
var loggingWorkspaceResourceGroupName = deployCentralLogAnalytics ? 'rg-${namePrefix}-monitoring' : existingWorkspaceResourceIdParts[4]
var loggingWorkspaceName = deployCentralLogAnalytics ? 'log-${namePrefix}-central' : existingWorkspaceResourceIdParts[8]

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
      purgeProtectionEffect: {
        type: 'String'
        metadata: {
          displayName: 'Key Vault purge protection effect'
          description: 'Key Vault purge protection is never disabled, so this control only ever audits or denies. A global Disabled selection still maps to Audit here.'
        }
        allowedValues: [
          'Audit'
          'Deny'
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
          // Bound to purgeProtectionEffect, which can only be Audit or Deny, so
          // purge protection can never be disabled from the reviewed effect.
          effect: {
            value: '[parameters(\'purgeProtectionEffect\')]'
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
      purgeProtectionEffect: {
        value: dataProtectionPurgeProtectionEffect
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

module activityLogExportAssignment 'modules/policy-assignment.bicep' = if (!activityLogRemediationDeployRequested) {
  name: 'assign-activity-logs'
  scope: managementGroup(demoRootManagementGroupId)
  params: {
    assignmentName: 'demo-activity-logs'
    displayName: 'Demo - export Activity Logs to Log Analytics'
    description: 'Configures subscription Activity Log diagnostic settings to stream to the effective central Log Analytics workspace.'
    policyDefinitionId: activityLogExportPolicyDefinitionId
    definitionVersion: '1.*.*'
    enforcementMode: denyPolicyEnforcementMode
    parameters: {
      effect: {
        value: activityLogExportPolicyEffect
      }
      logsEnabled: {
        value: activityLogExportLogsEnabled
      }
      logAnalytics: {
        value: validatedLoggingWorkspaceResourceId
      }
    }
    nonComplianceMessages: [
      {
        message: 'Activity Log export requires a valid effective Log Analytics workspace resource ID and the configured subscription diagnostic settings must stream to that workspace.'
      }
    ]
  }
  dependsOn: [
    hierarchy
  ]
}

module activityLogExportRemediatingAssignment 'modules/remediating-policy-assignment.bicep' = if (activityLogRemediationDeployRequested) {
  name: 'assign-activity-logs-remediating'
  scope: managementGroup(demoRootManagementGroupId)
  params: {
    assignmentName: 'demo-activity-logs'
    displayName: 'Demo - export Activity Logs to Log Analytics'
    description: 'Configures subscription Activity Log diagnostic settings to stream to the effective central Log Analytics workspace.'
    policyDefinitionId: activityLogExportPolicyDefinitionId
    definitionVersion: '1.*.*'
    location: deploymentLocation
    identity: {
      type: 'SystemAssigned'
    }
    verifiedRoleDefinitionIds: [
      monitoringContributorRoleDefinitionId
      logAnalyticsContributorRoleDefinitionId
    ]
    deployRemediationRoleAssignments: deployActivityLogRemediationRoleAssignments
    enforcementMode: denyPolicyEnforcementMode
    parameters: {
      effect: {
        value: activityLogExportPolicyEffect
      }
      logsEnabled: {
        value: activityLogExportLogsEnabled
      }
      logAnalytics: {
        value: validatedLoggingWorkspaceResourceId
      }
    }
    nonComplianceMessages: [
      {
        message: 'Activity Log export requires a valid effective Log Analytics workspace resource ID and the configured subscription diagnostic settings must stream to that workspace.'
      }
    ]
  }
  dependsOn: [
    hierarchy
  ]
}

module resourceDiagnosticsAssignment 'modules/policy-assignment.bicep' = if (!resourceDiagnosticsRemediationDeployRequested) {
  name: 'assign-resource-diagnostics'
  scope: managementGroup(demoRootManagementGroupId)
  params: {
    assignmentName: 'demo-resource-diags'
    displayName: 'Demo - export supported resource diagnostics'
    description: 'Assigns the built-in supported-resource diagnostics initiative to stream logs to the effective central Log Analytics workspace.'
    policyDefinitionId: resourceDiagnosticsPolicySetDefinitionId
    definitionVersion: '1.*.*'
    enforcementMode: denyPolicyEnforcementMode
    parameters: {
      effect: {
        value: resourceDiagnosticsPolicyEffect
      }
      logAnalytics: {
        value: validatedLoggingWorkspaceResourceId
      }
    }
    nonComplianceMessages: [
      {
        message: 'Supported-resource diagnostics export requires a valid effective Log Analytics workspace resource ID and compliant diagnostic settings for supported resource types.'
      }
    ]
  }
  dependsOn: [
    hierarchy
  ]
}

module resourceDiagnosticsRemediatingAssignment 'modules/remediating-policy-assignment.bicep' = if (resourceDiagnosticsRemediationDeployRequested) {
  name: 'assign-resource-diagnostics-remediating'
  scope: managementGroup(demoRootManagementGroupId)
  params: {
    assignmentName: 'demo-resource-diags'
    displayName: 'Demo - export supported resource diagnostics'
    description: 'Assigns the built-in supported-resource diagnostics initiative to stream logs to the effective central Log Analytics workspace.'
    policyDefinitionId: resourceDiagnosticsPolicySetDefinitionId
    definitionVersion: '1.*.*'
    location: deploymentLocation
    identity: {
      type: 'SystemAssigned'
    }
    verifiedRoleDefinitionIds: [
      logAnalyticsContributorRoleDefinitionId
    ]
    deployRemediationRoleAssignments: deployResourceDiagnosticsRemediationRoleAssignments
    enforcementMode: denyPolicyEnforcementMode
    parameters: {
      effect: {
        value: resourceDiagnosticsPolicyEffect
      }
      logAnalytics: {
        value: validatedLoggingWorkspaceResourceId
      }
    }
    nonComplianceMessages: [
      {
        message: 'Supported-resource diagnostics export requires a valid effective Log Analytics workspace resource ID and compliant diagnostic settings for supported resource types.'
      }
    ]
  }
  dependsOn: [
    hierarchy
  ]
}

module activityLogWorkspaceDestinationRbac 'modules/workspace-remediation-rbac.bicep' = if (deployActivityLogRemediationRoleAssignments) {
  name: 'activity-log-workspace-destination-rbac'
  scope: resourceGroup(loggingWorkspaceSubscriptionId, loggingWorkspaceResourceGroupName)
  params: {
    workspaceName: loggingWorkspaceName
    principalId: activityLogExportRemediatingAssignment!.outputs.identityPrincipalId
    roleDefinitionIds: [
      logAnalyticsContributorRoleDefinitionId
    ]
  }
}

module resourceDiagnosticsWorkspaceDestinationRbac 'modules/workspace-remediation-rbac.bicep' = if (deployResourceDiagnosticsRemediationRoleAssignments) {
  name: 'resource-diagnostics-workspace-destination-rbac'
  scope: resourceGroup(loggingWorkspaceSubscriptionId, loggingWorkspaceResourceGroupName)
  params: {
    workspaceName: loggingWorkspaceName
    principalId: resourceDiagnosticsRemediatingAssignment!.outputs.identityPrincipalId
    roleDefinitionIds: [
      logAnalyticsContributorRoleDefinitionId
    ]
  }
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
output loggingAssignments object = {
  activityLogExport: {
    policyAssignmentId: activityLogRemediationDeployRequested ? activityLogExportRemediatingAssignment!.outputs.policyAssignmentId : activityLogExportAssignment!.outputs.policyAssignmentId
    identityPrincipalId: activityLogRemediationDeployRequested ? activityLogExportRemediatingAssignment!.outputs.identityPrincipalId : ''
    roleAssignmentIds: activityLogRemediationDeployRequested ? activityLogExportRemediatingAssignment!.outputs.roleAssignmentIds : []
    remediationRoleAssignmentIds: activityLogRemediationDeployRequested ? activityLogExportRemediatingAssignment!.outputs.roleAssignmentIds : []
    workspaceDestinationRoleAssignmentIds: deployActivityLogRemediationRoleAssignments ? activityLogWorkspaceDestinationRbac!.outputs.roleAssignmentIds : []
    effect: activityLogExportPolicyEffect
  }
  resourceDiagnostics: {
    policyAssignmentId: resourceDiagnosticsRemediationDeployRequested ? resourceDiagnosticsRemediatingAssignment!.outputs.policyAssignmentId : resourceDiagnosticsAssignment!.outputs.policyAssignmentId
    identityPrincipalId: resourceDiagnosticsRemediationDeployRequested ? resourceDiagnosticsRemediatingAssignment!.outputs.identityPrincipalId : ''
    roleAssignmentIds: resourceDiagnosticsRemediationDeployRequested ? resourceDiagnosticsRemediatingAssignment!.outputs.roleAssignmentIds : []
    remediationRoleAssignmentIds: resourceDiagnosticsRemediationDeployRequested ? resourceDiagnosticsRemediatingAssignment!.outputs.roleAssignmentIds : []
    workspaceDestinationRoleAssignmentIds: deployResourceDiagnosticsRemediationRoleAssignments ? resourceDiagnosticsWorkspaceDestinationRbac!.outputs.roleAssignmentIds : []
    effect: resourceDiagnosticsPolicyEffect
    categoryGroup: resourceDiagnosticsCategoryGroup
    policySetDefinitionId: resourceDiagnosticsPolicySetDefinitionId
  }
}
output tagInheritanceRemediation object = {
  enabled: enableTagInheritance
  policyAssignmentId: tagInheritanceAssignment.?outputs.?policyAssignmentId ?? ''
  policyDefinitionReferenceIds: tagInheritanceInitiative.outputs.policyDefinitionReferenceIds
  remediationStarted: false
}
