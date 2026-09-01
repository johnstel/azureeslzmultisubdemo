[CmdletBinding()]
param(
    [string]$CompiledMainTemplate = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir
$ArtifactsParent = Join-Path $ProjectDir '.test-artifacts'
$TempDir = Join-Path $ArtifactsParent ("policy-assignment-ps1-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $ArtifactsParent -Force | Out-Null
New-Item -ItemType Directory -Path $TempDir | Out-Null

function Stop-Test {
    param([string]$Message)
    throw $Message
}

function Find-JsonObjects {
    param(
        [Parameter(Mandatory = $true)]
        $Node,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Predicate
    )
    $results = @()
    if ($null -eq $Node) {
        return $results
    }
    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        if (& $Predicate $Node) {
            $results += $Node
        }
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

function Assert-ExactNames {
    param(
        [string[]]$Actual,
        [string[]]$Expected,
        [string]$Message
    )
    if (Compare-Object -ReferenceObject @($Expected | Sort-Object) -DifferenceObject @($Actual | Sort-Object)) {
        Stop-Test $Message
    }
}

function Get-TemplateResources {
    param($Resources)
    if ($Resources -is [array]) {
        return $Resources
    }
    return @($Resources.PSObject.Properties.Value)
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
    $supportedId = $builtIn -or (Test-ManagementGroupDefinitionId -Value $Binding.policyDefinitionId)
    return $supportedId -and (
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
    [array]$values = if ($inProperty) { $inProperty.Value } else { $notInProperty.Value }
    return $values.Count -eq 1 -and $values[0] -eq 'subscriptionLevelResources'
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
        Stop-Test 'Azure CLI is required for policy assignment validation.'
    }

    if ([string]::IsNullOrEmpty($CompiledMainTemplate)) {
        $CompiledMainTemplate = Join-Path $TempDir 'main.json'
        & az bicep build --file (Join-Path $ProjectDir 'main.bicep') --outfile $CompiledMainTemplate | Out-Null
        if ($LASTEXITCODE -ne 0) { Stop-Test 'main.bicep build failed.' }
    }
    if (-not (Test-Path -LiteralPath $CompiledMainTemplate -PathType Leaf)) {
        Stop-Test "Compiled main template not found: $CompiledMainTemplate"
    }

    $compiledShapes = Join-Path $TempDir 'policy-assignment-shapes.json'
    & az bicep build `
        --file (Join-Path $ScriptDir 'fixtures/policy-assignment-shapes.bicep') `
        --outfile $compiledShapes | Out-Null
    if ($LASTEXITCODE -ne 0) { Stop-Test 'Policy assignment shape fixture build failed.' }

    $compiledExemptionShapes = Join-Path $TempDir 'policy-exemption-shapes.json'
    & az bicep build `
        --file (Join-Path $ScriptDir 'fixtures/policy-exemption-shapes.bicep') `
        --outfile $compiledExemptionShapes | Out-Null
    if ($LASTEXITCODE -ne 0) { Stop-Test 'Policy exemption shape fixture build failed.' }

    Assert-BicepBuildFails `
        -Fixture (Join-Path $ScriptDir 'fixtures/invalid-policy-assignment-name.bicep') `
        -Description 'a management-group policy assignment name longer than 24 characters'
    Assert-BicepBuildFails `
        -Fixture (Join-Path $ScriptDir 'fixtures/invalid-policy-selector-kind.bicep') `
        -Description 'policyDefinitionReferenceId as a resource selector kind'
    Assert-BicepBuildFails `
        -Fixture (Join-Path $ScriptDir 'fixtures/invalid-policy-exemption-expiry.bicep') `
        -Description 'a policy exemption with an empty expiresOn value'
    Assert-BicepBuildFails `
        -Fixture (Join-Path $ScriptDir 'fixtures/invalid-policy-exemption-scope.bicep') `
        -Description 'a policy exemption with an unsupported exemptionScopeType value'

    $validationCases = Get-Content -LiteralPath (Join-Path $ScriptDir 'fixtures/policy-assignment-validation-cases.json') -Raw | ConvertFrom-Json
    foreach ($case in $validationCases.assignmentNames) {
        if ((Test-AssignmentName -Value $case.value) -ne [bool]$case.valid) {
            Stop-Test "Assignment name validation produced the wrong result for '$($case.value)'."
        }
    }
    foreach ($case in $validationCases.definitionBindings) {
        if ((Test-DefinitionBinding -Binding $case) -ne [bool]$case.valid) {
            Stop-Test "Definition binding validation produced the wrong result for '$($case.policyDefinitionId)' with version '$($case.definitionVersion)'."
        }
    }
    foreach ($case in $validationCases.notScopes) {
        if ((Test-NotScope -Value $case.value -CurrentManagementGroupId $validationCases.currentManagementGroupId) -ne [bool]$case.valid) {
            Stop-Test "notScope validation produced the wrong result for '$($case.value)'."
        }
    }
    foreach ($case in $validationCases.resourceWithoutLocationSelectors) {
        if ((Test-ResourceWithoutLocation -Selector $case.selector) -ne [bool]$case.valid) {
            Stop-Test 'resourceWithoutLocation validation produced the wrong result for a negative contract case.'
        }
    }

    $mainJson = Get-Content -LiteralPath $CompiledMainTemplate -Raw | ConvertFrom-Json
    $assignmentNames = @(
        'assign-allowed-locations'
        'assign-audit-public-ip'
        'assign-expensive-resources'
        'assign-platform-tags'
        'assign-workload-rg-tags'
    )
    $assignmentDeployments = @(
        Find-JsonObjects -Node $mainJson -Predicate {
            param($node)
            $node.PSObject.Properties['type'] -and
                $node.type -eq 'Microsoft.Resources/deployments' -and
                $node.PSObject.Properties['name'] -and
                $node.name -in $assignmentNames
        }
    )
    if ($assignmentDeployments.Count -ne 5) {
        Stop-Test "Expected five existing policy assignment deployments, found $($assignmentDeployments.Count)."
    }
    Assert-ExactNames -Actual @($assignmentDeployments.name) -Expected $assignmentNames -Message 'Existing policy assignment names changed.'

    $assignmentsByName = @{}
    foreach ($assignmentDeployment in $assignmentDeployments) {
        $assignmentsByName[$assignmentDeployment.name] = $assignmentDeployment
        $assignmentResource = $assignmentDeployment.properties.template.resources.assignment
        if ($assignmentResource.PSObject.Properties['identity'] -or $assignmentResource.PSObject.Properties['location']) {
            Stop-Test "Policy assignment $($assignmentDeployment.name) must not emit identity or location."
        }
    }

    foreach ($name in @('assign-allowed-locations', 'assign-audit-public-ip', 'assign-expensive-resources')) {
        if (-not $assignmentsByName[$name].scope.Contains("variables('demoRootManagementGroupId')")) {
            Stop-Test "$name is no longer scoped to the dedicated demo root."
        }
    }
    if (-not $assignmentsByName['assign-platform-tags'].scope.Contains("variables('platformManagementGroupId')")) {
        Stop-Test 'assign-platform-tags scope changed.'
    }
    if (-not $assignmentsByName['assign-workload-rg-tags'].scope.Contains("variables('workloadManagementGroupId')")) {
        Stop-Test 'assign-workload-rg-tags scope changed.'
    }

    if ($assignmentsByName['assign-allowed-locations'].properties.parameters.enforcementMode.value -ne "[parameters('denyPolicyEnforcementMode')]" -or
        $assignmentsByName['assign-expensive-resources'].properties.parameters.enforcementMode.value -ne "[parameters('denyPolicyEnforcementMode')]" -or
        $assignmentsByName['assign-workload-rg-tags'].properties.parameters.enforcementMode.value -ne "[parameters('denyPolicyEnforcementMode')]") {
        Stop-Test 'Existing deny assignment enforcement wiring changed.'
    }
    if ($assignmentsByName['assign-audit-public-ip'].properties.parameters.enforcementMode.value -ne 'Default' -or
        $assignmentsByName['assign-platform-tags'].properties.parameters.enforcementMode.value -ne 'Default') {
        Stop-Test 'Existing audit assignment enforcement wiring changed.'
    }
    $expectedResourceNames = @{
        'assign-allowed-locations' = 'demo-allowed-us-locs'
        'assign-audit-public-ip' = 'demo-audit-public-ip'
        'assign-expensive-resources' = 'demo-block-expensive'
        'assign-platform-tags' = 'demo-audit-platform-tags'
        'assign-workload-rg-tags' = 'demo-require-rg-tags'
    }
    $actualResourceNames = @()
    foreach ($assignmentDeployment in $assignmentDeployments) {
        $resourceName = $assignmentDeployment.properties.parameters.assignmentName.value
        if ($resourceName -ne $expectedResourceNames[$assignmentDeployment.name] -or $resourceName.Length -gt 24) {
            Stop-Test "Management-group policy assignment resource name is invalid for $($assignmentDeployment.name)."
        }
        $actualResourceNames += $resourceName
    }
    if (@($actualResourceNames | Select-Object -Unique).Count -ne 5) {
        Stop-Test 'Management-group policy assignment resource names must be unique.'
    }
    if ($assignmentsByName['assign-allowed-locations'].properties.parameters.parameters.value.allowedLocations.value -ne "[parameters('allowedLocations')]") {
        Stop-Test 'Allowed locations assignment parameters changed.'
    }
    foreach ($name in @('assign-audit-public-ip', 'assign-expensive-resources', 'assign-platform-tags', 'assign-workload-rg-tags')) {
        if (@($assignmentsByName[$name].properties.parameters.parameters.value.PSObject.Properties).Count -ne 0) {
            Stop-Test "$name no longer passes an empty parameter object."
        }
    }

    $rootRestrictions = @($mainJson.resources | Where-Object {
        $_.type -eq 'Microsoft.Resources/deployments' -and $_.name -eq 'root-deployment-restrictions'
    })
    if ($rootRestrictions.Count -ne 1) {
        Stop-Test 'Expected exactly one root deployment-restrictions module.'
    }
    $rootRestrictions = $rootRestrictions[0]
    if (-not $rootRestrictions.scope.Contains("variables('demoRootManagementGroupId')") -or
        $rootRestrictions.properties.parameters.allowedLocations.value -ne "[parameters('customerAllowedLocations')]" -or
        $rootRestrictions.properties.parameters.allowedResourceTypes.value -ne "[parameters('customerAllowedResourceTypes')]" -or
        $rootRestrictions.properties.parameters.allowedVmSkus.value -ne "[parameters('customerAllowedVmSkus')]" -or
        $rootRestrictions.properties.parameters.enforcementMode.value -ne "[parameters('denyPolicyEnforcementMode')]" -or
        -not $rootRestrictions.properties.parameters.allowedResourceTypesPolicyDefinitionId.value.Contains('allowedResourceTypesAllPolicyDefinitionId')) {
        Stop-Test 'Root deployment-restrictions scope or parameter wiring is invalid.'
    }
    if ((Compare-Object @('eastus', 'eastus2') @($mainJson.parameters.customerAllowedLocations.defaultValue)) -or
        @($mainJson.parameters.allowedLocations.defaultValue).Count -ne 9) {
        Stop-Test 'Customer location defaults must remain separate from the existing safe demo profile.'
    }
    $restrictionDeployments = @(Get-TemplateResources -Resources $rootRestrictions.properties.template.resources)
    $restrictionInitiative = @($restrictionDeployments | Where-Object name -eq 'root-deployment-restrictions')
    $restrictionAssignment = @($restrictionDeployments | Where-Object name -eq 'assign-root-deployment-restrictions')
    if ($restrictionInitiative.Count -ne 1 -or $restrictionAssignment.Count -ne 1) {
        Stop-Test 'Root deployment-restrictions must compose one initiative and one assignment.'
    }
    $references = @($restrictionInitiative[0].properties.parameters.policyDefinitionReferences.value)
    $expectedReferenceIds = @('allowed-locations', 'allowed-resource-types', 'allowed-vm-skus', 'audit-managed-disks', 'audit-public-ip')
    Assert-ExactNames -Actual @($references.policyDefinitionReferenceId) -Expected $expectedReferenceIds -Message 'Root deployment-restrictions policy references changed.'
    $policyLibrary = @($mainJson.resources | Where-Object {
        $_.type -eq 'Microsoft.Resources/deployments' -and $_.name.Contains('policy-library')
    })
    $policyLibraryResources = @(Get-TemplateResources -Resources $policyLibrary[0].properties.template.resources)
    $allowedResourceTypesPolicy = @($policyLibraryResources | Where-Object {
        $_.properties.displayName -eq 'Demo - allowed resource types (all resources)'
    })
    if ($allowedResourceTypesPolicy.Count -ne 1 -or
        $allowedResourceTypesPolicy[0].properties.mode -ne 'All' -or
        $allowedResourceTypesPolicy[0].properties.parameters.allowedResourceTypes.type -ne 'Array' -or
        $allowedResourceTypesPolicy[0].properties.policyRule.if.field -ne 'type' -or
        $allowedResourceTypesPolicy[0].properties.policyRule.if.notIn -ne "[[parameters('allowedResourceTypes')]" -or
        $allowedResourceTypesPolicy[0].properties.policyRule.then.effect -ne 'deny') {
        Stop-Test 'The custom allowed-resource-types policy must evaluate all resource types.'
    }
    if ($references[0].parameters.listOfAllowedLocations.value -ne "[[parameters('allowedLocations')]" -or
        $references[0].parameters.effect.value -ne 'Deny' -or
        $references[1].policyDefinitionId -ne "[parameters('allowedResourceTypesPolicyDefinitionId')]" -or
        $references[1].parameters.allowedResourceTypes.value -ne "[[parameters('allowedResourceTypes')]" -or
        $references[2].parameters.listOfAllowedSKUs.value -ne "[[parameters('allowedVmSkus')]") {
        Stop-Test 'Root deployment-restrictions initiative parameter mappings are invalid.'
    }
    $restrictionAssignmentParameters = $restrictionAssignment[0].properties.parameters
    $messages = @($restrictionAssignmentParameters.nonComplianceMessages.value)
    if ($restrictionAssignmentParameters.assignmentName.value -ne 'demo-deploy-restrictions' -or
        $restrictionAssignmentParameters.enforcementMode.value -ne "[parameters('enforcementMode')]" -or
        $messages.Count -ne 5) {
        Stop-Test 'Root deployment-restrictions assignment is not safely configured.'
    }
    Assert-ExactNames -Actual @($messages.policyDefinitionReferenceId) -Expected $expectedReferenceIds -Message 'Root deployment-restrictions noncompliance messages are incomplete.'
    $requiredResourceTypes = @(
        'Microsoft.Authorization/policyDefinitions'
        'Microsoft.Authorization/policyExemptions'
        'Microsoft.Authorization/policySetDefinitions'
        'Microsoft.Insights/diagnosticSettings'
        'Microsoft.Compute/virtualMachines/extensions'
        'Microsoft.Network/networkInterfaces'
        'Microsoft.Network/privateEndpoints'
        'Microsoft.Network/privateEndpoints/privateDnsZoneGroups'
        'Microsoft.Network/privateDnsZones/virtualNetworkLinks'
        'Microsoft.Network/publicIPAddresses'
        'Microsoft.RecoveryServices/vaults/backupPolicies'
        'Microsoft.RecoveryServices/vaults/backupFabrics'
        'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers'
        'Microsoft.PolicyInsights/remediations'
        'Microsoft.Resources/resourceGroups'
        'Microsoft.Network/networkSecurityGroups'
        'Microsoft.Network/virtualNetworks'
        'Microsoft.SecurityInsights/onboardingStates'
    )
    if (Compare-Object $requiredResourceTypes @($mainJson.parameters.customerAllowedResourceTypes.defaultValue) |
        Where-Object SideIndicator -eq '<=') {
        Stop-Test 'Customer resource-type defaults omit required child, remediation, or evidence resource types.'
    }

    $shapesJson = Get-Content -LiteralPath $compiledShapes -Raw | ConvertFrom-Json
    $shapeDeployments = @(
        Find-JsonObjects -Node $shapesJson -Predicate {
            param($node)
            $node.PSObject.Properties['type'] -and
                $node.type -eq 'Microsoft.Resources/deployments' -and
                $node.PSObject.Properties['name'] -and
                $node.name -in @('example-policy-assignment', 'example-initiative-assignment', 'example-custom-policy-assignment')
        }
    )
    if ($shapeDeployments.Count -ne 3) {
        Stop-Test 'Expected compiled built-in policy, initiative, and custom policy assignment examples.'
    }
    $policy = $shapeDeployments | Where-Object name -eq 'example-policy-assignment'
    $initiative = $shapeDeployments | Where-Object name -eq 'example-initiative-assignment'
    $custom = $shapeDeployments | Where-Object name -eq 'example-custom-policy-assignment'

    Assert-ExactNames `
        -Actual @($policy.properties.parameters.PSObject.Properties.Name) `
        -Expected @('assignmentName', 'description', 'displayName', 'policyDefinitionId') `
        -Message 'Minimal policy assignment must omit all optional module arguments.'
    if ($policy.properties.parameters.policyDefinitionId.value -ne '/providers/Microsoft.Authorization/policyDefinitions/11111111-1111-1111-1111-111111111111') {
        Stop-Test 'Policy definition assignment example has the wrong definition ID shape.'
    }

    Assert-ExactNames `
        -Actual @($initiative.properties.parameters.PSObject.Properties.Name) `
        -Expected @('assignmentName', 'definitionVersion', 'description', 'displayName', 'enforcementMode', 'metadata', 'nonComplianceMessages', 'notScopes', 'parameters', 'policyDefinitionId', 'resourceSelectors') `
        -Message 'Initiative assignment example does not supply every supported property.'
    if ($initiative.properties.parameters.policyDefinitionId.value -ne '/providers/Microsoft.Authorization/policySetDefinitions/22222222-2222-2222-2222-222222222222' -or
        $initiative.properties.parameters.definitionVersion.value -ne '1.2.*' -or
        $initiative.properties.parameters.enforcementMode.value -ne 'Default' -or
        $initiative.properties.parameters.parameters.value.effect.value -ne 'Audit') {
        Stop-Test 'Initiative definition, version, enforcement, or parameter shape is invalid.'
    }
    if ($initiative.properties.parameters.metadata.value.category -ne 'Test' -or
        $initiative.properties.parameters.metadata.value.owner -ne 'Platform Team' -or
        @($initiative.properties.parameters.metadata.value.PSObject.Properties).Count -ne 2) {
        Stop-Test 'Initiative assignment metadata shape is invalid.'
    }
    if (@($initiative.properties.parameters.nonComplianceMessages.value).Count -ne 2 -or
        $initiative.properties.parameters.nonComplianceMessages.value[1].policyDefinitionReferenceId -ne 'audit-reference') {
        Stop-Test 'Initiative non-compliance message shape is invalid.'
    }
    if (@($initiative.properties.parameters.notScopes.value).Count -ne 2 -or
        $initiative.properties.parameters.notScopes.value[0] -ne '/providers/Microsoft.Management/managementGroups/excluded' -or
        $initiative.properties.parameters.notScopes.value[1] -ne '/subscriptions/33333333-3333-3333-3333-333333333333/resourceGroups/rg-excluded/providers/Microsoft.Network/virtualNetworks/vnet-excluded/subnets/default') {
        Stop-Test 'Initiative notScopes shape is invalid.'
    }
    $selectors = @($initiative.properties.parameters.resourceSelectors.value)
    if ($selectors.Count -ne 3 -or
        $selectors[0].selectors[0].kind -ne 'resourceLocation' -or
        @($selectors[0].selectors[0].in).Count -ne 2 -or
        $selectors[1].selectors[0].kind -ne 'resourceType' -or
        $selectors[1].selectors[0].notIn[0] -ne 'Microsoft.Compute/virtualMachines' -or
        $selectors[2].selectors[0].kind -ne 'resourceWithoutLocation' -or
        $selectors[2].selectors[0].in[0] -ne 'subscriptionLevelResources') {
        Stop-Test 'Initiative resource selector shape is invalid.'
    }
    if ($custom.properties.parameters.policyDefinitionId.value -ne '/providers/Microsoft.Management/managementGroups/demo-root/providers/Microsoft.Authorization/policyDefinitions/custom-policy' -or
        $custom.properties.parameters.PSObject.Properties['definitionVersion']) {
        Stop-Test 'Custom management-group policy definitions must compile without definitionVersion.'
    }

    $moduleTemplate = $policy.properties.template
    $resource = $moduleTemplate.resources.assignment
    if ($moduleTemplate.parameters.enforcementMode.defaultValue -ne 'DoNotEnforce' -or
        @($moduleTemplate.parameters.parameters.defaultValue.PSObject.Properties).Count -ne 0 -or
        $moduleTemplate.parameters.metadata.defaultValue.category -ne 'Demo Landing Zone' -or
        $moduleTemplate.parameters.metadata.defaultValue.source -ne 'Bicep' -or
        @($moduleTemplate.parameters.nonComplianceMessages.defaultValue).Count -ne 0 -or
        @($moduleTemplate.parameters.notScopes.defaultValue).Count -ne 0 -or
        @($moduleTemplate.parameters.resourceSelectors.defaultValue).Count -ne 0) {
        Stop-Test 'Safe assignment defaults changed.'
    }
    if ($moduleTemplate.parameters.assignmentName.maxLength -ne 24 -or
        $moduleTemplate.parameters.resourceSelectors.maxLength -ne 10 -or
        $moduleTemplate.definitions.NonComplianceMessage.additionalProperties -ne $false -or
        $moduleTemplate.definitions.NonComplianceMessage.properties.message.minLength -ne 1 -or
        $moduleTemplate.definitions.NonComplianceMessage.properties.message.maxLength -ne 500 -or
        $moduleTemplate.definitions.Selector.additionalProperties -ne $false -or
        $moduleTemplate.definitions.ResourceSelector.additionalProperties -ne $false -or
        $moduleTemplate.definitions.ResourceSelector.properties.selectors.minLength -ne 1 -or
        $moduleTemplate.definitions.ResourceSelector.properties.selectors.maxLength -ne 10) {
        Stop-Test 'Compiled policy assignment type constraints are incomplete.'
    }
    Assert-ExactNames `
        -Actual @($moduleTemplate.definitions.Selector.properties.kind.allowedValues) `
        -Expected @('resourceLocation', 'resourceType', 'resourceWithoutLocation') `
        -Message 'Selector kind allowlist is incomplete.'

    foreach ($validation in @{
        validatedAssignmentName = "fail('assignmentName contains a character that is invalid"
        validatedPolicyDefinitionId = "fail('policyDefinitionId must be an exact built-in or management-group"
        validatedDefinitionVersion = "fail('definitionVersion is supported only for built-in definitions and must use N.*.* or N.N.*"
        validatedNonComplianceMessages = "fail('policyDefinitionReferenceId must be non-empty"
        validatedNotScopes = "fail('notScopes must contain only valid descendant management-group"
        validatedResourceSelectors = "fail('resourceSelectors must use unique names"
    }.GetEnumerator()) {
        if (-not ([string]$moduleTemplate.variables.($validation.Key)).Contains($validation.Value)) {
            Stop-Test "Compiled validation missing from $($validation.Key)."
        }
    }
    foreach ($validationText in @(
        "fail('Each selector kind can be used only once within a resource selector",
        "fail('resourceLocation and resourceWithoutLocation cannot be used in the same resource selector",
        "fail('resourceWithoutLocation must use the single supported value subscriptionLevelResources",
        "fail('Each resource selector expression must provide one non-empty in or notIn array containing no more than 50 values"
    )) {
        if (-not ([string]$moduleTemplate.variables.validatedResourceSelectors).Contains($validationText)) {
            Stop-Test "Compiled resource selector validation is incomplete: $validationText"
        }
    }
    if (-not ([string]$moduleTemplate.variables.invalidSelectorExpressions).Contains('greater(length(')) {
        Stop-Test 'Compiled resource selector expression validation is incomplete.'
    }

    if ($resource.type -ne 'Microsoft.Authorization/policyAssignments' -or
        $resource.apiVersion -ne '2025-03-01' -or
        $resource.name -ne "[variables('validatedAssignmentName')]" -or
        $resource.PSObject.Properties['identity'] -or
        $resource.PSObject.Properties['location']) {
        Stop-Test 'Policy assignment resource must use the selected API without identity or location.'
    }
    foreach ($optionalProperty in @('definitionVersion', 'parameters', 'metadata', 'nonComplianceMessages', 'notScopes', 'resourceSelectors')) {
        $expectedFragment = "if(not(empty(parameters('$optionalProperty'))), createObject('$optionalProperty'"
        if (-not ([string]$resource.properties).Contains($expectedFragment)) {
            Stop-Test "Compiled assignment does not conditionally omit empty $optionalProperty."
        }
    }

    $exemptionShapesJson = Get-Content -LiteralPath $compiledExemptionShapes -Raw | ConvertFrom-Json
    $exemptionShapeDeployments = @(
        Find-JsonObjects -Node $exemptionShapesJson -Predicate {
            param($node)
            $node.PSObject.Properties['type'] -and
                $node.type -eq 'Microsoft.Resources/deployments' -and
                $node.PSObject.Properties['name'] -and
                $node.name -in @('example-management-group-exemption', 'example-subscription-exemption', 'example-resource-group-exemption')
        }
    )
    if ($exemptionShapeDeployments.Count -ne 3) {
        Stop-Test 'Expected compiled management-group, subscription, and resource-group policy exemption examples.'
    }
    $managementGroupExemption = $exemptionShapeDeployments | Where-Object name -eq 'example-management-group-exemption'
    $subscriptionExemption = $exemptionShapeDeployments | Where-Object name -eq 'example-subscription-exemption'
    $resourceGroupExemption = $exemptionShapeDeployments | Where-Object name -eq 'example-resource-group-exemption'

    Assert-ExactNames `
        -Actual @($managementGroupExemption.properties.parameters.PSObject.Properties.Name) `
        -Expected @('approver', 'createdOn', 'description', 'displayName', 'exemptionCategory', 'exemptionName', 'exemptionScopeType', 'expiresOn', 'justification', 'managementGroupName', 'owner', 'policyAssignmentId', 'reviewedOn', 'ticketReference') `
        -Message 'Management-group exemption example must include required accountability and expiry properties.'
    Assert-ExactNames `
        -Actual @($subscriptionExemption.properties.parameters.PSObject.Properties.Name) `
        -Expected @('approver', 'createdOn', 'description', 'displayName', 'exemptionCategory', 'exemptionName', 'exemptionScopeType', 'expiresOn', 'justification', 'owner', 'policyAssignmentId', 'reviewedOn', 'subscriptionId', 'ticketReference') `
        -Message 'Subscription exemption example must include required accountability and expiry properties.'
    Assert-ExactNames `
        -Actual @($resourceGroupExemption.properties.parameters.PSObject.Properties.Name) `
        -Expected @('approver', 'createdOn', 'description', 'displayName', 'exemptionCategory', 'exemptionName', 'exemptionScopeType', 'expiresOn', 'governanceOwner', 'justification', 'owner', 'policyAssignmentId', 'policyDefinitionReferenceIds', 'resourceGroupName', 'reviewedOn', 'source', 'subscriptionId', 'ticketReference') `
        -Message 'Resource-group exemption example must include initiative reference IDs and governance metadata overrides.'

    if ($managementGroupExemption.properties.parameters.exemptionCategory.value -ne 'Waiver' -or
        $subscriptionExemption.properties.parameters.exemptionCategory.value -ne 'Mitigated' -or
        (Compare-Object @($resourceGroupExemption.properties.parameters.policyDefinitionReferenceIds.value) @('public-management-ingress', 'require-subnet-nsg'))) {
        Stop-Test 'Exemption categories or policyDefinitionReferenceIds are invalid.'
    }

    $exemptionModuleTemplate = $managementGroupExemption.properties.template
    $managementGroupExemptionResource = $exemptionModuleTemplate.resources.managementGroupExemption.properties.template.resources.exemption
    if ($managementGroupExemptionResource.type -ne 'Microsoft.Authorization/policyExemptions' -or
        $managementGroupExemptionResource.apiVersion -ne '2024-12-01-preview' -or
        $managementGroupExemptionResource.name -ne "[parameters('exemptionName')]") {
        Stop-Test 'Policy exemption module must emit a policyExemptions resource using the expected API and naming.'
    }
    $exemptionResourcePropertiesExpression = [string]$managementGroupExemptionResource.properties
    foreach ($requiredPropertyText in @(
        'policyAssignmentId',
        'exemptionCategory',
        'expiresOn',
        'ticketReference',
        'governanceVersion',
        'policyDefinitionReferenceIds'
    )) {
        if (-not $exemptionResourcePropertiesExpression.Contains($requiredPropertyText)) {
            Stop-Test "Policy exemption properties are missing required content: $requiredPropertyText"
        }
    }
    if ($exemptionModuleTemplate.parameters.owner.minLength -ne 1 -or
        $exemptionModuleTemplate.parameters.expiresOn.minLength -ne 1 -or
        $exemptionModuleTemplate.parameters.ticketReference.minLength -ne 1 -or
        $exemptionModuleTemplate.parameters.subscriptionId.defaultValue -ne '' -or
        $exemptionModuleTemplate.parameters.resourceGroupName.defaultValue -ne '' -or
        $exemptionModuleTemplate.parameters.source.defaultValue -ne 'Bicep' -or
        $exemptionModuleTemplate.parameters.governanceOwner.defaultValue -ne 'eslz-v2-governance') {
        Stop-Test 'Policy exemption parameter defaults or required-field constraints changed.'
    }
    Assert-ExactNames `
        -Actual @($exemptionModuleTemplate.parameters.exemptionCategory.allowedValues) `
        -Expected @('Mitigated', 'Waiver') `
        -Message 'Policy exemption category allowlist is incomplete.'
    foreach ($validation in @{
        validatedPolicyAssignmentId = "fail('policyAssignmentId must be an exact Azure Policy assignment resource ID."
        validatedExpiresOn = "fail('expiresOn must be a non-empty UTC timestamp"
        validatedScopeType = "fail('resourceGroup exemptions require valid subscriptionId and resourceGroupName"
        validatedPolicyDefinitionReferenceIds = "fail('policyDefinitionReferenceIds cannot include empty values."
    }.GetEnumerator()) {
        if (-not ([string]$exemptionModuleTemplate.variables.($validation.Key)).Contains($validation.Value)) {
            Stop-Test "Compiled exemption validation missing from $($validation.Key)."
        }
    }

    Write-Host 'Policy assignment structural validation passed.'
}
finally {
    if (Test-Path -LiteralPath $TempDir) {
        Remove-Item -LiteralPath $TempDir -Recurse -Force
    }
    if (Test-Path -LiteralPath $ArtifactsParent) {
        $remainingArtifacts = @(Get-ChildItem -LiteralPath $ArtifactsParent -Force)
        if ($remainingArtifacts.Count -eq 0) {
            Remove-Item -LiteralPath $ArtifactsParent -Force
        }
    }
}
