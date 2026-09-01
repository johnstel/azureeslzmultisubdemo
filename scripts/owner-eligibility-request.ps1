[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ParameterFile,

    [string]$Location = 'eastus',

    [switch]$Execute
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir
$BicepFile = Join-Path $ProjectDir 'identity/azure-rbac/owner-eligibility-request.bicep'
$OwnerRoleDefinitionId = '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
$ApiVersion = '2020-10-01'
$ExecutionConfirmation = 'SUBMIT-OWNER-ELIGIBILITY'
$script:ParameterSnapshot = ''
$script:ParameterJsonDocument = $null

function Clear-WorkflowState {
    if (-not [string]::IsNullOrEmpty($script:ParameterSnapshot) -and (Test-Path -LiteralPath $script:ParameterSnapshot)) {
        Remove-Item -LiteralPath $script:ParameterSnapshot -Force -ErrorAction SilentlyContinue
    }
    $script:ParameterSnapshot = ''
    if ($null -ne $script:ParameterJsonDocument) {
        $script:ParameterJsonDocument.Dispose()
        $script:ParameterJsonDocument = $null
    }
}

function Stop-Workflow {
    param([string]$Message)

    Clear-WorkflowState
    Write-Error $Message -ErrorAction Continue
    exit 1
}

function Test-CanonicalGuid {
    param([string]$Value)

    return $Value -cmatch '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\z'
}

function Test-Rfc3339Utc {
    param([string]$Value)

    $match = [regex]::Match(
        $Value,
        '^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]+)?Z\z',
        [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
    )
    if (-not $match.Success) {
        return $false
    }

    $year = [int]$match.Groups[1].Value
    $month = [int]$match.Groups[2].Value
    $day = [int]$match.Groups[3].Value
    $hour = [int]$match.Groups[4].Value
    $minute = [int]$match.Groups[5].Value
    $second = [int]$match.Groups[6].Value
    if ($year -lt 1 -or $month -lt 1 -or $month -gt 12 -or $hour -gt 23 -or $minute -gt 59 -or $second -gt 59) {
        return $false
    }

    return $day -ge 1 -and $day -le [DateTime]::DaysInMonth($year, $month)
}

function Get-StringParameter {
    param(
        [System.Text.Json.JsonElement]$Parameters,
        [string]$Name
    )

    try {
        $valueElement = $Parameters.GetProperty($Name).GetProperty('value')
    }
    catch {
        Stop-Workflow "Parameter '$Name' must have a string value."
    }
    if ($valueElement.ValueKind -ne [System.Text.Json.JsonValueKind]::String) {
        Stop-Workflow "Parameter '$Name' must have a string value."
    }

    return $valueElement.GetString()
}

function Invoke-AzJson {
    param(
        [string[]]$Arguments,
        [string]$FailureMessage
    )

    $output = & az @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        Stop-Workflow $FailureMessage
    }

    try {
        $result = ($output -join [Environment]::NewLine) | ConvertFrom-Json
    }
    catch {
        Stop-Workflow "$FailureMessage Azure CLI returned invalid JSON."
    }
    if ($result -isnot [System.Management.Automation.PSCustomObject]) {
        Stop-Workflow "$FailureMessage Azure CLI returned an unexpected JSON shape."
    }
    return $result
}

function Test-ArmInventoryItem {
    param(
        [object]$Item,
        [switch]$RequireStatus
    )

    if ($Item -isnot [System.Management.Automation.PSCustomObject]) {
        return $false
    }
    foreach ($propertyName in @('id', 'name')) {
        $property = $Item.PSObject.Properties[$propertyName]
        if ($null -eq $property -or $property.Value -isnot [string]) {
            return $false
        }
    }
    $propertiesProperty = $Item.PSObject.Properties['properties']
    if ($null -eq $propertiesProperty -or $propertiesProperty.Value -isnot [System.Management.Automation.PSCustomObject]) {
        return $false
    }
    $requiredPropertyNames = @('scope', 'principalId', 'roleDefinitionId')
    if ($RequireStatus) {
        $requiredPropertyNames += 'status'
    }
    foreach ($propertyName in $requiredPropertyNames) {
        $property = $propertiesProperty.Value.PSObject.Properties[$propertyName]
        if ($null -eq $property -or $property.Value -isnot [string]) {
            return $false
        }
    }

    return $true
}

function Get-ArmCollection {
    param(
        [string]$InitialUrl,
        [string]$FailureMessage
    )

    $items = @()
    $nextUrl = $InitialUrl
    $pageCount = 0
    while (-not [string]::IsNullOrEmpty($nextUrl)) {
        if (-not $nextUrl.StartsWith('https://management.azure.com/', [System.StringComparison]::OrdinalIgnoreCase)) {
            Stop-Workflow $FailureMessage
        }

        $pageCount++
        if ($pageCount -gt 100) {
            Stop-Workflow $FailureMessage
        }

        $page = Invoke-AzJson -Arguments @(
            'rest',
            '--method', 'get',
            '--url', $nextUrl,
            '--subscription', $script:NormalizedSubscriptionId,
            '--output', 'json'
        ) -FailureMessage $FailureMessage

        if ($null -eq $page.PSObject.Properties['value'] -or $page.value -isnot [System.Array]) {
            Stop-Workflow $FailureMessage
        }
        $items += @($page.value)

        if ($null -ne $page.PSObject.Properties['nextLink'] -and $null -ne $page.nextLink) {
            $nextUrl = [string]$page.nextLink
        }
        else {
            $nextUrl = ''
        }
    }

    return $items
}

if (-not (Test-CanonicalGuid $SubscriptionId)) {
    Stop-Workflow 'SubscriptionId must be a canonical GUID.'
}
if (-not (Test-Path -LiteralPath $ParameterFile -PathType Leaf)) {
    Stop-Workflow 'ParameterFile must identify an existing local JSON file.'
}
if ($Location -cnotmatch '^[a-z0-9-]+$') {
    Stop-Workflow 'Location must contain only lowercase letters, numbers, and hyphens.'
}
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Stop-Workflow 'Azure CLI is required.'
}

try {
    $parameterText = Get-Content -LiteralPath $ParameterFile -Raw
    $script:ParameterJsonDocument = [System.Text.Json.JsonDocument]::Parse($parameterText)
    $parameterElement = $script:ParameterJsonDocument.RootElement.GetProperty('parameters')
}
catch {
    Stop-Workflow 'ParameterFile is not valid JSON.'
}
if ($parameterElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
    Stop-Workflow 'ParameterFile is not a valid ARM deployment parameter document.'
}
$script:ParameterSnapshot = Join-Path ([System.IO.Path]::GetTempPath()) "eslz-owner-eligibility-$([guid]::NewGuid().ToString('N')).json"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($script:ParameterSnapshot, $parameterText, $utf8NoBom)
$ParameterFile = $script:ParameterSnapshot

try {
    $submitValueElement = $parameterElement.GetProperty('submitEligibilityRequest').GetProperty('value')
}
catch {
    Stop-Workflow "Parameter 'submitEligibilityRequest' must have a boolean value."
}
if (
    $submitValueElement.ValueKind -ne [System.Text.Json.JsonValueKind]::True -and
    $submitValueElement.ValueKind -ne [System.Text.Json.JsonValueKind]::False
) {
    Stop-Workflow "Parameter 'submitEligibilityRequest' must have a boolean value."
}
if (-not $submitValueElement.GetBoolean()) {
    Stop-Workflow "Set 'submitEligibilityRequest' to true only in the reviewed local one-shot file before using this workflow."
}

$requestId = Get-StringParameter -Parameters $parameterElement -Name 'requestId'
$requestType = Get-StringParameter -Parameters $parameterElement -Name 'requestType'
$groupId = Get-StringParameter -Parameters $parameterElement -Name 'subscriptionPrivilegedAccessGroupObjectId'
$targetScheduleId = Get-StringParameter -Parameters $parameterElement -Name 'targetRoleEligibilityScheduleId'
$startTime = Get-StringParameter -Parameters $parameterElement -Name 'eligibleOwnerAssignmentStartDateTime'
$duration = Get-StringParameter -Parameters $parameterElement -Name 'eligibleOwnerAssignmentDuration'
$justification = Get-StringParameter -Parameters $parameterElement -Name 'eligibleOwnerAssignmentJustification'
$fileWorkflowToken = Get-StringParameter -Parameters $parameterElement -Name 'operatorWorkflowVerificationToken'

if (-not (Test-CanonicalGuid $requestId)) {
    Stop-Workflow 'requestId must be a canonical GUID.'
}
if (-not (Test-CanonicalGuid $groupId)) {
    Stop-Workflow 'subscriptionPrivilegedAccessGroupObjectId must be a canonical GUID.'
}
if ([string]::IsNullOrWhiteSpace($justification)) {
    Stop-Workflow 'eligibleOwnerAssignmentJustification must not be blank.'
}
if ($duration -notin @('P30D', 'P90D', 'P180D', 'P365D')) {
    Stop-Workflow 'eligibleOwnerAssignmentDuration must be one of P30D, P90D, P180D, or P365D.'
}
if ($fileWorkflowToken -cne 'UNSUPPORTED_OUTSIDE_SCRIPTS_OWNER_ELIGIBILITY_REQUEST') {
    Stop-Workflow 'Do not place workflow verification evidence in the parameter file; use this operator workflow.'
}

switch -CaseSensitive ($requestType) {
    'AdminAssign' {
        if (-not [string]::IsNullOrEmpty($targetScheduleId)) {
            Stop-Workflow 'AdminAssign requires an empty targetRoleEligibilityScheduleId.'
        }
        if (-not (Test-Rfc3339Utc $startTime)) {
            Stop-Workflow 'AdminAssign requires an RFC3339 UTC eligibleOwnerAssignmentStartDateTime ending in Z.'
        }
    }
    'AdminUpdate' {
        if (-not (Test-CanonicalGuid $targetScheduleId)) {
            Stop-Workflow 'AdminUpdate requires a canonical targetRoleEligibilityScheduleId GUID.'
        }
        if (-not (Test-Rfc3339Utc $startTime)) {
            Stop-Workflow 'AdminUpdate requires an RFC3339 UTC eligibleOwnerAssignmentStartDateTime ending in Z.'
        }
    }
    'AdminRemove' {
        if (-not (Test-CanonicalGuid $targetScheduleId)) {
            Stop-Workflow 'AdminRemove requires a canonical targetRoleEligibilityScheduleId GUID.'
        }
        if (-not [string]::IsNullOrEmpty($startTime)) {
            Stop-Workflow 'AdminRemove requires an empty eligibleOwnerAssignmentStartDateTime.'
        }
    }
    default {
        Stop-Workflow 'requestType must be AdminAssign, AdminUpdate, or AdminRemove.'
    }
}

if ($Execute -and $env:ESLZ_OWNER_ELIGIBILITY_CONFIRMATION -cne $ExecutionConfirmation) {
    Stop-Workflow "--Execute requires ESLZ_OWNER_ELIGIBILITY_CONFIRMATION=$ExecutionConfirmation."
}

$workflowRequestId = $requestId
$workflowGroupId = $groupId
$script:NormalizedSubscriptionId = $SubscriptionId.ToLowerInvariant()
$requestId = $requestId.ToLowerInvariant()
$groupId = $groupId.ToLowerInvariant()
$targetScheduleId = $targetScheduleId.ToLowerInvariant()
$scope = "/subscriptions/$script:NormalizedSubscriptionId"
$ownerRoleDefinitionResourceId = "$scope/providers/microsoft.authorization/roledefinitions/$OwnerRoleDefinitionId"
$workflowToken = "verified:$workflowRequestId`:$workflowGroupId`:$requestType`:$script:NormalizedSubscriptionId"

$subscription = Invoke-AzJson -Arguments @(
    'account', 'show',
    '--subscription', $script:NormalizedSubscriptionId,
    '--output', 'json'
) -FailureMessage 'Unable to read the target subscription context.'
$subscriptionIdProperty = $subscription.PSObject.Properties['id']
$subscriptionStateProperty = $subscription.PSObject.Properties['state']
$subscriptionTenantProperty = $subscription.PSObject.Properties['tenantId']
if (
    $null -eq $subscriptionIdProperty -or
    $subscriptionIdProperty.Value -isnot [string] -or
    ([string]$subscriptionIdProperty.Value).ToLowerInvariant() -cne $script:NormalizedSubscriptionId -or
    $null -eq $subscriptionStateProperty -or
    $subscriptionStateProperty.Value -isnot [string] -or
    ([string]$subscriptionStateProperty.Value).ToLowerInvariant() -cne 'enabled' -or
    $null -eq $subscriptionTenantProperty -or
    $subscriptionTenantProperty.Value -isnot [string] -or
    [string]::IsNullOrWhiteSpace([string]$subscriptionTenantProperty.Value)
) {
    Stop-Workflow 'Target subscription context is missing, disabled, or ambiguous.'
}
$targetTenantId = ([string]$subscriptionTenantProperty.Value).ToLowerInvariant()

$activeContext = Invoke-AzJson -Arguments @(
    'account', 'show',
    '--output', 'json'
) -FailureMessage 'Unable to read the active Azure CLI context.'
$activeTenantProperty = $activeContext.PSObject.Properties['tenantId']
$activeStateProperty = $activeContext.PSObject.Properties['state']
if (
    $null -eq $activeTenantProperty -or
    $activeTenantProperty.Value -isnot [string] -or
    ([string]$activeTenantProperty.Value).ToLowerInvariant() -cne $targetTenantId -or
    $null -eq $activeStateProperty -or
    $activeStateProperty.Value -isnot [string] -or
    ([string]$activeStateProperty.Value).ToLowerInvariant() -cne 'enabled'
) {
    Stop-Workflow 'The active Azure CLI context must use the target subscription tenant before the Entra group lookup.'
}

$group = Invoke-AzJson -Arguments @(
    'ad', 'group', 'show',
    '--group', $groupId,
    '--output', 'json'
) -FailureMessage 'Unable to verify the privileged principal through Microsoft Entra.'
$groupIdProperty = $group.PSObject.Properties['id']
$securityEnabledProperty = $group.PSObject.Properties['securityEnabled']
if (
    $null -eq $groupIdProperty -or
    $groupIdProperty.Value -isnot [string] -or
    ([string]$groupIdProperty.Value).ToLowerInvariant() -cne $groupId -or
    $null -eq $securityEnabledProperty -or
    $securityEnabledProperty.Value -isnot [bool] -or
    $securityEnabledProperty.Value -ne $true
) {
    Stop-Workflow 'The supplied privileged principal is not the exact existing security-enabled Microsoft Entra group.'
}

$principalFilter = "principalId%20eq%20$groupId"
$schedulesUrl = "https://management.azure.com$scope/providers/Microsoft.Authorization/roleEligibilitySchedules?api-version=$ApiVersion&%24filter=$principalFilter"
$requestsUrl = "https://management.azure.com$scope/providers/Microsoft.Authorization/roleEligibilityScheduleRequests?api-version=$ApiVersion&%24filter=atScope()"
$schedules = @(Get-ArmCollection -InitialUrl $schedulesUrl -FailureMessage 'Unable to enumerate existing Owner eligibility schedules; refusing to preview or submit.')
$requests = @(Get-ArmCollection -InitialUrl $requestsUrl -FailureMessage 'Unable to enumerate existing or pending eligibility requests; refusing to preview or submit.')
if (@($schedules | Where-Object { -not (Test-ArmInventoryItem -Item $_) }).Count -ne 0) {
    Stop-Workflow 'Existing eligibility schedule inventory returned an unexpected shape.'
}
if (@($requests | Where-Object { -not (Test-ArmInventoryItem -Item $_ -RequireStatus) }).Count -ne 0) {
    Stop-Workflow 'Eligibility request inventory returned an unexpected shape.'
}

$matchingSchedules = @($schedules | Where-Object {
    $principalMatches = ([string]$_.properties.principalId).ToLowerInvariant() -ceq $groupId
    $roleMatches = ([string]$_.properties.roleDefinitionId).ToLowerInvariant() -ceq $ownerRoleDefinitionResourceId
    $scopeMatches =
        ([string]$_.properties.scope).ToLowerInvariant() -ceq $scope -or
        ([string]$_.id).ToLowerInvariant().StartsWith(
            "$scope/providers/microsoft.authorization/roleeligibilityschedules/",
            [System.StringComparison]::Ordinal
        )
    $principalMatches -and $roleMatches -and $scopeMatches
})

$matchingRequests = @($requests | Where-Object {
    $principalMatches = ([string]$_.properties.principalId).ToLowerInvariant() -ceq $groupId
    $roleMatches = ([string]$_.properties.roleDefinitionId).ToLowerInvariant() -ceq $ownerRoleDefinitionResourceId
    $scopeMatches =
        ([string]$_.properties.scope).ToLowerInvariant() -ceq $scope -or
        ([string]$_.id).ToLowerInvariant().StartsWith(
            "$scope/providers/microsoft.authorization/roleeligibilityschedulerequests/",
            [System.StringComparison]::Ordinal
        )
    $principalMatches -and $roleMatches -and $scopeMatches
})

$requestIdReuse = @($requests | Where-Object {
    ([string]$_.name).ToLowerInvariant() -ceq $requestId -or
    ([string]$_.id).ToLowerInvariant().EndsWith("/$requestId", [System.StringComparison]::Ordinal)
})
if ($requestIdReuse.Count -ne 0) {
    Stop-Workflow 'requestId already exists at this subscription scope and must never be reused.'
}

$terminalStatuses = @(
    'denied',
    'admindenied',
    'canceled',
    'failed',
    'failedasresourceislocked',
    'revoked',
    'timedout',
    'invalid',
    'provisioned',
    'schedulecreated'
)
$unresolvedRequests = @($matchingRequests | Where-Object {
    $terminalStatuses -notcontains ([string]$_.properties.status).ToLowerInvariant()
})
if ($unresolvedRequests.Count -ne 0) {
    Stop-Workflow 'A matching eligibility request is pending or has an unknown non-terminal status.'
}

if ($requestType -ceq 'AdminAssign') {
    if ($matchingSchedules.Count -ne 0) {
        Stop-Workflow 'AdminAssign is blocked because matching Owner eligibility already exists.'
    }
}
else {
    $targetSchedules = @($matchingSchedules | Where-Object {
        ([string]$_.name).ToLowerInvariant() -ceq $targetScheduleId -or
        ([string]$_.id).ToLowerInvariant().EndsWith("/$targetScheduleId", [System.StringComparison]::Ordinal)
    })
    if ($matchingSchedules.Count -ne 1 -or $targetSchedules.Count -ne 1) {
        Stop-Workflow "$requestType requires exactly one matching existing Owner eligibility schedule with the supplied target schedule ID."
    }
}

Write-Host "Preflight passed for $requestType at $scope."
Write-Host "Verified principal: security-enabled group $groupId"
Write-Host 'Running subscription what-if; no eligibility request is submitted by this step.'
& az deployment sub what-if `
    --name "owner-eligibility-$requestId" `
    --location $Location `
    --subscription $script:NormalizedSubscriptionId `
    --template-file $BicepFile `
    --parameters "@$ParameterFile" `
    "operatorWorkflowVerificationToken=$workflowToken"
if ($LASTEXITCODE -ne 0) {
    Stop-Workflow 'Owner eligibility what-if failed; no request was submitted.'
}

if (-not $Execute) {
    Clear-WorkflowState
    Write-Host 'Preview complete. No eligibility request was submitted.'
    exit 0
}

$typedRequestId = Read-Host "Type the one-time request ID $requestId to submit the unchanged preview"
if ($typedRequestId -cne $requestId) {
    Stop-Workflow 'Typed request ID did not match; no eligibility request was submitted.'
}

& az deployment sub create `
    --name "owner-eligibility-$requestId" `
    --location $Location `
    --subscription $script:NormalizedSubscriptionId `
    --template-file $BicepFile `
    --parameters "@$ParameterFile" `
    "operatorWorkflowVerificationToken=$workflowToken"
if ($LASTEXITCODE -ne 0) {
    Stop-Workflow 'Owner eligibility submission failed or returned an ambiguous result. Do not retry with the same request ID; repeat the preflight with a fresh request ID.'
}

Clear-WorkflowState
Write-Host "One-time Owner eligibility request submitted. Do not retry or reuse request ID $requestId."
