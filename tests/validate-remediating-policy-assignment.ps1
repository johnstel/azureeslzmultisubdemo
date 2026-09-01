[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir
$ArtifactsParent = Join-Path $ProjectDir '.test-artifacts'
$TempDir = Join-Path $ArtifactsParent ("remediating-policy-assignment-ps1-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $ArtifactsParent -Force | Out-Null
New-Item -ItemType Directory -Path $TempDir | Out-Null

function Stop-Test {
    param([string]$Message)
    throw $Message
}

function Assert-BicepBuildFails {
    param(
        [string]$Fixture,
        [string]$Description
    )
    $failed = $false
    try {
        & az bicep build --file $Fixture --stdout 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $failed = $true
        }
    }
    catch {
        $failed = $true
    }
    if (-not $failed) {
        Stop-Test "Bicep unexpectedly accepted $Description."
    }
}

function Test-AssignmentName {
    param([string]$Value)
    if ($Value.Length -lt 1 -or $Value.Length -gt 24 -or $Value.EndsWith('.') -or $Value.EndsWith(' ')) {
        return $false
    }
    if ($Value.IndexOfAny([char[]]'#<>%&:\?/') -ge 0) {
        return $false
    }
    foreach ($character in $Value.ToCharArray()) {
        if ([char]::IsControl($character)) {
            return $false
        }
    }
    return $true
}

function Test-BuiltInDefinitionId {
    param([string]$Value)
    return $Value -eq $Value.Trim() -and
        $Value -match '^/providers/Microsoft\.Authorization/(policyDefinitions|policySetDefinitions)/[^/]+$'
}

function Test-ManagementGroupDefinitionId {
    param([string]$Value)
    return $Value -eq $Value.Trim() -and
        $Value -match '^/providers/Microsoft\.Management/managementGroups/[^/]+/providers/Microsoft\.Authorization/(policyDefinitions|policySetDefinitions)/[^/]+$'
}

function Test-DefinitionVersion {
    param([string]$Value)
    return $Value -match '^(0|[1-9][0-9]*)\.(\*|0|[1-9][0-9]*)\.\*$'
}

function Test-DefinitionBinding {
    param($Binding)
    $builtIn = Test-BuiltInDefinitionId -Value $Binding.policyDefinitionId
    return ($builtIn -or (Test-ManagementGroupDefinitionId -Value $Binding.policyDefinitionId)) -and (
        $Binding.definitionVersion -eq '' -or
        ($builtIn -and (Test-DefinitionVersion -Value $Binding.definitionVersion))
    )
}

function Test-ResourceIdSegments {
    param([string]$Value)
    if (-not $Value.StartsWith('/') -or $Value.EndsWith('/')) {
        return $false
    }
    $segments = $Value.Split('/')
    for ($index = 1; $index -lt $segments.Count; $index++) {
        if ($segments[$index].Length -eq 0 -or $segments[$index] -ne $segments[$index].Trim()) {
            return $false
        }
    }
    return $true
}

function Test-NotScope {
    param(
        [string]$Value,
        [string]$CurrentManagementGroupId
    )
    if ($Value.Equals($CurrentManagementGroupId, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-ResourceIdSegments -Value $Value)) {
        return $false
    }
    $managementGroupPattern = '^/providers/Microsoft\.Management/managementGroups/[^/]+$'
    $subscriptionPattern = '^/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(/resourceGroups/[^/]+(/providers/[^/]+/[^/]+/[^/]+(/[^/]+/[^/]+)*)?|/providers/[^/]+/[^/]+/[^/]+(/[^/]+/[^/]+)*)?$'
    return $Value -match $managementGroupPattern -or $Value -match $subscriptionPattern
}

function Test-ResourceWithoutLocation {
    param($Selector)
    $inProperty = $Selector.PSObject.Properties['in']
    $notInProperty = $Selector.PSObject.Properties['notIn']
    if ($Selector.kind -ne 'resourceWithoutLocation' -or [bool]$inProperty -eq [bool]$notInProperty) {
        return $false
    }
    $values = @()
    if ($inProperty) {
        $values += $inProperty.Value
    }
    else {
        $values += $notInProperty.Value
    }
    return $values.Count -eq 1 -and $values[0] -eq 'subscriptionLevelResources'
}

try {
    if ($null -eq (Get-Command az -ErrorAction SilentlyContinue)) {
        Stop-Test 'Azure CLI is required for remediating policy assignment validation.'
    }

    $compiledShapes = Join-Path $TempDir 'remediating-policy-assignment-shapes.json'
    & az bicep build `
        --file (Join-Path $ScriptDir 'fixtures/remediating-policy-assignment-shapes.bicep') `
        --outfile $compiledShapes | Out-Null
    if ($LASTEXITCODE -ne 0) { Stop-Test 'Remediating policy assignment shape fixture build failed.' }

    Assert-BicepBuildFails `
        -Fixture (Join-Path $ScriptDir 'fixtures/invalid-remediating-assignment-missing-identity.bicep') `
        -Description 'a remediating assignment without an identity type'
    Assert-BicepBuildFails `
        -Fixture (Join-Path $ScriptDir 'fixtures/invalid-remediating-assignment-missing-location.bicep') `
        -Description 'a remediating assignment without a location'
    Assert-BicepBuildFails `
        -Fixture (Join-Path $ScriptDir 'fixtures/invalid-remediating-assignment-incomplete-user-identity.bicep') `
        -Description 'a user-assigned remediation identity without a resource ID'
    Assert-BicepBuildFails `
        -Fixture (Join-Path $ScriptDir 'fixtures/invalid-remediating-assignment-name.bicep') `
        -Description 'a management-group remediating policy assignment name longer than 24 characters'
    Assert-BicepBuildFails `
        -Fixture (Join-Path $ScriptDir 'fixtures/invalid-remediating-policy-selector-kind.bicep') `
        -Description 'policyDefinitionReferenceId as a remediating resource selector kind'

    $validationCases = Get-Content -LiteralPath (Join-Path $ScriptDir 'fixtures/policy-assignment-validation-cases.json') -Raw | ConvertFrom-Json
    foreach ($case in $validationCases.assignmentNames) {
        if ((Test-AssignmentName -Value $case.value) -ne [bool]$case.valid) {
            Stop-Test "Remediating assignment name validation produced the wrong result for '$($case.value)'."
        }
    }
    foreach ($case in $validationCases.definitionBindings) {
        if ((Test-DefinitionBinding -Binding $case) -ne [bool]$case.valid) {
            Stop-Test "Remediating definition binding validation produced the wrong result for '$($case.policyDefinitionId)' with version '$($case.definitionVersion)'."
        }
    }
    foreach ($case in $validationCases.notScopes) {
        if ((Test-NotScope -Value $case.value -CurrentManagementGroupId $validationCases.currentManagementGroupId) -ne [bool]$case.valid) {
            Stop-Test "Remediating notScope validation produced the wrong result for '$($case.value)'."
        }
    }
    foreach ($case in $validationCases.resourceWithoutLocationSelectors) {
        if ((Test-ResourceWithoutLocation -Selector $case.selector) -ne [bool]$case.valid) {
            Stop-Test 'Remediating resourceWithoutLocation validation produced the wrong result.'
        }
    }

    $template = Get-Content -LiteralPath $compiledShapes -Raw | ConvertFrom-Json
    $system = $template.resources | Where-Object name -eq 'example-system-remediation'
    $user = $template.resources | Where-Object name -eq 'example-user-remediation'
    if (@($template.resources).Count -ne 2 -or $null -eq $system -or $null -eq $user) {
        Stop-Test 'Expected system-assigned and user-assigned remediation examples.'
    }
    if ($system.properties.parameters.location.value -ne 'eastus2' -or
        $system.properties.parameters.identity.value.type -ne 'SystemAssigned' -or
        @($system.properties.parameters.verifiedRoleDefinitionIds.value).Count -ne 1) {
        Stop-Test 'System-assigned remediation arguments are invalid.'
    }
    if ($user.properties.parameters.location.value -ne 'westus2' -or
        $user.properties.parameters.identity.value.type -ne 'UserAssigned' -or
        $user.properties.parameters.identity.value.PSObject.Properties['principalId'] -or
        @($user.properties.parameters.verifiedRoleDefinitionIds.value).Count -ne 2 -or
        $user.properties.parameters.enforcementMode.value -ne 'Default' -or
        $user.properties.parameters.parameters.value.effect.value -ne 'Modify') {
        Stop-Test 'User-assigned remediation arguments are invalid.'
    }

    $module = $system.properties.template
    $assignment = $module.resources.assignment
    $existingIdentity = $module.resources.userAssignedIdentity
    $rbacDeployment = $module.resources.remediationRbac
    $roles = $rbacDeployment.properties.template.resources.remediationRoleAssignments
    if ($module.parameters.location.PSObject.Properties['defaultValue'] -or
        $module.parameters.location.minLength -ne 1 -or
        $module.parameters.identity.PSObject.Properties['defaultValue'] -or
        $module.parameters.identity.'$ref' -ne '#/definitions/RemediationIdentity' -or
        $module.definitions.SystemAssignedIdentity.additionalProperties -ne $false -or
        $module.definitions.UserAssignedIdentity.additionalProperties -ne $false -or
        $module.definitions.UserAssignedIdentity.properties.resourceId.minLength -ne 1 -or
        $module.definitions.UserAssignedIdentity.properties.PSObject.Properties['principalId'] -or
        $module.parameters.verifiedRoleDefinitionIds.PSObject.Properties['defaultValue'] -or
        $module.parameters.verifiedRoleDefinitionIds.minLength -ne 1 -or
        $module.parameters.enforcementMode.defaultValue -ne 'DoNotEnforce') {
        Stop-Test 'Required remediation inputs or safe enforcement defaults changed.'
    }
    foreach ($validation in @{
        validatedAssignmentName = "fail('assignmentName contains a character that is invalid"
        validatedPolicyDefinitionId = "fail('policyDefinitionId must be an exact built-in or management-group"
        validatedDefinitionVersion = "fail('definitionVersion is supported only for built-in definitions and must use N.*.* or N.N.*"
        validatedNonComplianceMessages = "fail('policyDefinitionReferenceId must be non-empty"
        validatedNotScopes = "fail('notScopes must contain only valid descendant management-group"
        validatedResourceSelectors = "fail('resourceSelectors must use unique names"
    }.GetEnumerator()) {
        if (-not ([string]$module.variables.($validation.Key)).Contains($validation.Value)) {
            Stop-Test "Compiled remediation validation missing from $($validation.Key)."
        }
    }
    foreach ($validationText in @(
        "fail('Each selector kind can be used only once within a resource selector",
        "fail('resourceLocation and resourceWithoutLocation cannot be used in the same resource selector",
        "fail('resourceWithoutLocation must use the single supported value subscriptionLevelResources",
        "fail('Each resource selector expression must provide one non-empty in or notIn array containing no more than 50 values"
    )) {
        if (-not ([string]$module.variables.validatedResourceSelectors).Contains($validationText)) {
            Stop-Test "Compiled remediation resource selector validation is incomplete: $validationText"
        }
    }
    if (-not ([string]$module.variables.validatedLocation).Contains('location must be a non-global Azure region') -or
        -not ([string]$module.variables.validatedUserAssignedIdentityResourceId).Contains('UserAssigned identity configuration must contain a valid user-assigned managed identity resource ID') -or
        -not ([string]$module.variables.validatedRoleDefinitionIds).Contains('must not contain Owner or User Access Administrator')) {
        Stop-Test 'Compiled location, identity, or privileged-role validation is incomplete.'
    }
    if ($assignment.type -ne 'Microsoft.Authorization/policyAssignments' -or
        $assignment.apiVersion -ne '2025-03-01' -or
        $assignment.location -ne "[variables('validatedLocation')]" -or
        -not ([string]$assignment.identity).Contains('userAssignedIdentities')) {
        Stop-Test 'Remediating policy assignment identity or location wiring is invalid.'
    }
    if ($existingIdentity.existing -ne $true -or
        $existingIdentity.type -ne 'Microsoft.ManagedIdentity/userAssignedIdentities' -or
        $existingIdentity.apiVersion -ne '2024-11-30' -or
        -not ([string]$rbacDeployment.properties.parameters.principalId).Contains("reference('userAssignedIdentity').principalId") -or
        -not ([string]$rbacDeployment.properties.parameters.principalId).Contains("reference('assignment'") -or
        @($rbacDeployment.dependsOn).Count -ne 2) {
        Stop-Test 'Authoritative identity lookup or dependent RBAC deployment wiring is invalid.'
    }
    $expectedRoleName = "[guid(managementGroup().id, parameters('principalId'), parameters('roleDefinitionIds')[copyIndex()])]"
    $expectedRoleDefinition = "[tenantResourceId('Microsoft.Authorization/roleDefinitions', parameters('roleDefinitionIds')[copyIndex()])]"
    if ($roles.type -ne 'Microsoft.Authorization/roleAssignments' -or
        $roles.copy.count -ne "[length(parameters('roleDefinitionIds'))]" -or
        $roles.name -ne $expectedRoleName -or
        $roles.properties.principalType -ne 'ServicePrincipal' -or
        $roles.properties.principalId -ne "[parameters('principalId')]" -or
        $roles.properties.roleDefinitionId -ne $expectedRoleDefinition) {
        Stop-Test 'Deterministic least-privilege remediation role wiring is invalid.'
    }
    $expectedOutputs = @('identityPrincipalId', 'identityResourceId', 'policyAssignmentId', 'roleAssignmentIds')
    if (Compare-Object -ReferenceObject $expectedOutputs -DifferenceObject @($module.outputs.PSObject.Properties.Name)) {
        Stop-Test 'Remediation orchestration outputs are incomplete.'
    }
    if ((Get-Content -LiteralPath $compiledShapes -Raw).Contains('Microsoft.PolicyInsights/remediations')) {
        Stop-Test 'The assignment foundation must not create remediation tasks.'
    }

    Write-Host 'Remediating policy assignment structural validation passed.'
}
finally {
    if (Test-Path -LiteralPath $TempDir) {
        Remove-Item -LiteralPath $TempDir -Recurse -Force
    }
    if ((Test-Path -LiteralPath $ArtifactsParent) -and
        @(Get-ChildItem -LiteralPath $ArtifactsParent -Force).Count -eq 0) {
        Remove-Item -LiteralPath $ArtifactsParent -ErrorAction SilentlyContinue
    }
}
