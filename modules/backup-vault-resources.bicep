targetScope = 'resourceGroup'

@description('Unique lowercase prefix used to name the customer-owned Recovery Services vault.')
@minLength(3)
@maxLength(24)
param namePrefix string

@description('Azure region for the customer-owned Recovery Services vault.')
@minLength(1)
param location string

@description('Tags applied to the customer-owned vault. Must record the metered, customer-owned cost model.')
param tags object

@description('Standard-tier backup storage redundancy. LocallyRedundant is the lowest-cost option; GeoRedundant and ZoneRedundant increase storage cost.')
@allowed([
  'LocallyRedundant'
  'ZoneRedundant'
  'GeoRedundant'
])
param storageRedundancy string

@description('Vault public network access. Disabled requires private endpoints supplied by the customer network design.')
@allowed([
  'Disabled'
  'Enabled'
])
param publicNetworkAccess string

@description('Vault soft-delete state. AlwaysON cannot be reversed.')
@allowed([
  'Enabled'
  'AlwaysON'
])
param softDeleteState string

@description('Soft-delete retention period in days for deleted backup data.')
@minValue(14)
@maxValue(180)
param softDeleteRetentionInDays int

@description('Vault immutability state. Locked is irreversible and must be selected deliberately.')
@allowed([
  'Disabled'
  'Unlocked'
  'Locked'
])
param immutabilityState string

@description('Set true to create a customer-owned VM backup policy in the new vault.')
param createBackupPolicy bool

@description('Daily backup schedule run time in UTC ISO 8601 form, for example 2026-01-01T02:00:00Z.')
param backupScheduleRunTime string

@description('Time zone name used by the backup schedule.')
@minLength(1)
param backupScheduleTimeZone string

@description('Daily recovery point retention in days. There is no universal retention period; supply the value required by the workload.')
@minValue(7)
@maxValue(9999)
param dailyRetentionInDays int

@description('Weekly recovery point retention in weeks. 0 disables weekly retention.')
@minValue(0)
@maxValue(5163)
param weeklyRetentionInWeeks int

@description('Monthly recovery point retention in months. 0 disables monthly retention.')
@minValue(0)
@maxValue(1188)
param monthlyRetentionInMonths int

@description('Yearly recovery point retention in years. 0 disables yearly retention.')
@minValue(0)
@maxValue(99)
param yearlyRetentionInYears int

@description('Instant restore snapshot retention in days.')
@minValue(1)
@maxValue(30)
param instantRestoreRetentionInDays int

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
param retentionDayOfWeek string

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
param retentionMonthOfYear string

var weeklyRetentionSchedule = {
  daysOfTheWeek: [
    retentionDayOfWeek
  ]
  weeksOfTheMonth: [
    'First'
  ]
}

resource recoveryServicesVault 'Microsoft.RecoveryServices/vaults@2025-02-01' = {
  name: 'rsv-${namePrefix}-backup'
  location: location
  tags: tags
  sku: {
    name: 'RS0'
    tier: 'Standard'
  }
  properties: {
    publicNetworkAccess: publicNetworkAccess
    redundancySettings: {
      standardTierStorageRedundancy: storageRedundancy
      crossRegionRestore: 'Disabled'
    }
    securitySettings: {
      immutabilitySettings: {
        state: immutabilityState
      }
      softDeleteSettings: {
        softDeleteState: softDeleteState
        softDeleteRetentionPeriodInDays: softDeleteRetentionInDays
      }
    }
  }
}

resource backupPolicy 'Microsoft.RecoveryServices/vaults/backupPolicies@2025-02-01' = if (createBackupPolicy) {
  parent: recoveryServicesVault
  name: 'bkp-${namePrefix}-vm-daily'
  properties: {
    backupManagementType: 'AzureIaasVM'
    policyType: 'V2'
    timeZone: backupScheduleTimeZone
    instantRpRetentionRangeInDays: instantRestoreRetentionInDays
    schedulePolicy: {
      schedulePolicyType: 'SimpleSchedulePolicyV2'
      scheduleRunFrequency: 'Daily'
      dailySchedule: {
        scheduleRunTimes: [
          backupScheduleRunTime
        ]
      }
    }
    retentionPolicy: {
      retentionPolicyType: 'LongTermRetentionPolicy'
      dailySchedule: {
        retentionTimes: [
          backupScheduleRunTime
        ]
        retentionDuration: {
          count: dailyRetentionInDays
          durationType: 'Days'
        }
      }
      ...(weeklyRetentionInWeeks > 0
        ? {
            weeklySchedule: {
              daysOfTheWeek: [
                retentionDayOfWeek
              ]
              retentionTimes: [
                backupScheduleRunTime
              ]
              retentionDuration: {
                count: weeklyRetentionInWeeks
                durationType: 'Weeks'
              }
            }
          }
        : {})
      ...(monthlyRetentionInMonths > 0
        ? {
            monthlySchedule: {
              retentionScheduleFormatType: 'Weekly'
              retentionScheduleWeekly: weeklyRetentionSchedule
              retentionTimes: [
                backupScheduleRunTime
              ]
              retentionDuration: {
                count: monthlyRetentionInMonths
                durationType: 'Months'
              }
            }
          }
        : {})
      ...(yearlyRetentionInYears > 0
        ? {
            yearlySchedule: {
              retentionScheduleFormatType: 'Weekly'
              monthsOfYear: [
                retentionMonthOfYear
              ]
              retentionScheduleWeekly: weeklyRetentionSchedule
              retentionTimes: [
                backupScheduleRunTime
              ]
              retentionDuration: {
                count: yearlyRetentionInYears
                durationType: 'Years'
              }
            }
          }
        : {})
    }
  }
}

@description('Resource ID of the customer-owned Recovery Services vault created by this module.')
output vaultResourceId string = recoveryServicesVault.id

@description('Resource ID of the customer-owned VM backup policy, or empty when no policy was requested.')
output backupPolicyResourceId string = createBackupPolicy ? backupPolicy!.id : ''
