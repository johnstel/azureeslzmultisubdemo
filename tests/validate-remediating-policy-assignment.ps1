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
        -Description 'a user-assigned remediation identity without a principal ID'

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
        $user.properties.parameters.identity.value.principalId -ne '55555555-5555-5555-5555-555555555555' -or
        @($user.properties.parameters.verifiedRoleDefinitionIds.value).Count -ne 2 -or
        $user.properties.parameters.enforcementMode.value -ne 'Default' -or
        $user.properties.parameters.parameters.value.effect.value -ne 'Modify') {
        Stop-Test 'User-assigned remediation arguments are invalid.'
    }

    $module = $system.properties.template
    $assignment = $module.resources.assignment
    $roles = $module.resources.remediationRoleAssignments
    if ($module.parameters.location.PSObject.Properties['defaultValue'] -or
        $module.parameters.location.minLength -ne 1 -or
        $module.parameters.identity.PSObject.Properties['defaultValue'] -or
        $module.parameters.identity.'$ref' -ne '#/definitions/RemediationIdentity' -or
        $module.definitions.SystemAssignedIdentity.additionalProperties -ne $false -or
        $module.definitions.UserAssignedIdentity.additionalProperties -ne $false -or
        $module.definitions.UserAssignedIdentity.properties.resourceId.minLength -ne 1 -or
        $module.definitions.UserAssignedIdentity.properties.principalId.minLength -ne 1 -or
        $module.parameters.verifiedRoleDefinitionIds.PSObject.Properties['defaultValue'] -or
        $module.parameters.verifiedRoleDefinitionIds.minLength -ne 1 -or
        $module.parameters.enforcementMode.defaultValue -ne 'DoNotEnforce') {
        Stop-Test 'Required remediation inputs or safe enforcement defaults changed.'
    }
    if (-not ([string]$module.variables.validatedLocation).Contains('location must be a non-global Azure region') -or
        -not ([string]$module.variables.validatedUserAssignedIdentityResourceId).Contains('UserAssigned identity configuration must contain a valid identity resource ID and principal ID') -or
        -not ([string]$module.variables.validatedRoleDefinitionIds).Contains('must not contain Owner or User Access Administrator')) {
        Stop-Test 'Compiled location, identity, or privileged-role validation is incomplete.'
    }
    if ($assignment.type -ne 'Microsoft.Authorization/policyAssignments' -or
        $assignment.apiVersion -ne '2025-03-01' -or
        $assignment.location -ne "[variables('validatedLocation')]" -or
        -not ([string]$assignment.identity).Contains('userAssignedIdentities')) {
        Stop-Test 'Remediating policy assignment identity or location wiring is invalid.'
    }
    $expectedRoleName = "[guid(managementGroup().id, variables('roleAssignmentPrincipalSeed'), variables('validatedRoleDefinitionIds')[copyIndex()])]"
    $expectedRoleDefinition = "[tenantResourceId('Microsoft.Authorization/roleDefinitions', variables('validatedRoleDefinitionIds')[copyIndex()])]"
    if ($roles.type -ne 'Microsoft.Authorization/roleAssignments' -or
        $roles.copy.count -ne "[length(variables('validatedRoleDefinitionIds'))]" -or
        $roles.name -ne $expectedRoleName -or
        $roles.properties.principalType -ne 'ServicePrincipal' -or
        $roles.properties.roleDefinitionId -ne $expectedRoleDefinition -or
        @($roles.dependsOn).Count -ne 1 -or
        $roles.dependsOn[0] -ne 'assignment') {
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
    if (Test-Path -LiteralPath $ArtifactsParent) {
        Remove-Item -LiteralPath $ArtifactsParent -ErrorAction SilentlyContinue
    }
}
