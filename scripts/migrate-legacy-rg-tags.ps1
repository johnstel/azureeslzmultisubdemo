[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$ParameterFile,

    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir
if ([string]::IsNullOrWhiteSpace($ParameterFile)) {
    $ParameterFile = Join-Path $ProjectDir 'parameters/demo.parameters.json'
}

function Stop-Migration {
    param([string]$Message, [int]$ExitCode = 1)
    Write-Error $Message -ErrorAction Continue
    exit $ExitCode
}

if (-not (Test-Path -LiteralPath $ParameterFile -PathType Leaf)) {
    Stop-Migration "Parameter file not found: $ParameterFile"
}
try {
    $parameters = Get-Content -LiteralPath $ParameterFile -Raw | ConvertFrom-Json
    $tenantRoot = [string]$parameters.parameters.tenantRootManagementGroupId.value
    $prefix = [string]$parameters.parameters.namePrefix.value
    $archetype = [string]$parameters.parameters.workloadArchetype.value
    $connectivitySubscription = [string]$parameters.parameters.connectivitySubscriptionId.value
    $workloadSubscription = [string]$parameters.parameters.workloadSubscriptionId.value
}
catch {
    Stop-Migration "Unable to read required parameters: $($_.Exception.Message)"
}
if ($prefix -cnotmatch '^[a-z0-9][a-z0-9-]{2,23}$') {
    Stop-Migration 'namePrefix must be 3-24 lowercase letters, numbers, or hyphens and start with a letter or number.'
}
if ($archetype -cne 'corp' -and $archetype -cne 'online') {
    Stop-Migration 'workloadArchetype must be corp or online.'
}

$legacyAssignmentName = 'demo-require-rg-tags'
$legacyDefinitionName = "$prefix-require-workload-rg-tags"
$replacementInitiativeName = "$prefix-required-rg-tags"
$demoRootScope = "/providers/Microsoft.Management/managementGroups/$prefix"
$tenantRootScope = "/providers/Microsoft.Management/managementGroups/$tenantRoot"
$landingZonesScope = "/providers/Microsoft.Management/managementGroups/$prefix-landingzones"
$workloadScope = "/providers/Microsoft.Management/managementGroups/$prefix-$archetype"
$legacyDefinitionId = "$demoRootScope/providers/Microsoft.Authorization/policyDefinitions/$legacyDefinitionName"
$legacyAssignmentId = "$workloadScope/providers/Microsoft.Authorization/policyAssignments/$legacyAssignmentName"
$replacementInitiativeId = "$landingZonesScope/providers/Microsoft.Authorization/policySetDefinitions/$replacementInitiativeName"
$replacementAssignmentId = "$landingZonesScope/providers/Microsoft.Authorization/policyAssignments/$legacyAssignmentName"

Write-Host 'LEGACY RESOURCE-GROUP TAG POLICY MIGRATION PLAN'
Write-Host '  1. Validate the active tenant/subscription, exact demo ancestry, legacy relationship, and replacement controls.'
Write-Host "  2. Remove assignment $legacyAssignmentName only at $workloadScope when it exists."
Write-Host "  3. Remove custom policy definition $legacyDefinitionName only from management group $prefix when it exists."
Write-Host 'The replacement initiative must be previewed, deployed, and approved before execution.'

if (-not $Execute) {
    Write-Host 'Dry run only. Add -Execute to perform read-only validation before the documented approval prompts.'
    exit 0
}
if ($null -eq (Get-Command az -ErrorAction SilentlyContinue)) {
    Stop-Migration 'Azure CLI is required for execution.'
}

function Read-AzureRequired {
    param([string]$Description, [string[]]$Arguments)
    $errorFile = Join-Path ([IO.Path]::GetTempPath()) "eslz-migration-$PID-$([guid]::NewGuid().ToString('N')).err"
    try {
        $output = (& az @Arguments --output json 2>$errorFile | Out-String)
        if ($LASTEXITCODE -ne 0) {
            $errorText = Get-Content -LiteralPath $errorFile -Raw
            Stop-Migration "Cannot validate ${Description}: $errorText"
        }
        return ($output | ConvertFrom-Json)
    }
    finally {
        Remove-Item -LiteralPath $errorFile -Force -ErrorAction SilentlyContinue
    }
}

function Read-AzureOptional {
    param([string]$Description, [string]$NotFoundPattern, [string[]]$Arguments)
    $errorFile = Join-Path ([IO.Path]::GetTempPath()) "eslz-migration-$PID-$([guid]::NewGuid().ToString('N')).err"
    try {
        $output = (& az @Arguments --output json 2>$errorFile | Out-String)
        if ($LASTEXITCODE -eq 0) {
            return [pscustomobject]@{ Exists = $true; Resource = ($output | ConvertFrom-Json) }
        }
        $errorText = Get-Content -LiteralPath $errorFile -Raw
        if ($errorText -match $NotFoundPattern) {
            Write-Host "Already absent: $Description."
            return [pscustomobject]@{ Exists = $false; Resource = $null }
        }
        Stop-Migration "Cannot validate ${Description}: $errorText"
    }
    finally {
        Remove-Item -LiteralPath $errorFile -Force -ErrorAction SilentlyContinue
    }
}

$activeAccount = Read-AzureRequired 'the active Azure account' @('account', 'show')
$activeTenant = [string]$activeAccount.tenantId
$activeSubscription = [string]$activeAccount.id
if ([string]$activeAccount.state -cne 'Enabled') {
    Stop-Migration 'The active Azure subscription is not enabled.'
}
if ($activeSubscription -ine $connectivitySubscription -and $activeSubscription -ine $workloadSubscription) {
    Stop-Migration 'The active Azure subscription is not one of the two subscriptions in the parameter file.'
}
$connectivityAccount = Read-AzureRequired 'the connectivity subscription' @('account', 'show', '--subscription', $connectivitySubscription)
$workloadAccount = Read-AzureRequired 'the workload subscription' @('account', 'show', '--subscription', $workloadSubscription)
if ($activeTenant -ine [string]$connectivityAccount.tenantId -or $activeTenant -ine [string]$workloadAccount.tenantId) {
    Stop-Migration 'The active account and both supplied subscriptions must belong to the same tenant.'
}
if ([string]$connectivityAccount.id -ine $connectivitySubscription -or [string]$connectivityAccount.state -cne 'Enabled') {
    Stop-Migration 'The connectivity subscription response does not match an enabled supplied subscription.'
}
if ([string]$workloadAccount.id -ine $workloadSubscription -or [string]$workloadAccount.state -cne 'Enabled') {
    Stop-Migration 'The workload subscription response does not match an enabled supplied subscription.'
}

$tenantRootGroup = Read-AzureRequired 'the tenant root management group' @('account', 'management-group', 'show', '--name', $tenantRoot)
$demoRoot = Read-AzureRequired 'the demo root management group' @('account', 'management-group', 'show', '--name', $prefix)
$landingZones = Read-AzureRequired 'the Landing Zones management group' @('account', 'management-group', 'show', '--name', "$prefix-landingzones")
$workloadGroup = Read-AzureRequired 'the workload management group' @('account', 'management-group', 'show', '--name', "$prefix-$archetype")
if ([string]$tenantRootGroup.id -ine $tenantRootScope) { Stop-Migration 'The tenant root management-group ID does not match tenantRootManagementGroupId.' }
if ([string]$demoRoot.id -ine $demoRootScope) { Stop-Migration 'The demo root management-group ID does not match namePrefix.' }
if ([string]$landingZones.id -ine $landingZonesScope) { Stop-Migration 'The Landing Zones management-group ID does not match namePrefix.' }
if ([string]$workloadGroup.id -ine $workloadScope) { Stop-Migration 'The workload management-group ID does not match namePrefix and workloadArchetype.' }
if ([string]$demoRoot.details.parent.id -ine $tenantRootScope) { Stop-Migration 'The demo root is not an exact child of tenantRootManagementGroupId.' }
if ([string]$landingZones.details.parent.id -ine $demoRootScope) { Stop-Migration 'The Landing Zones management group is not an exact child of the demo root.' }
if ([string]$workloadGroup.details.parent.id -ine $landingZonesScope) { Stop-Migration 'The workload management group is not an exact child of Landing Zones.' }

$replacementInitiative = Read-AzureRequired 'the replacement tagging initiative' @(
    'policy', 'set-definition', 'show', '--name', $replacementInitiativeName, '--management-group', "$prefix-landingzones"
)
if ([string]$replacementInitiative.id -ine $replacementInitiativeId) {
    Stop-Migration 'The replacement tagging initiative has an unexpected resource ID.'
}
$replacementAssignment = Read-AzureRequired 'the replacement Landing Zones assignment' @(
    'policy', 'assignment', 'show', '--name', $legacyAssignmentName, '--scope', $landingZonesScope
)
if ([string]$replacementAssignment.id -ine $replacementAssignmentId) {
    Stop-Migration 'The replacement Landing Zones assignment has an unexpected resource ID.'
}
if ([string]$replacementAssignment.policyDefinitionId -ine $replacementInitiativeId) {
    Stop-Migration 'The replacement Landing Zones assignment does not reference the replacement tagging initiative.'
}

$legacyAssignment = Read-AzureOptional 'legacy workload assignment' 'PolicyAssignmentNotFound|ResourceNotFound' @(
    'policy', 'assignment', 'show', '--name', $legacyAssignmentName, '--scope', $workloadScope
)
if ($legacyAssignment.Exists -and [string]$legacyAssignment.Resource.id -ine $legacyAssignmentId) {
    Stop-Migration 'The legacy workload assignment has an unexpected resource ID.'
}
if ($legacyAssignment.Exists -and [string]$legacyAssignment.Resource.policyDefinitionId -ine $legacyDefinitionId) {
    Stop-Migration 'The legacy workload assignment does not reference the exact obsolete custom definition.'
}
$legacyDefinition = Read-AzureOptional 'obsolete custom tag definition' 'PolicyDefinitionNotFound|ResourceNotFound' @(
    'policy', 'definition', 'show', '--name', $legacyDefinitionName, '--management-group', $prefix
)
if ($legacyDefinition.Exists -and [string]$legacyDefinition.Resource.id -ine $legacyDefinitionId) {
    Stop-Migration 'The obsolete custom definition has an unexpected resource ID.'
}

Write-Host "Validated active tenant $activeTenant and subscription $activeSubscription; replacement controls are present."
if (-not $legacyAssignment.Exists -and -not $legacyDefinition.Exists) {
    Write-Host 'Migration already complete; no delete operation is required.'
    exit 0
}
if ($env:ESLZ_TAG_MIGRATION_CONFIRMATION -cne 'REMOVE-LEGACY-RG-TAG-POLICY') {
    Stop-Migration 'Set ESLZ_TAG_MIGRATION_CONFIRMATION=REMOVE-LEGACY-RG-TAG-POLICY only after reviewing the validated context above.' 2
}
$expectedConfirmation = "$activeTenant/$prefix-$archetype"
$typedConfirmation = Read-Host "Type the validated tenant and legacy workload management group ($expectedConfirmation) to continue"
if ($typedConfirmation -cne $expectedConfirmation) {
    Stop-Migration 'Confirmation did not match; migration cancelled.' 2
}

if ($legacyAssignment.Exists) {
    & az policy assignment delete --name $legacyAssignmentName --scope $workloadScope
    if ($LASTEXITCODE -ne 0) { Stop-Migration 'Failed to remove the legacy resource-group tag assignment.' }
}
if ($legacyDefinition.Exists) {
    & az policy definition delete --name $legacyDefinitionName --management-group $prefix
    if ($LASTEXITCODE -ne 0) { Stop-Migration 'Failed to remove the legacy resource-group tag definition.' }
}

Write-Host 'Legacy resource-group tag policy migration completed.'
