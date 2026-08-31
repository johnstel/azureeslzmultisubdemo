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

function Stop-Teardown {
    param(
        [string]$Message,
        [int]$ExitCode = 1
    )
    Write-Error $Message -ErrorAction Continue
    exit $ExitCode
}

if ($null -eq (Get-Command az -ErrorAction SilentlyContinue)) {
    Stop-Teardown "Required command 'az' is not installed."
}
if (-not (Test-Path -LiteralPath $ParameterFile -PathType Leaf)) {
    Stop-Teardown "Parameter file not found: $ParameterFile"
}

$parameterText = Get-Content -LiteralPath $ParameterFile -Raw
try {
    $parameters = $parameterText | ConvertFrom-Json
}
catch {
    Stop-Teardown "Parameter file is not valid JSON: $($_.Exception.Message)"
}

function Get-Value {
    param([string]$Name)
    $property = $parameters.parameters.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value.value) {
        Stop-Teardown "Required parameter '$Name' is missing."
    }
    return [string]$property.Value.value
}

function Get-OptionalBoolValue {
    param(
        [string]$Name,
        [bool]$Default
    )
    $property = $parameters.parameters.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value.value) {
        return $Default
    }
    return [bool]$property.Value.value
}

$tenantRoot = Get-Value 'tenantRootManagementGroupId'
$prefix = Get-Value 'namePrefix'
$archetype = Get-Value 'workloadArchetype'
$connectivitySubscription = Get-Value 'connectivitySubscriptionId'
$workloadSubscription = Get-Value 'workloadSubscriptionId'
$governanceGroup = Get-Value 'governanceAdminsGroupObjectId'
$ownersGroup = Get-Value 'subscriptionOwnersGroupObjectId'
$networkGroup = Get-Value 'networkOperatorsGroupObjectId'
$workloadGroup = Get-Value 'workloadContributorsGroupObjectId'
$auditorsGroup = Get-Value 'readOnlyAuditorsGroupObjectId'
# Optional: defaults to $false when absent so older parameter files remain safe to tear down.
$centralLogAnalyticsEnabled = Get-OptionalBoolValue 'deployCentralLogAnalytics' $false

$demoRootScope = "/providers/Microsoft.Management/managementGroups/$prefix"
$platformScope = "/providers/Microsoft.Management/managementGroups/$prefix-platform"
$workloadScope = "/providers/Microsoft.Management/managementGroups/$prefix-$archetype"
$connectivityScope = "/subscriptions/$connectivitySubscription"
$subscriptionWorkloadScope = "/subscriptions/$workloadSubscription"
$monitoringResourceGroupName = "rg-$prefix-monitoring"

Write-Host 'TEARDOWN PLAN (reverse dependency order)'
Write-Host "  1. Delete resource groups rg-$prefix-connectivity and rg-$prefix-$archetype-demo if present."
if ($centralLogAnalyticsEnabled) {
    Write-Host "  1a. Delete the demo-created monitoring resource group $monitoringResourceGroupName (deployCentralLogAnalytics=true)."
}
Write-Host '  2. Delete only the seven demo role assignments for the five groups at their documented scopes.'
Write-Host '  3. Delete demo policy assignments and the five custom policy definitions.'
Write-Host "  4. Move subscriptions $connectivitySubscription and $workloadSubscription back to $tenantRoot."
Write-Host "  5. Delete management groups $prefix-connectivity, $prefix-platform, $prefix-$archetype, $prefix-landingzones, then $prefix."
Write-Host ''
Write-Host 'Subscriptions, Entra groups, and any customer-supplied existing Log Analytics workspace are never deleted.'

if (-not $Execute) {
    Write-Host ''
    Write-Host 'Dry run only. Add -Execute and the documented environment confirmation to perform teardown.'
    exit 0
}

if ($parameterText -match 'REPLACE_WITH_') {
    Stop-Teardown 'Execution is blocked because the parameter file still contains REPLACE_WITH_* placeholders.' 2
}
if ($env:ESLZ_TEARDOWN_CONFIRMATION -ne 'DELETE-ESLZ-DEMO') {
    Stop-Teardown 'Set ESLZ_TEARDOWN_CONFIRMATION=DELETE-ESLZ-DEMO to unlock teardown.' 2
}

$typedConfirmation = Read-Host "Type the demo root ID ($prefix) to permanently remove this demo"
if ($typedConfirmation -ne $prefix) {
    Stop-Teardown 'Confirmation did not match; teardown cancelled.' 2
}

function Remove-RoleMapping {
    param(
        [string]$Assignee,
        [string]$Role,
        [string]$Scope
    )
    & az role assignment delete --assignee $Assignee --role $Role --scope $Scope 2>$null
}

function Remove-PolicyAssignment {
    param(
        [string]$AssignmentName,
        [string]$Scope
    )
    & az policy assignment delete --name $AssignmentName --scope $Scope 2>$null
}

$connectivityResourceGroup = "rg-$prefix-connectivity"
$workloadResourceGroup = "rg-$prefix-$archetype-demo"

$connectivityExists = & az group exists `
    --subscription $connectivitySubscription `
    --name $connectivityResourceGroup `
    --output tsv 2>$null
if ([string]$connectivityExists -eq 'true') {
    & az group delete --subscription $connectivitySubscription --name $connectivityResourceGroup --yes --no-wait
    if ($LASTEXITCODE -ne 0) { Stop-Teardown "Failed to start deletion of $connectivityResourceGroup." }
}

$workloadExists = & az group exists `
    --subscription $workloadSubscription `
    --name $workloadResourceGroup `
    --output tsv 2>$null
if ([string]$workloadExists -eq 'true') {
    & az group delete --subscription $workloadSubscription --name $workloadResourceGroup --yes --no-wait
    if ($LASTEXITCODE -ne 0) { Stop-Teardown "Failed to start deletion of $workloadResourceGroup." }
}

# Only delete the monitoring resource group when this repository created it
# (deployCentralLogAnalytics=true). A supplied existing workspace/resource group is never
# owned by this demo and must never be deleted here.
if ($centralLogAnalyticsEnabled) {
    $monitoringExists = & az group exists `
        --subscription $connectivitySubscription `
        --name $monitoringResourceGroupName `
        --output tsv 2>$null
    if ([string]$monitoringExists -eq 'true') {
        & az group delete --subscription $connectivitySubscription --name $monitoringResourceGroupName --yes --no-wait
        if ($LASTEXITCODE -ne 0) { Stop-Teardown "Failed to start deletion of $monitoringResourceGroupName." }
    }
}

& az group wait --subscription $connectivitySubscription --name $connectivityResourceGroup --deleted --interval 10 --timeout 900 2>$null
& az group wait --subscription $workloadSubscription --name $workloadResourceGroup --deleted --interval 10 --timeout 900 2>$null
if ($centralLogAnalyticsEnabled) {
    & az group wait --subscription $connectivitySubscription --name $monitoringResourceGroupName --deleted --interval 10 --timeout 900 2>$null
}

Remove-RoleMapping $governanceGroup 'Management Group Contributor' $demoRootScope
Remove-RoleMapping $governanceGroup 'Resource Policy Contributor' $demoRootScope
Remove-RoleMapping $auditorsGroup 'Reader' $demoRootScope
Remove-RoleMapping $ownersGroup 'Owner' $connectivityScope
Remove-RoleMapping $networkGroup 'Network Contributor' $connectivityScope
Remove-RoleMapping $ownersGroup 'Owner' $subscriptionWorkloadScope
Remove-RoleMapping $workloadGroup 'Contributor' $subscriptionWorkloadScope

Remove-PolicyAssignment 'demo-require-workload-rg-tags' $workloadScope
Remove-PolicyAssignment 'demo-audit-platform-tags' $platformScope
Remove-PolicyAssignment 'demo-block-expensive' $demoRootScope
Remove-PolicyAssignment 'demo-audit-public-ip' $demoRootScope
Remove-PolicyAssignment 'demo-allowed-us-locations' $demoRootScope

$policyNames = @(
    "$prefix-require-workload-rg-tags",
    "$prefix-audit-platform-tags",
    "$prefix-block-expensive",
    "$prefix-audit-public-ip",
    "$prefix-allowed-us-locations"
)
foreach ($policyName in $policyNames) {
    & az policy definition delete --name $policyName --management-group $prefix 2>$null
}

& az account management-group subscription add --name $tenantRoot --subscription $connectivitySubscription
if ($LASTEXITCODE -ne 0) { Stop-Teardown 'Failed to move the connectivity subscription.' }
& az account management-group subscription add --name $tenantRoot --subscription $workloadSubscription
if ($LASTEXITCODE -ne 0) { Stop-Teardown 'Failed to move the workload subscription.' }

$managementGroups = @(
    "$prefix-connectivity",
    "$prefix-platform",
    "$prefix-$archetype",
    "$prefix-landingzones",
    $prefix
)
foreach ($managementGroup in $managementGroups) {
    & az account management-group delete --name $managementGroup
    if ($LASTEXITCODE -ne 0) { Stop-Teardown "Failed to delete management group $managementGroup." }
}

Write-Host ''
Write-Host 'Teardown commands completed. Verify the hierarchy and both subscriptions in the Azure portal.'
