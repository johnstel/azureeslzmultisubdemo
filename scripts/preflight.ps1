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

function Test-GuidShape {
    param([string]$Value)
    return $Value -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
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

& az account management-group show --name $tenantRoot --output none 2>$null
if ($LASTEXITCODE -ne 0) {
    Stop-Preflight "Cannot read tenant-root management group '$tenantRoot'. Check the ID and tenant permissions."
}

Write-Host ''
Write-Host 'Preflight passed.'
Write-Host "  Active tenant: $signedInTenant"
Write-Host "  Tenant root MG: $tenantRoot"
Write-Host "  Connectivity subscription: $connectivitySubscription"
Write-Host "  Workload subscription: $workloadSubscription"
Write-Host "  Tenant deployment location: $deploymentLocation"
Write-Host '  Entra group IDs: GUID format and uniqueness verified where supplied (directory group type is not queried).'
