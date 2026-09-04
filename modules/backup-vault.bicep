targetScope = 'subscription'

@description('Set true only to create a metered, customer-owned Recovery Services vault. Leave false (default) and integrate an approved existing vault instead; a vault plus protected items introduces ongoing backup storage charges.')
param deployRecoveryServicesVault bool = false

@description('Set true to create a customer-owned VM backup policy in the new vault. Only used when deployRecoveryServicesVault is true.')
param createBackupPolicy bool = true

@description('Unique lowercase prefix used to name any newly created backup resources.')
@minLength(3)
@maxLength(24)
param namePrefix string

@description('Azure region for the newly created vault. Must be an approved vault region in the same subscription and region as the workloads it protects.')
param location string

@description('Additional tags applied to the created backup resources. The metered, customer-owned cost model is always recorded on top of these tags.')
param tags object = {}

@description('Standard-tier backup storage redundancy for the created vault.')
@allowed([
  'LocallyRedundant'
  'ZoneRedundant'
  'GeoRedundant'
])
param storageRedundancy string = 'LocallyRedundant'

@description('Public network access for the created vault. Disabled is the default and requires customer-supplied private endpoints.')
@allowed([
  'Disabled'
  'Enabled'
])
param publicNetworkAccess string = 'Disabled'

@description('Soft-delete state for the created vault. AlwaysON cannot be reversed.')
@allowed([
  'Enabled'
  'AlwaysON'
])
param softDeleteState string = 'Enabled'

@description('Soft-delete retention period in days for the created vault.')
@minValue(14)
@maxValue(180)
param softDeleteRetentionInDays int = 14

@description('Immutability state for the created vault. Locked is irreversible; Unlocked is the reversible default.')
@allowed([
  'Disabled'
  'Unlocked'
  'Locked'
])
param immutabilityState string = 'Unlocked'

@description('Daily backup schedule run time in UTC ISO 8601 form.')
param backupScheduleRunTime string = '2026-01-01T02:00:00Z'

@description('Time zone name used by the backup schedule.')
@minLength(1)
param backupScheduleTimeZone string = 'UTC'

@description('Daily recovery point retention in days. No universal retention period is assumed for every workload.')
@minValue(7)
@maxValue(9999)
param dailyRetentionInDays int = 30

@description('Weekly recovery point retention in weeks. 0 disables weekly retention.')
@minValue(0)
@maxValue(5163)
param weeklyRetentionInWeeks int = 0

@description('Monthly recovery point retention in months. 0 disables monthly retention.')
@minValue(0)
@maxValue(1188)
param monthlyRetentionInMonths int = 0

@description('Yearly recovery point retention in years. 0 disables yearly retention.')
@minValue(0)
@maxValue(99)
param yearlyRetentionInYears int = 0

@description('Instant restore snapshot retention in days.')
@minValue(1)
@maxValue(30)
param instantRestoreRetentionInDays int = 2

@description('Day of the week retained by the weekly, monthly, and yearly retention schedules.')
@allowed([
  'Sunday'
  'Monday'
  'Tuesday'
  'Wednesday'
  'Thursday'
  'Friday'
  'Saturday'
])
param retentionDayOfWeek string = 'Sunday'

@description('Month retained by the yearly retention schedule.')
@allowed([
  'January'
  'February'
  'March'
  'April'
  'May'
  'June'
  'July'
  'August'
  'September'
  'October'
  'November'
  'December'
])
param retentionMonthOfYear string = 'January'

// Creating a vault is a metered, customer-owned decision, so the switch alone must not be
// enough: an unusable location would otherwise silently produce an unplaceable vault.
var requestedLocation = trim(location)
var invalidVaultLocation = deployRecoveryServicesVault && (empty(requestedLocation) || toLower(requestedLocation) == 'global')

// A deliberately unresolvable resource type is used as a configuration guard: it is never
// registered as an Azure resource provider, so Azure Resource Manager rejects the deployment
// before any metered backup resource is created, and the resource name surfaces the error.
resource vaultLocationGuard 'Microsoft.BackupVaultGuard/configurationError@2024-01-01' = if (invalidVaultLocation) {
  name: 'deployRecoveryServicesVault-requires-a-non-global-approved-vault-region'
}

var createVault = deployRecoveryServicesVault && !invalidVaultLocation
var resourceGroupName = 'rg-${namePrefix}-backup'
var vaultTags = union(tags, {
  CostModel: 'Metered'
  Ownership: 'Customer-owned'
  Purpose: 'Backup'
  ESLZLifecycleOwner: namePrefix
})

resource backupResourceGroup 'Microsoft.Resources/resourceGroups@2025-04-01' = if (createVault) {
  name: resourceGroupName
  location: requestedLocation
  tags: vaultTags
}

module vaultResources 'backup-vault-resources.bicep' = if (createVault) {
  name: 'customer-owned-backup-vault'
  scope: resourceGroup(resourceGroupName)
  params: {
    namePrefix: namePrefix
    location: requestedLocation
    tags: vaultTags
    storageRedundancy: storageRedundancy
    publicNetworkAccess: publicNetworkAccess
    softDeleteState: softDeleteState
    softDeleteRetentionInDays: softDeleteRetentionInDays
    immutabilityState: immutabilityState
    createBackupPolicy: createBackupPolicy
    backupScheduleRunTime: backupScheduleRunTime
    backupScheduleTimeZone: backupScheduleTimeZone
    dailyRetentionInDays: dailyRetentionInDays
    weeklyRetentionInWeeks: weeklyRetentionInWeeks
    monthlyRetentionInMonths: monthlyRetentionInMonths
    yearlyRetentionInYears: yearlyRetentionInYears
    instantRestoreRetentionInDays: instantRestoreRetentionInDays
    retentionDayOfWeek: retentionDayOfWeek
    retentionMonthOfYear: retentionMonthOfYear
  }
  dependsOn: [
    backupResourceGroup
  ]
}

@description('True when this deployment created a metered, customer-owned vault.')
output vaultCreated bool = createVault

@description('Resource ID of the created vault, or empty when no vault was created.')
// The null-forgiving '!' operator is safe here: this branch only evaluates when createVault
// is true, which is the exact condition under which the vaultResources module is deployed.
output vaultResourceId string = createVault ? vaultResources!.outputs.vaultResourceId : ''

@description('Resource ID of the created VM backup policy, or empty when none was created.')
output backupPolicyResourceId string = createVault ? vaultResources!.outputs.backupPolicyResourceId : ''

@description('Name of the resource group created for the vault, or empty when no vault was created.')
output backupResourceGroupName string = createVault ? resourceGroupName : ''

@description('Retention posture recorded for the created vault. Empty values are reported when no vault was created.')
output vaultRetentionPosture object = {
  dailyRetentionInDays: createVault ? dailyRetentionInDays : 0
  weeklyRetentionInWeeks: createVault ? weeklyRetentionInWeeks : 0
  monthlyRetentionInMonths: createVault ? monthlyRetentionInMonths : 0
  yearlyRetentionInYears: createVault ? yearlyRetentionInYears : 0
  softDeleteState: createVault ? softDeleteState : ''
  softDeleteRetentionInDays: createVault ? softDeleteRetentionInDays : 0
  immutabilityState: createVault ? immutabilityState : ''
  publicNetworkAccess: createVault ? publicNetworkAccess : ''
  storageRedundancy: createVault ? storageRedundancy : ''
}
