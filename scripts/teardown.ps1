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

function Get-OptionalStringValue {
    param(
        [string]$Name,
        [string]$Default
    )
    $property = $parameters.parameters.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value.value) {
        return $Default
    }
    return [string]$property.Value.value
}

$tenantRoot = Get-Value 'tenantRootManagementGroupId'
$prefix = Get-Value 'namePrefix'
$archetype = Get-Value 'workloadArchetype'
$connectivitySubscription = Get-Value 'connectivitySubscriptionId'
$workloadSubscription = Get-Value 'workloadSubscriptionId'
$governanceGroup = Get-Value 'governanceAdminsGroupObjectId'
$networkGroup = Get-Value 'networkOperatorsGroupObjectId'
$workloadGroup = Get-Value 'workloadContributorsGroupObjectId'
$auditorsGroup = Get-Value 'readOnlyAuditorsGroupObjectId'
# Optional: defaults to $false when absent so older parameter files remain safe to tear down.
$centralLogAnalyticsEnabled = Get-OptionalBoolValue 'deployCentralLogAnalytics' $false
$recoveryServicesVaultEnabled = Get-OptionalBoolValue 'deployRecoveryServicesVault' $false
$roleAssignmentsEnabled = Get-OptionalBoolValue 'deployRoleAssignments' $false

# Optional: resource ID of a customer-supplied existing Log Analytics workspace. Its
# subscription and resource group are read-only protected inputs and must never be deleted
# by this script, regardless of any naming collision with a generated resource group name.
# Presence is determined by string length only (matching Bicep's empty() and Bash's -n/-z
# tests), NOT by IsNullOrWhiteSpace: Bicep's conflict guard treats any non-empty string
# (including a whitespace-only one) as "an existing workspace was supplied", so teardown
# must use the identical semantics or it could misclassify the monitoring resource group as
# repository-owned when Bicep actually refused to create it.
$existingWorkspaceResourceId = Get-OptionalStringValue 'existingLogAnalyticsWorkspaceResourceId' ''
$existingWorkspaceSupplied = $existingWorkspaceResourceId.Length -gt 0
$existingWorkspaceSubscription = ''
$existingWorkspaceResourceGroup = ''
if ($existingWorkspaceSupplied) {
    # Resource ID shape: /subscriptions/<sub>/resourceGroups/<rg>/providers/<ns>/<type>/<name>
    $existingWorkspaceIdParts = $existingWorkspaceResourceId -split '/'
    if ($existingWorkspaceIdParts.Length -gt 2) { $existingWorkspaceSubscription = $existingWorkspaceIdParts[2] }
    if ($existingWorkspaceIdParts.Length -gt 4) { $existingWorkspaceResourceGroup = $existingWorkspaceIdParts[4] }
}

$criticalEnabled = $false
$criticalProperty = $parameters.parameters.PSObject.Properties['enableCriticalInfrastructure']
if ($null -ne $criticalProperty -and $null -ne $criticalProperty.Value.value) {
    $criticalEnabled = [bool]$criticalProperty.Value.value
}
$criticalSubscriptions = @()
$criticalSubscriptionsProperty = $parameters.parameters.PSObject.Properties['criticalInfrastructureSubscriptionIds']
if ($null -ne $criticalSubscriptionsProperty -and $null -ne $criticalSubscriptionsProperty.Value.value) {
    $criticalSubscriptions = @($criticalSubscriptionsProperty.Value.value)
}

$demoRootScope = "/providers/Microsoft.Management/managementGroups/$prefix"
$platformScope = "/providers/Microsoft.Management/managementGroups/$prefix-platform"
$landingZonesScope = "/providers/Microsoft.Management/managementGroups/$prefix-landingzones"
$workloadScope = "/providers/Microsoft.Management/managementGroups/$prefix-$archetype"
$connectivityScope = "/subscriptions/$connectivitySubscription"
$subscriptionWorkloadScope = "/subscriptions/$workloadSubscription"
$monitoringResourceGroupName = "rg-$prefix-monitoring"
$backupResourceGroupName = "rg-$prefix-backup"
# The monitoring resource group is only repository-owned (and thus safe to delete) when a
# new workspace was requested without also supplying an existing workspace resource ID. This
# mirrors the conflict guard in modules/central-monitoring.bicep: a conflicting configuration
# (deployCentralLogAnalytics=true AND a non-empty existingLogAnalyticsWorkspaceResourceId,
# including a whitespace-only one) never creates a monitoring resource group there, so
# teardown must not delete one either.
$monitoringGroupIsRepoOwned = $centralLogAnalyticsEnabled -and -not $existingWorkspaceSupplied

# Returns $true when the given subscription/resource-group pair matches the supplied
# existing workspace's subscription/resource group, meaning it must never be deleted here.
function Test-ProtectedExistingWorkspaceGroup {
    param(
        [string]$Subscription,
        [string]$Group
    )
    if ([string]::IsNullOrWhiteSpace($existingWorkspaceResourceGroup)) {
        return $false
    }
    return ($Subscription -ieq $existingWorkspaceSubscription) -and ($Group -ieq $existingWorkspaceResourceGroup)
}

# Deletes the named resource group only when it is not the protected existing-workspace
# resource group. Safe to call even when the group does not exist.
function Remove-ResourceGroupIfNotProtected {
    param(
        [string]$Subscription,
        [string]$Group
    )
    if (Test-ProtectedExistingWorkspaceGroup -Subscription $Subscription -Group $Group) {
        Write-Warning "SKIP: $Group matches the supplied existingLogAnalyticsWorkspaceResourceId resource group; it is never deleted by this script."
        return
    }
    $groupExists = & az group exists --subscription $Subscription --name $Group --output tsv 2>$null
    if ([string]$groupExists -eq 'true') {
        & az group delete --subscription $Subscription --name $Group --yes --no-wait
        if ($LASTEXITCODE -ne 0) { Stop-Teardown "Failed to start deletion of $Group." }
    }
}

# Waits for deletion of the named resource group unless it is the protected
# existing-workspace resource group, in which case there is nothing to wait for.
function Wait-ResourceGroupDeletionIfNotProtected {
    param(
        [string]$Subscription,
        [string]$Group
    )
    if (Test-ProtectedExistingWorkspaceGroup -Subscription $Subscription -Group $Group) {
        return
    }
    & az group wait --subscription $Subscription --name $Group --deleted --interval 10 --timeout 900 2>$null
}

Write-Host 'TEARDOWN PLAN (reverse dependency order)'
Write-Host "  1. Delete resource groups rg-$prefix-connectivity and rg-$prefix-$archetype-demo if present."
if ($monitoringGroupIsRepoOwned) {
    Write-Host "  1a. Delete the demo-created monitoring resource group $monitoringResourceGroupName (deployCentralLogAnalytics=true and no existing workspace supplied)."
}
if ($recoveryServicesVaultEnabled) {
    Write-Host "  1b. Delete the demo-created backup resource group $backupResourceGroupName."
}
if (-not [string]::IsNullOrWhiteSpace($existingWorkspaceResourceGroup)) {
    Write-Host ''
    Write-Host "NOTE: existingLogAnalyticsWorkspaceResourceId is set; resource group $existingWorkspaceResourceGroup in subscription $existingWorkspaceSubscription is protected and will never be deleted by this script, even if its name collides with a group above."
}
Write-Host '  2. Delete deployment-owned policy exemptions, remediating assignments and their role mappings, then all other demo policy assignments.'
Write-Host '  3. Delete deployment-owned custom initiatives and policy definitions after their assignments.'
Write-Host "  4. Move subscriptions $connectivitySubscription and $workloadSubscription back to $tenantRoot."
$stepNumber = 5
if ($criticalEnabled -and $criticalSubscriptions.Count -gt 0) {
    $criticalSubscriptionsList = $criticalSubscriptions -join ', '
    Write-Host "  $stepNumber. Move critical infrastructure subscriptions ($criticalSubscriptionsList) back to $tenantRoot."
    $stepNumber++
}
if ($criticalEnabled) {
    Write-Host "  $stepNumber. Delete management groups $prefix-connectivity, $prefix-platform, $prefix-$archetype, $prefix-criticalinfra, $prefix-landingzones, then $prefix."
}
else {
    Write-Host "  $stepNumber. Delete management groups $prefix-connectivity, $prefix-platform, $prefix-$archetype, $prefix-landingzones, then $prefix."
}
Write-Host ''
Write-Host 'NOTE: Owner eligibility is managed only through the separate one-shot PIM artifact. This teardown never discovers or removes it; submit a new, separately reviewed AdminRemove request for each existing schedule and verify removal in PIM.'
Write-Host ''
Write-Host 'Only objects named by this deployment and optional resource groups enabled in this parameter file are deployment-owned. Supplied workspace, firewall, key, vault, policy, and other external IDs are never deleted. Subscriptions and Entra groups are never deleted.'

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
    $principalId = & az policy assignment show --name $AssignmentName --scope $Scope --query identity.principalId --output tsv 2>$null
    if (-not [string]::IsNullOrWhiteSpace([string]$principalId) -and [string]$principalId -ne 'null') {
        $roleAssignmentIds = & az role assignment list --assignee $principalId --query '[].id' --output tsv 2>$null
        foreach ($roleAssignmentId in @($roleAssignmentIds)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$roleAssignmentId)) {
                & az role assignment delete --ids $roleAssignmentId 2>$null
            }
        }
    }
    & az policy assignment delete --name $AssignmentName --scope $Scope 2>$null
}

function Remove-PolicyExemptions {
    foreach ($exemption in @($parameters.parameters.policyExemptions.value)) {
        if ($null -eq $exemption) { continue }
        $assignmentId = [string]$exemption.policyAssignmentId
        $marker = '/providers/Microsoft.Authorization/policyAssignments/'
        $markerIndex = $assignmentId.IndexOf($marker, [StringComparison]::OrdinalIgnoreCase)
        if ($markerIndex -ge 0) {
            & az policy exemption delete --name ([string]$exemption.exemptionName) --scope $assignmentId.Substring(0, $markerIndex) 2>$null
        }
    }
}

function Remove-DemoPolicyAssignments {
    $scopes = @($demoRootScope, $platformScope, $landingZonesScope, $workloadScope)
    $assignmentNames = @(
        'demo-allowed-us-locs', 'demo-audit-public-ip', 'demo-deploy-restrictions',
        'demo-network-ingress', 'demo-private-access', 'demo-data-protection',
        'demo-block-expensive', 'demo-audit-platform-tags', 'demo-require-rg-tags',
        'demo-defender-cspm', 'demo-defender-servers', 'demo-defender-storage',
        'demo-audit-vuln-assess', 'demo-audit-ama-windows', 'demo-audit-ama-linux',
        'demo-inherit-rg-tags', 'demo-mcsb-baseline', 'demo-cis-foundations',
        'demo-nist-800-53-r5', 'demo-backup-posture', 'demo-vault-diagnostics',
        'demo-activity-logs', 'demo-resource-diags'
    )
    foreach ($scope in $scopes) {
        foreach ($assignmentName in $assignmentNames) {
            Remove-PolicyAssignment $assignmentName $scope
        }
    }
    if ($criticalEnabled) {
        $criticalScope = "/providers/Microsoft.Management/managementGroups/$prefix-criticalinfra"
        foreach ($assignmentName in @('demo-critical-private', 'demo-critical-fw-routes', 'demo-nerc-cip-technical')) {
            Remove-PolicyAssignment $assignmentName $criticalScope
        }
    }
}

$connectivityResourceGroup = "rg-$prefix-connectivity"
$workloadResourceGroup = "rg-$prefix-$archetype-demo"

Remove-ResourceGroupIfNotProtected -Subscription $connectivitySubscription -Group $connectivityResourceGroup
Remove-ResourceGroupIfNotProtected -Subscription $workloadSubscription -Group $workloadResourceGroup

# Only delete the monitoring resource group when this repository created it (no conflicting
# existing workspace was supplied). A supplied existing workspace/resource group is never
# owned by this demo and must never be deleted here, even by name collision.
if ($monitoringGroupIsRepoOwned) {
    Remove-ResourceGroupIfNotProtected -Subscription $connectivitySubscription -Group $monitoringResourceGroupName
}
if ($recoveryServicesVaultEnabled) {
    Remove-ResourceGroupIfNotProtected -Subscription $workloadSubscription -Group $backupResourceGroupName
}

Wait-ResourceGroupDeletionIfNotProtected -Subscription $connectivitySubscription -Group $connectivityResourceGroup
Wait-ResourceGroupDeletionIfNotProtected -Subscription $workloadSubscription -Group $workloadResourceGroup
if ($monitoringGroupIsRepoOwned) {
    Wait-ResourceGroupDeletionIfNotProtected -Subscription $connectivitySubscription -Group $monitoringResourceGroupName
}
if ($recoveryServicesVaultEnabled) {
    Wait-ResourceGroupDeletionIfNotProtected -Subscription $workloadSubscription -Group $backupResourceGroupName
}

if ($roleAssignmentsEnabled) {
    Remove-RoleMapping $governanceGroup 'Management Group Contributor' $demoRootScope
    Remove-RoleMapping $governanceGroup 'Resource Policy Contributor' $demoRootScope
    Remove-RoleMapping $auditorsGroup 'Reader' $demoRootScope
    Remove-RoleMapping $networkGroup 'Network Contributor' $connectivityScope
    Remove-RoleMapping $workloadGroup 'Contributor' $subscriptionWorkloadScope
}

Remove-PolicyExemptions
Remove-PolicyAssignment 'demo-require-rg-tags' $landingZonesScope
Remove-PolicyAssignment 'demo-require-rg-tags' $workloadScope
Remove-PolicyAssignment 'demo-audit-platform-tags' $platformScope
Remove-PolicyAssignment 'demo-block-expensive' $demoRootScope
Remove-PolicyAssignment 'demo-audit-public-ip' $demoRootScope
Remove-PolicyAssignment 'demo-allowed-us-locs' $demoRootScope
Remove-DemoPolicyAssignments

$policyNames = @(
    "$prefix-allowed-us-locations",
    "$prefix-allowed-resource-types-all",
    "$prefix-require-workload-rg-tags",
    "$prefix-inherit-rg-tags",
    "$prefix-network-ingress",
    "$prefix-private-access",
    "$prefix-data-protection",
    "$prefix-deploy-restrictions",
    "$prefix-backup-posture",
    "$prefix-nerc-cip-technical-overlay",
    "$prefix-audit-platform-tags",
    "$prefix-block-expensive",
    "$prefix-audit-public-ip",
    "$prefix-public-mgmt-ingress",
    "$prefix-require-subnet-nsg",
    "$prefix-audit-paas-public-network",
    "$prefix-audit-approved-firewall-routes",
    "$prefix-audit-storage-cmk-approved-key"
)
foreach ($policyName in $policyNames) {
    & az policy definition delete --name $policyName --management-group $prefix 2>$null
}
foreach ($initiativeName in @(
    "$prefix-required-rg-tags",
    "$prefix-inherit-rg-tags",
    "$prefix-network-ingress",
    "$prefix-private-access",
    "$prefix-data-protection",
    "$prefix-deploy-restrictions",
    "$prefix-backup-posture",
    "$prefix-nerc-cip-technical-overlay"
)) {
    & az policy set-definition delete --name $initiativeName --management-group $prefix 2>$null
}

& az account management-group subscription add --name $tenantRoot --subscription $connectivitySubscription
if ($LASTEXITCODE -ne 0) { Stop-Teardown 'Failed to move the connectivity subscription.' }
& az account management-group subscription add --name $tenantRoot --subscription $workloadSubscription
if ($LASTEXITCODE -ne 0) { Stop-Teardown 'Failed to move the workload subscription.' }

if ($criticalEnabled) {
    foreach ($criticalSubscription in $criticalSubscriptions) {
        & az account management-group subscription add --name $tenantRoot --subscription $criticalSubscription
        if ($LASTEXITCODE -ne 0) { Stop-Teardown "Failed to move critical infrastructure subscription $criticalSubscription." }
    }
}

$managementGroups = @(
    "$prefix-connectivity",
    "$prefix-platform",
    "$prefix-$archetype"
)
if ($criticalEnabled) {
    $managementGroups += "$prefix-criticalinfra"
}
$managementGroups += "$prefix-landingzones"
$managementGroups += $prefix
foreach ($managementGroup in $managementGroups) {
    & az account management-group delete --name $managementGroup
    if ($LASTEXITCODE -ne 0) { Stop-Teardown "Failed to delete management group $managementGroup." }
}

Write-Host ''
Write-Host 'Teardown commands completed. Verify the hierarchy, both subscriptions, and any separately managed PIM eligibility schedules in the Azure portal.'
