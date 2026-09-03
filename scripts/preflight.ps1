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

function Test-ActionPatternMatch {
    param(
        [string]$Action,
        [string]$Pattern
    )
    if ([string]::IsNullOrWhiteSpace($Action) -or [string]::IsNullOrWhiteSpace($Pattern)) {
        return $false
    }
    $normalizedAction = $Action.Trim().ToLowerInvariant()
    $normalizedPattern = $Pattern.Trim().ToLowerInvariant()
    return $normalizedAction -match ('^' + [regex]::Escape($normalizedPattern).Replace('\*', '.*') + '$')
}

function Test-ActionPermitted {
    param(
        [string]$Action,
        $Permissions
    )
    if ($null -eq $Permissions -or $null -eq $Permissions.value) {
        return $false
    }
    foreach ($permissionSet in @($Permissions.value)) {
        if ($null -eq $permissionSet) { continue }
        $allowed = $false
        $denied = $false
        $allowedCandidates = @()
        foreach ($propertyName in @('actions')) {
            if ($null -ne $permissionSet.PSObject.Properties[$propertyName]) {
                $allowedCandidates += @($permissionSet.$propertyName)
            }
        }
        foreach ($candidate in $allowedCandidates) {
            if ($null -ne $candidate -and (Test-ActionPatternMatch -Action $Action -Pattern ([string]$candidate))) {
                $allowed = $true
            }
        }

        $deniedCandidates = @()
        foreach ($propertyName in @('notActions')) {
            if ($null -ne $permissionSet.PSObject.Properties[$propertyName]) {
                $deniedCandidates += @($permissionSet.$propertyName)
            }
        }
        foreach ($candidate in $deniedCandidates) {
            if ($null -ne $candidate -and (Test-ActionPatternMatch -Action $Action -Pattern ([string]$candidate))) {
                $denied = $true
            }
        }
        if ($allowed -and -not $denied) { return $true }
    }
    return $false
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
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -ne $Value.Trim() -or $Value.EndsWith('/')) { return $false }
    $segments = $Value.Split('/')
    return $segments.Count -eq 9 -and $segments[0] -eq '' -and
        $segments[1] -ieq 'subscriptions' -and (Test-GuidShape $segments[2]) -and
        $segments[3] -ieq 'resourceGroups' -and -not [string]::IsNullOrWhiteSpace($segments[4]) -and
        $segments[5] -ieq 'providers' -and $segments[6] -ieq $Provider -and
        $segments[7] -ieq $Type -and -not [string]::IsNullOrWhiteSpace($segments[8])
}

function Get-ResourceSubscriptionId {
    param([string]$ResourceId)
    if ([string]::IsNullOrWhiteSpace($ResourceId)) {
        return $null
    }
    $segments = $ResourceId.Trim().Split('/')
    if ($segments.Length -lt 3) {
        return $null
    }
    return $segments[2]
}

function Test-Ipv4Address {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $octets = $Value.Split('.')
    if ($octets.Count -ne 4) { return $false }
    foreach ($octet in $octets) {
        if ($octet -notmatch '^[0-9]+$') { return $false }
        $octetValue = [int]$octet
        if ($octetValue -lt 0 -or $octetValue -gt 255) { return $false }
    }
    return $true
}

function Test-Ipv4Cidr {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $parts = $Value.Split('/')
    if ($parts.Count -ne 2) { return $false }
    if (-not (Test-Ipv4Address $parts[0])) { return $false }
    if ($parts[1] -notmatch '^[0-9]+$') { return $false }
    $prefixLength = [int]$parts[1]
    return ($prefixLength -ge 0 -and $prefixLength -le 32)
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

function Invoke-Preflight {
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
$profileDocument = Get-Content -LiteralPath (Join-Path $ProjectDir 'parameters/demo.parameters.template.json') -Raw | ConvertFrom-Json
$profileShape = @($profileDocument.parameters.PSObject.Properties | Sort-Object Name | ForEach-Object {
    '{0}:{1}' -f $_.Name, $_.Value.value.GetType().FullName
})
$parameterShape = @($script:ParameterDocument.parameters.PSObject.Properties | Sort-Object Name | ForEach-Object {
    '{0}:{1}' -f $_.Name, $_.Value.value.GetType().FullName
})
if (Compare-Object $profileShape $parameterShape) {
    Stop-Preflight 'Parameter file must expose the same parameter names and value types as the committed v2 profiles.'
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

$privateAccessServiceCategoriesValue = Get-OptionalParameterValue privateAccessServiceCategories
$privateAccessServiceCategories = @()
if ($null -ne $privateAccessServiceCategoriesValue) {
    $privateAccessServiceCategories = @($privateAccessServiceCategoriesValue)
    if ($privateAccessServiceCategories.Count -eq 0) {
        Stop-Preflight 'privateAccessServiceCategories must contain non-empty, uniquely cased Storage and/or KeyVault values.'
    }
}
$seenPrivateAccessServiceCategories = @{}
foreach ($serviceCategory in $privateAccessServiceCategories) {
    $serviceCategoryValue = [string]$serviceCategory
    if ([string]::IsNullOrWhiteSpace($serviceCategoryValue)) {
        Stop-Preflight 'privateAccessServiceCategories must contain non-empty, uniquely cased Storage and/or KeyVault values.'
    }
    if ($serviceCategoryValue -notin @('Storage', 'KeyVault')) {
        Stop-Preflight 'privateAccessServiceCategories must contain non-empty, uniquely cased Storage and/or KeyVault values.'
    }
    if ($seenPrivateAccessServiceCategories.ContainsKey($serviceCategoryValue)) {
        Stop-Preflight 'privateAccessServiceCategories must contain non-empty, uniquely cased Storage and/or KeyVault values.'
    }
    $seenPrivateAccessServiceCategories[$serviceCategoryValue] = $true
}

Test-ResourceIdParameter existingLogAnalyticsWorkspaceResourceId Microsoft.OperationalInsights workspaces
Test-ResourceIdParameter approvedFirewallResourceId Microsoft.Network azureFirewalls
$routeTableIds = @(Get-OptionalParameterValue approvedRouteTableResourceIds)
$seenRouteTableIds = @{}
foreach ($routeTableId in $routeTableIds) {
    $routeTableIdText = [string]$routeTableId
    if ([string]::IsNullOrWhiteSpace($routeTableIdText) -or -not (Test-ResourceId $routeTableIdText Microsoft.Network routeTables)) {
        Stop-Preflight 'approvedRouteTableResourceIds contains an invalid Microsoft.Network/routeTables resource ID.'
    }
    $normalizedRouteTableId = $routeTableIdText.ToLowerInvariant()
    if ($seenRouteTableIds.ContainsKey($normalizedRouteTableId)) {
        Stop-Preflight 'approvedRouteTableResourceIds contains duplicate Microsoft.Network/routeTables resource IDs.'
    }
    $seenRouteTableIds[$normalizedRouteTableId] = $true
}
$keyVaultUris = Get-OptionalParameterValue approvedCustomerManagedKeyVaultUris
if ($null -ne $keyVaultUris) {
    foreach ($keyVaultUri in @($keyVaultUris)) {
        if ([string]$keyVaultUri -notmatch '^https://[a-zA-Z0-9-]+\.vault\.azure\.net/$') {
            Stop-Preflight 'approvedCustomerManagedKeyVaultUris contains an invalid Key Vault URI.'
        }
    }
}
$keyNames = Get-OptionalParameterValue approvedCustomerManagedKeyNames
if ($null -ne $keyNames) {
    foreach ($keyName in @($keyNames)) {
        if ([string]$keyName -notmatch '^[A-Za-z0-9-]{1,127}$') {
            Stop-Preflight 'approvedCustomerManagedKeyNames contains an invalid key name.'
        }
    }
}

if (Test-ParameterTrue enableFirewallRouteGuardrails) {
    if ([string]::IsNullOrWhiteSpace([string](Get-OptionalParameterValue approvedFirewallResourceId))) { Stop-Preflight 'enableFirewallRouteGuardrails requires approvedFirewallResourceId.' }
    $approvedFirewallPrivateIp = [string](Get-OptionalParameterValue approvedFirewallPrivateIp)
    if ([string]::IsNullOrWhiteSpace($approvedFirewallPrivateIp)) { Stop-Preflight 'enableFirewallRouteGuardrails requires approvedFirewallPrivateIp.' }
    if (-not (Test-Ipv4Address $approvedFirewallPrivateIp)) { Stop-Preflight 'approvedFirewallPrivateIp must be an IPv4 address.' }
    if (@(Get-OptionalParameterValue approvedRouteTableResourceIds).Count -eq 0) { Stop-Preflight 'enableFirewallRouteGuardrails requires approvedRouteTableResourceIds.' }
    if (@(Get-OptionalParameterValue approvedRouteTablePrefixes).Count -eq 0) { Stop-Preflight 'enableFirewallRouteGuardrails requires approvedRouteTablePrefixes.' }
    $routeTablePrefixes = @((Get-OptionalParameterValue approvedRouteTablePrefixes))
    $seenRouteTablePrefixes = @{}
    foreach ($routeTablePrefix in $routeTablePrefixes) {
        $routeTablePrefixText = [string]$routeTablePrefix
        if ([string]::IsNullOrWhiteSpace($routeTablePrefixText) -or -not (Test-Ipv4Cidr $routeTablePrefixText)) { Stop-Preflight 'approvedRouteTablePrefixes contains an invalid IPv4 CIDR.' }
        $normalizedRouteTablePrefix = $routeTablePrefixText.ToLowerInvariant()
        if ($seenRouteTablePrefixes.ContainsKey($normalizedRouteTablePrefix)) {
            Stop-Preflight 'approvedRouteTablePrefixes contains duplicate IPv4 CIDR values.'
        }
        $seenRouteTablePrefixes[$normalizedRouteTablePrefix] = $true
    }
}
if ((Test-ParameterTrue deployCentralLogAnalytics) -and -not [string]::IsNullOrWhiteSpace([string](Get-OptionalParameterValue existingLogAnalyticsWorkspaceResourceId))) {
    Stop-Preflight 'deployCentralLogAnalytics and existingLogAnalyticsWorkspaceResourceId cannot both be supplied.'
}
if ((Test-ParameterTrue deploySentinel) -and -not (Test-ParameterTrue deployCentralLogAnalytics) -and [string]::IsNullOrWhiteSpace([string](Get-OptionalParameterValue existingLogAnalyticsWorkspaceResourceId))) {
    Stop-Preflight 'deploySentinel requires deployCentralLogAnalytics or existingLogAnalyticsWorkspaceResourceId.'
}
$loggingWorkspaceConfigured = (Test-ParameterTrue deployCentralLogAnalytics) -or -not [string]::IsNullOrWhiteSpace([string](Get-OptionalParameterValue existingLogAnalyticsWorkspaceResourceId))
if ((Get-OptionalParameterValue activityLogExportPolicyEffect) -eq 'DeployIfNotExists' -or
    (Get-OptionalParameterValue resourceDiagnosticsPolicyEffect) -eq 'AuditIfNotExists' -or
    (Get-OptionalParameterValue resourceDiagnosticsPolicyEffect) -eq 'DeployIfNotExists') {
    if (-not $loggingWorkspaceConfigured) { Stop-Preflight 'Activity Log and supported-resource diagnostics assignments require deployCentralLogAnalytics or existingLogAnalyticsWorkspaceResourceId.' }
}
if ((Get-OptionalParameterValue activityLogExportPolicyEffect) -eq 'DeployIfNotExists') {
    if (-not (Test-ParameterTrue deployLoggingRemediationRoleAssignments)) { Stop-Preflight 'activityLogExportPolicyEffect=DeployIfNotExists requires deployLoggingRemediationRoleAssignments.' }
    if (-not (Test-ParameterTrue deployRoleAssignments)) { Stop-Preflight 'activityLogExportPolicyEffect=DeployIfNotExists requires deployRoleAssignments.' }
}

$criticalSubscriptions = @()
$criticalSubscriptionIds = Get-OptionalParameterValue criticalInfrastructureSubscriptionIds
if ($null -ne $criticalSubscriptionIds) {
    foreach ($criticalSubscription in @($criticalSubscriptionIds)) {
        if (-not (Test-GuidShape ([string]$criticalSubscription))) { Stop-Preflight 'criticalInfrastructureSubscriptionIds contains a non-GUID subscription ID.' }
        if ($criticalSubscriptions -contains ([string]$criticalSubscription).ToLowerInvariant()) { Stop-Preflight 'criticalInfrastructureSubscriptionIds must not contain duplicate subscription IDs.' }
        $criticalSubscriptions += ([string]$criticalSubscription).ToLowerInvariant()
    }
}
if (Test-ParameterTrue enableCriticalInfrastructure) {
    if ($criticalSubscriptions.Count -eq 0) {
        Stop-Preflight 'enableCriticalInfrastructure requires one or more criticalInfrastructureSubscriptionIds.'
    }
}
foreach ($criticalSubscription in $criticalSubscriptions) {
    if ($criticalSubscription -eq $connectivitySubscription.ToLowerInvariant() -or $criticalSubscription -eq $workloadSubscription.ToLowerInvariant()) {
        Stop-Preflight 'criticalInfrastructureSubscriptionIds must not overlap with connectivitySubscriptionId or workloadSubscriptionId.'
    }
}

$approvedBackupVaultInput = Get-OptionalParameterValue approvedBackupVaults
$approvedBackupVaults = if ($null -eq $approvedBackupVaultInput) { @() } else { @($approvedBackupVaultInput) }
foreach ($approvedBackupVault in $approvedBackupVaults) {
    $vaultId = [string]$approvedBackupVault.vaultResourceId
    $backupPolicyId = [string]$approvedBackupVault.backupPolicyResourceId
    if ([string]::IsNullOrWhiteSpace($vaultId) -or [string]::IsNullOrWhiteSpace($backupPolicyId)) { Stop-Preflight 'approvedBackupVaults entries require vaultResourceId and backupPolicyResourceId.' }
    if (-not (Test-ResourceId $vaultId Microsoft.RecoveryServices vaults)) { Stop-Preflight 'approvedBackupVaults contains an invalid Recovery Services vault resource ID.' }
    if (-not $backupPolicyId.StartsWith("$vaultId/backupPolicies/", [System.StringComparison]::OrdinalIgnoreCase) -or
        $backupPolicyId.Length -eq ($vaultId.Length + '/backupPolicies/'.Length) -or
        $backupPolicyId.Substring($vaultId.Length + '/backupPolicies/'.Length).Contains('/')) { Stop-Preflight 'approvedBackupVaults backupPolicyResourceId must be inside its vault.' }
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

function Test-ScopeAccess {
    param(
        [string]$Scope,
        [string]$Label
    )
    & az role assignment list --scope $Scope --include-inherited --all --output none 2>$null
    if ($LASTEXITCODE -ne 0) {
        Stop-Preflight "Cannot read effective role assignments at $Label scope $Scope; request Reader access before deployment."
    }
}

$tenantRootScope = "/providers/Microsoft.Management/managementGroups/$tenantRoot"
Test-ScopeAccess $tenantRootScope 'tenant-root management group'
Test-ScopeAccess "/subscriptions/$connectivitySubscription" 'connectivity subscription'
Test-ScopeAccess "/subscriptions/$workloadSubscription" 'workload subscription'
function Test-EffectivePermission {
    param(
        [string]$Scope,
        [string]$Action
    )
    $permissions = Invoke-AzJson @(
        'rest', '--method', 'get',
        '--url', "https://management.azure.com$Scope/providers/Microsoft.Authorization/permissions?api-version=2015-07-01",
        '--output', 'json'
    )
    if ($null -eq $permissions) {
        Stop-Preflight "Cannot determine effective permissions at $Scope; request $Action before deployment."
    }
    if (-not (Test-ActionPermitted -Action $Action -Permissions $permissions)) {
        Stop-Preflight "The deployment caller lacks $Action at $Scope; grant the required role before deployment."
    }
}
Test-EffectivePermission $tenantRootScope 'microsoft.authorization/policyassignments/write'
Test-EffectivePermission $tenantRootScope 'microsoft.authorization/policydefinitions/write'
Test-EffectivePermission $tenantRootScope 'microsoft.authorization/policysetdefinitions/write'
if ((Test-ParameterTrue deployRoleAssignments) -or (Test-ParameterTrue enableVmBackupRemediation) -or (Test-ParameterTrue grantVaultDiagnosticsWorkspaceAccess)) {
    Test-EffectivePermission $tenantRootScope 'microsoft.authorization/roleassignments/write'
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
if (Test-ParameterTrue deployCentralLogAnalytics) {
    Test-ProviderRegistration $connectivitySubscription Microsoft.OperationalInsights
}
if (Test-ParameterTrue deployRecoveryServicesVault) {
    Test-ProviderRegistration $workloadSubscription Microsoft.RecoveryServices
}

function Test-OwnedResourceGroupCollision {
    param([string]$Subscription, [string]$Group)
    $exists = & az group exists --subscription $Subscription --name $Group --output tsv 2>$null
    if ([string]$exists -eq 'true') {
        $owner = & az group show --subscription $Subscription --name $Group --query 'tags.ESLZLifecycleOwner' --output tsv 2>$null
        if ($LASTEXITCODE -ne 0) { Stop-Preflight "Cannot read existing resource group $Group; it is protected." }
        if ([string]::IsNullOrEmpty([string]$owner)) { Stop-Preflight "Resource group $Group already exists without an ESLZLifecycleOwner marker; it is protected." }
        if ([string]$owner -cne $namePrefix) { Stop-Preflight "Resource group $Group belongs to a different ESLZLifecycleOwner; it is protected." }
    }
}
if (Test-ParameterTrue deployEvidenceResources) {
    Test-OwnedResourceGroupCollision $connectivitySubscription "rg-$namePrefix-connectivity"
    Test-OwnedResourceGroupCollision $workloadSubscription "rg-$namePrefix-$((Get-ParameterValue workloadArchetype))-demo"
}
if ((Test-ParameterTrue deployCentralLogAnalytics) -and [string]::IsNullOrEmpty([string](Get-OptionalParameterValue existingLogAnalyticsWorkspaceResourceId))) {
    Test-OwnedResourceGroupCollision $connectivitySubscription "rg-$namePrefix-monitoring"
}
if (Test-ParameterTrue deployRecoveryServicesVault) {
    Test-OwnedResourceGroupCollision $workloadSubscription "rg-$namePrefix-backup"
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
if (-not [string]::IsNullOrWhiteSpace($workspaceId)) {
    $workspaceSubscriptionId = Get-ResourceSubscriptionId $workspaceId
    Test-Subscription $workspaceSubscriptionId 'workspace'
    Test-ProviderRegistration $workspaceSubscriptionId Microsoft.OperationalInsights
    Test-ReferencedResource $workspaceId Microsoft.OperationalInsights/workspaces
    if ((Test-ParameterTrue grantVaultDiagnosticsWorkspaceAccess) -or
        ((Test-ParameterTrue deployLoggingRemediationRoleAssignments) -and
        (((Get-OptionalParameterValue activityLogExportPolicyEffect) -eq 'DeployIfNotExists') -or
        ((Get-OptionalParameterValue resourceDiagnosticsPolicyEffect) -eq 'DeployIfNotExists')))) {
        Test-EffectivePermission $workspaceId 'microsoft.authorization/roleassignments/write'
    }
}
$firewallId = [string](Get-OptionalParameterValue approvedFirewallResourceId)
if (-not [string]::IsNullOrWhiteSpace($firewallId)) {
    $firewallSubscriptionId = Get-ResourceSubscriptionId $firewallId
    Test-Subscription $firewallSubscriptionId 'firewall'
    Test-ProviderRegistration $firewallSubscriptionId Microsoft.Network
    Test-ReferencedResource $firewallId Microsoft.Network/azureFirewalls
}
if ($null -ne $routeTableIds) {
    foreach ($routeTableId in @($routeTableIds)) {
        $routeTableIdText = [string]$routeTableId
        if ([string]::IsNullOrWhiteSpace($routeTableIdText)) { continue }
        $routeTableSubscriptionId = Get-ResourceSubscriptionId $routeTableIdText
        if ([string]::IsNullOrWhiteSpace($routeTableSubscriptionId)) { continue }
        Test-Subscription $routeTableSubscriptionId 'route-table'
        Test-ProviderRegistration $routeTableSubscriptionId Microsoft.Network
        Test-ReferencedResource $routeTableIdText Microsoft.Network/routeTables
    }
}
foreach ($approvedBackupVault in $approvedBackupVaults) {
    $vaultResourceId = [string]$approvedBackupVault.vaultResourceId
    if ([string]::IsNullOrWhiteSpace($vaultResourceId) -or [string]::IsNullOrWhiteSpace([string]$approvedBackupVault.backupPolicyResourceId)) { Stop-Preflight 'approvedBackupVaults entries require vaultResourceId and backupPolicyResourceId.' }
    $backupVaultSubscriptionId = Get-ResourceSubscriptionId $vaultResourceId
    if ([string]::IsNullOrWhiteSpace($backupVaultSubscriptionId)) { continue }
    Test-Subscription $backupVaultSubscriptionId 'backup-vault'
    Test-ProviderRegistration $backupVaultSubscriptionId Microsoft.RecoveryServices
    Test-ReferencedResource $vaultResourceId Microsoft.RecoveryServices/vaults
    Test-ReferencedResource ([string]$approvedBackupVault.backupPolicyResourceId) Microsoft.RecoveryServices/vaults/backupPolicies
    if (Test-ParameterTrue enableVmBackupRemediation) {
        Test-EffectivePermission $vaultResourceId 'microsoft.authorization/roleassignments/write'
    }
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
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Preflight
}
