[CmdletBinding()]
param(
    [string]$CompiledTemplate,
    [string]$CompiledEligibilityTemplate
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
    if ([string]::IsNullOrWhiteSpace($CompiledEligibilityTemplate)) {
        if ($null -eq (Get-Command az -ErrorAction SilentlyContinue)) {
            Stop-Validation "Required command 'az' is not installed."
        }
        $CompiledEligibilityTemplate = Join-Path $TempDir 'owner-eligibility-request.json'
        & az bicep build `
            --file (Join-Path $ProjectDir 'identity/azure-rbac/owner-eligibility-request.bicep') `
            --outfile $CompiledEligibilityTemplate | Out-Null
        if ($LASTEXITCODE -ne 0) { Stop-Validation 'Owner eligibility Bicep build failed.' }
    }
    if (-not (Test-Path -LiteralPath $CompiledTemplate -PathType Leaf)) {
        Stop-Validation "Compiled template not found: $CompiledTemplate"
    }
    if (-not (Test-Path -LiteralPath $CompiledEligibilityTemplate -PathType Leaf)) {
        Stop-Validation "Compiled eligibility template not found: $CompiledEligibilityTemplate"
    }

    try {
        $compiledText = Get-Content -LiteralPath $CompiledTemplate -Raw
        $compiled = $compiledText | ConvertFrom-Json
    }
    catch {
        Stop-Validation "Compiled template is not valid JSON: $($_.Exception.Message)"
    }
    try {
        $compiledEligibility = Get-Content -LiteralPath $CompiledEligibilityTemplate -Raw | ConvertFrom-Json
    }
    catch {
        Stop-Validation "Compiled eligibility template is not valid JSON: $($_.Exception.Message)"
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
    # modules/remediating-policy-assignment.bicep stores the Owner and User
    # Access Administrator IDs only as deny-list constants that make the
    # deployment fail when a caller asks for either role. Those guard constants
    # are ignored here (and only when the guard that rejects them is present in
    # the same template); every other Owner reference remains an error.
    $guardedCompiled = $compiledText | ConvertFrom-Json
    $remediationGuards = Find-JsonObjects -Node $guardedCompiled -Predicate {
        param($node)
        $node.PSObject.Properties['variables'] -and
        $node.variables -and
        $node.variables.PSObject.Properties['ownerRoleDefinitionId'] -and
        $node.variables.PSObject.Properties['userAccessAdministratorRoleDefinitionId'] -and
        [string]$node.variables.invalidRoleDefinitionIds -match 'ownerRoleDefinitionId' -and
        [string]$node.variables.validatedRoleDefinitionIds -match 'fail\('
    }
    foreach ($remediationGuard in @($remediationGuards)) {
        $remediationGuard.variables.PSObject.Properties.Remove('ownerRoleDefinitionId')
        $remediationGuard.variables.PSObject.Properties.Remove('userAccessAdministratorRoleDefinitionId')
    }
    if (($guardedCompiled | ConvertTo-Json -Depth 100) -match [regex]::Escape($ownerRoleDefinitionId)) {
        Stop-Validation 'Compiled main contains an Owner role definition reference.'
    }

    $ordinaryRoleAssignments = Find-JsonObjects -Node $compiled -Predicate {
        param($node)
        $node.PSObject.Properties['type'] -and $node.type -eq 'Microsoft.Authorization/roleAssignments'
    }
    $groupRoleAssignments = @($ordinaryRoleAssignments | Where-Object { $_.properties.principalType -eq 'Group' })
    $remediationRoleAssignments = @($ordinaryRoleAssignments |
        Where-Object { [string]$_.properties.principalId -eq "[parameters('principalId')]" })
    $invalidRemediationRoleAssignments = @($remediationRoleAssignments | Where-Object {
        $_.properties.principalType -ne 'ServicePrincipal' -or
        [string]$_.properties.roleDefinitionId -notmatch "parameters\('roleDefinitionIds'\)"
    })
    if ($groupRoleAssignments.Count -ne 5 -or
        @($ordinaryRoleAssignments).Count -ne ($groupRoleAssignments.Count + $remediationRoleAssignments.Count) -or
        $invalidRemediationRoleAssignments.Count -ne 0) {
        Stop-Validation 'Ordinary role assignments must target groups (exactly five lower-privilege assignments), and any remediation assignment must bind a policy-assignment service principal to verified role definition IDs.'
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
    if (@($eligibleRequests).Count -ne 0) {
        Stop-Validation "Repeatable main template contains $(@($eligibleRequests).Count) one-time eligibility schedule request artifact(s)."
    }

    $mainPimParameters = @(
        'deployEligibleOwnerRoleAssignments',
        'subscriptionPrivilegedAccessGroupObjectId',
        'eligibleOwnerAssignmentStartDateTime',
        'eligibleOwnerAssignmentDuration',
        'eligibleOwnerAssignmentJustification'
    )
    if ($compiled.parameters.deployRoleAssignments.defaultValue -ne $false -or
        @($mainPimParameters | Where-Object { $compiled.parameters.PSObject.Properties[$_] }).Count -ne 0) {
        Stop-Validation 'Repeatable main template must keep ordinary RBAC disabled and contain no PIM request parameters.'
    }

    $oneShotRequests = Find-JsonObjects -Node $compiledEligibility -Predicate {
        param($node)
        $node.PSObject.Properties['type'] -and $node.type -eq 'Microsoft.Authorization/roleEligibilityScheduleRequests'
    }
    $requestIdHasDefault = $null -ne $compiledEligibility.parameters.requestId.PSObject.Properties['defaultValue']
    $requestTypeHasDefault = $null -ne $compiledEligibility.parameters.requestType.PSObject.Properties['defaultValue']
    $workflowTokenHasDefault = $null -ne $compiledEligibility.parameters.operatorWorkflowVerificationToken.PSObject.Properties['defaultValue']
    $allowedRequestTypes = @($compiledEligibility.parameters.requestType.allowedValues) -join ','
    $allowedDurations = @($compiledEligibility.parameters.eligibleOwnerAssignmentDuration.allowedValues) -join ','
    $oneShotRequest = @($oneShotRequests) | Select-Object -First 1
    if (@($compiledEligibility.resources).Count -ne 1 -or
        @($oneShotRequests).Count -ne 1 -or
        $compiledEligibility.parameters.submitEligibilityRequest.defaultValue -ne $false -or
        $requestIdHasDefault -or
        $compiledEligibility.parameters.requestId.minLength -ne 36 -or
        $compiledEligibility.parameters.requestId.maxLength -ne 36 -or
        $requestTypeHasDefault -or
        $allowedRequestTypes -ne 'AdminAssign,AdminUpdate,AdminRemove' -or
        $compiledEligibility.parameters.targetRoleEligibilityScheduleId.defaultValue -ne '' -or
        $compiledEligibility.parameters.eligibleOwnerAssignmentStartDateTime.defaultValue -ne '' -or
        $compiledEligibility.parameters.eligibleOwnerAssignmentDuration.defaultValue -ne 'P90D' -or
        $allowedDurations -ne 'P30D,P90D,P180D,P365D' -or
        $compiledEligibility.parameters.operatorWorkflowVerificationToken.type -ne 'securestring' -or
        $workflowTokenHasDefault -or
        $compiledEligibility.variables.ownerRoleDefinitionId -ne $ownerRoleDefinitionId -or
        $compiledEligibility.variables.baseRequestProperties.principalId -ne "[variables('validatedPrincipalId')]" -or
        $compiledEligibility.variables.baseRequestProperties.roleDefinitionId -ne "[subscriptionResourceId('Microsoft.Authorization/roleDefinitions', variables('ownerRoleDefinitionId'))]" -or
        $compiledEligibility.variables.baseRequestProperties.requestType -ne "[parameters('requestType')]" -or
        $compiledEligibility.variables.baseRequestProperties.justification -ne "[parameters('eligibleOwnerAssignmentJustification')]" -or
        [string]$compiledEligibility.variables.scheduleProperties -notmatch 'AdminRemove' -or
        [string]$compiledEligibility.variables.scheduleProperties -notmatch 'AfterDuration' -or
        [string]$compiledEligibility.variables.scheduleProperties -notmatch 'eligibleOwnerAssignmentDuration' -or
        [string]$compiledEligibility.variables.targetScheduleProperties -notmatch 'AdminAssign' -or
        [string]$compiledEligibility.variables.targetScheduleProperties -notmatch 'targetRoleEligibilityScheduleId' -or
        $oneShotRequest.apiVersion -ne '2020-10-01' -or
        $oneShotRequest.name -ne "[parameters('requestId')]" -or
        $oneShotRequest.condition -ne "[parameters('submitEligibilityRequest')]" -or
        $oneShotRequest.properties -ne "[union(variables('baseRequestProperties'), variables('scheduleProperties'), variables('targetScheduleProperties'))]") {
        Stop-Validation 'One-shot Owner eligibility artifact must require a caller request ID, explicit opt-in and lifecycle action, group input, and a finite schedule.'
    }

    if (
        [string]$compiledEligibility.variables.requestIdInputIsValid -notmatch 'requestIdResidualCharacters' -or
        [string]$compiledEligibility.variables.principalInputIsValid -notmatch 'principalResidualCharacters' -or
        [string]$compiledEligibility.variables.targetScheduleGuidIsCanonical -notmatch 'targetScheduleResidualCharacters' -or
        [string]$compiledEligibility.variables.startTimeInputIsRfc3339Utc -notmatch 'startTimeBaseResidualCharacters' -or
        [string]$compiledEligibility.variables.startTimeInputIsRfc3339Utc -notmatch 'startTimeSuffixResidualCharacters' -or
        [string]$compiledEligibility.variables.targetScheduleInputIsValid -cne "[if(equals(parameters('requestType'), 'AdminAssign'), empty(parameters('targetRoleEligibilityScheduleId')), variables('targetScheduleGuidIsCanonical'))]" -or
        [string]$compiledEligibility.variables.scheduleInputIsValid -cne "[if(equals(parameters('requestType'), 'AdminRemove'), empty(parameters('eligibleOwnerAssignmentStartDateTime')), variables('startTimeInputIsRfc3339Utc'))]" -or
        [string]$compiledEligibility.variables.workflowMarkerIsValid -cne "[equals(parameters('operatorWorkflowVerificationToken'), variables('expectedOperatorWorkflowVerificationToken'))]" -or
        [string]$compiledEligibility.variables.executionInputsAreValid -cne "[or(not(parameters('submitEligibilityRequest')), and(and(and(and(and(variables('requestIdInputIsValid'), variables('principalInputIsValid')), variables('targetScheduleInputIsValid')), variables('scheduleInputIsValid')), not(empty(trim(parameters('eligibleOwnerAssignmentJustification'))))), variables('workflowMarkerIsValid')))]"
    ) {
        Stop-Validation 'One-shot Owner eligibility compiled input guards were weakened or replaced.'
    }

    $oneShotForbiddenResources = Find-JsonObjects -Node $compiledEligibility -Predicate {
        param($node)
        $node.PSObject.Properties['type'] -and
        $node.type -in @(
            'Microsoft.Authorization/roleAssignments',
            'Microsoft.Authorization/roleAssignmentScheduleRequests',
            'Microsoft.Authorization/roleManagementPolicies',
            'Microsoft.Authorization/roleManagementPolicyAssignments'
        )
    }
    if (@($oneShotForbiddenResources).Count -ne 0) {
        Stop-Validation 'One-shot Owner eligibility artifact must not contain permanent/active Owner or PIM activation-policy resources.'
    }

    $normalDeploymentFiles = @(
        (Join-Path $ProjectDir 'main.bicep')
        (Get-ChildItem (Join-Path $ProjectDir 'modules') -Filter '*.bicep' | ForEach-Object { $_.FullName })
        (Join-Path $ProjectDir 'scripts/preflight.sh')
        (Join-Path $ProjectDir 'scripts/preflight.ps1')
        (Join-Path $ProjectDir 'scripts/what-if.sh')
        (Join-Path $ProjectDir 'scripts/what-if.ps1')
        (Join-Path $ProjectDir 'scripts/deploy.sh')
        (Join-Path $ProjectDir 'scripts/deploy.ps1')
        (Join-Path $ProjectDir 'scripts/teardown.sh')
        (Join-Path $ProjectDir 'scripts/teardown.ps1')
    )
    foreach ($normalDeploymentFile in $normalDeploymentFiles) {
        if ((Get-Content -LiteralPath $normalDeploymentFile -Raw) -match 'owner-eligibility-request|roleEligibilityScheduleRequests') {
            Stop-Validation "Normal deployment path invokes the one-shot Owner eligibility artifact: $normalDeploymentFile"
        }
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
        $parameterTemplate.parameters.PSObject.Properties['deployEligibleOwnerRoleAssignments'] -or
        $parameterTemplate.parameters.PSObject.Properties['subscriptionPrivilegedAccessGroupObjectId']) {
        Stop-Validation 'The normal JSON parameter template must not expose the one-shot Owner eligibility workflow.'
    }

    $bicepParameterText = Get-Content -LiteralPath (Join-Path $ProjectDir 'parameters/main.template.bicepparam') -Raw
    if ($bicepParameterText -match 'deployEligibleOwnerRoleAssignments|subscriptionPrivilegedAccessGroupObjectId|eligibleOwnerAssignment') {
        Stop-Validation 'The normal Bicep parameter template must not expose the one-shot Owner eligibility workflow.'
    }

    $eligibilityParameterPath = Join-Path $ProjectDir 'identity/azure-rbac/owner-eligibility-request.parameters.template.json'
    if (-not (Test-Path -LiteralPath $eligibilityParameterPath -PathType Leaf)) {
        Stop-Validation "Missing one-shot Owner eligibility parameter template: $eligibilityParameterPath"
    }
    $eligibilityParameters = Get-Content -LiteralPath $eligibilityParameterPath -Raw | ConvertFrom-Json
    if ($eligibilityParameters.parameters.submitEligibilityRequest.value -ne $false -or
        $eligibilityParameters.parameters.requestId.value -ne 'REPLACE_WITH_NEW_UNIQUE_REQUEST_GUID' -or
        $eligibilityParameters.parameters.requestType.value -ne 'AdminAssign' -or
        $eligibilityParameters.parameters.subscriptionPrivilegedAccessGroupObjectId.value -ne 'REPLACE_WITH_SUBSCRIPTION_PRIVILEGED_ACCESS_GROUP_OBJECT_GUID' -or
        $eligibilityParameters.parameters.targetRoleEligibilityScheduleId.value -ne '' -or
        $eligibilityParameters.parameters.eligibleOwnerAssignmentStartDateTime.value -ne 'REPLACE_WITH_ELIGIBLE_OWNER_START_DATE_TIME_UTC' -or
        $eligibilityParameters.parameters.eligibleOwnerAssignmentDuration.value -ne 'P90D' -or
        $eligibilityParameters.parameters.eligibleOwnerAssignmentJustification.value -ne 'REPLACE_WITH_ELIGIBLE_OWNER_REQUEST_JUSTIFICATION' -or
        $eligibilityParameters.parameters.operatorWorkflowVerificationToken.value -ne 'UNSUPPORTED_OUTSIDE_SCRIPTS_OWNER_ELIGIBILITY_REQUEST') {
        Stop-Validation 'One-shot Owner eligibility parameter template must stay disabled and retain explicit tenant-independent placeholders.'
    }

    $pimGuidance = Get-Content -LiteralPath (Join-Path $ProjectDir 'docs/AZURE-RBAC-PIM.md') -Raw
    foreach ($requiredGuidance in @(
        'existing eligibility',
        'AdminAssign',
        'AdminUpdate',
        'AdminRemove',
        'fresh request GUID',
        'never reuse',
        'immutable compiled template snapshot',
        'ancestor management-group scope',
        'immediately before submission'
    )) {
        if ($pimGuidance -notmatch [regex]::Escape($requiredGuidance)) {
            Stop-Validation "PIM runbook is missing one-shot lifecycle guidance: $requiredGuidance"
        }
    }

    $ownerOperatorBash = Get-Content -LiteralPath (Join-Path $ProjectDir 'scripts/owner-eligibility-request.sh') -Raw
    $ownerOperatorPowerShell = Get-Content -LiteralPath (Join-Path $ProjectDir 'scripts/owner-eligibility-request.ps1') -Raw
    foreach ($requiredPattern in @(
        'az ad group show',
        'securityEnabled == true',
        'roleEligibilitySchedules',
        'roleEligibilityScheduleRequests',
        'atScope()',
        'deployment sub what-if',
        'deployment sub create',
        'az bicep build',
        'template_snapshot',
        'verify_live_state',
        'management/managementgroups',
        '.nextLink | type == "string"',
        'ESLZ_OWNER_ELIGIBILITY_CONFIRMATION',
        'UNSUPPORTED_OUTSIDE_SCRIPTS_OWNER_ELIGIBILITY_REQUEST'
    )) {
        if (-not $ownerOperatorBash.Contains($requiredPattern)) {
            Stop-Validation "Bash Owner eligibility workflow is missing required fail-closed control: $requiredPattern"
        }
    }
    foreach ($requiredPattern in @(
        "'ad', 'group', 'show'",
        'securityEnabledProperty.Value -ne $true',
        'roleEligibilitySchedules',
        'roleEligibilityScheduleRequests',
        'atScope()',
        'deployment sub what-if',
        'deployment sub create',
        'bicep build',
        'TemplateSnapshot',
        'Test-LiveEligibilityState',
        'management/managementgroups',
        'nextLinkProperty.Value -isnot [string]',
        'ESLZ_OWNER_ELIGIBILITY_CONFIRMATION',
        'UNSUPPORTED_OUTSIDE_SCRIPTS_OWNER_ELIGIBILITY_REQUEST'
    )) {
        if (-not $ownerOperatorPowerShell.Contains($requiredPattern)) {
            Stop-Validation "PowerShell Owner eligibility workflow is missing required fail-closed control: $requiredPattern"
        }
    }
    $bashGroupCheckIndex = $ownerOperatorBash.IndexOf('securityEnabled == true', [System.StringComparison]::Ordinal)
    $bashInventoryIndex = $ownerOperatorBash.IndexOf('schedules_url=', [System.StringComparison]::Ordinal)
    $bashWhatIfIndex = $ownerOperatorBash.IndexOf('az deployment sub what-if', [System.StringComparison]::Ordinal)
    if ($bashGroupCheckIndex -lt 0 -or $bashGroupCheckIndex -gt $bashInventoryIndex -or $bashGroupCheckIndex -gt $bashWhatIfIndex) {
        Stop-Validation 'Bash Owner eligibility workflow must verify the security-enabled group before state inventory or what-if.'
    }
    $powerShellGroupCheckIndex = $ownerOperatorPowerShell.IndexOf('securityEnabledProperty.Value -ne $true', [System.StringComparison]::Ordinal)
    $powerShellInventoryIndex = $ownerOperatorPowerShell.IndexOf('$schedulesUrl =', [System.StringComparison]::Ordinal)
    $powerShellWhatIfIndex = $ownerOperatorPowerShell.IndexOf('& az deployment sub what-if', [System.StringComparison]::Ordinal)
    if ($powerShellGroupCheckIndex -lt 0 -or $powerShellGroupCheckIndex -gt $powerShellInventoryIndex -or $powerShellGroupCheckIndex -gt $powerShellWhatIfIndex) {
        Stop-Validation 'PowerShell Owner eligibility workflow must verify the security-enabled group before state inventory or what-if.'
    }

    $bashVerifyMatches = [regex]::Matches($ownerOperatorBash, '(?m)^verify_live_state\r?$')
    $bashSnapshotUses = [regex]::Matches($ownerOperatorBash, [regex]::Escape('--template-file "${template_snapshot}"'))
    $bashCompileIndex = $ownerOperatorBash.IndexOf('az bicep build', [System.StringComparison]::Ordinal)
    $bashConfirmationIndex = $ownerOperatorBash.IndexOf('IFS= read -r typed_request_id', [System.StringComparison]::Ordinal)
    $bashCreateIndex = $ownerOperatorBash.IndexOf('az deployment sub create', [System.StringComparison]::Ordinal)
    if (
        $bashVerifyMatches.Count -ne 2 -or
        $bashSnapshotUses.Count -ne 2 -or
        $bashCompileIndex -lt 0 -or
        $bashConfirmationIndex -lt 0 -or
        $bashCreateIndex -lt 0 -or
        $bashCompileIndex -gt $bashVerifyMatches[0].Index -or
        $bashVerifyMatches[0].Index -gt $bashWhatIfIndex -or
        $bashConfirmationIndex -gt $bashVerifyMatches[1].Index -or
        $bashVerifyMatches[1].Index -gt $bashCreateIndex
    ) {
        Stop-Validation 'Bash Owner eligibility workflow must compile once, reuse the reviewed snapshot, and revalidate live state after confirmation before create.'
    }

    $powerShellVerifyMatches = [regex]::Matches($ownerOperatorPowerShell, '(?m)^Test-LiveEligibilityState\r?$')
    $powerShellSnapshotUses = [regex]::Matches($ownerOperatorPowerShell, [regex]::Escape('--template-file $script:TemplateSnapshot'))
    $powerShellCompileIndex = $ownerOperatorPowerShell.IndexOf('& az bicep build', [System.StringComparison]::Ordinal)
    $powerShellConfirmationIndex = $ownerOperatorPowerShell.IndexOf('$typedRequestId = Read-Host', [System.StringComparison]::Ordinal)
    $powerShellCreateIndex = $ownerOperatorPowerShell.IndexOf('& az deployment sub create', [System.StringComparison]::Ordinal)
    if (
        $powerShellVerifyMatches.Count -ne 2 -or
        $powerShellSnapshotUses.Count -ne 2 -or
        $powerShellCompileIndex -lt 0 -or
        $powerShellConfirmationIndex -lt 0 -or
        $powerShellCreateIndex -lt 0 -or
        $powerShellCompileIndex -gt $powerShellVerifyMatches[0].Index -or
        $powerShellVerifyMatches[0].Index -gt $powerShellWhatIfIndex -or
        $powerShellConfirmationIndex -gt $powerShellVerifyMatches[1].Index -or
        $powerShellVerifyMatches[1].Index -gt $powerShellCreateIndex
    ) {
        Stop-Validation 'PowerShell Owner eligibility workflow must compile once, reuse the reviewed snapshot, and revalidate live state after confirmation before create.'
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
