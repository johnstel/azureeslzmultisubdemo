targetScope = 'tenant'

func stripDigits(value string) string => replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(value, '0', ''), '1', ''), '2', ''), '3', ''), '4', ''), '5', ''), '6', ''), '7', ''), '8', ''), '9', '')
func stripHex(value string) string => replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(toLower(value), '0', ''), '1', ''), '2', ''), '3', ''), '4', ''), '5', ''), '6', ''), '7', ''), '8', ''), '9', ''), 'a', ''), 'b', ''), 'c', ''), 'd', ''), 'e', ''), 'f', '')
func isGuid(value string) bool => length(value) == 36 ? substring(value, 8, 1) == '-' && substring(value, 13, 1) == '-' && substring(value, 18, 1) == '-' && substring(value, 23, 1) == '-' && length(replace(value, '-', '')) == 32 && empty(stripHex(replace(value, '-', ''))) : false
func isIpv4(value string) bool => length(split(value, '.')) == 4 && value == trim(value) && !empty(value) && empty(filter(split(value, '.'), octet => empty(octet) || !empty(stripDigits(octet)) || int(octet) > 255))
func isIpv4Cidr(value string) bool => length(split(value, '/')) == 2 && isIpv4(first(split(value, '/'))) && !empty(last(split(value, '/'))) && empty(stripDigits(last(split(value, '/')))) && int(last(split(value, '/'))) >= 0 && int(last(split(value, '/'))) <= 32
func hasCanonicalArmIdSegments(value string) bool => startsWith(value, '/') && !endsWith(value, '/') && value == trim(value) && length(filter(skip(split(value, '/'), 1), segment => empty(segment) || segment != trim(segment))) == 0
func stripAlpha(value string) string => replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(toLower(value), 'a', ''), 'b', ''), 'c', ''), 'd', ''), 'e', ''), 'f', ''), 'g', ''), 'h', ''), 'i', ''), 'j', ''), 'k', ''), 'l', ''), 'm', ''), 'n', ''), 'o', ''), 'p', ''), 'q', ''), 'r', ''), 's', ''), 't', ''), 'u', ''), 'v', ''), 'w', ''), 'x', ''), 'y', ''), 'z', '')
func stripAlphaNumeric(value string) string => stripAlpha(stripDigits(value))
func hasDisallowedResourceGroupAsciiChars(value string) bool => contains(value, ' ') || contains(value, '!') || contains(value, '"') || contains(value, '\u{27}') || contains(value, '#') || contains(value, '$') || contains(value, '%') || contains(value, '&') || contains(value, '*') || contains(value, '+') || contains(value, ',') || contains(value, '/') || contains(value, ':') || contains(value, ';') || contains(value, '<') || contains(value, '=') || contains(value, '>') || contains(value, '?') || contains(value, '@') || contains(value, '[') || contains(value, '\u{5C}') || contains(value, ']') || contains(value, '^') || contains(value, '`') || contains(value, '{') || contains(value, '|') || contains(value, '}') || contains(value, '~')
func isResourceGroupName(value string) bool => !empty(value) && length(value) <= 90 && value == trim(value) && !endsWith(value, '.') && !hasDisallowedResourceGroupAsciiChars(value)
func isLogAnalyticsWorkspaceName(value string) bool => length(value) >= 4 && length(value) <= 63 && value == trim(value) && !startsWith(value, '-') && !endsWith(value, '-') && empty(stripAlphaNumeric(replace(value, '-', '')))
func isResourceId(value string, resourceType string) bool => length(split(value, '/')) == 9 && toLower(split(value, '/')[1]) == 'subscriptions' && isGuid(split(value, '/')[2]) && toLower(split(value, '/')[3]) == 'resourcegroups' && !empty(trim(split(value, '/')[4])) && toLower(split(value, '/')[5]) == 'providers' && toLower(split(value, '/')[6]) == 'microsoft.network' && toLower(split(value, '/')[7]) == toLower(resourceType) && !empty(trim(split(value, '/')[8])) && value == trim(value)
func isWorkspaceResourceId(value string) bool => length(split(value, '/')) == 9 && hasCanonicalArmIdSegments(value) && toLower(split(value, '/')[1]) == 'subscriptions' && isGuid(split(value, '/')[2]) && toLower(split(value, '/')[3]) == 'resourcegroups' && isResourceGroupName(split(value, '/')[4]) && toLower(split(value, '/')[5]) == 'providers' && toLower(split(value, '/')[6]) == 'microsoft.operationalinsights' && toLower(split(value, '/')[7]) == 'workspaces' && isLogAnalyticsWorkspaceName(split(value, '/')[8])
func isResourceNameSegment(value string) bool => !empty(value) && value == trim(value) && empty(filter(['<', '>', '%', '&', '\\', '?', '#', '+', ':', '"', '|', '*', ';', ' '], forbiddenCharacter => contains(value, forbiddenCharacter)))
func isRecoveryServicesVaultId(value string) bool => value == trim(value) && length(split(value, '/')) == 9 && empty(split(value, '/')[0]) && toLower(split(value, '/')[1]) == 'subscriptions' && isGuid(split(value, '/')[2]) && toLower(split(value, '/')[3]) == 'resourcegroups' && isResourceNameSegment(split(value, '/')[4]) && toLower(split(value, '/')[5]) == 'providers' && toLower(split(value, '/')[6]) == 'microsoft.recoveryservices' && toLower(split(value, '/')[7]) == 'vaults' && isResourceNameSegment(split(value, '/')[8])
func isLogAnalyticsWorkspaceId(value string) bool => value == trim(value) && length(split(value, '/')) == 9 && empty(split(value, '/')[0]) && toLower(split(value, '/')[1]) == 'subscriptions' && isGuid(split(value, '/')[2]) && toLower(split(value, '/')[3]) == 'resourcegroups' && isResourceNameSegment(split(value, '/')[4]) && toLower(split(value, '/')[5]) == 'providers' && toLower(split(value, '/')[6]) == 'microsoft.operationalinsights' && toLower(split(value, '/')[7]) == 'workspaces' && isResourceNameSegment(split(value, '/')[8])
func isBackupPolicyIdOfVault(value string, vaultResourceId string) bool => value == trim(value) && length(split(value, '/')) == 11 && isRecoveryServicesVaultId(vaultResourceId) && startsWith(toLower(value), '${toLower(vaultResourceId)}/backuppolicies/') && toLower(split(value, '/')[9]) == 'backuppolicies' && isResourceNameSegment(split(value, '/')[10])

@sealed()
type approvedBackupVault = {
  @description('Workload or application name that this approved vault and backup policy serve.')
  @minLength(1)
  workload: string

  @description('Region of the approved vault. Must be one of approvedVaultRegions and must match the region of the virtual machines it protects.')
  @minLength(1)
  region: string

  @description('Resource ID of the approved existing Recovery Services vault. This template never creates, replaces, or deletes it.')
  @minLength(1)
  vaultResourceId: string

  @description('Resource ID of the approved existing backup policy inside the same vault.')
  @minLength(1)
  backupPolicyResourceId: string

  @description('Inclusion tag values that mark virtual machines protected by this vault and policy.')
  @minLength(1)
  inclusionTagValues: string[]
}

@sealed()
type policyExemption = {
  exemptionName: string
  exemptionScopeType: 'managementGroup' | 'subscription' | 'resourceGroup'
  managementGroupName: string
  subscriptionId: string
  resourceGroupName: string
  policyAssignmentId: string
  displayName: string
  description: string
  exemptionCategory: 'Waiver' | 'Mitigated'
  owner: string
  justification: string
  expiresOn: string
  ticketReference: string
  policyDefinitionReferenceIds: string[]
  allowedPolicyDefinitionReferenceIds: string[]
  permittedAncestorAssignmentScopeIds: string[]
  source: string
  approver: string
  createdOn: string
  reviewedOn: string
  governanceOwner: string
}

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

@description('Documented, time-bound policy exemptions. Empty by default; no exemption is deployed unless a complete record is supplied. Each record is validated and scoped by modules/policy-exemption.bicep.')
param policyExemptions policyExemption[] = []

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

// The built-in that configures virtual machine backup (REQ-BKP-02) targets virtual machines by
// location plus inclusion tag value, and its remediation deployment is placed in the subscription
// and resource group parsed from the supplied backupPolicyId. Approved vault records are therefore
// validated as a composite workload/region mapping with non-overlapping region/tag targeting, and a
// vault outside the governed subscriptions (a central backup subscription) is allowed only behind
// allowCrossSubscriptionBackupVaults, instead of assuming one centralized vault for the whole tenant.
var normalizedApprovedVaultRegions = [for approvedVaultRegion in approvedVaultRegions: toLower(trim(approvedVaultRegion))]
var invalidApprovedVaultRegions = filter(normalizedApprovedVaultRegions, approvedVaultRegion => empty(approvedVaultRegion) || approvedVaultRegion == 'global')
var backupEligibleSubscriptionIds = [for backupEligibleSubscriptionId in concat([workloadSubscriptionId], enableCriticalInfrastructure ? criticalInfrastructureSubscriptionIds : []): toLower(trim(backupEligibleSubscriptionId))]
var invalidApprovedBackupVaults = filter(approvedBackupVaults, approvedVault => empty(trim(approvedVault.workload)) || !contains(normalizedApprovedVaultRegions, toLower(trim(approvedVault.region))) || !isRecoveryServicesVaultId(approvedVault.vaultResourceId) || !isBackupPolicyIdOfVault(approvedVault.backupPolicyResourceId, approvedVault.vaultResourceId) || empty(approvedVault.inclusionTagValues) || !empty(filter(approvedVault.inclusionTagValues, inclusionTagValue => empty(trim(inclusionTagValue)))))
var crossSubscriptionApprovedBackupVaults = filter(approvedBackupVaults, approvedVault => isRecoveryServicesVaultId(approvedVault.vaultResourceId) && !contains(backupEligibleSubscriptionIds, toLower(split(approvedVault.vaultResourceId, '/')[2])))
var approvedBackupVaultKeys = [for approvedVault in approvedBackupVaults: '${toLower(trim(approvedVault.workload))}|${toLower(trim(approvedVault.region))}']
var approvedBackupVaultTargetKeyGroups = [for approvedVault in approvedBackupVaults: map(approvedVault.inclusionTagValues, inclusionTagValue => '${toLower(trim(approvedVault.region))}|${toLower(trim(inclusionTagValue))}')]
var approvedBackupVaultTargetKeys = flatten(approvedBackupVaultTargetKeyGroups)
var approvedBackupVaultResourceIds = [for approvedVault in approvedBackupVaults: toLower(trim(approvedVault.vaultResourceId))]
var approvedBackupVaultResourceIdRegionKeys = [for approvedVault in approvedBackupVaults: '${toLower(trim(approvedVault.vaultResourceId))}|${toLower(trim(approvedVault.region))}']
var validatedApprovedBackupVaults = !empty(invalidApprovedVaultRegions) || length(normalizedApprovedVaultRegions) != length(union(normalizedApprovedVaultRegions, []))
  ? fail('approvedVaultRegions must contain non-empty, non-global, case-insensitively unique Azure regions.')
  : !empty(invalidApprovedBackupVaults)
    ? fail('Each approvedBackupVaults entry must name a workload, use an approved vault region, reference a canonical absolute Recovery Services vault resource ID, reference a backup policy inside that same vault, and list at least one non-empty inclusion tag value.')
    : !allowCrossSubscriptionBackupVaults && !empty(crossSubscriptionApprovedBackupVaults)
      ? fail('approvedBackupVaults entries reference a Recovery Services vault outside the workload and critical-infrastructure subscriptions. Set allowCrossSubscriptionBackupVaults to true to approve that central backup subscription and grant the assignment identity Backup Contributor there.')
      : length(approvedBackupVaultKeys) != length(union(approvedBackupVaultKeys, []))
        ? fail('approvedBackupVaults must use case-insensitively unique workload and region pairs; a workload may appear once per region and a region may host several workloads.')
        : length(approvedBackupVaultTargetKeys) != length(union(approvedBackupVaultTargetKeys, []))
          ? fail('approvedBackupVaults entries in the same region must not share an inclusion tag value, because the backup built-in targets virtual machines by location and inclusion tag value only.')
          : length(union(approvedBackupVaultResourceIdRegionKeys, [])) != length(union(approvedBackupVaultResourceIds, []))
            ? fail('Each approvedBackupVaults vault resource ID must map to exactly one region, because a Recovery Services vault is a single-region resource and the backup built-in protects only virtual machines colocated with the vault; use a separate vault per region.')
            : approvedBackupVaults
var vmBackupRemediationInputsValid = !empty(validatedApprovedBackupVaults) && !empty(trim(vmBackupInclusionTagName)) && !empty(trim(backupRetentionStandardId))
var validatedVmBackupRemediation = enableVmBackupRemediation && !vmBackupRemediationInputsValid
  ? fail('enableVmBackupRemediation requires approvedBackupVaults entries with valid vault and backup policy IDs, a non-empty vmBackupInclusionTagName, and a documented backupRetentionStandardId.')
  : true
var vaultDiagnosticsWorkspaceConfigured = deployCentralLogAnalytics || !empty(trim(existingLogAnalyticsWorkspaceResourceId))
var validatedVaultDiagnostics = enableVaultDiagnostics && !vaultDiagnosticsWorkspaceConfigured
  ? fail('enableVaultDiagnostics requires deployCentralLogAnalytics to be true or a non-empty existingLogAnalyticsWorkspaceResourceId.')
  : true
// The vault diagnostics assignment identity receives Log Analytics Contributor at the assigned
// landing zones scope, which does not cover the effective workspace when that workspace lives in
// the sibling connectivity subscription or in a customer-supplied subscription. The workspace
// resource ID is therefore recomputed from parameters only (module outputs cannot be used as a
// deployment scope) so an explicitly gated, least-privilege role assignment can be created at the
// workspace itself.
var centralLogAnalyticsWorkspaceResourceId = '/subscriptions/${connectivitySubscriptionId}/resourceGroups/rg-${namePrefix}-monitoring/providers/Microsoft.OperationalInsights/workspaces/log-${namePrefix}-central'
var vaultDiagnosticsWorkspaceResourceId = deployCentralLogAnalytics ? centralLogAnalyticsWorkspaceResourceId : existingLogAnalyticsWorkspaceResourceId
var vaultDiagnosticsWorkspaceIdValid = isLogAnalyticsWorkspaceId(vaultDiagnosticsWorkspaceResourceId)
var vaultDiagnosticsWorkspaceIdParts = split(vaultDiagnosticsWorkspaceIdValid ? vaultDiagnosticsWorkspaceResourceId : '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/placeholder/providers/Microsoft.OperationalInsights/workspaces/placeholder', '/')
var validatedVaultDiagnosticsWorkspaceAccess = grantVaultDiagnosticsWorkspaceAccess && !enableVaultDiagnostics
  ? fail('grantVaultDiagnosticsWorkspaceAccess requires enableVaultDiagnostics to be true, because the role assignment binds the diagnostics assignment identity that only exists when vault diagnostics are assigned.')
  : grantVaultDiagnosticsWorkspaceAccess && vaultDiagnosticsEffect != 'DeployIfNotExists'
    ? fail('grantVaultDiagnosticsWorkspaceAccess requires vaultDiagnosticsEffect to be DeployIfNotExists, because an AuditIfNotExists or Disabled assignment only reports and must never receive a managed identity or a role assignment.')
    : grantVaultDiagnosticsWorkspaceAccess && !vaultDiagnosticsWorkspaceIdValid
      ? fail('grantVaultDiagnosticsWorkspaceAccess requires a canonical absolute effective Log Analytics workspace resource ID of the form /subscriptions/<guid>/resourceGroups/<name>/providers/Microsoft.OperationalInsights/workspaces/<name> with no surrounding whitespace, so supply existingLogAnalyticsWorkspaceResourceId or set deployCentralLogAnalytics to true.')
      : true
var validatedRecoveryServicesVaultCreation = deployRecoveryServicesVault && !empty(approvedBackupVaults)
  ? fail('deployRecoveryServicesVault must stay false when approvedBackupVaults records are supplied; approved existing vault and backup policy IDs are the preferred integration path.')
  : deployRecoveryServicesVault && (empty(normalizedApprovedVaultRegions) || !contains(normalizedApprovedVaultRegions, toLower(trim(recoveryServicesVaultLocation))))
    ? fail('recoveryServicesVaultLocation must be one of approvedVaultRegions when a customer-owned vault is created, and approvedVaultRegions must not be empty, so no metered vault is created in an unapproved region.')
    : deployRecoveryServicesVault && empty(trim(backupRetentionStandardId))
      ? fail('deployRecoveryServicesVault requires a documented backupRetentionStandardId so the metered customer-owned vault records an approved retention standard instead of an undocumented default.')
      : true

@description('Assign the stable Microsoft cloud security benchmark (MCSB) initiative at the demo root. Enabled by default for the customer-control profile. The separate Microsoft cloud security benchmark v2 preview initiative is never assigned by this template.')
param enableMicrosoftCloudSecurityBenchmark bool = true

@description('Set true to add the optional CIS Microsoft Azure Foundations Benchmark v2.0.0 overlay at the demo root. Independent of the MCSB and NIST switches; assignment alone does not establish CIS compliance.')
param enableCisAzureFoundationsBenchmark bool = false

@description('Set true to add the optional NIST SP 800-53 Rev. 5 overlay at the demo root. This initiative contains four fixed Guest Configuration DeployIfNotExists/Modify members, so the assignment needs a system-assigned identity with the Contributor role; assignment alone does not establish NIST compliance.')
param enableNistSp80053Rev5 bool = false

@description('Effect for the virtual machine backup coverage audit (REQ-BKP-01). AuditIfNotExists reports uncovered virtual machines without configuring any backup.')
@allowed([
  'AuditIfNotExists'
  'Disabled'
])
param vmBackupCoveragePolicyEffect string = 'AuditIfNotExists'

@description('Effect for the Recovery Services vault public-network-access control (REQ-BKP-04). Keep Audit until private endpoints are in place.')
@allowed([
  'Audit'
  'Deny'
  'Disabled'
])
param vaultPublicNetworkPolicyEffect string = 'Audit'

@description('Effect for the Recovery Services vault customer-managed-key control (REQ-BKP-05). Keep Audit until a customer-managed key is available.')
@allowed([
  'Audit'
  'Deny'
  'Disabled'
])
param vaultEncryptionPolicyEffect string = 'Audit'

@description('Set true to also require infrastructure double encryption on vaults evaluated by the customer-managed-key control.')
param vaultDoubleEncryptionRequired bool = false

@description('Effect for the Recovery Services vault immutability control (REQ-BKP-06).')
@allowed([
  'Audit'
  'Disabled'
])
param vaultImmutabilityPolicyEffect string = 'Audit'

@description('Set true to report only vaults whose immutability is locked (irreversible). Set false to also treat unlocked immutability as compliant. Soft delete is audited separately by REQ-BKP-08.')
param vaultCheckLockedImmutabilityOnly bool = true

@description('Effect for the Recovery Services vault soft-delete control (REQ-BKP-08). Audit reports vaults whose soft delete is not enabled; this template never changes an existing vault setting.')
@allowed([
  'Audit'
  'Disabled'
])
param vaultSoftDeletePolicyEffect string = 'Audit'

@description('Set true to report only vaults whose soft delete is AlwaysOn (irreversible). False, the safe default, treats Enabled and AlwaysOn as compliant.')
param vaultCheckAlwaysOnSoftDeleteOnly bool = false

@description('Effect for the Recovery Services vault multi-user authorization (MUA) control (REQ-BKP-09). MUA uses a customer-owned Resource Guard, so this control stays audit-only.')
@allowed([
  'Audit'
  'Disabled'
])
param vaultMultiUserAuthorizationPolicyEffect string = 'Audit'

@description('Customer-approved regions in which backup vaults may be placed. The configure-backup built-in matches virtual machines whose location equals the vault region, so placement is approved per region rather than assuming a single centralized vault.')
param approvedVaultRegions array = []

@description('Customer-owned identifier of the documented backup retention standard, for example a change record or SSP control ID. No universal retention period is defined for every workload; this records which standard applies.')
param backupRetentionStandardId string = ''

@description('Approved existing vault and backup-policy integration records by workload and region. Existing vault and policy IDs are the preferred integration path and are required before virtual machine backup remediation can be enabled.')
param approvedBackupVaults approvedBackupVault[] = []

@description('Set true to approve approvedBackupVaults entries whose vault lives outside the workload and critical-infrastructure subscriptions, such as a central backup subscription. The configure-backup built-in deploys the protected item into the vault subscription, so the assignment identity must hold Backup Contributor there.')
param allowCrossSubscriptionBackupVaults bool = false

@description('Set true only after supplying approvedBackupVaults, approvedVaultRegions, a retention standard ID, and an inclusion tag name. This assigns the configure-backup built-in with a remediating identity. This template starts no remediation task, but a DeployIfNotExists effect combined with denyPolicyEnforcementMode Default also protects matching virtual machines automatically on create or update, which is metered.')
param enableVmBackupRemediation bool = false

@description('Effect for the configure-backup control (REQ-BKP-02). AuditIfNotExists keeps the opt-in assignment reporting-only. DeployIfNotExists allows a manually started remediation of existing virtual machines and, when denyPolicyEnforcementMode is Default, automatic protection of matching virtual machines on create or update.')
@allowed([
  'AuditIfNotExists'
  'DeployIfNotExists'
  'Disabled'
])
param vmBackupConfigurationEffect string = 'AuditIfNotExists'

@description('Tag name that marks virtual machines eligible for backup configuration. Required when enableVmBackupRemediation is true.')
param vmBackupInclusionTagName string = ''

@description('Set true to assign Recovery Services vault diagnostic settings to the effective central monitoring workspace. Requires deployCentralLogAnalytics or an existing workspace resource ID.')
param enableVaultDiagnostics bool = false

@description('Effect for the vault diagnostic-settings control (REQ-BKP-07). AuditIfNotExists reports missing vault diagnostics; DeployIfNotExists allows remediation.')
@allowed([
  'AuditIfNotExists'
  'DeployIfNotExists'
  'Disabled'
])
param vaultDiagnosticsEffect string = 'AuditIfNotExists'

@description('Set true to grant the vault diagnostics assignment identity Log Analytics Contributor at the effective central Log Analytics workspace scope. The landing zones grant does not cover a workspace in the connectivity or a customer subscription, so a DeployIfNotExists remediation would fail without it. Off by default so no role assignment is created.')
param grantVaultDiagnosticsWorkspaceAccess bool = false

@description('Set true only to create a metered, customer-owned Recovery Services vault and backup policy in the workload subscription. Leave false (default) and integrate an approved existing vault instead.')
param deployRecoveryServicesVault bool = false

@description('Region for an optional customer-owned vault. Must be an approved vault region when approvedVaultRegions is supplied. Ignored when deployRecoveryServicesVault is false.')
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
param recoveryServicesVaultLocation string = 'eastus2'

@description('Immutability state for an optional customer-owned vault. Locked is irreversible; Unlocked is the reversible default.')
@allowed([
  'Disabled'
  'Unlocked'
  'Locked'
])
param vaultImmutabilityState string = 'Unlocked'

@description('Soft-delete state for an optional customer-owned vault. AlwaysON cannot be reversed.')
@allowed([
  'Enabled'
  'AlwaysON'
])
param vaultSoftDeleteState string = 'Enabled'

@description('Soft-delete retention period in days for an optional customer-owned vault.')
@minValue(14)
@maxValue(180)
param vaultSoftDeleteRetentionInDays int = 14

@description('Daily recovery point retention in days for an optional customer-owned backup policy. Longer retention increases backup storage cost.')
@minValue(7)
@maxValue(9999)
param backupDailyRetentionInDays int = 30

@description('Weekly recovery point retention in weeks for an optional customer-owned backup policy. 0 disables weekly retention.')
@minValue(0)
@maxValue(5163)
param backupWeeklyRetentionInWeeks int = 0

@description('Monthly recovery point retention in months for an optional customer-owned backup policy. 0 disables monthly retention.')
@minValue(0)
@maxValue(1188)
param backupMonthlyRetentionInMonths int = 0

@description('Yearly recovery point retention in years for an optional customer-owned backup policy. 0 disables yearly retention.')
@minValue(0)
@maxValue(99)
param backupYearlyRetentionInYears int = 0

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

@description('Only applies when enableDefenderForStorage is true and enableDefenderStorageMalwareScanning is true. Monthly GB cap per storage account for the malware-scanning extension. Defaults to 10000, matching the built-in\'s own verified default; only meaningful once malware scanning is separately approved above.')
param defenderStorageMalwareScanningCapGBPerMonthPerStorageAccount int = 10000

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
var vmBackupCoveragePolicyDefinitionId = tenantResourceId(
  'Microsoft.Authorization/policyDefinitions',
  '013e242c-8828-4970-87b3-ab247555486d'
)
var vaultPublicNetworkPolicyDefinitionId = tenantResourceId(
  'Microsoft.Authorization/policyDefinitions',
  '9ebbbba3-4d65-4da9-bb67-b22cfaaff090'
)
var vaultEncryptionPolicyDefinitionId = tenantResourceId(
  'Microsoft.Authorization/policyDefinitions',
  '2e94d99a-8a36-4563-bc77-810d8893b671'
)
var vaultImmutabilityPolicyDefinitionId = tenantResourceId(
  'Microsoft.Authorization/policyDefinitions',
  'd6f6f560-14b7-49a4-9fc8-d2c3a9807868'
)
var vaultSoftDeletePolicyDefinitionId = tenantResourceId(
  'Microsoft.Authorization/policyDefinitions',
  '31b8092a-36b8-434b-9af7-5ec844364148'
)
var vaultMultiUserAuthorizationPolicyDefinitionId = tenantResourceId(
  'Microsoft.Authorization/policyDefinitions',
  'c7031eab-0fc0-4cd9-acd0-4497bd66d91a'
)
var configureVmBackupPolicyDefinitionId = tenantResourceId(
  'Microsoft.Authorization/policyDefinitions',
  '345fa903-145c-4fe1-8bcd-93ec2adccde8'
)
var resourceDiagnosticsToLogAnalyticsPolicySetDefinitionId = tenantResourceId(
  'Microsoft.Authorization/policySetDefinitions',
  '0884adba-2312-4468-abeb-5422caed1038'
)
var virtualMachineContributorRoleDefinitionId = '9980e02c-c2be-4d73-94e8-173b1dc7cf3c'
var backupContributorRoleDefinitionId = '5e467623-bb1f-42f4-a55d-6e525e11384b'
var logAnalyticsContributorRoleDefinitionId = '92aaf0da-9dab-42b6-94a3-d43ce8d16293'


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

module backupPostureInitiative 'modules/policy-initiative.bicep' = {
  name: 'backup-posture-initiative'
  scope: managementGroup(demoRootManagementGroupId)
  params: {
    initiativeName: '${namePrefix}-backup-posture'
    initiativeDisplayName: 'Demo - backup coverage and vault posture'
    initiativeDescription: 'Audits virtual machine backup coverage and Recovery Services vault public access, encryption, immutability, soft delete, and multi-user authorization posture. Auditing alone creates no vault and configures no backup.'
    initiativeCategory: 'Backup'
    initiativeVersion: '1.0.0'
    initiativeParameters: {
      vmBackupCoverageEffect: {
        type: 'String'
        metadata: {
          displayName: 'Virtual machine backup coverage effect'
          description: 'AuditIfNotExists reports virtual machines without Azure Backup coverage.'
        }
        allowedValues: [
          'AuditIfNotExists'
          'Disabled'
        ]
        defaultValue: 'AuditIfNotExists'
      }
      vaultPublicNetworkAccessEffect: {
        type: 'String'
        metadata: {
          displayName: 'Vault public network access effect'
          description: 'Audit is the safe default. Select Deny only after private endpoints are in place.'
        }
        allowedValues: [
          'Audit'
          'Deny'
          'Disabled'
        ]
        defaultValue: 'Audit'
      }
      vaultEncryptionEffect: {
        type: 'String'
        metadata: {
          displayName: 'Vault customer-managed key effect'
          description: 'Audit is the safe default. Select Deny only after a customer-managed key is available.'
        }
        allowedValues: [
          'Audit'
          'Deny'
          'Disabled'
        ]
        defaultValue: 'Audit'
      }
      vaultDoubleEncryption: {
        type: 'Boolean'
        metadata: {
          displayName: 'Require vault infrastructure double encryption'
        }
        allowedValues: [
          true
          false
        ]
        defaultValue: false
      }
      vaultImmutabilityEffect: {
        type: 'String'
        metadata: {
          displayName: 'Vault immutability effect'
        }
        allowedValues: [
          'Audit'
          'Disabled'
        ]
        defaultValue: 'Audit'
      }
      vaultCheckLockedImmutabilityOnly: {
        type: 'Boolean'
        metadata: {
          displayName: 'Report only locked vault immutability'
        }
        allowedValues: [
          true
          false
        ]
        defaultValue: true
      }
      vaultSoftDeleteEffect: {
        type: 'String'
        metadata: {
          displayName: 'Vault soft delete effect'
          description: 'Audit reports Recovery Services vaults whose soft delete is not enabled.'
        }
        allowedValues: [
          'Audit'
          'Disabled'
        ]
        defaultValue: 'Audit'
      }
      vaultCheckAlwaysOnSoftDeleteOnly: {
        type: 'Boolean'
        metadata: {
          displayName: 'Report only always-on vault soft delete'
        }
        allowedValues: [
          true
          false
        ]
        defaultValue: false
      }
      vaultMultiUserAuthorizationEffect: {
        type: 'String'
        metadata: {
          displayName: 'Vault multi-user authorization effect'
          description: 'Audit reports Recovery Services vaults without multi-user authorization (Resource Guard).'
        }
        allowedValues: [
          'Audit'
          'Disabled'
        ]
        defaultValue: 'Audit'
      }
    }
    policyDefinitionGroups: [
      {
        name: 'backup-coverage'
        displayName: 'Backup coverage'
        category: 'Backup'
        description: 'Virtual machine backup coverage across landing-zone workloads.'
      }
      {
        name: 'vault-posture'
        displayName: 'Vault posture'
        category: 'Backup'
        description: 'Recovery Services vault private access, encryption, immutability, soft delete, and multi-user authorization posture.'
      }
    ]
    policyDefinitionReferences: [
      {
        policyDefinitionId: vmBackupCoveragePolicyDefinitionId
        definitionVersion: '3.*.*'
        policyDefinitionReferenceId: 'vm-backup-coverage'
        parameters: {
          effect: {
            value: '[parameters(\'vmBackupCoverageEffect\')]'
          }
        }
        groupNames: [
          'backup-coverage'
        ]
      }
      {
        policyDefinitionId: vaultPublicNetworkPolicyDefinitionId
        definitionVersion: '1.*.*'
        policyDefinitionReferenceId: 'vault-public-network-access'
        parameters: {
          effect: {
            value: '[parameters(\'vaultPublicNetworkAccessEffect\')]'
          }
        }
        groupNames: [
          'vault-posture'
        ]
      }
      {
        policyDefinitionId: vaultEncryptionPolicyDefinitionId
        definitionVersion: '1.*.*'
        policyDefinitionReferenceId: 'vault-customer-managed-key'
        parameters: {
          effect: {
            value: '[parameters(\'vaultEncryptionEffect\')]'
          }
          enableDoubleEncryption: {
            value: '[parameters(\'vaultDoubleEncryption\')]'
          }
        }
        groupNames: [
          'vault-posture'
        ]
      }
      {
        policyDefinitionId: vaultImmutabilityPolicyDefinitionId
        definitionVersion: '1.*.*'
        policyDefinitionReferenceId: 'vault-immutability'
        parameters: {
          effect: {
            value: '[parameters(\'vaultImmutabilityEffect\')]'
          }
          checkLockedImmutabilityOnly: {
            value: '[parameters(\'vaultCheckLockedImmutabilityOnly\')]'
          }
        }
        groupNames: [
          'vault-posture'
        ]
      }
      {
        policyDefinitionId: vaultSoftDeletePolicyDefinitionId
        definitionVersion: '1.*.*'
        policyDefinitionReferenceId: 'vault-soft-delete'
        parameters: {
          effect: {
            value: '[parameters(\'vaultSoftDeleteEffect\')]'
          }
          checkAlwaysOnSoftDeleteOnly: {
            value: '[parameters(\'vaultCheckAlwaysOnSoftDeleteOnly\')]'
          }
        }
        groupNames: [
          'vault-posture'
        ]
      }
      {
        policyDefinitionId: vaultMultiUserAuthorizationPolicyDefinitionId
        definitionVersion: '1.*.*'
        policyDefinitionReferenceId: 'vault-multi-user-authorization'
        parameters: {
          effect: {
            value: '[parameters(\'vaultMultiUserAuthorizationEffect\')]'
          }
        }
        groupNames: [
          'vault-posture'
        ]
      }
    ]
  }
}

module backupPostureAssignment 'modules/policy-assignment.bicep' = {
  name: 'assign-backup-posture'
  scope: managementGroup(landingZonesManagementGroupId)
  params: {
    assignmentName: 'demo-backup-posture'
    displayName: 'Demo - backup coverage and vault posture'
    description: 'Audits landing-zone virtual machine backup coverage and Recovery Services vault posture. This assignment never creates a vault or configures backup.'
    policyDefinitionId: backupPostureInitiative.outputs.policySetDefinitionId
    enforcementMode: denyPolicyEnforcementMode
    parameters: {
      vmBackupCoverageEffect: {
        value: vmBackupCoveragePolicyEffect
      }
      vaultPublicNetworkAccessEffect: {
        value: vaultPublicNetworkPolicyEffect
      }
      vaultEncryptionEffect: {
        value: vaultEncryptionPolicyEffect
      }
      vaultDoubleEncryption: {
        value: vaultDoubleEncryptionRequired
      }
      vaultImmutabilityEffect: {
        value: vaultImmutabilityPolicyEffect
      }
      vaultCheckLockedImmutabilityOnly: {
        value: vaultCheckLockedImmutabilityOnly
      }
      vaultSoftDeleteEffect: {
        value: vaultSoftDeletePolicyEffect
      }
      vaultCheckAlwaysOnSoftDeleteOnly: {
        value: vaultCheckAlwaysOnSoftDeleteOnly
      }
      vaultMultiUserAuthorizationEffect: {
        value: vaultMultiUserAuthorizationPolicyEffect
      }
    }
    nonComplianceMessages: [
      {
        message: 'Virtual machines must be protected by Azure Backup using an approved vault and backup policy.'
        policyDefinitionReferenceId: 'vm-backup-coverage'
      }
      {
        message: 'Recovery Services vaults must set publicNetworkAccess to Disabled. This audit evaluates the vault setting only and does not prove that private endpoints or private DNS are in place.'
        policyDefinitionReferenceId: 'vault-public-network-access'
      }
      {
        message: 'Recovery Services vaults must encrypt backup data with a customer-managed key.'
        policyDefinitionReferenceId: 'vault-customer-managed-key'
      }
      {
        message: 'Recovery Services vaults must enable immutability to protect backup data from early deletion.'
        policyDefinitionReferenceId: 'vault-immutability'
      }
      {
        message: 'Recovery Services vaults must enable soft delete so deleted backup data can be recovered.'
        policyDefinitionReferenceId: 'vault-soft-delete'
      }
      {
        message: 'Recovery Services vaults must enable multi-user authorization with a customer-owned Resource Guard.'
        policyDefinitionReferenceId: 'vault-multi-user-authorization'
      }
    ]
  }
  dependsOn: [
    hierarchy
  ]
}

module vmBackupConfigurationAssignments 'modules/remediating-policy-assignment.bicep' = [
  for (approvedVault, approvedVaultIndex) in validatedApprovedBackupVaults: if (vmBackupRemediationActive) {
    name: 'assign-vm-backup-${approvedVaultIndex}'
    scope: managementGroup(landingZonesManagementGroupId)
    params: {
      assignmentName: 'demo-vm-backup-${approvedVaultIndex}'
      displayName: 'Demo - configure backup (${approvedVault.workload})'
      description: 'Configures backup for tagged virtual machines in ${approvedVault.region} to the approved existing vault and backup policy for ${approvedVault.workload}. This template starts no remediation task, but with effect DeployIfNotExists and enforcementMode Default the assignment also protects newly created or updated matching virtual machines automatically, which is a metered backup cost.'
      policyDefinitionId: configureVmBackupPolicyDefinitionId
      definitionVersion: '9.*.*'
      location: deploymentLocation
      identity: {
        type: 'SystemAssigned'
      }
      verifiedRoleDefinitionIds: [
        virtualMachineContributorRoleDefinitionId
        backupContributorRoleDefinitionId
      ]
      enforcementMode: denyPolicyEnforcementMode
      parameters: {
        effect: {
          value: vmBackupConfigurationEffect
        }
        vaultLocation: {
          value: approvedVault.region
        }
        inclusionTagName: {
          value: vmBackupInclusionTagName
        }
        inclusionTagValue: {
          value: approvedVault.inclusionTagValues
        }
        backupPolicyId: {
          value: approvedVault.backupPolicyResourceId
        }
      }
    }
    dependsOn: [
      hierarchy
    ]
  }
]

// The vault diagnostics control keeps least privilege by effect: an AuditIfNotExists or Disabled
// assignment only reports, so it is created without a managed identity and without any role
// assignment. Only the explicit DeployIfNotExists effect uses the remediating assignment that
// attaches an identity and grants Log Analytics Contributor.
module vaultDiagnosticsAuditAssignment 'modules/policy-assignment.bicep' = if (vaultDiagnosticsAuditActive) {
  name: 'assign-vault-diagnostics-audit'
  scope: managementGroup(landingZonesManagementGroupId)
  params: {
    assignmentName: 'demo-vault-diagnostics'
    displayName: 'Demo - Recovery Services vault diagnostics'
    description: 'Reports Recovery Services vaults without diagnostic settings that send logs to the effective central Log Analytics workspace. This assignment has no identity and deploys nothing.'
    policyDefinitionId: resourceDiagnosticsToLogAnalyticsPolicySetDefinitionId
    definitionVersion: '1.*.*'
    enforcementMode: denyPolicyEnforcementMode
    parameters: {
      effect: {
        value: vaultDiagnosticsEffect
      }
      logAnalytics: {
        value: centralMonitoring.outputs.effectiveLogAnalyticsWorkspaceResourceId
      }
      resourceTypeList: {
        value: [
          'microsoft.recoveryservices/vaults'
        ]
      }
    }
  }
  dependsOn: [
    hierarchy
  ]
}

module vaultDiagnosticsAssignment 'modules/remediating-policy-assignment.bicep' = if (vaultDiagnosticsRemediationActive) {
  name: 'assign-vault-diagnostics'
  scope: managementGroup(landingZonesManagementGroupId)
  params: {
    assignmentName: 'demo-vault-diagnostics'
    displayName: 'Demo - Recovery Services vault diagnostics'
    description: 'Sends Recovery Services vault logs to the effective central Log Analytics workspace. Remediation tasks are not started by this template.'
    policyDefinitionId: resourceDiagnosticsToLogAnalyticsPolicySetDefinitionId
    definitionVersion: '1.*.*'
    location: deploymentLocation
    identity: {
      type: 'SystemAssigned'
    }
    verifiedRoleDefinitionIds: [
      logAnalyticsContributorRoleDefinitionId
    ]
    enforcementMode: denyPolicyEnforcementMode
    parameters: {
      effect: {
        value: vaultDiagnosticsEffect
      }
      logAnalytics: {
        value: centralMonitoring.outputs.effectiveLogAnalyticsWorkspaceResourceId
      }
      resourceTypeList: {
        value: [
          'microsoft.recoveryservices/vaults'
        ]
      }
    }
  }
  dependsOn: [
    hierarchy
  ]
}

module vaultDiagnosticsWorkspaceRbac 'modules/workspace-diagnostics-rbac.bicep' = if (vaultDiagnosticsWorkspaceAccessActive) {
  name: 'vault-diagnostics-workspace-rbac'
  scope: resourceGroup(vaultDiagnosticsWorkspaceIdParts[2], vaultDiagnosticsWorkspaceIdParts[4])
  params: {
    principalId: vaultDiagnosticsRemediationActive ? vaultDiagnosticsAssignment!.outputs.identityPrincipalId : ''
    roleDefinitionIds: [
      logAnalyticsContributorRoleDefinitionId
    ]
    workspaceName: vaultDiagnosticsWorkspaceIdParts[8]
  }
}

module customerOwnedBackupVault 'modules/backup-vault.bicep' = if (customerOwnedVaultActive) {
  name: 'customer-owned-backup-vault'
  scope: subscription(workloadSubscriptionId)
  params: {
    deployRecoveryServicesVault: deployRecoveryServicesVault
    namePrefix: namePrefix
    location: recoveryServicesVaultLocation
    tags: {
      ApplicationName: 'Landing Zone Demo'
      Environment: 'Sandbox'
      Owner: 'Workload Team'
      CostCenter: 'Demo'
      DataClassification: 'Non-sensitive'
      'SSP-ID': 'Demo'
      BackupRetentionStandard: empty(trim(backupRetentionStandardId)) ? 'Undocumented' : trim(backupRetentionStandardId)
    }
    immutabilityState: vaultImmutabilityState
    softDeleteState: vaultSoftDeleteState
    softDeleteRetentionInDays: vaultSoftDeleteRetentionInDays
    dailyRetentionInDays: backupDailyRetentionInDays
    weeklyRetentionInWeeks: backupWeeklyRetentionInWeeks
    monthlyRetentionInMonths: backupMonthlyRetentionInMonths
    yearlyRetentionInYears: backupYearlyRetentionInYears
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

module policyExemptionModules 'modules/policy-exemption.bicep' = [for (exemption, exemptionIndex) in policyExemptions: {
  name: 'policy-exemption-${exemptionIndex}-${uniqueString(deployment().name, exemption.exemptionName, exemption.policyAssignmentId)}'
  params: {
    exemptionName: exemption.exemptionName
    exemptionScopeType: exemption.exemptionScopeType
    managementGroupName: exemption.managementGroupName
    subscriptionId: exemption.subscriptionId
    resourceGroupName: exemption.resourceGroupName
    policyAssignmentId: exemption.policyAssignmentId
    displayName: exemption.displayName
    description: exemption.description
    exemptionCategory: exemption.exemptionCategory
    owner: exemption.owner
    justification: exemption.justification
    expiresOn: exemption.expiresOn
    ticketReference: exemption.ticketReference
    policyDefinitionReferenceIds: exemption.policyDefinitionReferenceIds
    allowedPolicyDefinitionReferenceIds: exemption.allowedPolicyDefinitionReferenceIds
    permittedAncestorAssignmentScopeIds: exemption.permittedAncestorAssignmentScopeIds
    source: exemption.source
    approver: exemption.approver
    createdOn: exemption.createdOn
    reviewedOn: exemption.reviewedOn
    governanceOwner: exemption.governanceOwner
  }
  dependsOn: [
    hierarchy
  ]
}]

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

var vmBackupRemediationActive = enableVmBackupRemediation && validatedVmBackupRemediation
var vaultDiagnosticsActive = enableVaultDiagnostics && validatedVaultDiagnostics
var customerOwnedVaultActive = deployRecoveryServicesVault && validatedRecoveryServicesVaultCreation
var vaultDiagnosticsRemediationActive = vaultDiagnosticsActive && vaultDiagnosticsEffect == 'DeployIfNotExists'
var vaultDiagnosticsAuditActive = vaultDiagnosticsActive && vaultDiagnosticsEffect != 'DeployIfNotExists'
var vaultDiagnosticsWorkspaceAccessActive = grantVaultDiagnosticsWorkspaceAccess && vaultDiagnosticsRemediationActive && validatedVaultDiagnosticsWorkspaceAccess

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


output defenderCspmPolicyAssignmentId string = defenderCspmAssignment.outputs.policyAssignmentId
output defenderCspmIdentityPrincipalId string = defenderCspmAssignment.outputs.identityPrincipalId
output defenderForServersPolicyAssignmentId string = defenderForServersAssignment.outputs.policyAssignmentId
output defenderForServersIdentityPrincipalId string = defenderForServersAssignment.outputs.identityPrincipalId
output defenderForStoragePolicyAssignmentId string = defenderForStorageAssignment.outputs.policyAssignmentId
output defenderForStorageIdentityPrincipalId string = defenderForStorageAssignment.outputs.identityPrincipalId
output defenderAmaAuditWindowsPolicyAssignmentId string = defenderAmaAuditWindowsAssignment.outputs.policyAssignmentId
output defenderAmaAuditLinuxPolicyAssignmentId string = defenderAmaAuditLinuxAssignment.outputs.policyAssignmentId
output tagInheritanceRemediation object = {
  enabled: enableTagInheritance
  policyAssignmentId: tagInheritanceAssignment.?outputs.?policyAssignmentId ?? ''
  policyDefinitionReferenceIds: tagInheritanceInitiative.outputs.policyDefinitionReferenceIds
  remediationStarted: false
}

@description('Backup governance posture. Safe defaults create no vault, configure no backup, and start no remediation.')
output backupGovernance object = {
  vmBackupCoverageEffect: vmBackupCoveragePolicyEffect
  vaultPublicNetworkAccessEffect: vaultPublicNetworkPolicyEffect
  vaultEncryptionEffect: vaultEncryptionPolicyEffect
  vaultDoubleEncryptionRequired: vaultDoubleEncryptionRequired
  vaultImmutabilityEffect: vaultImmutabilityPolicyEffect
  vaultCheckLockedImmutabilityOnly: vaultCheckLockedImmutabilityOnly
  vaultSoftDeleteEffect: vaultSoftDeletePolicyEffect
  vaultCheckAlwaysOnSoftDeleteOnly: vaultCheckAlwaysOnSoftDeleteOnly
  vaultMultiUserAuthorizationEffect: vaultMultiUserAuthorizationPolicyEffect
  approvedVaultRegions: normalizedApprovedVaultRegions
  crossSubscriptionVaultsApproved: allowCrossSubscriptionBackupVaults
  approvedVaultCount: length(validatedApprovedBackupVaults)
  backupRetentionStandardId: backupRetentionStandardId
  vmBackupRemediationEnabled: vmBackupRemediationActive
  vmBackupConfigurationEffect: enableVmBackupRemediation ? vmBackupConfigurationEffect : 'Disabled'
  vaultDiagnosticsEnabled: vaultDiagnosticsActive
  customerOwnedVaultRequested: customerOwnedVaultActive
}

@description('Documented workload-to-vault placement mapping used as the integration target for virtual machine backup configuration.')
output backupWorkloadToVaultMapping array = [
  for approvedVault in validatedApprovedBackupVaults: {
    workload: approvedVault.workload
    region: approvedVault.region
    vaultResourceId: approvedVault.vaultResourceId
    backupPolicyResourceId: approvedVault.backupPolicyResourceId
  }
]

@description('Remediating assignment identities and role assignments available for a manually started remediation. This template never starts a remediation task, but a DeployIfNotExists effect under enforcementMode Default also protects matching virtual machines automatically on create or update, and creates vault diagnostic settings automatically on vault create or update.')
output backupRemediation object = {
  remediationTasksStarted: false
  vmBackupEnforcementMode: denyPolicyEnforcementMode
  vmBackupAutomaticProtectionOnResourceWrite: vmBackupRemediationActive && vmBackupConfigurationEffect == 'DeployIfNotExists' && denyPolicyEnforcementMode == 'Default'
  vmBackupRoleDefinitionIds: [
    virtualMachineContributorRoleDefinitionId
    backupContributorRoleDefinitionId
  ]
  vaultDiagnosticsAssignmentId: vaultDiagnosticsRemediationActive
    ? vaultDiagnosticsAssignment!.outputs.policyAssignmentId
    : vaultDiagnosticsAuditActive ? vaultDiagnosticsAuditAssignment!.outputs.policyAssignmentId : ''
  vaultDiagnosticsIdentityAttached: vaultDiagnosticsRemediationActive
  vaultDiagnosticsRoleDefinitionIds: vaultDiagnosticsRemediationActive
    ? [
        logAnalyticsContributorRoleDefinitionId
      ]
    : []
  vaultDiagnosticsEnforcementMode: denyPolicyEnforcementMode
  vaultDiagnosticsAutomaticSettingsOnResourceWrite: vaultDiagnosticsRemediationActive && denyPolicyEnforcementMode == 'Default'
  vaultDiagnosticsPrincipalId: vaultDiagnosticsRemediationActive ? vaultDiagnosticsAssignment!.outputs.identityPrincipalId : ''
  vaultDiagnosticsWorkspaceResourceId: vaultDiagnosticsActive ? vaultDiagnosticsWorkspaceResourceId : ''
  vaultDiagnosticsWorkspaceAccessGranted: vaultDiagnosticsWorkspaceAccessActive
  vaultDiagnosticsWorkspaceRoleAssignmentIds: vaultDiagnosticsWorkspaceAccessActive
    ? vaultDiagnosticsWorkspaceRbac!.outputs.roleAssignmentIds
    : []
  remediationLocation: deploymentLocation
}

@description('Policy assignment IDs of the opt-in virtual machine backup remediating assignments. Remediation tasks must be started manually against these assignments.')
output backupVmRemediationAssignmentIds array = [
  for (approvedVault, approvedVaultIndex) in validatedApprovedBackupVaults: vmBackupRemediationActive
    ? vmBackupConfigurationAssignments[approvedVaultIndex]!.outputs.policyAssignmentId
    : ''
]

@description('Managed identity principal IDs of the opt-in virtual machine backup remediating assignments.')
output backupVmRemediationPrincipalIds array = [
  for (approvedVault, approvedVaultIndex) in validatedApprovedBackupVaults: vmBackupRemediationActive
    ? vmBackupConfigurationAssignments[approvedVaultIndex]!.outputs.identityPrincipalId
    : ''
]

@description('Customer-owned vault created by this deployment, or empty values when the preferred existing-vault integration path is used.')
output customerOwnedBackupVault object = {
  vaultCreated: customerOwnedVaultActive
  vaultResourceId: customerOwnedVaultActive ? customerOwnedBackupVault!.outputs.vaultResourceId : ''
  backupPolicyResourceId: customerOwnedVaultActive ? customerOwnedBackupVault!.outputs.backupPolicyResourceId : ''
  retentionPosture: customerOwnedVaultActive ? customerOwnedBackupVault!.outputs.vaultRetentionPosture : {}
}
