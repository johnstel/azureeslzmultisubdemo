[CmdletBinding()]
param(
    [string]$CompiledTemplate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir
$TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("eslz-rbac-validation-" + [guid]::NewGuid().ToString('N'))

function Stop-Validation {
    param([string]$Message)
    Write-Error $Message -ErrorAction Continue
    exit 1
}

function Find-JsonObjects {
    param(
        [Parameter(Mandatory = $true)]$Node,
        [Parameter(Mandatory = $true)][scriptblock]$Predicate
    )
    $results = @()
    if ($null -eq $Node) { return $results }
    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        if (& $Predicate $Node) { $results += $Node }
        foreach ($property in $Node.PSObject.Properties) {
            $results += Find-JsonObjects -Node $property.Value -Predicate $Predicate
        }
    }
    elseif ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
        foreach ($item in $Node) {
            $results += Find-JsonObjects -Node $item -Predicate $Predicate
        }
    }
    return $results
}

try {
    New-Item -ItemType Directory -Path $TempDir | Out-Null
    if ([string]::IsNullOrWhiteSpace($CompiledTemplate)) {
        if ($null -eq (Get-Command az -ErrorAction SilentlyContinue)) {
            Stop-Validation "Required command 'az' is not installed."
        }
        $CompiledTemplate = Join-Path $TempDir 'main.json'
        & az bicep build --file (Join-Path $ProjectDir 'main.bicep') --outfile $CompiledTemplate | Out-Null
        if ($LASTEXITCODE -ne 0) { Stop-Validation 'Bicep build failed.' }
    }
    if (-not (Test-Path -LiteralPath $CompiledTemplate -PathType Leaf)) {
        Stop-Validation "Compiled template not found: $CompiledTemplate"
    }

    try {
        $compiled = Get-Content -LiteralPath $CompiledTemplate -Raw | ConvertFrom-Json
    }
    catch {
        Stop-Validation "Compiled template is not valid JSON: $($_.Exception.Message)"
    }

    $ownerRoleDefinitionId = '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
    $permanentOwners = Find-JsonObjects -Node $compiled -Predicate {
        param($node)
        $node.PSObject.Properties['type'] -and
        $node.type -eq 'Microsoft.Authorization/roleAssignments' -and
        $node.PSObject.Properties['properties'] -and
        [string]$node.properties.roleDefinitionId -match "($ownerRoleDefinitionId|ownerRoleDefinitionId)"
    }
    if (@($permanentOwners).Count -ne 0) {
        Stop-Validation "Compiled default contains $(@($permanentOwners).Count) permanent Owner role assignment(s)."
    }

    $ordinaryRoleAssignments = Find-JsonObjects -Node $compiled -Predicate {
        param($node)
        $node.PSObject.Properties['type'] -and $node.type -eq 'Microsoft.Authorization/roleAssignments'
    }
    if (@($ordinaryRoleAssignments).Count -ne 5 -or
        @($ordinaryRoleAssignments | Where-Object { $_.properties.principalType -ne 'Group' }).Count -ne 0) {
        Stop-Validation 'Every ordinary role assignment must target a group, and exactly five lower-privilege assignments are expected.'
    }

    $activeOwnerSchedules = Find-JsonObjects -Node $compiled -Predicate {
        param($node)
        $node.PSObject.Properties['type'] -and
        $node.type -eq 'Microsoft.Authorization/roleAssignmentScheduleRequests' -and
        $node.PSObject.Properties['properties'] -and
        [string]$node.properties.roleDefinitionId -match "($ownerRoleDefinitionId|ownerRoleDefinitionId)"
    }
    if (@($activeOwnerSchedules).Count -ne 0) {
        Stop-Validation "Compiled default contains $(@($activeOwnerSchedules).Count) active Owner schedule request(s); Owner must be eligible only."
    }

    $eligibleRequests = Find-JsonObjects -Node $compiled -Predicate {
        param($node)
        $node.PSObject.Properties['type'] -and $node.type -eq 'Microsoft.Authorization/roleEligibilityScheduleRequests'
    }
    if (@($eligibleRequests).Count -ne 2) {
        Stop-Validation "Expected exactly two subscription Owner eligibility schedule request artifacts, found $(@($eligibleRequests).Count)."
    }
    foreach ($request in $eligibleRequests) {
        $properties = $request.properties
        if ($request.apiVersion -ne '2020-10-01' -or
            $request.condition -ne "[parameters('deployEligibleOwnerRoleAssignment')]" -or
            $properties.requestType -ne 'AdminAssign' -or
            $properties.roleDefinitionId -ne "[subscriptionResourceId('Microsoft.Authorization/roleDefinitions', variables('ownerRoleDefinitionId'))]" -or
            $properties.principalId -ne "[variables('validatedPrivilegedAccessGroupObjectId')]" -or
            $properties.justification -ne "[parameters('eligibleOwnerAssignmentJustification')]" -or
            $properties.scheduleInfo.startDateTime -ne "[parameters('eligibleOwnerAssignmentStartDateTime')]" -or
            $properties.scheduleInfo.expiration.type -ne 'AfterDuration' -or
            $properties.scheduleInfo.expiration.duration -ne "[parameters('eligibleOwnerAssignmentDuration')]") {
            Stop-Validation 'Eligible Owner request artifacts must use the stable API, AdminAssign, group input, justification, and a finite parameterized schedule.'
        }
    }

    if ($compiled.parameters.deployRoleAssignments.defaultValue -ne $false -or
        $compiled.parameters.deployEligibleOwnerRoleAssignments.defaultValue -ne $false -or
        $compiled.parameters.subscriptionPrivilegedAccessGroupObjectId.defaultValue -ne '' -or
        $compiled.parameters.eligibleOwnerAssignmentStartDateTime.defaultValue -ne '' -or
        $compiled.parameters.eligibleOwnerAssignmentDuration.defaultValue -ne 'P90D' -or
        $compiled.parameters.eligibleOwnerAssignmentJustification.defaultValue -ne '') {
        Stop-Validation 'Compiled RBAC and eligible Owner parameters must retain safe defaults.'
    }

    $eligibleModuleDefaults = Find-JsonObjects -Node $compiled -Predicate {
        param($node)
        $node.PSObject.Properties['parameters'] -and
        $node.parameters.PSObject.Properties['deployEligibleOwnerRoleAssignment'] -and
        $node.parameters.deployEligibleOwnerRoleAssignment.PSObject.Properties['defaultValue'] -and
        $node.parameters.deployEligibleOwnerRoleAssignment.defaultValue -eq $false -and
        $node.parameters.PSObject.Properties['subscriptionPrivilegedAccessGroupObjectId'] -and
        $node.parameters.subscriptionPrivilegedAccessGroupObjectId.defaultValue -eq ''
    }
    if (@($eligibleModuleDefaults).Count -ne 2) {
        Stop-Validation 'Both subscription RBAC modules must default the eligible Owner request off and its group input empty.'
    }

    $roleManagementPolicies = Find-JsonObjects -Node $compiled -Predicate {
        param($node)
        $node.PSObject.Properties['type'] -and
        $node.type -in @(
            'Microsoft.Authorization/roleManagementPolicies',
            'Microsoft.Authorization/roleManagementPolicyAssignments'
        )
    }
    if (@($roleManagementPolicies).Count -ne 0) {
        Stop-Validation 'PIM activation policy resources are out of scope and must remain static/report-only.'
    }

    $parameterTemplate = Get-Content -LiteralPath (Join-Path $ProjectDir 'parameters/demo.parameters.template.json') -Raw | ConvertFrom-Json
    if ($parameterTemplate.parameters.deployRoleAssignments.value -ne $false -or
        $parameterTemplate.parameters.deployEligibleOwnerRoleAssignments.value -ne $false -or
        $parameterTemplate.parameters.subscriptionPrivilegedAccessGroupObjectId.value -ne 'REPLACE_WITH_SUBSCRIPTION_PRIVILEGED_ACCESS_GROUP_OBJECT_GUID' -or
        $parameterTemplate.parameters.eligibleOwnerAssignmentStartDateTime.value -ne 'REPLACE_WITH_ELIGIBLE_OWNER_START_DATE_TIME_UTC' -or
        $parameterTemplate.parameters.eligibleOwnerAssignmentDuration.value -ne 'P90D' -or
        $parameterTemplate.parameters.eligibleOwnerAssignmentJustification.value -ne 'REPLACE_WITH_ELIGIBLE_OWNER_ASSIGNMENT_JUSTIFICATION') {
        Stop-Validation 'The JSON parameter template must keep eligible Owner disabled and use tenant-independent placeholders.'
    }

    $bicepParameterText = Get-Content -LiteralPath (Join-Path $ProjectDir 'parameters/main.template.bicepparam') -Raw
    if ($bicepParameterText -notmatch '(?m)^param deployEligibleOwnerRoleAssignments = false$' -or
        $bicepParameterText -notmatch "(?m)^param subscriptionPrivilegedAccessGroupObjectId = 'REPLACE_WITH_SUBSCRIPTION_PRIVILEGED_ACCESS_GROUP_OBJECT_GUID'$") {
        Stop-Validation 'The Bicep parameter template must keep eligible Owner disabled and use a privileged-access group placeholder.'
    }

    $requirementsPath = Join-Path $ProjectDir 'identity/azure-rbac/owner-activation-requirements.template.json'
    if (-not (Test-Path -LiteralPath $requirementsPath -PathType Leaf)) {
        Stop-Validation "Missing static Owner activation requirements: $requirementsPath"
    }
    $requirementsText = Get-Content -LiteralPath $requirementsPath -Raw
    try {
        $requirements = $requirementsText | ConvertFrom-Json
    }
    catch {
        Stop-Validation "Owner activation requirements are not valid JSON: $($_.Exception.Message)"
    }
    $activationDuration = $requirements.activation.maximumActivationDurationHours
    $activationDurationIsInteger = ($activationDuration -is [int]) -or
        ($activationDuration -is [long]) -or
        ($activationDuration -is [int32]) -or
        ($activationDuration -is [int64])
    if ($requirements.artifactType -ne 'azureRbacPimActivationRequirements' -or
        $requirements.state -ne 'reportOnly' -or
        $requirements.roleName -ne 'Owner' -or
        $requirements.scopeType -ne 'subscription' -or
        $requirements.principalType -ne 'Group' -or
        $requirements.assignmentType -ne 'eligible' -or
        $requirements.eligibility.requireTimeBoundSchedule -ne $true -or
        $requirements.eligibility.maximumEligibilityDuration -ne 'P365D' -or
        $requirements.activation.requireApproval -ne $true -or
        @($requirements.activation.approvers).Count -lt 1 -or
        @($requirements.activation.approvers | Where-Object { $_ -notmatch '^REPLACE_WITH_.+$' }).Count -ne 0 -or
        $requirements.activation.requireMultiFactorAuthentication -ne $true -or
        $requirements.activation.requireJustification -ne $true -or
        -not $activationDurationIsInteger -or
        $activationDuration -lt 1 -or
        $activationDuration -gt 8 -or
        $requirements.notifications.notifyAdminsOnActivation -ne $true -or
        $requirements.notifications.notifyApproversOnActivationRequest -ne $true -or
        $requirements.notifications.notifyAssigneeOnActivation -ne $true -or
        $requirements.emergencyAccess.handledOutsideRepository -ne $true -or
        $requirements.emergencyAccess.permanentOwnerAssignmentCreatedByRepository -ne $false) {
        Stop-Validation 'Static Owner activation requirements must enforce group eligibility, approval, MFA, justification, bounded duration, notifications, and external emergency access.'
    }
    if ($requirementsText -match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') {
        Stop-Validation 'Static Owner activation requirements must not contain tenant-specific object IDs.'
    }

    Write-Host 'PIM-ready subscription RBAC artifacts validated offline.'
}
finally {
    if (Test-Path -LiteralPath $TempDir) {
        Remove-Item -LiteralPath $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
