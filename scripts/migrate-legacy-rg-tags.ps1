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
    param(
        [string]$Message,
        [int]$ExitCode = 1
    )
    Write-Error $Message -ErrorAction Continue
    exit $ExitCode
}

if (-not (Test-Path -LiteralPath $ParameterFile -PathType Leaf)) {
    Stop-Migration "Parameter file not found: $ParameterFile"
}
try {
    $parameters = Get-Content -LiteralPath $ParameterFile -Raw | ConvertFrom-Json
    $prefix = [string]$parameters.parameters.namePrefix.value
    $archetype = [string]$parameters.parameters.workloadArchetype.value
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
$legacyAssignmentScope = "/providers/Microsoft.Management/managementGroups/$prefix-$archetype"
$legacyDefinitionName = "$prefix-require-workload-rg-tags"

Write-Host 'LEGACY RESOURCE-GROUP TAG POLICY MIGRATION PLAN'
Write-Host "  1. Remove assignment $legacyAssignmentName only at $legacyAssignmentScope."
Write-Host "  2. Remove custom policy definition $legacyDefinitionName only from management group $prefix."
Write-Host 'The replacement initiative must be previewed, deployed, and approved before execution.'

if (-not $Execute) {
    Write-Host 'Dry run only. Add -Execute and the documented confirmation after replacement approval.'
    exit 0
}

if ($null -eq (Get-Command az -ErrorAction SilentlyContinue)) {
    Stop-Migration 'Azure CLI is required for execution.'
}
if ($env:ESLZ_TAG_MIGRATION_CONFIRMATION -cne 'REMOVE-LEGACY-RG-TAG-POLICY') {
    Stop-Migration 'Set ESLZ_TAG_MIGRATION_CONFIRMATION=REMOVE-LEGACY-RG-TAG-POLICY only after replacement approval.' 2
}

$expectedConfirmation = "$prefix-$archetype"
$typedConfirmation = Read-Host "Type the legacy workload management group ID ($expectedConfirmation) to continue"
if ($typedConfirmation -cne $expectedConfirmation) {
    Stop-Migration 'Confirmation did not match; migration cancelled.' 2
}

& az policy assignment delete --name $legacyAssignmentName --scope $legacyAssignmentScope
if ($LASTEXITCODE -ne 0) { Stop-Migration 'Failed to remove the legacy resource-group tag assignment.' }
& az policy definition delete --name $legacyDefinitionName --management-group $prefix
if ($LASTEXITCODE -ne 0) { Stop-Migration 'Failed to remove the legacy resource-group tag definition.' }

Write-Host 'Legacy resource-group tag policy artifacts removed.'
