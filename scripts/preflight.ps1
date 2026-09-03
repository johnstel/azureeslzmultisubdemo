[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$ParameterFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir
if ([string]::IsNullOrWhiteSpace($ParameterFile)) {
    $ParameterFile = Join-Path $ProjectDir 'parameters/demo.parameters.json'
}

function Stop-Preflight {
    param([string]$Message)
    Write-Error $Message -ErrorAction Continue
    exit 1
}

function Get-ParameterValue {
    param([string]$Name)
    $property = $script:ParameterDocument.parameters.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value.value) {
        Stop-Preflight "Required parameter '$Name' is missing."
    }
    return $property.Value.value
}

function Get-OptionalParameterValue {
    param([string]$Name)
    $property = $script:ParameterDocument.parameters.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value.value) {
        return $null
    }
    return $property.Value.value
}

function Test-ParameterTrue {
    param([string]$Name)
    return (Get-OptionalParameterValue $Name) -eq $true
}

function Test-GuidShape {
    param([string]$Value)
    return $Value -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
}

function Test-ResourceId {
    param(
        [string]$Value,
        [string]$Provider,
        [string]$Type
    )
    $pattern = '^/subscriptions/[0-9a-fA-F-]{{36}}/resourceGroups/[^/\s]+/providers/{0}/{1}/[^/\s]+$' -f [regex]::Escape($Provider), [regex]::Escape($Type)
    return $Value -match $pattern
}

function Test-ResourceIdParameter {
    param(
        [string]$Name,
        [string]$Provider,
        [string]$Type
    )
    $value = [string](Get-OptionalParameterValue $Name)
    if (-not [string]::IsNullOrWhiteSpace($value) -and -not (Test-ResourceId $value $Provider $Type)) {
        Stop-Preflight "$Name must be a canonical $Provider/$Type resource ID when supplied."
    }
}

function Invoke-AzJson {
    param([string[]]$Arguments)
    $output = & az @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $null
    }
    return (($output -join [Environment]::NewLine) | ConvertFrom-Json)
}

if ($null -eq (Get-Command az -ErrorAction SilentlyContinue)) {
    Stop-Preflight "Required command 'az' is not installed."
}
if (-not (Test-Path -LiteralPath $ParameterFile -PathType Leaf)) {
    Stop-Preflight "Parameter file not found: $ParameterFile"
}

try {
    $parameterText = Get-Content -LiteralPath $ParameterFile -Raw
    $script:ParameterDocument = $parameterText | ConvertFrom-Json
}
catch {
    Stop-Preflight "Parameter file is not valid JSON: $($_.Exception.Message)"
}

if ($null -eq $script:ParameterDocument.parameters) {
    Stop-Preflight 'Parameter file is not an ARM deployment-parameters JSON document.'
}
if ($parameterText -match 'REPLACE_WITH_') {
    Stop-Preflight 'Parameter file still contains REPLACE_WITH_* placeholders.'
}

$tenantRoot = [string](Get-ParameterValue 'tenantRootManagementGroupId')
$namePrefix = [string](Get-ParameterValue 'namePrefix')
$connectivitySubscription = [string](Get-ParameterValue 'connectivitySubscriptionId')
$workloadSubscription = [string](Get-ParameterValue 'workloadSubscriptionId')
$deploymentLocation = [string](Get-ParameterValue 'deploymentLocation')

if ($namePrefix -notmatch '^[a-z0-9][a-z0-9-]{1,22}[a-z0-9]$') {
    Stop-Preflight 'namePrefix must be 3-24 lowercase letters, numbers, or hyphens, with no leading/trailing hyphen.'
}
if ($deploymentLocation -ieq 'global') {
    Stop-Preflight 'deploymentLocation must not be global because policy identities require an Azure region.'
}
if (-not (Test-GuidShape $connectivitySubscription)) {
    Stop-Preflight 'connectivitySubscriptionId is not a GUID.'
}
if (-not (Test-GuidShape $workloadSubscription)) {
    Stop-Preflight 'workloadSubscriptionId is not a GUID.'
}
if ($connectivitySubscription.Equals($workloadSubscription, [System.StringComparison]::OrdinalIgnoreCase)) {
    Stop-Preflight 'The connectivity and workload subscription IDs must be different.'
}

$groupParameters = @(
    'governanceAdminsGroupObjectId',
    'networkOperatorsGroupObjectId',
    'workloadContributorsGroupObjectId',
    'readOnlyAuditorsGroupObjectId'
)
$seenGroupIds = @{}
foreach ($groupParameter in $groupParameters) {
    $groupId = [string](Get-ParameterValue $groupParameter)
    if (-not (Test-GuidShape $groupId)) {
        Stop-Preflight "$groupParameter is not a GUID."
    }
    $normalizedGroupId = $groupId.ToLowerInvariant()
    if ($seenGroupIds.ContainsKey($normalizedGroupId)) {
        Stop-Preflight "$groupParameter duplicates $($seenGroupIds[$normalizedGroupId]); use five distinct least-privilege groups."
    }
    $seenGroupIds[$normalizedGroupId] = $groupParameter
}

Test-ResourceIdParameter existingLogAnalyticsWorkspaceResourceId Microsoft.OperationalInsights workspaces
Test-ResourceIdParameter approvedFirewallResourceId Microsoft.Network azureFirewalls
foreach ($routeTableId in @(Get-OptionalParameterValue approvedRouteTableResourceIds)) {
    if (-not (Test-ResourceId ([string]$routeTableId) Microsoft.Network routeTables)) {
        Stop-Preflight 'approvedRouteTableResourceIds contains an invalid Microsoft.Network/routeTables resource ID.'
    }
    foreach ($keyVaultUri in @(Get-OptionalParameterValue approvedCustomerManagedKeyVaultUris)) {
        if ([string]$keyVaultUri -notmatch '^https://[a-zA-Z0-9-]+\.vault\.azure\.net/$') {
            Stop-Preflight 'approvedCustomerManagedKeyVaultUris contains an invalid Key Vault URI.'
        }
    }
    foreach ($keyName in @(Get-OptionalParameterValue approvedCustomerManagedKeyNames)) {
        if ([string]$keyName -notmatch '^[A-Za-z0-9-]{1,127}$') {
            Stop-Preflight 'approvedCustomerManagedKeyNames contains an invalid key name.'
        }
    }
}

if (Test-ParameterTrue enableFirewallRouteGuardrails) {
    if ([string]::IsNullOrWhiteSpace([string](Get-OptionalParameterValue approvedFirewallResourceId))) { Stop-Preflight 'enableFirewallRouteGuardrails requires approvedFirewallResourceId.' }
    if ([string]::IsNullOrWhiteSpace([string](Get-OptionalParameterValue approvedFirewallPrivateIp))) { Stop-Preflight 'enableFirewallRouteGuardrails requires approvedFirewallPrivateIp.' }
    if (@(Get-OptionalParameterValue approvedRouteTableResourceIds).Count -eq 0) { Stop-Preflight 'enableFirewallRouteGuardrails requires approvedRouteTableResourceIds.' }
    if (@(Get-OptionalParameterValue approvedRouteTablePrefixes).Count -eq 0) { Stop-Preflight 'enableFirewallRouteGuardrails requires approvedRouteTablePrefixes.' }
}
if ((Test-ParameterTrue deployCentralLogAnalytics) -and -not [string]::IsNullOrWhiteSpace([string](Get-OptionalParameterValue existingLogAnalyticsWorkspaceResourceId))) {
    Stop-Preflight 'deployCentralLogAnalytics and existingLogAnalyticsWorkspaceResourceId cannot both be supplied.'
}
if ((Test-ParameterTrue deploySentinel) -and -not (Test-ParameterTrue deployCentralLogAnalytics) -and [string]::IsNullOrWhiteSpace([string](Get-OptionalParameterValue existingLogAnalyticsWorkspaceResourceId))) {
    Stop-Preflight 'deploySentinel requires deployCentralLogAnalytics or existingLogAnalyticsWorkspaceResourceId.'
}

$criticalSubscriptions = @()
foreach ($criticalSubscription in @(Get-OptionalParameterValue criticalInfrastructureSubscriptionIds)) {
    if (-not (Test-GuidShape ([string]$criticalSubscription))) { Stop-Preflight 'criticalInfrastructureSubscriptionIds contains a non-GUID subscription ID.' }
    if ($criticalSubscriptions -contains ([string]$criticalSubscription).ToLowerInvariant()) { Stop-Preflight 'criticalInfrastructureSubscriptionIds must not contain duplicate subscription IDs.' }
    $criticalSubscriptions += ([string]$criticalSubscription).ToLowerInvariant()
}
if ((Test-ParameterTrue enableCriticalInfrastructure) -and $criticalSubscriptions.Count -eq 0) {
    Stop-Preflight 'enableCriticalInfrastructure requires one or more criticalInfrastructureSubscriptionIds.'
}

$approvedBackupVaults = @(Get-OptionalParameterValue approvedBackupVaults)
foreach ($approvedBackupVault in $approvedBackupVaults) {
    $vaultId = [string]$approvedBackupVault.vaultResourceId
    $backupPolicyId = [string]$approvedBackupVault.backupPolicyResourceId
    if (-not (Test-ResourceId $vaultId Microsoft.RecoveryServices vaults)) { Stop-Preflight 'approvedBackupVaults contains an invalid Recovery Services vault resource ID.' }
    if (-not $backupPolicyId.StartsWith("$vaultId/backupPolicies/", [System.StringComparison]::OrdinalIgnoreCase)) { Stop-Preflight 'approvedBackupVaults backupPolicyResourceId must be inside its vault.' }
}
if (Test-ParameterTrue enableVmBackupRemediation) {
    if ($approvedBackupVaults.Count -eq 0) { Stop-Preflight 'enableVmBackupRemediation requires approvedBackupVaults.' }
    if ([string]::IsNullOrWhiteSpace([string](Get-OptionalParameterValue vmBackupInclusionTagName))) { Stop-Preflight 'enableVmBackupRemediation requires vmBackupInclusionTagName.' }
    if ([string]::IsNullOrWhiteSpace([string](Get-OptionalParameterValue backupRetentionStandardId))) { Stop-Preflight 'enableVmBackupRemediation requires backupRetentionStandardId.' }
    if (-not (Test-ParameterTrue deployRoleAssignments)) { Stop-Preflight 'enableVmBackupRemediation requires deployRoleAssignments for remediation permissions.' }
}
if ((Test-ParameterTrue deployRecoveryServicesVault) -and $approvedBackupVaults.Count -gt 0) { Stop-Preflight 'deployRecoveryServicesVault cannot be combined with approvedBackupVaults.' }
if ((Test-ParameterTrue deployRecoveryServicesVault) -and [string]::IsNullOrWhiteSpace([string](Get-OptionalParameterValue backupRetentionStandardId))) { Stop-Preflight 'deployRecoveryServicesVault requires backupRetentionStandardId.' }
if ((Test-ParameterTrue enableVaultDiagnostics) -and -not (Test-ParameterTrue deployCentralLogAnalytics) -and [string]::IsNullOrWhiteSpace([string](Get-OptionalParameterValue existingLogAnalyticsWorkspaceResourceId))) { Stop-Preflight 'enableVaultDiagnostics requires deployCentralLogAnalytics or existingLogAnalyticsWorkspaceResourceId.' }
if (Test-ParameterTrue grantVaultDiagnosticsWorkspaceAccess) {
    if (-not (Test-ParameterTrue enableVaultDiagnostics)) { Stop-Preflight 'grantVaultDiagnosticsWorkspaceAccess requires enableVaultDiagnostics.' }
    if ((Get-OptionalParameterValue vaultDiagnosticsEffect) -ne 'DeployIfNotExists') { Stop-Preflight 'grantVaultDiagnosticsWorkspaceAccess requires vaultDiagnosticsEffect=DeployIfNotExists.' }
    if (-not (Test-ParameterTrue deployRoleAssignments)) { Stop-Preflight 'grantVaultDiagnosticsWorkspaceAccess requires deployRoleAssignments.' }
}
if ((Get-OptionalParameterValue resourceDiagnosticsPolicyEffect) -eq 'DeployIfNotExists') {
    if (-not (Test-ParameterTrue deployLoggingRemediationRoleAssignments)) { Stop-Preflight 'resourceDiagnosticsPolicyEffect=DeployIfNotExists requires deployLoggingRemediationRoleAssignments.' }
    if (-not (Test-ParameterTrue deployRoleAssignments)) { Stop-Preflight 'resourceDiagnosticsPolicyEffect=DeployIfNotExists requires deployRoleAssignments.' }
}

Write-Host 'Building Bicep locally...'
& az bicep build --file (Join-Path $ProjectDir 'main.bicep') --stdout | Out-Null
if ($LASTEXITCODE -ne 0) {
    Stop-Preflight 'Bicep build failed.'
}

Write-Host 'Checking Azure sign-in and supplied scopes (read-only)...'
$account = Invoke-AzJson @('account', 'show', '--output', 'json')
if ($null -eq $account) {
    Stop-Preflight 'Azure CLI is not signed in. Run az login --tenant <tenant-guid>.'
}
$signedInTenant = [string]$account.tenantId

function Test-Subscription {
    param(
        [string]$SubscriptionId,
        [string]$Label
    )

    $subscription = Invoke-AzJson @(
        'account', 'show',
        '--subscription', $SubscriptionId,
        '--output', 'json'
    )
    if ($null -eq $subscription) {
        Stop-Preflight "Cannot read the $Label subscription $SubscriptionId."
    }
    if ([string]$subscription.state -ne 'Enabled') {
        Stop-Preflight "$Label subscription state is '$($subscription.state)', not Enabled."
    }
    if (-not ([string]$subscription.tenantId).Equals($signedInTenant, [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-Preflight "$Label subscription belongs to tenant $($subscription.tenantId), but the active tenant is $signedInTenant."
    }
}

Test-Subscription $connectivitySubscription 'connectivity'
Test-Subscription $workloadSubscription 'workload'
foreach ($criticalSubscription in $criticalSubscriptions) {
    Test-Subscription $criticalSubscription 'critical infrastructure'
}

& az account management-group show --name $tenantRoot --output none 2>$null
if ($LASTEXITCODE -ne 0) {
    Stop-Preflight "Cannot read tenant-root management group '$tenantRoot'. Check the ID and tenant permissions."
}

function Test-ProviderRegistration {
    param(
        [string]$SubscriptionId,
        [string]$Namespace
    )
    $registrationState = & az provider show --subscription $SubscriptionId --namespace $Namespace --query registrationState --output tsv 2>$null
    if ($LASTEXITCODE -ne 0) {
        Stop-Preflight "Cannot read provider $Namespace in subscription $SubscriptionId."
    }
    if (($registrationState -join '').Trim() -ne 'Registered') {
        Stop-Preflight "Provider $Namespace is not registered in subscription $SubscriptionId; register it before deployment."
    }
}

foreach ($subscriptionId in @($connectivitySubscription, $workloadSubscription) + $criticalSubscriptions) {
    Test-ProviderRegistration $subscriptionId Microsoft.Authorization
    Test-ProviderRegistration $subscriptionId Microsoft.Resources
}
if (Test-ParameterTrue enableFirewallRouteGuardrails) {
    Test-ProviderRegistration $workloadSubscription Microsoft.Network
}
if ((Test-ParameterTrue deployCentralLogAnalytics) -or -not [string]::IsNullOrWhiteSpace([string](Get-OptionalParameterValue existingLogAnalyticsWorkspaceResourceId))) {
    Test-ProviderRegistration $connectivitySubscription Microsoft.OperationalInsights
}
if ($approvedBackupVaults.Count -gt 0 -or (Test-ParameterTrue deployRecoveryServicesVault)) {
    Test-ProviderRegistration $workloadSubscription Microsoft.RecoveryServices
}

function Test-ReferencedResource {
    param(
        [string]$ResourceId,
        [string]$ExpectedType
    )
    $actualType = & az resource show --ids $ResourceId --query type --output tsv 2>$null
    if ($LASTEXITCODE -ne 0) {
        Stop-Preflight "Cannot read referenced resource $ResourceId. Check its ID and permissions."
    }
    if (($actualType -join '').Trim() -ine $ExpectedType) {
        Stop-Preflight "Referenced resource $ResourceId is $($actualType -join ''), not $ExpectedType."
    }
}

$workspaceId = [string](Get-OptionalParameterValue existingLogAnalyticsWorkspaceResourceId)
if (-not [string]::IsNullOrWhiteSpace($workspaceId)) { Test-ReferencedResource $workspaceId Microsoft.OperationalInsights/workspaces }
$firewallId = [string](Get-OptionalParameterValue approvedFirewallResourceId)
if (-not [string]::IsNullOrWhiteSpace($firewallId)) { Test-ReferencedResource $firewallId Microsoft.Network/azureFirewalls }
foreach ($routeTableId in @(Get-OptionalParameterValue approvedRouteTableResourceIds)) {
    Test-ReferencedResource ([string]$routeTableId) Microsoft.Network/routeTables
}
foreach ($approvedBackupVault in $approvedBackupVaults) {
    Test-ReferencedResource ([string]$approvedBackupVault.vaultResourceId) Microsoft.RecoveryServices/vaults
    Test-ReferencedResource ([string]$approvedBackupVault.backupPolicyResourceId) Microsoft.RecoveryServices/vaults/backupPolicies
}

foreach ($control in @($ProjectDir | ForEach-Object { (Get-Content -LiteralPath (Join-Path $_ 'policy/control-catalog.json') -Raw | ConvertFrom-Json).controls })) {
    $mechanism = $control.mechanism
    if ($mechanism.builtIn -ne $true -or [string]::IsNullOrWhiteSpace([string]$mechanism.definitionId) -or -not (Test-GuidShape ([string]$mechanism.definitionId))) { continue }
    if ($mechanism.kind -eq 'policySetDefinition') {
        $actualVersion = & az policy set-definition show --name $mechanism.definitionId --query properties.version --output tsv 2>$null
        if ($LASTEXITCODE -ne 0) { Stop-Preflight "Cannot read built-in policy initiative $($mechanism.definitionId) in the active Azure cloud." }
    }
    else {
        $actualVersion = & az policy definition show --name $mechanism.definitionId --query properties.version --output tsv 2>$null
        if ($LASTEXITCODE -ne 0) { Stop-Preflight "Cannot read built-in policy definition $($mechanism.definitionId) in the active Azure cloud." }
    }
    if (-not (($actualVersion -join '').Trim().StartsWith("$($mechanism.majorVersion).", [System.StringComparison]::Ordinal))) {
        Stop-Preflight "Built-in policy $($mechanism.definitionId) is version $($actualVersion -join ''), not pinned major version $($mechanism.majorVersion)."
    }
}

Write-Host ''
Write-Host 'Preflight passed.'
Write-Host "  Active tenant: $signedInTenant"
Write-Host "  Tenant root MG: $tenantRoot"
Write-Host "  Connectivity subscription: $connectivitySubscription"
Write-Host "  Workload subscription: $workloadSubscription"
Write-Host "  Tenant deployment location: $deploymentLocation"
Write-Host '  Entra group IDs: GUID format and uniqueness verified where supplied (directory group type is not queried).'
