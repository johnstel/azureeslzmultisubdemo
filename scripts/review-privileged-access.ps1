[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [Parameter(Mandatory = $true)]
    [string[]]$SubscriptionId,

    [string[]]$ManagementGroupId,

    [string]$CriteriaFile = (Join-Path (Split-Path -Parent $PSScriptRoot) 'policy/access-review-criteria.json'),

    [string]$OutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) '.access-reviews'),

    [string]$AssignmentsFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Stop-Review {
    param(
        [string]$Message,
        [int]$ExitCode = 1
    )

    Write-Error -Message "ERROR: $Message" -ErrorAction Continue
    exit $ExitCode
}

function Expand-DelimitedList {
    param([object[]]$Values)

    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($value in @($Values)) {
        if ($null -eq $value) {
            continue
        }
        foreach ($item in ($value -split ',')) {
            if (-not [string]::IsNullOrWhiteSpace($item)) {
                $result.Add($item.Trim())
            }
        }
    }

    return @($result)
}

function Test-CanonicalGuid {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    return $Value -cmatch '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'
}

function Test-ManagementGroupId {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    return $Value -cmatch '^[-_().a-zA-Z0-9]{1,90}$'
}

function Test-JsonArrayOfNonEmptyStrings {
    param([object]$Value)

    if ($null -eq $Value) {
        return $false
    }
    $items = @($Value)
    if ($items.Count -lt 1) {
        return $false
    }
    foreach ($item in $items) {
        if ($item -isnot [string] -or [string]::IsNullOrWhiteSpace($item)) {
            return $false
        }
    }

    return $true
}

function Test-PositiveIntegerProperty {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) {
        return $false
    }
    $value = $Object.PSObject.Properties[$Name].Value
    if ($value -isnot [int] -and $value -isnot [long] -and $value -isnot [double] -and $value -isnot [decimal]) {
        return $false
    }
    $numeric = [double]$value

    return ($numeric -ge 1) -and ($numeric -eq [math]::Floor($numeric))
}

function Invoke-LiveAssignments {
    param(
        [string]$RequestedTenantId,
        [string[]]$RequestedSubscriptions,
        [string[]]$RequestedManagementGroups
    )

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        Stop-Review "Required command 'az' is not installed."
    }

    $signedInTenant = (& az account show --query tenantId --output tsv 2>$null | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($signedInTenant)) {
        Stop-Review 'Azure CLI is not signed in. Sign in read-only before running this review.'
    }
    if ($signedInTenant -ine $RequestedTenantId) {
        Stop-Review "Signed-in tenant $signedInTenant does not match the requested -TenantId."
    }

    $observations = @()
    foreach ($subscriptionId in $RequestedSubscriptions) {
        $page = (& az role assignment list --subscription $subscriptionId --all --include-inherited --output json 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
            Stop-Review "Unable to read role assignments for subscription $subscriptionId."
        }
        if (-not [string]::IsNullOrWhiteSpace($page)) {
            try {
                $parsed = $page | ConvertFrom-Json -Depth 50
            }
            catch {
                Stop-Review "Unable to read role assignments for subscription $subscriptionId."
            }
            $observations += [pscustomobject]@{
                source = [pscustomobject]@{
                    kind = 'subscription'
                    id = $subscriptionId
                }
                assignments = @($parsed)
            }
        }
    }

    foreach ($managementGroupId in $RequestedManagementGroups) {
        $page = (& az role assignment list --scope "/providers/Microsoft.Management/managementGroups/$managementGroupId" --include-inherited --output json 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
            Stop-Review "Unable to read role assignments for management group $managementGroupId."
        }
        if (-not [string]::IsNullOrWhiteSpace($page)) {
            try {
                $parsed = $page | ConvertFrom-Json -Depth 50
            }
            catch {
                Stop-Review "Unable to read role assignments for management group $managementGroupId."
            }
            $observations += [pscustomobject]@{
                source = [pscustomobject]@{
                    kind = 'managementGroup'
                    id = $managementGroupId
                }
                assignments = @($parsed)
            }
        }
    }

    return $observations
}

function Get-ScopeType {
    param([string]$Scope)

    if ([string]::IsNullOrWhiteSpace($Scope)) {
        return 'unknown'
    }
    if ($Scope -ceq '/') {
        return 'tenantRoot'
    }
    if ($Scope -match '^/providers/[Mm]icrosoft\.[Mm]anagement/managementGroups/[^/]+$') {
        return 'managementGroup'
    }
    if ($Scope -match '^/subscriptions/[^/]+$') {
        return 'subscription'
    }
    if ($Scope -match '^/subscriptions/[^/]+/[Rr]esource[Gg]roups/[^/]+$') {
        return 'resourceGroup'
    }
    if ($Scope -match '^/subscriptions/[^/]+/[Rr]esource[Gg]roups/[^/]+/.+$') {
        return 'resource'
    }

    return 'unknown'
}

function Get-SubscriptionIdFromScope {
    param([string]$Scope)

    if ([string]::IsNullOrWhiteSpace($Scope)) {
        return $null
    }
    $match = [regex]::Match($Scope, '^/subscriptions/(?<id>[^/]+)')
    if ($match.Success) {
        return $match.Groups['id'].Value
    }

    return $null
}

function Get-SeverityRank {
    param([string]$Severity)

    switch ($Severity) {
        'high' { return 0 }
        'medium' { return 1 }
        'low' { return 2 }
        default { return 3 }
    }
}

function Get-AssignmentKey {
    param([object]$Assignment)

    $idValue = $null
    if ($null -ne $Assignment.PSObject.Properties['id']) {
        $idValue = [string]$Assignment.id
    }
    if (-not [string]::IsNullOrWhiteSpace($idValue)) {
        return "id:$($idValue.ToLowerInvariant())"
    }

    $scopeValue = ''
    if ($null -ne $Assignment.PSObject.Properties['scope']) {
        $scopeValue = [string]$Assignment.scope
    }
    $principalValue = ''
    if ($null -ne $Assignment.PSObject.Properties['principalId']) {
        $principalValue = [string]$Assignment.principalId
    }
    $roleValue = ''
    if ($null -ne $Assignment.PSObject.Properties['roleDefinitionName']) {
        $roleValue = [string]$Assignment.roleDefinitionName
    }

    return "composite:$($scopeValue.ToLowerInvariant())|$($principalValue.ToLowerInvariant())|$($roleValue.ToLowerInvariant())"
}

function Get-JsonObjectArray {
    param(
        [object]$Document,
        [string]$FailureMessage
    )

    if ($Document -is [System.Array]) {
        return @([pscustomobject]@{ source = $null; assignments = @($Document) })
    }

    if ($Document -is [System.Management.Automation.PSCustomObject]) {
        $valueProperty = $Document.PSObject.Properties['value']
        if ($null -ne $valueProperty -and $valueProperty.Value -is [System.Array]) {
            return @([pscustomobject]@{ source = $null; assignments = @($valueProperty.Value) })
        }

        $observationsProperty = $Document.PSObject.Properties['observations']
        if ($null -ne $observationsProperty -and $observationsProperty.Value -is [System.Array]) {
            $result = @()
            foreach ($observation in @($observationsProperty.Value)) {
                if ($observation -isnot [System.Management.Automation.PSCustomObject]) {
                    Stop-Review $FailureMessage
                }
                $sourceProperty = $observation.PSObject.Properties['source']
                $assignmentsProperty = $observation.PSObject.Properties['assignments']
                if ($null -eq $sourceProperty -or $null -eq $assignmentsProperty) {
                    Stop-Review $FailureMessage
                }
                if ($sourceProperty.Value -isnot [System.Management.Automation.PSCustomObject] -or $assignmentsProperty.Value -isnot [System.Array]) {
                    Stop-Review $FailureMessage
                }

                $kindProperty = $sourceProperty.Value.PSObject.Properties['kind']
                $idProperty = $sourceProperty.Value.PSObject.Properties['id']
                if ($null -eq $kindProperty -or $null -eq $idProperty) {
                    Stop-Review $FailureMessage
                }
                if ($kindProperty.Value -isnot [string] -or ($kindProperty.Value -ne 'subscription' -and $kindProperty.Value -ne 'managementGroup')) {
                    Stop-Review $FailureMessage
                }
                if ($idProperty.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($idProperty.Value)) {
                    Stop-Review $FailureMessage
                }

                $result += [pscustomobject]@{
                    source = [pscustomobject]@{
                        kind = $kindProperty.Value
                        id = $idProperty.Value
                    }
                    assignments = @($assignmentsProperty.Value)
                }
            }
            return $result
        }
    }

    Stop-Review $FailureMessage
}

if (-not (Test-CanonicalGuid $TenantId)) {
    Stop-Review 'Tenant ID must be a canonical GUID.'
}

$subscriptionIdList = @(Expand-DelimitedList -Values $SubscriptionId)
if ($subscriptionIdList.Count -lt 1) {
    Stop-Review 'At least one -SubscriptionId is required; this review never enumerates the whole tenant implicitly.'
}
foreach ($subscription in $subscriptionIdList) {
    if (-not (Test-CanonicalGuid $subscription)) {
        Stop-Review "Subscription ID must be a canonical GUID: $subscription"
    }
    $duplicates = @($subscriptionIdList | Where-Object { $_ -ceq $subscription })
    if ($duplicates.Count -gt 1) {
        Stop-Review "Duplicate subscription ID: $subscription"
    }
}

$managementGroupIdList = @(Expand-DelimitedList -Values $ManagementGroupId | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($managementGroupIdList.Count -gt 0) {
    foreach ($managementGroup in $managementGroupIdList) {
        if (-not (Test-ManagementGroupId $managementGroup)) {
            Stop-Review "Management group ID contains unsupported characters: $managementGroup"
        }
        $duplicates = @($managementGroupIdList | Where-Object { $_ -ceq $managementGroup })
        if ($duplicates.Count -gt 1) {
            Stop-Review "Duplicate management group ID: $managementGroup"
        }
    }
}

if (-not (Test-Path -LiteralPath $CriteriaFile -PathType Leaf)) {
    Stop-Review "Criteria file not found: $CriteriaFile"
}

try {
    $criteriaDocument = Get-Content -LiteralPath $CriteriaFile -Raw | ConvertFrom-Json -Depth 20
}
catch {
    Stop-Review "Criteria file is not a valid access-review criteria document: $CriteriaFile"
}

if ($null -eq $criteriaDocument) {
    Stop-Review "Criteria file is not a valid access-review criteria document: $CriteriaFile"
}

$criteriaVersionProperty = $criteriaDocument.PSObject.Properties['criteriaVersion']
$allCriteriaValid =
    ($null -ne $criteriaVersionProperty) -and
    ($criteriaVersionProperty.Value -is [string]) -and
    (-not [string]::IsNullOrWhiteSpace($criteriaVersionProperty.Value)) -and
    (Test-PositiveIntegerProperty -Object $criteriaDocument -Name 'reviewCadenceDays') -and
    (Test-PositiveIntegerProperty -Object $criteriaDocument -Name 'maxOwnersPerSubscription') -and
    (Test-JsonArrayOfNonEmptyStrings -Value $criteriaDocument.broadScopeTypes) -and
    (Test-JsonArrayOfNonEmptyStrings -Value $criteriaDocument.nonHumanPrincipalTypes) -and
    (Test-JsonArrayOfNonEmptyStrings -Value $criteriaDocument.highPrivilegeRoleNames) -and
    (Test-JsonArrayOfNonEmptyStrings -Value $criteriaDocument.elevatedRoleNames)

if (-not $allCriteriaValid) {
    Stop-Review "Criteria file is not a valid access-review criteria document: $CriteriaFile"
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    Stop-Review '-OutputDirectory must name a directory.'
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
    New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
}

$assignmentsData = @()
$mode = 'live-read-only'
if (-not [string]::IsNullOrWhiteSpace($AssignmentsFile)) {
    if (-not (Test-Path -LiteralPath $AssignmentsFile -PathType Leaf)) {
        Stop-Review "Assignments file not found: $AssignmentsFile"
    }
    try {
        $assignmentsSource = Get-Content -LiteralPath $AssignmentsFile -Raw | ConvertFrom-Json -Depth 50
    }
    catch {
        Stop-Review 'Assignments file must be a JSON array, an object with a "value" array, or an object with an "observations" array.'
    }
    $assignmentsData = Get-JsonObjectArray -Document $assignmentsSource -FailureMessage 'Assignments file must be a JSON array, an object with a "value" array, or an object with an "observations" array.'
    $mode = 'offline-file'
}
else {
    $assignmentsData = Invoke-LiveAssignments -RequestedTenantId $TenantId -RequestedSubscriptions $subscriptionIdList -RequestedManagementGroups $managementGroupIdList
}

foreach ($observation in $assignmentsData) {
    $assignments = @($observation.assignments)
    foreach ($assignment in $assignments) {
        if ($assignment -isnot [System.Management.Automation.PSCustomObject]) {
            Stop-Review 'Every role assignment must supply string roleDefinitionName, scope, principalId, and principalType values.'
        }
        foreach ($propertyName in @('roleDefinitionName', 'scope', 'principalId', 'principalType')) {
            $property = $assignment.PSObject.Properties[$propertyName]
            if ($null -eq $property -or $property.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($property.Value)) {
                Stop-Review 'Every role assignment must supply string roleDefinitionName, scope, principalId, and principalType values.'
            }
        }
    }
}

$generatedOn = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$reportStamp = $generatedOn -replace '[-:]', ''
$reportJsonPath = Join-Path $OutputDirectory "privileged-access-review-$reportStamp.json"
$reportMarkdownPath = Join-Path $OutputDirectory "privileged-access-review-$reportStamp.md"

$highPrivilegeRoles = @($criteriaDocument.highPrivilegeRoleNames | ForEach-Object { $_.ToLowerInvariant() })
$elevatedRoles = @($criteriaDocument.elevatedRoleNames | ForEach-Object { $_.ToLowerInvariant() })
$nonHumanTypes = @($criteriaDocument.nonHumanPrincipalTypes | ForEach-Object { $_.ToLowerInvariant() })
$broadScopes = @($criteriaDocument.broadScopeTypes | ForEach-Object { $_.ToLowerInvariant() })

$observed = @()
foreach ($observation in $assignmentsData) {
    $source = $observation.source
    $sourceKind = $null
    $sourceId = $null
    if ($null -ne $source -and $source -is [System.Management.Automation.PSCustomObject]) {
        $sourceKind = $source.PSObject.Properties['kind'].Value
        $sourceId = $source.PSObject.Properties['id'].Value
    }

    foreach ($assignment in @($observation.assignments)) {
        $observed += [pscustomobject]@{
            assignment = $assignment
            observedInSubscription = if ($sourceKind -eq 'subscription') { [string]$sourceId } else { $null }
        }
    }
}

$observationCount = $observed.Count
$requestedSubscriptionsLower = @($subscriptionIdList | ForEach-Object { $_.ToLowerInvariant() })
$groupedObserved = @{}
foreach ($entry in $observed) {
    $key = Get-AssignmentKey -Assignment $entry.assignment
    if (-not $groupedObserved.ContainsKey($key)) {
        $groupedObserved[$key] = @()
    }
    $groupedObserved[$key] += $entry
}

$evaluated = @()
foreach ($entries in $groupedObserved.Values) {
    $assignment = $entries[0].assignment
    $scope = [string]$assignment.scope
    $scopeType = Get-ScopeType -Scope $scope
    $roleKey = [string]$assignment.roleDefinitionName
    $principalKey = [string]$assignment.principalType
    $roleLower = $roleKey.ToLowerInvariant()
    $principalLower = $principalKey.ToLowerInvariant()
    $isHighPrivilegeRole = $highPrivilegeRoles.Contains($roleLower)
    $isElevatedRole = $elevatedRoles.Contains($roleLower)
    $isNonHumanPrincipal = $nonHumanTypes.Contains($principalLower)
    $isBroadScope = $broadScopes.Contains($scopeType.ToLowerInvariant())

    $reasons = [System.Collections.Generic.List[string]]::new()
    if ($isHighPrivilegeRole) {
        $reasons.Add('high-privilege-role')
    }
    if ($isElevatedRole) {
        $reasons.Add('elevated-role')
    }
    if (-not $isHighPrivilegeRole -and -not $isElevatedRole) {
        $reasons.Add('unclassified-role')
    }
    if ($isNonHumanPrincipal) {
        $reasons.Add('direct-non-human-principal-assignment')
    }
    if ($isBroadScope) {
        $reasons.Add('broad-scope')
    }

    $assignmentIdValue = $null
    if ($null -ne $assignment.PSObject.Properties['id']) {
        $idString = [string]$assignment.id
        if (-not [string]::IsNullOrWhiteSpace($idString)) {
            $assignmentIdValue = $idString
        }
    }

    $scopeSubscription = Get-SubscriptionIdFromScope -Scope $scope
    $candidateSubscriptions = @()
    foreach ($entry in $entries) {
        if (-not [string]::IsNullOrWhiteSpace($entry.observedInSubscription)) {
            $candidateSubscriptions += $entry.observedInSubscription
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($scopeSubscription)) {
        $candidateSubscriptions += $scopeSubscription
    }

    $lowerCandidateSubscriptions = @()
    foreach ($candidate in $candidateSubscriptions) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $lowerCandidateSubscriptions += $candidate.ToLowerInvariant()
        }
    }
    $lowerCandidateSubscriptions = @($lowerCandidateSubscriptions | Select-Object -Unique | Sort-Object)
    $matchingLowerCandidates = @()
    foreach ($candidate in $lowerCandidateSubscriptions) {
        if ($requestedSubscriptionsLower -contains $candidate) {
            $matchingLowerCandidates += $candidate
        }
    }

    $observedInSubscriptions = @()
    foreach ($candidate in @($matchingLowerCandidates | Select-Object -Unique | Sort-Object)) {
        $matched = $subscriptionIdList | Where-Object { $_.ToLowerInvariant() -eq $candidate } | Select-Object -First 1
        if ($null -ne $matched) {
            $observedInSubscriptions += $matched
        }
    }

    $evaluated += [pscustomobject]@{
        assignmentId = $assignmentIdValue
        principalId = $assignment.principalId
        principalType = $assignment.principalType
        roleDefinitionName = $assignment.roleDefinitionName
        scope = $scope
        scopeType = $scopeType
        subscriptionId = $scopeSubscription
        observedInSubscriptions = @($observedInSubscriptions)
        observationCount = $entries.Count
        isHighPrivilegeRole = $isHighPrivilegeRole
        isElevatedRole = $isElevatedRole
        isNonHumanPrincipal = $isNonHumanPrincipal
        isBroadScope = $isBroadScope
        reasons = @($reasons)
    }
}

$findings = @(
    $evaluated |
        Where-Object {
            $_.isHighPrivilegeRole -or ($_.isElevatedRole -and $_.isBroadScope) -or $_.isNonHumanPrincipal
        } |
        ForEach-Object {
            $severity = if ($_.isHighPrivilegeRole -and ($_.isBroadScope -or $_.isNonHumanPrincipal)) {
                'high'
            }
            elseif ($_.isHighPrivilegeRole -or ($_.isNonHumanPrincipal -and ($_.isBroadScope -or $_.isElevatedRole))) {
                'medium'
            }
            else {
                'low'
            }

            [ordered]@{
                assignmentId = $_.assignmentId
                principalId = $_.principalId
                principalType = $_.principalType
                roleDefinitionName = $_.roleDefinitionName
                scope = $_.scope
                scopeType = $_.scopeType
                subscriptionId = $_.subscriptionId
                observedInSubscriptions = @($_.observedInSubscriptions)
                severity = $severity
                reasons = @($_.reasons)
                reviewAction = 'manual-review-required'
            }
        } |
        Sort-Object -Property @(
            @{ Expression = { Get-SeverityRank $_.severity }; Ascending = $true },
            @{ Expression = { $_.scope }; Ascending = $true },
            @{ Expression = { $_.roleDefinitionName }; Ascending = $true },
            @{ Expression = { $_.principalId }; Ascending = $true }
        )
)

# Owner counts attribute every Owner grant that confers Owner over the whole
# subscription: one scoped directly to it, or one inherited from a management
# group or the tenant root. Resource-group and resource-scoped Owner grants
# stay findings but never count as subscription Owners, because they do not
# confer Owner over the subscription.
$ownerCounts = @()
foreach ($subscription in $subscriptionIdList) {
    $ownerAssignments = @(
        $evaluated |
            Where-Object {
                $_.roleDefinitionName -eq 'Owner' -and
                ($_.scopeType -eq 'subscription' -or $_.scopeType -eq 'managementGroup' -or $_.scopeType -eq 'tenantRoot') -and
                ($_.observedInSubscriptions -contains $subscription)
            }
    )
    $directOwners = @($ownerAssignments | Where-Object { $_.scopeType -eq 'subscription' })
    $inheritedOwners = @($ownerAssignments | Where-Object { $_.scopeType -ne 'subscription' })
    $ownerPrincipalIds = @($ownerAssignments | ForEach-Object { $_.principalId } | Select-Object -Unique)
    $directOwnerPrincipalIds = @($directOwners | ForEach-Object { $_.principalId } | Select-Object -Unique)
    $inheritedOwnerPrincipalIds = @($inheritedOwners | ForEach-Object { $_.principalId } | Select-Object -Unique)

    $ownerCounts += [ordered]@{
        subscriptionId = $subscription
        ownerPrincipalCount = $ownerPrincipalIds.Count
        directOwnerPrincipalCount = $directOwnerPrincipalIds.Count
        inheritedOwnerPrincipalCount = $inheritedOwnerPrincipalIds.Count
        exceedsThreshold = ($ownerPrincipalIds.Count -gt [int]$criteriaDocument.maxOwnersPerSubscription)
    }
}
$ownerCounts = @($ownerCounts | Sort-Object -Property @{ Expression = { $_.subscriptionId }; Ascending = $true })

$summary = [ordered]@{
    assignmentsCollected = $observationCount
    assignmentsEvaluated = $evaluated.Count
    duplicateObservationsCollapsed = $observationCount - $evaluated.Count
    findingCount = $findings.Count
    highSeverityFindingCount = @($findings | Where-Object { $_.severity -eq 'high' }).Count
    mediumSeverityFindingCount = @($findings | Where-Object { $_.severity -eq 'medium' }).Count
    lowSeverityFindingCount = @($findings | Where-Object { $_.severity -eq 'low' }).Count
    nonHumanAssignmentCount = @($evaluated | Where-Object { $_.isNonHumanPrincipal }).Count
    nonHumanHighPrivilegeAssignmentCount = @($evaluated | Where-Object { $_.isNonHumanPrincipal -and $_.isHighPrivilegeRole }).Count
    managementGroupScopedAssignmentCount = @($evaluated | Where-Object { $_.scopeType -eq 'managementGroup' -or $_.scopeType -eq 'tenantRoot' }).Count
    subscriptionOwnerCounts = $ownerCounts
    subscriptionsExceedingOwnerThreshold = @($ownerCounts | Where-Object { $_.exceedsThreshold } | ForEach-Object { $_.subscriptionId })
}

$report = [ordered]@{
    schemaVersion = '1.0'
    generatedOn = $generatedOn
    mode = $mode
    tenantId = $TenantId
    subscriptionIds = @($subscriptionIdList)
    managementGroupIds = @($managementGroupIdList)
    criteria = [ordered]@{
        criteriaVersion = $criteriaDocument.criteriaVersion
        reviewCadenceDays = [int]$criteriaDocument.reviewCadenceDays
        maxOwnersPerSubscription = [int]$criteriaDocument.maxOwnersPerSubscription
        highPrivilegeRoleNames = @($criteriaDocument.highPrivilegeRoleNames)
        elevatedRoleNames = @($criteriaDocument.elevatedRoleNames)
        nonHumanPrincipalTypes = @($criteriaDocument.nonHumanPrincipalTypes)
        broadScopeTypes = @($criteriaDocument.broadScopeTypes)
    }
    summary = $summary
    findings = @($findings)
}

$reportJsonText = $report | ConvertTo-Json -Depth 20
[System.IO.File]::WriteAllText($reportJsonPath, $reportJsonText, [System.Text.UTF8Encoding]::new($false))

$subscriptionLines = if ($report.subscriptionIds.Count -gt 0) { ($report.subscriptionIds -join ', ') } else { '' }
$managementGroupLines = if ($report.managementGroupIds.Count -gt 0) { ($report.managementGroupIds -join ', ') } else { '(none supplied)' }
$reportMarkdownLines = [System.Collections.Generic.List[string]]::new()
$reportMarkdownLines.Add('# Privileged access review')
$reportMarkdownLines.Add('')
$reportMarkdownLines.Add("- Generated (UTC): $($report.generatedOn)")
$reportMarkdownLines.Add("- Mode: $($report.mode)")
$reportMarkdownLines.Add("- Tenant: $($report.tenantId)")
$reportMarkdownLines.Add("- Subscriptions: $subscriptionLines")
$reportMarkdownLines.Add("- Management groups: $managementGroupLines")
$reportMarkdownLines.Add("- Criteria version: $($report.criteria.criteriaVersion) (review cadence $($report.criteria.reviewCadenceDays) days, Owner threshold $($report.criteria.maxOwnersPerSubscription))")
$reportMarkdownLines.Add('')
$reportMarkdownLines.Add('This report highlights assignments for human review. It never concludes that')
$reportMarkdownLines.Add('a principal is excessive, and it changes nothing in Azure or Microsoft Entra.')
$reportMarkdownLines.Add('')
$reportMarkdownLines.Add('## Summary')
$reportMarkdownLines.Add('')
$reportMarkdownLines.Add('| Measure | Value |')
$reportMarkdownLines.Add('| --- | --- |')
$reportMarkdownLines.Add("| Assignments collected | $($report.summary.assignmentsCollected) |")
$reportMarkdownLines.Add("| Duplicate observations collapsed | $($report.summary.duplicateObservationsCollapsed) |")
$reportMarkdownLines.Add("| Distinct assignments evaluated | $($report.summary.assignmentsEvaluated) |")
$reportMarkdownLines.Add("| Findings | $($report.summary.findingCount) |")
$reportMarkdownLines.Add("| High severity | $($report.summary.highSeverityFindingCount) |")
$reportMarkdownLines.Add("| Medium severity | $($report.summary.mediumSeverityFindingCount) |")
$reportMarkdownLines.Add("| Low severity | $($report.summary.lowSeverityFindingCount) |")
$reportMarkdownLines.Add("| Service-principal or managed-identity grants | $($report.summary.nonHumanAssignmentCount) |")
$reportMarkdownLines.Add("| Service-principal or managed-identity high-privilege grants | $($report.summary.nonHumanHighPrivilegeAssignmentCount) |")
$reportMarkdownLines.Add("| Management-group or tenant-root scoped assignments | $($report.summary.managementGroupScopedAssignmentCount) |")
$reportMarkdownLines.Add('')
$reportMarkdownLines.Add('## Subscription Owner counts')
$reportMarkdownLines.Add('')
$reportMarkdownLines.Add('| Subscription | Distinct Owner principals | Direct | Inherited | Exceeds threshold |')
$reportMarkdownLines.Add('| --- | --- | --- | --- | --- |')
if ($report.summary.subscriptionOwnerCounts.Count -gt 0) {
    foreach ($ownerCount in $report.summary.subscriptionOwnerCounts) {
        $ownerResult = if ($ownerCount.exceedsThreshold) { 'yes' } else { 'no' }
        $reportMarkdownLines.Add("| $($ownerCount.subscriptionId) | $($ownerCount.ownerPrincipalCount) | $($ownerCount.directOwnerPrincipalCount) | $($ownerCount.inheritedOwnerPrincipalCount) | $ownerResult |")
    }
}
else {
    $reportMarkdownLines.Add('| (no requested subscriptions) | 0 | 0 | 0 | no |')
}
$reportMarkdownLines.Add('')
$reportMarkdownLines.Add('These totals count only Owner grants that confer Owner over the whole')
$reportMarkdownLines.Add('subscription: those scoped directly to it, and those inherited from a')
$reportMarkdownLines.Add('management group or the tenant root. Inherited grants are already folded in')
$reportMarkdownLines.Add('for every requested subscription that observed them, and are attributed only')
$reportMarkdownLines.Add('where they were actually observed, because a management-group query alone')
$reportMarkdownLines.Add('cannot prove which subscriptions it reaches. Owner grants scoped to a')
$reportMarkdownLines.Add('resource group or a resource remain findings below but are excluded here.')
$reportMarkdownLines.Add('')
$reportMarkdownLines.Add('## Findings')
$reportMarkdownLines.Add('')
$reportMarkdownLines.Add('| Severity | Principal type | Principal ID | Role | Scope | Affected subscriptions | Reasons |')
$reportMarkdownLines.Add('| --- | --- | --- | --- | --- | --- | --- |')
if ($report.findings.Count -gt 0) {
    foreach ($finding in $report.findings) {
        $affectedSubscriptions = if ($finding.observedInSubscriptions.Count -gt 0) { ($finding.observedInSubscriptions -join ', ') } else { '(not observed in a requested subscription)' }
        $reportMarkdownLines.Add("| $($finding.severity) | $($finding.principalType) | $($finding.principalId) | $($finding.roleDefinitionName) | $($finding.scope) | $affectedSubscriptions | $($finding.reasons -join ', ') |")
    }
}
else {
    $reportMarkdownLines.Add('| (none) | | | | | | |')
}
$reportMarkdownLines.Add('')
$reportMarkdownLines.Add('Every finding requires a documented reviewer decision: keep, reduce scope,')
$reportMarkdownLines.Add('replace with a time-bound eligible assignment, or remove.')
$reportMarkdownLines.Add('')
$reportMarkdownLines.Add('')
$reportMarkdownText = ($reportMarkdownLines -join [Environment]::NewLine)
[System.IO.File]::WriteAllText($reportMarkdownPath, $reportMarkdownText, [System.Text.UTF8Encoding]::new($false))

Write-Host "Privileged access review complete (mode: $mode, read-only)."
Write-Host "  Assignments evaluated: $($report.summary.assignmentsEvaluated) (collected $($report.summary.assignmentsCollected), duplicate observations collapsed $($report.summary.duplicateObservationsCollapsed))"
Write-Host "  Findings: $($report.summary.findingCount) (high: $($report.summary.highSeverityFindingCount), medium: $($report.summary.mediumSeverityFindingCount), low: $($report.summary.lowSeverityFindingCount))"
Write-Host "  JSON report: $reportJsonPath"
Write-Host "  Markdown report: $reportMarkdownPath"
Write-Host 'Reports contain directory identifiers. Keep them out of source control.'
