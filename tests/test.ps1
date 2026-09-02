[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir
$ArtifactsParent = Join-Path $ProjectDir '.test-artifacts'
$TempDir = Join-Path $ArtifactsParent ("test-ps1-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $ArtifactsParent -Force | Out-Null
New-Item -ItemType Directory -Path $TempDir | Out-Null

function Stop-Test {
    param([string]$Message)
    throw $Message
}

function ConvertTo-TestMessage {
    param($Output)

    $text = (@($Output) | ForEach-Object { [string]$_ }) -join "`n"
    $text = $text -replace "$([char]27)\[[0-9;]*[A-Za-z]", ''
    $text = (($text -split "`r?`n") | ForEach-Object { $_ -replace '^\s*\|\s?', '' }) -join ' '
    return ($text -replace '\s+', ' ').Trim()
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

function Find-ProhibitedPaidDeclarations {
    param($Node)
    $results = @()
    if ($null -eq $Node) {
        return $results
    }
    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        $typeProperty = $Node.PSObject.Properties['type']
        $apiVersionProperty = $Node.PSObject.Properties['apiVersion']
        $nameProperty = $Node.PSObject.Properties['name']
        if ($typeProperty -and $typeProperty.Value -eq 'Microsoft.Resources/deployments' -and
            $nameProperty -and $nameProperty.Value -in @('central-monitoring', 'central-monitoring-workspace', 'central-monitoring-sentinel', 'activity-log-workspace-destination-rbac', 'resource-diagnostics-workspace-destination-rbac')) {
            return $results
        }
        $prohibitedPattern = '^Microsoft\.(Compute/virtualMachines|OperationalInsights/workspaces|Network/(azureFirewalls|bastionHosts|natGateways|publicIPAddresses|virtualNetworkGateways)|Storage/storageAccounts)$'
        if ($typeProperty -and $apiVersionProperty -and $typeProperty.Value -match $prohibitedPattern) {
            $results += $typeProperty.Value
        }
        foreach ($property in $Node.PSObject.Properties) {
            $results += Find-ProhibitedPaidDeclarations -Node $property.Value
        }
    }
    elseif ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
        foreach ($item in $Node) {
            $results += Find-ProhibitedPaidDeclarations -Node $item
        }
    }
    return $results
}

try {
    if ($null -eq (Get-Command az -ErrorAction SilentlyContinue)) {
        Stop-Test 'Azure CLI is required for Bicep validation.'
    }

    Write-Host '1/24 Validate repository versioning and branch guidance...'
    $versionPath = Join-Path $ProjectDir 'VERSION'
    $versionValue = (Get-Content -LiteralPath $versionPath -Raw).Trim()
    if ($versionValue -ne '2.0.0-dev') {
        Stop-Test 'VERSION must be exactly 2.0.0-dev.'
    }
    $readmeText = Get-Content -LiteralPath (Join-Path $ProjectDir 'README.md') -Raw
    foreach ($requiredText in @(
        '**Version status:** `main` is the **v2 development line** (`2.0.0-dev`).',
        'https://github.com/johnstel/azureeslzmultisubdemo/releases/tag/v1.0.0',
        'https://github.com/johnstel/azureeslzmultisubdemo/tree/release/v1',
        'https://github.com/johnstel/azureeslzmultisubdemo/issues?q=milestone%3A%22v2.0.0%22'
    )) {
        if (-not $readmeText.Contains($requiredText)) {
            Stop-Test "README is missing required v2 guidance: $requiredText"
        }
    }

    Write-Host '2/24 Build the complete tenant template and validate policy assignment shapes...'
    $compiledTemplate = Join-Path $TempDir 'main.json'
    $buildOutput = & az bicep build --file (Join-Path $ProjectDir 'main.bicep') --outfile $compiledTemplate 2>&1
    if ($LASTEXITCODE -ne 0) { Stop-Test 'Bicep build failed.' }
    if ($buildOutput -match 'BCP318') {
        Stop-Test 'main.bicep build must not emit a BCP318 nullable-module-output warning.'
    }
    $compiledEligibilityTemplate = Join-Path $TempDir 'owner-eligibility-request.json'
    & az bicep build `
        --file (Join-Path $ProjectDir 'identity/azure-rbac/owner-eligibility-request.bicep') `
        --outfile $compiledEligibilityTemplate
    if ($LASTEXITCODE -ne 0) { Stop-Test 'Owner eligibility Bicep build failed.' }
    & (Join-Path $ScriptDir 'validate-policy-assignment.ps1') -CompiledMainTemplate $compiledTemplate
    $compiledJson = Get-Content -LiteralPath $compiledTemplate -Raw | ConvertFrom-Json
    Write-Host '    Confirm the exact six-tag initiative and compliant evidence resource groups...'
    $requiredTags = @('CostCenter', 'ApplicationName', 'Owner', 'Environment', 'DataClassification', 'SSP-ID')
    $initiativeDeployment = Find-JsonObjects -Node $compiledJson -Predicate {
        param($node)
        $node.PSObject.Properties['type'] -and $node.type -eq 'Microsoft.Resources/deployments' -and
        $node.PSObject.Properties['name'] -and $node.name -eq 'resource-group-tags-initiative'
    } | Select-Object -First 1
    $assignmentDeployment = Find-JsonObjects -Node $compiledJson -Predicate {
        param($node)
        $node.PSObject.Properties['type'] -and $node.type -eq 'Microsoft.Resources/deployments' -and
        $node.PSObject.Properties['name'] -and $node.name -eq 'assign-resource-group-tags'
    } | Select-Object -First 1
    if ($null -eq $initiativeDeployment -or $null -eq $assignmentDeployment) {
        Stop-Test 'Required resource-group tag initiative or assignment deployment is missing.'
    }
    $tagReferences = @($initiativeDeployment.properties.parameters.policyDefinitionReferences.value)
    if ($tagReferences.Count -ne 6) {
        Stop-Test 'Required resource-group tag initiative must contain exactly six policy references.'
    }
    $actualTags = @($tagReferences.parameters.tagName.value)
    if (Compare-Object -ReferenceObject $requiredTags -DifferenceObject $actualTags -CaseSensitive) {
        Stop-Test 'Required resource-group tag initiative must contain the exact six case-sensitive tag names.'
    }
    foreach ($tagReference in $tagReferences) {
        if ($tagReference.policyDefinitionId -cne "[variables('requireResourceGroupTagPolicyDefinitionId')]") {
            Stop-Test 'Every required tag must use the verified built-in resource-group tag policy.'
        }
        if ($tagReference.definitionVersion -cne '1.*.*') {
            Stop-Test 'Every required tag policy reference must pin the catalog-supported 1.*.* major version.'
        }
    }
    if (-not $initiativeDeployment.scope.Contains('demoRootManagementGroupId')) {
        Stop-Test 'Required resource-group tag initiative definition must be stored at the demo root.'
    }
    if (-not $assignmentDeployment.scope.Contains('landingZonesManagementGroupId')) {
        Stop-Test 'Required resource-group tag assignment must remain scoped to Landing Zones.'
    }
    if ($assignmentDeployment.properties.parameters.enforcementMode.value -cne "[parameters('denyPolicyEnforcementMode')]") {
        Stop-Test 'Required resource-group tag assignment must use the safe deny enforcement parameter.'
    }
    $nonComplianceMessages = @($assignmentDeployment.properties.parameters.nonComplianceMessages.value)
    if ($nonComplianceMessages.Count -ne 6) {
        Stop-Test 'Required resource-group tag assignment must contain exactly six noncompliance messages.'
    }
    $tagsByReference = @{}
    foreach ($tagReference in $tagReferences) {
        $tagsByReference[$tagReference.policyDefinitionReferenceId] = $tagReference.parameters.tagName.value
    }
    $messageReferences = @($nonComplianceMessages.policyDefinitionReferenceId)
    foreach ($tagReference in $tagReferences) {
        if (@($messageReferences | Where-Object { $_ -ceq $tagReference.policyDefinitionReferenceId }).Count -ne 1) {
            Stop-Test "Required tag reference $($tagReference.policyDefinitionReferenceId) must have exactly one noncompliance message."
        }
    }
    foreach ($nonComplianceMessage in $nonComplianceMessages) {
        $tagName = $tagsByReference[$nonComplianceMessage.policyDefinitionReferenceId]
        if ($null -eq $tagName -or
            $nonComplianceMessage.message -cne "Resource groups must include the $tagName tag.") {
            Stop-Test "Noncompliance message for $($nonComplianceMessage.policyDefinitionReferenceId) does not match its required tag."
        }
    }
    foreach ($evidenceDeploymentName in @('connectivity-evidence', 'workload-evidence')) {
        $evidenceDeployment = Find-JsonObjects -Node $compiledJson -Predicate {
            param($node)
            $node.PSObject.Properties['type'] -and $node.type -eq 'Microsoft.Resources/deployments' -and
            $node.PSObject.Properties['name'] -and $node.name -eq $evidenceDeploymentName
        } | Select-Object -First 1
        if ($null -eq $evidenceDeployment) {
            Stop-Test "$evidenceDeploymentName deployment is missing."
        }
        if ($evidenceDeploymentName -eq 'connectivity-evidence') {
            $evidenceTags = $evidenceDeployment.properties.template.variables.commonTags
        } else {
            $evidenceTags = @($evidenceDeployment.properties.template.resources |
                Where-Object { $_.type -eq 'Microsoft.Resources/resourceGroups' })[0].tags
        }
        foreach ($requiredTag in $requiredTags) {
            if (-not $evidenceTags.PSObject.Properties[$requiredTag]) {
                Stop-Test "$evidenceDeploymentName resource group is missing the exact $requiredTag tag."
            }
        }
    }
    & (Join-Path $ScriptDir 'validate-remediating-policy-assignment.ps1')

    Write-Host '3/24 Validate both parameter templates...'
    $parameterTemplatePath = Join-Path $ProjectDir 'parameters/demo.parameters.template.json'
    $parameterTemplate = Get-Content -LiteralPath $parameterTemplatePath -Raw | ConvertFrom-Json
    if ($parameterTemplate.parameters.deployRoleAssignments.value -ne $false) {
        Stop-Test 'deployRoleAssignments must default to false.'
    }
    if ($parameterTemplate.parameters.deployEvidenceResources.value -ne $false) {
        Stop-Test 'deployEvidenceResources must default to false.'
    }
    if ($parameterTemplate.parameters.denyPolicyEnforcementMode.value -ne 'DoNotEnforce') {
        Stop-Test 'denyPolicyEnforcementMode must default to DoNotEnforce.'
    }
    if (Compare-Object @('eastus', 'eastus2') @($parameterTemplate.parameters.customerAllowedLocations.value)) {
        Stop-Test 'customerAllowedLocations must default to eastus and eastus2.'
    }
    if ('Microsoft.PolicyInsights/remediations' -notin @($parameterTemplate.parameters.customerAllowedResourceTypes.value) -or
        @($parameterTemplate.parameters.customerAllowedVmSkus.value).Count -eq 0) {
        Stop-Test 'Customer resource-type and VM SKU allowlists must remain safe and populated.'
    }
    $compiledParametersPath = Join-Path $TempDir 'main.parameters.json'
    & az bicep build-params `
        --file (Join-Path $ProjectDir 'parameters/main.template.bicepparam') `
        --outfile $compiledParametersPath
    if ($LASTEXITCODE -ne 0) { Stop-Test 'Bicep parameter build failed.' }
    $compiledParameters = Get-Content -LiteralPath $compiledParametersPath -Raw | ConvertFrom-Json
    if ($compiledParameters.parameters.networkIngressPolicyEffect.value -ne 'Audit') {
        Stop-Test 'networkIngressPolicyEffect must default to Audit in the Bicep parameter template.'
    }
    if ($parameterTemplate.parameters.privateAccessPublicNetworkPolicyEffect.value -ne 'Audit' -or
        (Compare-Object @($parameterTemplate.parameters.privateAccessServiceCategories.value) @('Storage', 'KeyVault')) -or
        $parameterTemplate.parameters.enableFirewallRouteGuardrails.value -ne $false -or
        $parameterTemplate.parameters.approvedFirewallResourceId.value -ne '' -or
        $parameterTemplate.parameters.approvedFirewallPrivateIp.value -ne '' -or
        @($parameterTemplate.parameters.approvedRouteTableResourceIds.value).Count -ne 0 -or
        @($parameterTemplate.parameters.approvedRouteTablePrefixes.value).Count -ne 0 -or
        $parameterTemplate.parameters.deployLoggingRemediationRoleAssignments.value -ne $false) {
        Stop-Test 'Private-access and firewall-route JSON template parameters must retain safe defaults.'
    }
    if ($compiledParameters.parameters.privateAccessPublicNetworkPolicyEffect.value -ne 'Audit' -or
        (Compare-Object @($compiledParameters.parameters.privateAccessServiceCategories.value) @('Storage', 'KeyVault')) -or
        $compiledParameters.parameters.enableFirewallRouteGuardrails.value -ne $false -or
        $compiledParameters.parameters.approvedFirewallResourceId.value -ne '' -or
        $compiledParameters.parameters.approvedFirewallPrivateIp.value -ne '' -or
        @($compiledParameters.parameters.approvedRouteTableResourceIds.value).Count -ne 0 -or
        @($compiledParameters.parameters.approvedRouteTablePrefixes.value).Count -ne 0 -or
        $compiledParameters.parameters.deployLoggingRemediationRoleAssignments.value -ne $false) {
        Stop-Test 'Private-access and firewall-route Bicep template parameters must retain safe defaults.'
    }

    $compiledJson = Get-Content -LiteralPath $compiledTemplate -Raw | ConvertFrom-Json
    if ($compiledJson.resources -is [System.Management.Automation.PSCustomObject]) {
        $compiledJson.resources = @($compiledJson.resources.PSObject.Properties | ForEach-Object { $_.Value })
    }
    Write-Host '4/24 Confirm there are exactly two unconditional subscription associations...'
    $subscriptionAssociations = Find-JsonObjects -Node $compiledJson -Predicate {
        param($node)
        $node.PSObject.Properties['type'] -and $node.type -eq 'Microsoft.Management/managementGroups/subscriptions'
    }
    $unconditionalAssociations = $subscriptionAssociations | Where-Object { -not $_.PSObject.Properties['condition'] }
    if (@($unconditionalAssociations).Count -ne 2) {
        Stop-Test "Expected 2 unconditional subscription association resources, found $(@($unconditionalAssociations).Count)."
    }

    Write-Host '5/24 Confirm no paid always-on resource types are declared outside the opt-in central monitoring module...'
    if (@(Find-ProhibitedPaidDeclarations -Node $compiledJson).Count -ne 0) {
        Stop-Test 'A prohibited evidence resource type is declared.'
    }
    $paidResourceFixture = Join-Path $TempDir 'paid-resource-declaration.json'
    & az bicep build `
        --file (Join-Path $ScriptDir 'fixtures/paid-resource-declaration.bicep') `
        --outfile $paidResourceFixture
    if ($LASTEXITCODE -ne 0) { Stop-Test 'Paid-resource declaration fixture build failed.' }
    $paidResourceFixtureJson = Get-Content -LiteralPath $paidResourceFixture -Raw | ConvertFrom-Json
    if (@(Find-ProhibitedPaidDeclarations -Node $paidResourceFixtureJson).Count -eq 0) {
        Stop-Test 'The paid-resource declaration safety check did not reject its negative fixture.'
    }

    Write-Host '6/24 Confirm tenant-root scope is only used as the parent hierarchy input...'
    foreach ($bicepFile in Get-ChildItem $ProjectDir -Recurse -Filter '*.bicep') {
        if ((Get-Content -LiteralPath $bicepFile.FullName -Raw) -match 'scope:\s*managementGroup\(tenantRootManagementGroupId\)') {
            Stop-Test "A module or resource assigns governance directly at the tenant root in $($bicepFile.Name)."
        }
    }

    Write-Host '7/24 Confirm group-only RBAC, idempotent main, one-shot Owner eligibility, and guarded lifecycle scripts...'
    $mainBicepText = Get-Content -LiteralPath (Join-Path $ProjectDir 'main.bicep') -Raw
    $groupPattern = '(?m)^param (governanceAdminsGroupObjectId|networkOperatorsGroupObjectId|workloadContributorsGroupObjectId|readOnlyAuditorsGroupObjectId) string$'
    if (([regex]::Matches($mainBicepText, $groupPattern)).Count -ne 4) {
        Stop-Test 'Expected four ordinary Entra security-group parameters in main.bicep.'
    }
    $rbacValidatorPath = Join-Path $ProjectDir 'scripts/validate-rbac-artifacts.ps1'
    & $rbacValidatorPath `
        -CompiledTemplate $compiledTemplate `
        -CompiledEligibilityTemplate $compiledEligibilityTemplate
    if ($LASTEXITCODE -ne 0) { Stop-Test 'PIM-ready RBAC artifact validation failed.' }

    $rbacNegativeTemplate = Join-Path $TempDir 'main-permanent-owner.json'
    $rbacNegativeJson = Get-Content -LiteralPath $compiledTemplate -Raw | ConvertFrom-Json
    $rbacNegativeJson.resources | Add-Member -NotePropertyName __testPermanentOwner -NotePropertyValue ([pscustomobject]@{
        type = 'Microsoft.Authorization/roleAssignments'
        apiVersion = '2022-04-01'
        name = '00000000-0000-0000-0000-000000000000'
        properties = [pscustomobject]@{
            principalId = "[parameters('governanceAdminsGroupObjectId')]"
            roleDefinitionId = "[subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '8e3af657-a8ff-443c-a75c-2fe8c4bcb635')]"
        }
    }) -Force
    $rbacNegativeJson | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $rbacNegativeTemplate
    $rbacNegativeOutput = & pwsh -NoLogo -NoProfile -File $rbacValidatorPath `
        -CompiledTemplate $rbacNegativeTemplate `
        -CompiledEligibilityTemplate $compiledEligibilityTemplate 2>&1
    if ($LASTEXITCODE -eq 0) {
        Stop-Test 'RBAC validator accepted a compiled permanent Owner assignment.'
    }
    $rbacNegativeMessage = ConvertTo-TestMessage $rbacNegativeOutput
    if ($rbacNegativeMessage -notmatch 'permanent Owner role assignment') {
        Stop-Test "RBAC validator rejected the permanent Owner fixture for the wrong reason: $rbacNegativeMessage"
    }
    $rbacMainRequestTemplate = Join-Path $TempDir 'main-one-shot-request.json'
    $rbacMainRequestJson = Get-Content -LiteralPath $compiledTemplate -Raw | ConvertFrom-Json
    $rbacMainRequestJson.resources | Add-Member -NotePropertyName __testOneShotRequest -NotePropertyValue ([pscustomobject]@{
        type = 'Microsoft.Authorization/roleEligibilityScheduleRequests'
        apiVersion = '2020-10-01'
        name = "[guid(subscription().id, 'reused-request')]"
        condition = $false
        properties = [pscustomobject]@{}
    }) -Force
    $rbacMainRequestJson | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $rbacMainRequestTemplate
    $rbacMainRequestOutput = & pwsh -NoLogo -NoProfile -File $rbacValidatorPath `
        -CompiledTemplate $rbacMainRequestTemplate `
        -CompiledEligibilityTemplate $compiledEligibilityTemplate 2>&1
    if ($LASTEXITCODE -eq 0) {
        Stop-Test 'RBAC validator accepted a one-time eligibility request in the repeatable main template.'
    }
    $rbacMainRequestMessage = ConvertTo-TestMessage $rbacMainRequestOutput
    if ($rbacMainRequestMessage -notmatch 'one-time eligibility schedule request') {
        Stop-Test "RBAC validator rejected the main eligibility fixture for the wrong reason: $rbacMainRequestMessage"
    }
    $rbacOwnerBindingTemplate = Join-Path $TempDir 'main-owner-role-binding.json'
    (Get-Content -LiteralPath $compiledTemplate -Raw).Replace(
        '4d97b98b-1d4f-4787-a291-c67834d212e7',
        '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
    ) | Set-Content -LiteralPath $rbacOwnerBindingTemplate
    $rbacOwnerBindingOutput = & pwsh -NoLogo -NoProfile -File $rbacValidatorPath `
        -CompiledTemplate $rbacOwnerBindingTemplate `
        -CompiledEligibilityTemplate $compiledEligibilityTemplate 2>&1
    if ($LASTEXITCODE -eq 0) {
        Stop-Test 'RBAC validator accepted an Owner role passed through a nested module binding.'
    }
    $rbacOwnerBindingMessage = ConvertTo-TestMessage $rbacOwnerBindingOutput
    if ($rbacOwnerBindingMessage -notmatch 'Owner role definition reference') {
        Stop-Test "RBAC validator rejected the Owner module binding for the wrong reason: $rbacOwnerBindingMessage"
    }

    $rbacExtraResourceTemplate = Join-Path $TempDir 'owner-request-with-deployment-script.json'
    $rbacExtraResourceJson = Get-Content -LiteralPath $compiledEligibilityTemplate -Raw | ConvertFrom-Json
    $rbacExtraResourceJson.resources += [pscustomobject]@{
        type = 'Microsoft.Resources/deploymentScripts'
        apiVersion = '2023-08-01'
        name = 'prohibited-automation'
        properties = [pscustomobject]@{}
    }
    $rbacExtraResourceJson | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $rbacExtraResourceTemplate
    $rbacExtraResourceOutput = & pwsh -NoLogo -NoProfile -File $rbacValidatorPath `
        -CompiledTemplate $compiledTemplate `
        -CompiledEligibilityTemplate $rbacExtraResourceTemplate 2>&1
    if ($LASTEXITCODE -eq 0) {
        Stop-Test 'RBAC validator accepted an extra automation resource in the one-shot artifact.'
    }
    $rbacExtraResourceMessage = ConvertTo-TestMessage $rbacExtraResourceOutput
    if ($rbacExtraResourceMessage -notmatch 'One-shot Owner eligibility artifact') {
        Stop-Test "RBAC validator rejected the one-shot extra resource for the wrong reason: $rbacExtraResourceMessage"
    }
    foreach ($guardName in @('targetScheduleInputIsValid', 'scheduleInputIsValid', 'executionInputsAreValid')) {
        $rbacGuardTemplate = Join-Path $TempDir "owner-request-$guardName-true.json"
        $rbacGuardJson = Get-Content -LiteralPath $compiledEligibilityTemplate -Raw | ConvertFrom-Json
        $rbacGuardJson.variables.$guardName = $true
        $rbacGuardJson | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $rbacGuardTemplate
        $rbacGuardOutput = & pwsh -NoLogo -NoProfile -File $rbacValidatorPath `
            -CompiledTemplate $compiledTemplate `
            -CompiledEligibilityTemplate $rbacGuardTemplate 2>&1
        if ($LASTEXITCODE -eq 0) {
            Stop-Test "RBAC validator accepted $guardName replaced with true."
        }
        $rbacGuardMessage = ConvertTo-TestMessage $rbacGuardOutput
        if ($rbacGuardMessage -notmatch 'compiled input guards') {
            Stop-Test "RBAC validator rejected the $guardName mutation for the wrong reason: $rbacGuardMessage"
        }
    }

    $ownerRequestId = '22222222-2222-4222-8222-222222222222'
    $ownerGroupId = '33333333-3333-4333-8333-333333333333'
    $ownerSubscriptionId = '11111111-1111-4111-8111-111111111111'
    $ownerParameterFile = Join-Path $TempDir 'owner-valid.parameters.json'
    $ownerParameters = Get-Content -LiteralPath (Join-Path $ProjectDir 'identity/azure-rbac/owner-eligibility-request.parameters.template.json') -Raw | ConvertFrom-Json
    $ownerParameters.parameters.submitEligibilityRequest.value = $true
    $ownerParameters.parameters.requestId.value = $ownerRequestId
    $ownerParameters.parameters.subscriptionPrivilegedAccessGroupObjectId.value = $ownerGroupId
    $ownerParameters.parameters.eligibleOwnerAssignmentStartDateTime.value = '2030-01-02T03:04:05Z'
    $ownerParameters.parameters.eligibleOwnerAssignmentJustification.value = 'Approved sandbox Owner eligibility demonstration'
    $ownerParameters | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ownerParameterFile
    $ownerUpdateParameterFile = Join-Path $TempDir 'owner-update.parameters.json'
    $ownerUpdateParameters = $ownerParameters | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $ownerUpdateParameters.parameters.requestType.value = 'AdminUpdate'
    $ownerUpdateParameters.parameters.targetRoleEligibilityScheduleId.value = '55555555-5555-4555-8555-555555555555'
    $ownerUpdateParameters | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ownerUpdateParameterFile

    $ownerOperatorProject = Join-Path $TempDir 'owner-operator-project'
    $ownerOperatorScripts = Join-Path $ownerOperatorProject 'scripts'
    $ownerOperatorIdentity = Join-Path $ownerOperatorProject 'identity/azure-rbac'
    New-Item -ItemType Directory -Path $ownerOperatorScripts, $ownerOperatorIdentity -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $ProjectDir 'scripts/owner-eligibility-request.ps1') -Destination $ownerOperatorScripts
    Copy-Item -LiteralPath (Join-Path $ProjectDir 'identity/azure-rbac/owner-eligibility-request.bicep') -Destination $ownerOperatorIdentity
    $ownerOperatorPath = Join-Path $ownerOperatorScripts 'owner-eligibility-request.ps1'
    $ownerOperatorBicep = Join-Path $ownerOperatorIdentity 'owner-eligibility-request.bicep'

    $ownerAzLog = Join-Path $TempDir 'owner-ps-az-calls.log'
    $ownerTestWrapper = Join-Path $TempDir 'invoke-owner-workflow-with-mock.ps1'
    @'
$ErrorActionPreference = 'Stop'
function global:az {
    $arguments = @($args)
    $global:LASTEXITCODE = 0
    Add-Content -LiteralPath $env:OWNER_AZ_CALL_LOG -Value ($arguments -join ' ')
    if ($arguments[0] -eq 'bicep' -and $arguments[1] -eq 'build') {
        $sourceIndex = [Array]::IndexOf($arguments, '--file')
        $outputIndex = [Array]::IndexOf($arguments, '--outfile')
        [pscustomobject]@{
            compiledSource = Get-Content -LiteralPath $arguments[$sourceIndex + 1] -Raw
        } | ConvertTo-Json -Compress | Set-Content -LiteralPath $arguments[$outputIndex + 1]
        return
    }
    if ($arguments[0] -eq 'account' -and $arguments[1] -eq 'show') {
        [pscustomobject]@{
            id = $env:MOCK_SUBSCRIPTION_ID
            state = 'Enabled'
            tenantId = '44444444-4444-4444-8444-444444444444'
        } | ConvertTo-Json -Compress
        return
    }
    if ($arguments[0] -eq 'ad' -and $arguments[1] -eq 'group' -and $arguments[2] -eq 'show') {
        if (($arguments -join ' ') -cne "ad group show --group $env:MOCK_GROUP_ID --output json") {
            throw "Unsupported arguments passed to az ad group show: $($arguments -join ' ')"
        }
        [pscustomobject]@{
            id = $env:MOCK_GROUP_ID
            securityEnabled = if ($env:MOCK_SECURITY_AS_STRING -eq 'true') {
                'true'
            }
            else {
                $env:MOCK_SECURITY_ENABLED -ne 'false'
            }
        } | ConvertTo-Json -Compress
        return
    }
    if ($arguments[0] -eq 'rest') {
        $urlIndex = [Array]::IndexOf($arguments, '--url')
        $url = [string]$arguments[$urlIndex + 1]
        if ($url.Contains('roleEligibilitySchedules?')) {
            if ($env:MOCK_FALSE_NEXT_LINK -eq 'true') {
                [pscustomobject]@{ value = @(); nextLink = $false } | ConvertTo-Json -Compress
                return
            }
            if ($env:MOCK_ANCESTOR_SCHEDULE -eq 'true') {
                [pscustomobject]@{
                    value = @(
                        [pscustomobject]@{
                            name = '55555555-5555-4555-8555-555555555555'
                            id = '/providers/Microsoft.Management/managementGroups/eslz-parent/providers/Microsoft.Authorization/roleEligibilitySchedules/55555555-5555-4555-8555-555555555555'
                            properties = [pscustomobject]@{
                                scope = '/providers/Microsoft.Management/managementGroups/eslz-parent'
                                principalId = $env:MOCK_GROUP_ID
                                roleDefinitionId = '/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
                            }
                        }
                    )
                } | ConvertTo-Json -Compress -Depth 10
                return
            }
            if ($env:MOCK_EXISTING_SCHEDULE -eq 'true') {
                [pscustomobject]@{
                    value = @(
                        [pscustomobject]@{
                            name = '55555555-5555-4555-8555-555555555555'
                            id = "/subscriptions/$env:MOCK_SUBSCRIPTION_ID/providers/Microsoft.Authorization/roleEligibilitySchedules/55555555-5555-4555-8555-555555555555"
                            properties = [pscustomobject]@{
                                scope = "/subscriptions/$env:MOCK_SUBSCRIPTION_ID"
                                principalId = $env:MOCK_GROUP_ID
                                roleDefinitionId = "/subscriptions/$env:MOCK_SUBSCRIPTION_ID/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635"
                            }
                        }
                    )
                } | ConvertTo-Json -Compress -Depth 10
                return
            }
            [pscustomobject]@{ value = @() } | ConvertTo-Json -Compress
            return
        }
        if ($url.Contains('roleEligibilityScheduleRequests?') -and $url.Contains('page=2') -and $env:MOCK_PAGED_PENDING -eq 'true') {
            [pscustomobject]@{
                value = @(
                    [pscustomobject]@{
                        name = '66666666-6666-4666-8666-666666666666'
                        id = "/subscriptions/$env:MOCK_SUBSCRIPTION_ID/providers/Microsoft.Authorization/roleEligibilityScheduleRequests/66666666-6666-4666-8666-666666666666"
                        properties = [pscustomobject]@{
                            scope = "/subscriptions/$env:MOCK_SUBSCRIPTION_ID"
                            principalId = $env:MOCK_GROUP_ID
                            roleDefinitionId = "/subscriptions/$env:MOCK_SUBSCRIPTION_ID/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635"
                            status = 'PendingApproval'
                        }
                    }
                )
            } | ConvertTo-Json -Compress -Depth 10
            return
        }
        if ($url.Contains('roleEligibilityScheduleRequests?')) {
            if ($env:MOCK_FALSE_REQUEST_NEXT_LINK -eq 'true') {
                [pscustomobject]@{ value = @(); nextLink = $false } | ConvertTo-Json -Compress
                return
            }
            if ($env:MOCK_MALFORMED_REQUESTS -eq 'true') {
                [pscustomobject]@{ value = $false } | ConvertTo-Json -Compress
                return
            }
            if ($env:MOCK_ANCESTOR_PENDING_REQUEST -eq 'true') {
                [pscustomobject]@{
                    value = @(
                        [pscustomobject]@{
                            name = '66666666-6666-4666-8666-666666666666'
                            id = '/providers/Microsoft.Management/managementGroups/eslz-parent/providers/Microsoft.Authorization/roleEligibilityScheduleRequests/66666666-6666-4666-8666-666666666666'
                            properties = [pscustomobject]@{
                                scope = '/providers/Microsoft.Management/managementGroups/eslz-parent'
                                principalId = $env:MOCK_GROUP_ID
                                roleDefinitionId = '/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
                                status = 'PendingApproval'
                            }
                        }
                    )
                } | ConvertTo-Json -Compress -Depth 10
                return
            }
            if (
                $env:MOCK_LIVE_STATE_CHANGE_AFTER_PREVIEW -eq 'true' -and
                (Test-Path -LiteralPath $env:OWNER_MOCK_PHASE_FILE)
            ) {
                [pscustomobject]@{
                    value = @(
                        [pscustomobject]@{
                            name = '66666666-6666-4666-8666-666666666666'
                            id = "/subscriptions/$env:MOCK_SUBSCRIPTION_ID/providers/Microsoft.Authorization/roleEligibilityScheduleRequests/66666666-6666-4666-8666-666666666666"
                            properties = [pscustomobject]@{
                                scope = "/subscriptions/$env:MOCK_SUBSCRIPTION_ID"
                                principalId = $env:MOCK_GROUP_ID
                                roleDefinitionId = "/subscriptions/$env:MOCK_SUBSCRIPTION_ID/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635"
                                status = 'PendingApproval'
                            }
                        }
                    )
                } | ConvertTo-Json -Compress -Depth 10
                return
            }
            if ($env:MOCK_PAGED_PENDING -eq 'true') {
                [pscustomobject]@{
                    value = @()
                    nextLink = "https://management.azure.com/subscriptions/$env:MOCK_SUBSCRIPTION_ID/providers/Microsoft.Authorization/roleEligibilityScheduleRequests?api-version=2020-10-01&%24filter=atScope()&page=2"
                } | ConvertTo-Json -Compress -Depth 10
                return
            }
            [pscustomobject]@{ value = @() } | ConvertTo-Json -Compress
            return
        }
    }
    if ($arguments[0] -eq 'deployment' -and $arguments[1] -eq 'sub' -and $arguments[2] -eq 'what-if') {
        $templateIndex = [Array]::IndexOf($arguments, '--template-file')
        $templatePath = [string]$arguments[$templateIndex + 1]
        $templateHash = (Get-FileHash -LiteralPath $templatePath -Algorithm SHA256).Hash
        Add-Content -LiteralPath $env:OWNER_AZ_CALL_LOG -Value "WHAT_IF_TEMPLATE=$templatePath|$templateHash"
        if ($env:MOCK_MUTATE_SOURCE_AFTER_PREVIEW -eq 'true') {
            Add-Content -LiteralPath $env:MOCK_OPERATOR_BICEP_FILE -Value '// source changed after what-if'
        }
        if (-not [string]::IsNullOrEmpty($env:OWNER_MOCK_PHASE_FILE)) {
            Set-Content -LiteralPath $env:OWNER_MOCK_PHASE_FILE -Value 'post-preview'
        }
        '{"status":"previewed"}'
        return
    }
    if ($arguments[0] -eq 'deployment' -and $arguments[1] -eq 'sub' -and $arguments[2] -eq 'create') {
        $templateIndex = [Array]::IndexOf($arguments, '--template-file')
        $templatePath = [string]$arguments[$templateIndex + 1]
        $templateHash = (Get-FileHash -LiteralPath $templatePath -Algorithm SHA256).Hash
        Add-Content -LiteralPath $env:OWNER_AZ_CALL_LOG -Value "CREATE_TEMPLATE=$templatePath|$templateHash"
        '{"status":"submitted"}'
        return
    }
    throw "Unexpected az arguments: $($arguments -join ' ')"
}

if ($env:OWNER_EXECUTE -eq 'true') {
    & $env:OWNER_OPERATOR_PATH `
        -SubscriptionId $env:MOCK_SUBSCRIPTION_ID `
        -ParameterFile $env:OWNER_PARAMETER_FILE `
        -Execute
}
else {
    & $env:OWNER_OPERATOR_PATH `
        -SubscriptionId $env:MOCK_SUBSCRIPTION_ID `
        -ParameterFile $env:OWNER_PARAMETER_FILE
}
exit $LASTEXITCODE
'@ | Set-Content -LiteralPath $ownerTestWrapper

    New-Item -ItemType File -Path $ownerAzLog -Force | Out-Null
    $env:OWNER_AZ_CALL_LOG = $ownerAzLog
    $env:MOCK_SUBSCRIPTION_ID = $ownerSubscriptionId
    $env:MOCK_GROUP_ID = $ownerGroupId
    $env:MOCK_SECURITY_ENABLED = 'true'
    $env:MOCK_SECURITY_AS_STRING = 'false'
    $env:MOCK_MALFORMED_REQUESTS = 'false'
    $env:MOCK_PAGED_PENDING = 'true'
    $env:MOCK_EXISTING_SCHEDULE = 'false'
    $env:MOCK_ANCESTOR_SCHEDULE = 'false'
    $env:MOCK_ANCESTOR_PENDING_REQUEST = 'false'
    $env:MOCK_FALSE_NEXT_LINK = 'false'
    $env:MOCK_FALSE_REQUEST_NEXT_LINK = 'false'
    $env:MOCK_LIVE_STATE_CHANGE_AFTER_PREVIEW = 'false'
    $env:MOCK_MUTATE_SOURCE_AFTER_PREVIEW = 'false'
    $env:OWNER_EXECUTE = 'false'
    $env:OWNER_OPERATOR_PATH = $ownerOperatorPath
    $env:MOCK_OPERATOR_BICEP_FILE = $ownerOperatorBicep
    $env:OWNER_PARAMETER_FILE = $ownerParameterFile
    $ownerPagedOutput = & pwsh -NoLogo -NoProfile -File $ownerTestWrapper 2>&1
    $ownerPagedExitCode = $LASTEXITCODE
    if ($ownerPagedExitCode -eq 0) {
        Stop-Test 'PowerShell Owner eligibility workflow ignored a pending matching request on a later ARM page.'
    }
    $ownerPagedCalls = Get-Content -LiteralPath $ownerAzLog -Raw
    $ownerPagedMessage = ConvertTo-TestMessage $ownerPagedOutput
    if (
        $ownerPagedCalls -notmatch 'page=2' -or
        $ownerPagedCalls -match 'deployment sub what-if' -or
        $ownerPagedMessage -notmatch 'pending or has an unknown'
    ) {
        Stop-Test "PowerShell Owner eligibility workflow did not fail closed after paginated pending-request inventory. Output: $ownerPagedMessage"
    }

    foreach ($malformedCase in @('string-security-enabled', 'malformed-requests')) {
        New-Item -ItemType File -Path $ownerAzLog -Force | Out-Null
        $env:MOCK_SECURITY_AS_STRING = if ($malformedCase -eq 'string-security-enabled') { 'true' } else { 'false' }
        $env:MOCK_MALFORMED_REQUESTS = if ($malformedCase -eq 'malformed-requests') { 'true' } else { 'false' }
        $malformedOutput = & pwsh -NoLogo -NoProfile -File $ownerTestWrapper 2>&1
        $malformedExitCode = $LASTEXITCODE
        $malformedCalls = Get-Content -LiteralPath $ownerAzLog -Raw
        if ($malformedExitCode -eq 0 -or $malformedCalls -match 'deployment sub what-if') {
            Stop-Test "PowerShell Owner eligibility workflow did not fail closed for $malformedCase. Output: $(ConvertTo-TestMessage $malformedOutput)"
        }
    }

    $env:MOCK_SECURITY_AS_STRING = 'false'
    $env:MOCK_MALFORMED_REQUESTS = 'false'
    $env:MOCK_PAGED_PENDING = 'false'
    foreach ($blockedCase in @('ancestor-schedule', 'ancestor-pending-request', 'false-next-link', 'false-request-next-link')) {
        New-Item -ItemType File -Path $ownerAzLog -Force | Out-Null
        $env:MOCK_ANCESTOR_SCHEDULE = if ($blockedCase -eq 'ancestor-schedule') { 'true' } else { 'false' }
        $env:MOCK_ANCESTOR_PENDING_REQUEST = if ($blockedCase -eq 'ancestor-pending-request') { 'true' } else { 'false' }
        $env:MOCK_FALSE_NEXT_LINK = if ($blockedCase -eq 'false-next-link') { 'true' } else { 'false' }
        $env:MOCK_FALSE_REQUEST_NEXT_LINK = if ($blockedCase -eq 'false-request-next-link') { 'true' } else { 'false' }
        $blockedOutput = & pwsh -NoLogo -NoProfile -File $ownerTestWrapper 2>&1
        $blockedExitCode = $LASTEXITCODE
        $blockedCalls = Get-Content -LiteralPath $ownerAzLog -Raw
        if ($blockedExitCode -eq 0 -or $blockedCalls -match 'deployment sub what-if') {
            Stop-Test "PowerShell Owner eligibility workflow did not fail closed for $blockedCase. Output: $(ConvertTo-TestMessage $blockedOutput)"
        }
    }

    New-Item -ItemType File -Path $ownerAzLog -Force | Out-Null
    $env:MOCK_ANCESTOR_SCHEDULE = 'true'
    $env:MOCK_ANCESTOR_PENDING_REQUEST = 'false'
    $env:MOCK_FALSE_NEXT_LINK = 'false'
    $env:MOCK_FALSE_REQUEST_NEXT_LINK = 'false'
    $env:OWNER_PARAMETER_FILE = $ownerUpdateParameterFile
    $ownerAncestorUpdateOutput = & pwsh -NoLogo -NoProfile -File $ownerTestWrapper 2>&1
    $ownerAncestorUpdateExitCode = $LASTEXITCODE
    $ownerAncestorUpdateCalls = Get-Content -LiteralPath $ownerAzLog -Raw
    if ($ownerAncestorUpdateExitCode -eq 0 -or $ownerAncestorUpdateCalls -match 'deployment sub what-if') {
        Stop-Test "PowerShell AdminUpdate accepted an inherited schedule as its required exact subscription schedule. Output: $(ConvertTo-TestMessage $ownerAncestorUpdateOutput)"
    }

    New-Item -ItemType File -Path $ownerAzLog -Force | Out-Null
    $env:MOCK_ANCESTOR_SCHEDULE = 'false'
    $env:MOCK_ANCESTOR_PENDING_REQUEST = 'true'
    $env:MOCK_EXISTING_SCHEDULE = 'true'
    $ownerExactUpdateOutput = & pwsh -NoLogo -NoProfile -File $ownerTestWrapper 2>&1
    $ownerExactUpdateExitCode = $LASTEXITCODE
    $ownerExactUpdateCalls = Get-Content -LiteralPath $ownerAzLog -Raw
    if ($ownerExactUpdateExitCode -ne 0 -or $ownerExactUpdateCalls -notmatch 'deployment sub what-if') {
        Stop-Test "PowerShell AdminUpdate treated an ancestor request as mutable at the subscription scope. Output: $(ConvertTo-TestMessage $ownerExactUpdateOutput)"
    }

    $ownerPhaseFile = Join-Path $TempDir 'owner-ps-phase'
    Remove-Item -LiteralPath $ownerPhaseFile -Force -ErrorAction SilentlyContinue
    New-Item -ItemType File -Path $ownerAzLog -Force | Out-Null
    $env:MOCK_ANCESTOR_SCHEDULE = 'false'
    $env:MOCK_ANCESTOR_PENDING_REQUEST = 'false'
    $env:MOCK_EXISTING_SCHEDULE = 'false'
    $env:MOCK_FALSE_NEXT_LINK = 'false'
    $env:MOCK_FALSE_REQUEST_NEXT_LINK = 'false'
    $env:OWNER_PARAMETER_FILE = $ownerParameterFile
    $env:MOCK_MUTATE_SOURCE_AFTER_PREVIEW = 'true'
    $env:MOCK_LIVE_STATE_CHANGE_AFTER_PREVIEW = 'false'
    $env:OWNER_MOCK_PHASE_FILE = $ownerPhaseFile
    $env:OWNER_EXECUTE = 'true'
    $env:ESLZ_OWNER_ELIGIBILITY_CONFIRMATION = 'SUBMIT-OWNER-ELIGIBILITY'
    $ownerSnapshotOutput = $ownerRequestId | & pwsh -NoLogo -NoProfile -File $ownerTestWrapper 2>&1
    $ownerSnapshotExitCode = $LASTEXITCODE
    if ($ownerSnapshotExitCode -ne 0) {
        Stop-Test "PowerShell Owner eligibility immutable-snapshot execution failed: $(ConvertTo-TestMessage $ownerSnapshotOutput)"
    }
    $ownerSnapshotCalls = Get-Content -LiteralPath $ownerAzLog
    $whatIfSnapshot = ($ownerSnapshotCalls | Where-Object { $_ -match '^WHAT_IF_TEMPLATE=' } | Select-Object -First 1) -replace '^WHAT_IF_TEMPLATE=', ''
    $createSnapshot = ($ownerSnapshotCalls | Where-Object { $_ -match '^CREATE_TEMPLATE=' } | Select-Object -First 1) -replace '^CREATE_TEMPLATE=', ''
    if ([string]::IsNullOrEmpty($whatIfSnapshot) -or $whatIfSnapshot -cne $createSnapshot) {
        Stop-Test 'PowerShell Owner eligibility create did not reuse the exact immutable template snapshot reviewed by what-if.'
    }
    if ((Get-Content -LiteralPath $ownerOperatorBicep -Raw) -notmatch 'source changed after what-if') {
        Stop-Test 'PowerShell Owner eligibility template-race fixture did not mutate the source Bicep after preview.'
    }

    Copy-Item -LiteralPath (Join-Path $ProjectDir 'identity/azure-rbac/owner-eligibility-request.bicep') -Destination $ownerOperatorBicep -Force
    Remove-Item -LiteralPath $ownerPhaseFile -Force -ErrorAction SilentlyContinue
    New-Item -ItemType File -Path $ownerAzLog -Force | Out-Null
    $env:MOCK_MUTATE_SOURCE_AFTER_PREVIEW = 'false'
    $env:MOCK_LIVE_STATE_CHANGE_AFTER_PREVIEW = 'true'
    $ownerStateRaceOutput = $ownerRequestId | & pwsh -NoLogo -NoProfile -File $ownerTestWrapper 2>&1
    $ownerStateRaceExitCode = $LASTEXITCODE
    $ownerStateRaceCalls = Get-Content -LiteralPath $ownerAzLog -Raw
    if (
        $ownerStateRaceExitCode -eq 0 -or
        $ownerStateRaceCalls -notmatch 'deployment sub what-if' -or
        $ownerStateRaceCalls -match 'deployment sub create'
    ) {
        Stop-Test "PowerShell Owner eligibility workflow did not block create after live state changed during approval. Output: $(ConvertTo-TestMessage $ownerStateRaceOutput)"
    }
    if ([regex]::Matches($ownerStateRaceCalls, 'ad group show').Count -ne 2) {
        Stop-Test 'PowerShell Owner eligibility workflow did not repeat group verification immediately before create.'
    }

    foreach ($environmentName in @(
        'OWNER_AZ_CALL_LOG',
        'OWNER_MOCK_PHASE_FILE',
        'OWNER_EXECUTE',
        'MOCK_SUBSCRIPTION_ID',
        'MOCK_GROUP_ID',
        'MOCK_SECURITY_ENABLED',
        'MOCK_SECURITY_AS_STRING',
        'MOCK_MALFORMED_REQUESTS',
        'MOCK_PAGED_PENDING',
        'MOCK_EXISTING_SCHEDULE',
        'MOCK_ANCESTOR_SCHEDULE',
        'MOCK_ANCESTOR_PENDING_REQUEST',
        'MOCK_FALSE_NEXT_LINK',
        'MOCK_FALSE_REQUEST_NEXT_LINK',
        'MOCK_MUTATE_SOURCE_AFTER_PREVIEW',
        'MOCK_LIVE_STATE_CHANGE_AFTER_PREVIEW',
        'MOCK_OPERATOR_BICEP_FILE',
        'ESLZ_OWNER_ELIGIBILITY_CONFIRMATION',
        'OWNER_OPERATOR_PATH',
        'OWNER_PARAMETER_FILE'
    )) {
        Remove-Item "Env:\$environmentName" -ErrorAction SilentlyContinue
    }

    if ((Get-Content -LiteralPath (Join-Path $ProjectDir 'scripts/deploy.ps1') -Raw) -notmatch 'DEPLOY-ESLZ-DEMO') {
        Stop-Test 'PowerShell deployment confirmation guard is missing.'
    }
    if ((Get-Content -LiteralPath (Join-Path $ProjectDir 'scripts/teardown.ps1') -Raw) -notmatch 'DELETE-ESLZ-DEMO') {
        Stop-Test 'PowerShell teardown confirmation guard is missing.'
    }
    if ((Get-Content -LiteralPath (Join-Path $ProjectDir 'scripts/deploy.sh') -Raw) -notmatch 'DEPLOY-ESLZ-DEMO') {
        Stop-Test 'Bash deployment confirmation guard is missing.'
    }
    if ((Get-Content -LiteralPath (Join-Path $ProjectDir 'scripts/teardown.sh') -Raw) -notmatch 'DELETE-ESLZ-DEMO') {
        Stop-Test 'Bash teardown confirmation guard is missing.'
    }

    Write-Host '8/24 Confirm region policy and workload network guardrails are safe by default...'
    $policyText = Get-Content -LiteralPath (Join-Path $ProjectDir 'modules/policy-library.bicep') -Raw
    foreach ($requiredPolicyText in @(
        "field: 'location'",
        "notEquals: 'global'",
        "notEquals: 'Microsoft.AzureActiveDirectory/b2cDirectories'"
    )) {
        if (-not $policyText.Contains($requiredPolicyText)) {
            Stop-Test "Region policy is missing: $requiredPolicyText"
        }
    }
    if ($parameterTemplate.parameters.networkIngressPolicyEffect.value -ne 'Audit') {
        Stop-Test 'networkIngressPolicyEffect must default to Audit in the JSON parameter template.'
    }
    if ($compiledJson.parameters.networkIngressPolicyEffect.defaultValue -ne 'Audit' -or
        (Compare-Object @($compiledJson.parameters.networkIngressPolicyEffect.allowedValues) @('Audit', 'Deny', 'Disabled'))) {
        Stop-Test 'Compiled networkIngressPolicyEffect must allow Audit, Deny, and Disabled and default to Audit.'
    }

    $policyLibrary = @($compiledJson.resources | Where-Object {
        $_.PSObject.Properties['name'] -and $_.name.StartsWith("[format('policy-library-")
    })
    if ($policyLibrary.Count -ne 1) {
        Stop-Test 'Expected exactly one compiled policy-library deployment.'
    }
    $policyDefinitions = @($policyLibrary[0].properties.template.resources)
    $publicManagementIngress = @($policyDefinitions | Where-Object {
        $_.properties.displayName -eq 'Demo - block public RDP and SSH NSG rules'
    })
    $requireSubnetNsg = @($policyDefinitions | Where-Object {
        $_.properties.displayName -eq 'Demo - require NSGs on workload subnets'
    })
    if ($publicManagementIngress.Count -ne 1 -or $requireSubnetNsg.Count -ne 1) {
        Stop-Test 'Expected exactly one public-management-ingress and one subnet-NSG definition.'
    }
    if ($publicManagementIngress[0].properties.parameters.effect.defaultValue -ne 'Audit' -or
        (Compare-Object @($publicManagementIngress[0].properties.parameters.effect.allowedValues) @('Audit', 'Deny', 'Disabled'))) {
        Stop-Test 'Public-management-ingress effect must allow Audit, Deny, and Disabled and default to Audit.'
    }
    if (Compare-Object @($policyLibrary[0].properties.template.variables.managementPorts) @('22', '3389')) {
        Stop-Test 'Compiled management port list must contain exactly SSH 22 and RDP 3389.'
    }

    $ingressPolicyText = $publicManagementIngress[0].properties.policyRule.if | ConvertTo-Json -Depth 100 -Compress
    foreach ($requiredExpression in @(
        'ipRangeContains(',
        "ipRangeContains('0.0.0.0/0'",
        'int(first(split(',
        'int(last(split(',
        'Microsoft.Network/networkSecurityGroups/securityRules',
        'Microsoft.Network/networkSecurityGroups/securityRules[*]',
        'securityRules/sourceAddressPrefixes[*]',
        'securityRules[*].sourceAddressPrefixes[*]',
        'securityRules/destinationPortRanges[*]',
        'securityRules[*].destinationPortRanges[*]'
    )) {
        if (-not $ingressPolicyText.Contains($requiredExpression)) {
            Stop-Test "Compiled ingress policy is missing semantic expression: $requiredExpression"
        }
    }
    foreach ($expectedOccurrence in @(
        @{ Expression = "ipRangeContains('0.0.0.0/0'"; Count = 4 },
        @{ Expression = "ipRangeContains(current('nonPublicIpv4Range')"; Count = 4 },
        @{ Expression = 'int(first(split('; Count = 4 },
        @{ Expression = 'int(last(split('; Count = 4 }
    )) {
        $actualCount = ([regex]::Matches(
            $ingressPolicyText,
            [regex]::Escape($expectedOccurrence.Expression)
        )).Count
        if ($actualCount -ne $expectedOccurrence.Count) {
            Stop-Test "Compiled ingress policy has $actualCount occurrences of $($expectedOccurrence.Expression); expected $($expectedOccurrence.Count)."
        }
    }
    $subnetPolicyText = $requireSubnetNsg[0].properties.policyRule.if | ConvertTo-Json -Depth 100 -Compress
    foreach ($requiredExpression in @(
        'Microsoft.Network/virtualNetworks/subnets',
        'Microsoft.Network/virtualNetworks',
        'virtualNetworks/subnets[*].networkSecurityGroup.id'
    )) {
        if (-not $subnetPolicyText.Contains($requiredExpression)) {
            Stop-Test "Compiled subnet-NSG policy is missing resource shape: $requiredExpression"
        }
    }

    $networkInitiative = @($compiledJson.resources | Where-Object { $_.name -eq 'network-ingress-initiative' })
    $networkAssignment = @($compiledJson.resources | Where-Object { $_.name -eq 'assign-network-ingress' })
    if ($networkInitiative.Count -ne 1 -or $networkInitiative[0].scope -notmatch 'demoRootManagementGroupId') {
        Stop-Test 'Network ingress initiative must be defined once at the dedicated demo root.'
    }
    $referenceIds = @($networkInitiative[0].properties.parameters.policyDefinitionReferences.value |
        ForEach-Object { $_.policyDefinitionReferenceId } | Sort-Object)
    if (Compare-Object $referenceIds @('public-management-ingress', 'require-subnet-nsg')) {
        Stop-Test 'Network ingress initiative must contain only the two workload-boundary references.'
    }
    if ($networkAssignment.Count -ne 1 -or
        $networkAssignment[0].scope -notmatch 'workloadManagementGroupId' -or
        $networkAssignment[0].scope -match 'platformManagementGroupId') {
        Stop-Test 'Network ingress assignment must target only the selected workload management group.'
    }
    if ($networkAssignment[0].properties.parameters.enforcementMode.value -ne "[parameters('denyPolicyEnforcementMode')]" -or
        $networkAssignment[0].properties.parameters.parameters.value.effect.value -ne "[parameters('networkIngressPolicyEffect')]") {
        Stop-Test 'Network ingress assignment must preserve DoNotEnforce/Audit parameter wiring.'
    }
    if (@($networkAssignment[0].properties.parameters.nonComplianceMessages.value).Count -ne 2) {
        Stop-Test 'Network ingress assignment must provide two targeted noncompliance messages.'
    }
    $messageReferenceIds = @($networkAssignment[0].properties.parameters.nonComplianceMessages.value |
        ForEach-Object { $_.policyDefinitionReferenceId } | Sort-Object)
    if ((Compare-Object $messageReferenceIds @('public-management-ingress', 'require-subnet-nsg')) -or
        @($networkAssignment[0].properties.parameters.nonComplianceMessages.value |
            Where-Object { [string]::IsNullOrEmpty($_.message) }).Count -ne 0) {
        Stop-Test 'Network ingress noncompliance messages must be non-empty and target both initiative references.'
    }
    $rootPublicIpAssignments = @($compiledJson.resources | Where-Object {
        $_.name -eq 'assign-audit-public-ip' -and $_.scope -match 'demoRootManagementGroupId'
    })
    if ($rootPublicIpAssignments.Count -ne 1) {
        Stop-Test 'Expected the existing public-IP audit to remain a single dedicated-root assignment.'
    }

    $privateAccessInitiative = @($compiledJson.resources | Where-Object { $_.name -eq 'private-access-initiative' })
    $privateAccessWorkloadAssignment = @($compiledJson.resources | Where-Object { $_.name -eq 'assign-private-access-workload' })
    $privateAccessCriticalAssignment = @($compiledJson.resources | Where-Object { $_.name -eq 'assign-private-access-critical' })
    $firewallRouteWorkloadAssignment = @($compiledJson.resources | Where-Object { $_.name -eq 'assign-firewall-routes-workload' })
    if ($privateAccessInitiative.Count -ne 1 -or
        (Compare-Object @($privateAccessInitiative[0].properties.parameters.policyDefinitionReferences.value |
            ForEach-Object { $_.policyDefinitionReferenceId } | Sort-Object) @('key-vault-private-link', 'paas-public-network-access', 'storage-private-link')) -or
        $privateAccessInitiative[0].properties.parameters.initiativeParameters.value.publicNetworkAccessEffect.defaultValue -ne 'Audit') {
        Stop-Test 'Private-access initiative must contain the audit-first public-network and private-link references.'
    }
    $privateAccessReferences = @($privateAccessInitiative[0].properties.parameters.policyDefinitionReferences.value)
    if ((@($privateAccessReferences | Where-Object { $_.policyDefinitionReferenceId -eq 'storage-private-link' }).definitionVersion) -ne '2.*.*' -or
        (@($privateAccessReferences | Where-Object { $_.policyDefinitionReferenceId -eq 'key-vault-private-link' }).definitionVersion) -ne '1.*.*') {
        Stop-Test 'Private-link built-in references must be pinned to cataloged major versions.'
    }
    if ($privateAccessWorkloadAssignment.Count -ne 1 -or
        $privateAccessWorkloadAssignment[0].scope -notmatch 'workloadManagementGroupId' -or
        $privateAccessWorkloadAssignment[0].scope -match 'platformManagementGroupId' -or
        $privateAccessCriticalAssignment.Count -ne 1 -or
        $privateAccessCriticalAssignment[0].condition -ne "[parameters('enableCriticalInfrastructure')]" -or
        $privateAccessCriticalAssignment[0].scope -notmatch 'criticalInfrastructureManagementGroupId' -or
        $firewallRouteWorkloadAssignment.Count -ne 1 -or
        $firewallRouteWorkloadAssignment[0].condition -ne "[parameters('enableFirewallRouteGuardrails')]" -or
        $firewallRouteWorkloadAssignment[0].scope -notmatch 'workloadManagementGroupId') {
        Stop-Test 'Private-access and firewall-route assignments must remain workload/critical scoped and opt-in.'
    }
    $routeParameters = $firewallRouteWorkloadAssignment[0].properties.parameters.parameters.value
    if ([string]$routeParameters.approvedFirewallResourceId.value -ne "[parameters('approvedFirewallResourceId')]" -or
        ([string]$compiledJson.variables.validatedFirewallRouteInputs) -notmatch 'fail\(' -or
        ([string]$compiledJson.variables.validatedFirewallRouteInputs) -notmatch 'approvedRouteTablePrefixes') {
        Stop-Test 'Firewall-route assignment must retain approved-firewall evidence and validate all architecture inputs.'
    }
    foreach ($requiredValidationText in @(
        'privateAccessServiceCategories must contain non-empty, uniquely cased Storage and/or KeyVault values',
        'approvedFirewallResourceId must be an Azure Firewall resource ID'
    )) {
        if (-not $mainBicepText.Contains($requiredValidationText)) {
            Stop-Test "Guardrail input validation is missing: $requiredValidationText"
        }
        $inputValidationFixture = Get-Content -LiteralPath (Join-Path $ScriptDir 'fixtures/firewall-route-input-validation-cases.json') -Raw | ConvertFrom-Json
        foreach ($case in $inputValidationFixture.ipv4Cases) {
            $octets = @([string]$case.value -split '\.')
            $valid = $octets.Count -eq 4
            foreach ($octet in $octets) {
                [int]$number = 0
                if ($octet -notmatch '^\d+$' -or -not [int]::TryParse($octet, [ref]$number) -or $number -gt 255) {
                    $valid = $false
                }
            }
            if ($valid -ne $case.valid) {
                Stop-Test "IPv4 validation case failed: $($case.value)"
            }
        }
        foreach ($case in $inputValidationFixture.serviceCategoryCases) {
            $values = @($case.value)
            $valid = ($values.Count -gt 0) -and
                (@($values | Where-Object {
                    -not [string]::Equals($_, 'Storage', [System.StringComparison]::Ordinal) -and
                    -not [string]::Equals($_, 'KeyVault', [System.StringComparison]::Ordinal)
                }).Count -eq 0) -and
                (@($values | Microsoft.PowerShell.Utility\Sort-Object -Unique).Count -eq $values.Count)
            if ($valid -ne $case.valid) {
                Stop-Test "Private-access category validation case failed: $($values -join ',')"
            }
        }
    }
    $firewallRoutePolicy = @($policyDefinitions | Where-Object {
        $_.properties.displayName -eq 'Demo - audit approved firewall route expectations'
    })
    if ($firewallRoutePolicy.Count -ne 1) {
        Stop-Test 'Expected exactly one approved-firewall-routes policy definition.'
    }
    $firewallRoutePolicyText = $firewallRoutePolicy[0].properties.policyRule.if | ConvertTo-Json -Depth 100 -Compress
    foreach ($requiredExpression in @(
        'approvedRouteTablePrefixes',
        "current('approvedRouteTablePrefix')",
        'nextHopType',
        'VirtualAppliance',
        'nextHopIpAddress',
        'approvedFirewallPrivateIp'
    )) {
        if (-not $firewallRoutePolicyText.Contains($requiredExpression)) {
            Stop-Test "Compiled firewall route policy is missing: $requiredExpression"
        }
    }
    $firewallRouteFixture = Get-Content -LiteralPath (Join-Path $ScriptDir 'fixtures/firewall-route-semantic-cases.json') -Raw | ConvertFrom-Json
    foreach ($case in $firewallRouteFixture.cases) {
        $hasApprovedRoute = @($case.routes | Where-Object {
            $_.addressPrefix -eq $firewallRouteFixture.approvedRouteTablePrefix -and
            $_.nextHopType -eq 'VirtualAppliance' -and
            $_.nextHopIpAddress -eq $firewallRouteFixture.approvedFirewallPrivateIp
        }).Count -gt 0
        if ((-not $hasApprovedRoute) -ne $case.expectedNonCompliant) {
            Stop-Test "Firewall route semantic case failed: $($case.name)"
        }
    }

    $semanticFixture = Get-Content -LiteralPath (Join-Path $ScriptDir 'fixtures/network-ingress-semantic-cases.json') -Raw | ConvertFrom-Json
    $compiledNonPublicRanges = @($policyLibrary[0].properties.template.variables.nonPublicIpv4Ranges)
    if (Compare-Object $compiledNonPublicRanges @($semanticFixture.nonPublicIpv4Ranges)) {
        Stop-Test 'Compiled non-public IPv4 ranges differ from the behavioral fixture.'
    }

    function ConvertTo-Ipv4Network {
        param([string]$Value)
        $parts = $Value.Split('/')
        if ($parts.Count -gt 2 -or [string]::IsNullOrEmpty($parts[0])) { return $null }
        $address = $null
        if (-not [System.Net.IPAddress]::TryParse($parts[0], [ref]$address) -or
            $address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
            return $null
        }
        $prefixLength = 32
        if ($parts.Count -eq 2 -and
            (-not [int]::TryParse($parts[1], [ref]$prefixLength) -or $prefixLength -lt 0 -or $prefixLength -gt 32)) {
            return $null
        }
        $bytes = $address.GetAddressBytes()
        [uint64]$value = ([uint64]$bytes[0] -shl 24) -bor ([uint64]$bytes[1] -shl 16) -bor
            ([uint64]$bytes[2] -shl 8) -bor [uint64]$bytes[3]
        [uint64]$mask = if ($prefixLength -eq 0) {
            0
        } else {
            [uint64]4294967295 - (([uint64]1 -shl (32 - $prefixLength)) - 1)
        }
        return [pscustomobject]@{
            Network = $value -band $mask
            PrefixLength = $prefixLength
            Mask = $mask
        }
    }

    $nonPublicNetworks = @($semanticFixture.nonPublicIpv4Ranges | ForEach-Object { ConvertTo-Ipv4Network $_ })
    $supportedServiceTags = @($semanticFixture.supportedServiceTags)
    function Test-PublicIpv4Source {
        param([string]$Value)
        if ($Value -in @('*', 'Internet', '0.0.0.0/0')) { return $true }
        if ([string]::IsNullOrEmpty($Value) -or $Value -in $supportedServiceTags -or [char]::IsLetter($Value[0])) { return $false }
        $source = ConvertTo-Ipv4Network $Value
        if ($null -eq $source) { return $false }
        foreach ($network in $nonPublicNetworks) {
            if ($source.PrefixLength -ge $network.PrefixLength -and
                ($source.Network -band $network.Mask) -eq $network.Network) {
                return $false
            }
        }
        return $true
    }

    function Test-ManagementPortRange {
        param([string]$Value)
        if ($Value -eq '*') { return $true }
        if ($Value -notmatch '^([0-9]{1,5})(?:-([0-9]{1,5}))?$') { return $false }
        $start = [int]$Matches[1]
        $end = if ($Matches[2]) { [int]$Matches[2] } else { $start }
        if ($start -gt $end -or $end -gt 65535) { return $false }
        return (($start -le 22 -and 22 -le $end) -or ($start -le 3389 -and 3389 -le $end))
    }

    $coveredShapes = @{}
    $coveredSourceForms = @{}
    $coveredDestinationForms = @{}
    foreach ($case in $semanticFixture.cases) {
        $sourceForm = if ($case.PSObject.Properties['sourceForm']) { $case.sourceForm } else { 'single' }
        $destinationForm = if ($case.PSObject.Properties['destinationForm']) { $case.destinationForm } else { 'single' }
        $coveredShapes[$case.shape] = $true
        $coveredSourceForms[$sourceForm] = $true
        $coveredDestinationForms[$destinationForm] = $true
        $actual = (
            $case.access -eq 'Allow' -and
            $case.direction -eq 'Inbound' -and
            $case.protocol -in @('Tcp', '*') -and
            @($case.sourcePrefixes | Where-Object { Test-PublicIpv4Source $_ }).Count -gt 0 -and
            @($case.destinationPorts | Where-Object { Test-ManagementPortRange $_ }).Count -gt 0
        )
        if ($actual -ne $case.expectedNonCompliant) {
            Stop-Test "Network ingress semantic case failed: $($case.name) (expected $($case.expectedNonCompliant), got $actual)."
        }
    }
    if (@($coveredShapes.Keys).Count -ne 2 -or
        @($coveredSourceForms.Keys).Count -ne 2 -or
        @($coveredDestinationForms.Keys).Count -ne 2) {
        Stop-Test 'Network ingress fixtures must cover child/inline and singular/plural property forms.'
    }

    Write-Host '9/24 Confirm the Critical Infrastructure branch is opt-in and correctly wired...'
    $hierarchyBicepText = Get-Content -LiteralPath (Join-Path $ProjectDir 'modules/hierarchy.bicep') -Raw
    if ($hierarchyBicepText -notmatch '(?m)^param enableCriticalInfrastructure bool = false$') {
        Stop-Test 'enableCriticalInfrastructure parameter must default to false.'
    }
    if ($hierarchyBicepText -notmatch '(?m)^param criticalInfrastructureSubscriptionIds array = \[\]$') {
        Stop-Test 'criticalInfrastructureSubscriptionIds parameter must default to an empty array.'
    }
    if (-not $hierarchyBicepText.Contains("displayName: 'Critical Infrastructure'")) {
        Stop-Test 'Critical Infrastructure management group display name is missing.'
    }
    if ($compiledJson.parameters.enableCriticalInfrastructure.defaultValue -ne $false) {
        Stop-Test 'Compiled enableCriticalInfrastructure default must be false.'
    }
    if (@($compiledJson.parameters.criticalInfrastructureSubscriptionIds.defaultValue).Count -ne 0) {
        Stop-Test 'Compiled criticalInfrastructureSubscriptionIds default must be empty.'
    }
    $criticalManagementGroups = Find-JsonObjects -Node $compiledJson -Predicate {
        param($node)
        $node.PSObject.Properties['type'] -and $node.type -eq 'Microsoft.Management/managementGroups' -and
        $node.PSObject.Properties['properties'] -and $node.properties.displayName -eq 'Critical Infrastructure' -and
        $node.PSObject.Properties['condition'] -and $node.condition -eq "[parameters('enableCriticalInfrastructure')]" -and
        $node.properties.details.parent.id -match 'landingZonesManagementGroupId'
    }
    if (@($criticalManagementGroups).Count -ne 1) {
        Stop-Test 'Expected exactly one gated Critical Infrastructure management group parented under Landing Zones.'
    }
    $criticalSubscriptions = Find-JsonObjects -Node $compiledJson -Predicate {
        param($node)
        $node.PSObject.Properties['type'] -and $node.type -eq 'Microsoft.Management/managementGroups/subscriptions' -and
        $node.PSObject.Properties['condition'] -and $node.condition -eq "[parameters('enableCriticalInfrastructure')]" -and
        $node.PSObject.Properties['copy'] -and $node.copy.count -eq "[length(parameters('criticalInfrastructureSubscriptionIds'))]"
    }
    if (@($criticalSubscriptions).Count -ne 1) {
        Stop-Test 'Expected the Critical Infrastructure subscription associations to be gated and count-bound to criticalInfrastructureSubscriptionIds.'
    }
    if ($compiledJson.outputs.criticalInfrastructureEnabled.value -ne "[parameters('enableCriticalInfrastructure')]") {
        Stop-Test 'criticalInfrastructureEnabled output is missing or not wired to enableCriticalInfrastructure.'
    }

    Write-Host '10/24 Confirm criticalInfrastructureSubscriptionIds validates duplicates and overlap...'
    if ($hierarchyBicepText -notmatch "fail\('criticalInfrastructureSubscriptionIds must not contain duplicate subscription IDs") {
        Stop-Test 'Missing duplicate-subscription validation for criticalInfrastructureSubscriptionIds.'
    }
    if ($hierarchyBicepText -notmatch "fail\('criticalInfrastructureSubscriptionIds must not overlap with connectivitySubscriptionId or workloadSubscriptionId") {
        Stop-Test 'Missing overlap validation for criticalInfrastructureSubscriptionIds.'
    }
    $criticalInfraValidatedVariables = Find-JsonObjects -Node $compiledJson -Predicate {
        param($node)
        if (-not ($node.PSObject.Properties['type'] -and $node.type -eq 'Microsoft.Resources/deployments')) {
            return $false
        }
        if (-not ($node.PSObject.Properties['properties'] -and $node.properties.PSObject.Properties['template'])) {
            return $false
        }
        if (-not $node.properties.template.PSObject.Properties['variables']) {
            return $false
        }
        $templateVariables = $node.properties.template.variables
        return ($templateVariables.PSObject.Properties['hasDuplicateCriticalInfrastructureSubscriptionIds'] -and
            $templateVariables.PSObject.Properties['criticalInfrastructureSubscriptionIdsOverlapRequiredSubscriptions'] -and
            $templateVariables.PSObject.Properties['criticalInfrastructureManagementGroupIdValidated'] -and
            $templateVariables.criticalInfrastructureManagementGroupIdValidated -match 'fail\(')
    }
    if (@($criticalInfraValidatedVariables).Count -ne 1) {
        Stop-Test 'Expected the hierarchy module to compute duplicate/overlap validation and fail() the deployment when invalid.'
    }

    Write-Host '11/24 Confirm teardown scripts move critical subscriptions and delete the Critical Infrastructure management group before Landing Zones...'
    $teardownShLines = Get-Content -LiteralPath (Join-Path $ProjectDir 'scripts/teardown.sh')
    $criticalSubMoveLineSh = (($teardownShLines | Select-String -Pattern 'management-group subscription add --name "\$\{tenant_root\}" --subscription "\$\{critical_subscription\}"' | Select-Object -First 1).LineNumber)
    $criticalMgDeleteLineSh = (($teardownShLines | Select-String -Pattern 'management-group delete --name "\$\{prefix\}-criticalinfra"' | Select-Object -First 1).LineNumber)
    $landingZonesDeleteLineSh = (($teardownShLines | Select-String -Pattern 'management-group delete --name "\$\{prefix\}-landingzones"' | Select-Object -First 1).LineNumber)
    if (-not $criticalSubMoveLineSh -or -not $criticalMgDeleteLineSh -or -not $landingZonesDeleteLineSh) {
        Stop-Test 'teardown.sh is missing the critical infrastructure subscription move or management group deletion.'
    }
    if (-not ($criticalSubMoveLineSh -lt $criticalMgDeleteLineSh -and $criticalMgDeleteLineSh -lt $landingZonesDeleteLineSh)) {
        Stop-Test 'teardown.sh must move critical infrastructure subscriptions, then delete the Critical Infrastructure management group before Landing Zones.'
    }
    $teardownPs1Lines = Get-Content -LiteralPath (Join-Path $ProjectDir 'scripts/teardown.ps1')
    $criticalSubMoveLinePs1 = (($teardownPs1Lines | Select-String -Pattern 'az account management-group subscription add --name \$tenantRoot --subscription \$criticalSubscription' | Select-Object -First 1).LineNumber)
    $criticalMgDeleteLinePs1 = (($teardownPs1Lines | Select-String -Pattern '\$managementGroups \+= "\$prefix-criticalinfra"' | Select-Object -First 1).LineNumber)
    $landingZonesDeleteLinePs1 = (($teardownPs1Lines | Select-String -Pattern '\$managementGroups \+= "\$prefix-landingzones"' | Select-Object -First 1).LineNumber)
    if (-not $criticalSubMoveLinePs1 -or -not $criticalMgDeleteLinePs1 -or -not $landingZonesDeleteLinePs1) {
        Stop-Test 'teardown.ps1 is missing the critical infrastructure subscription move or management group deletion.'
    }
    if (-not ($criticalSubMoveLinePs1 -lt $criticalMgDeleteLinePs1 -and $criticalMgDeleteLinePs1 -lt $landingZonesDeleteLinePs1)) {
        Stop-Test 'teardown.ps1 must move critical infrastructure subscriptions, then delete the Critical Infrastructure management group before Landing Zones.'
    }

    Write-Host '12/24 Confirm central monitoring defaults create no metered resources...'
    if ($parameterTemplate.parameters.deployCentralLogAnalytics.value -ne $false) {
        Stop-Test 'deployCentralLogAnalytics must default to false.'
    }
    if ($parameterTemplate.parameters.deploySentinel.value -ne $false) {
        Stop-Test 'deploySentinel must default to false.'
    }
    if ($parameterTemplate.parameters.existingLogAnalyticsWorkspaceResourceId.value -ne '') {
        Stop-Test 'existingLogAnalyticsWorkspaceResourceId must default to an empty string.'
    }
    $centralMonitoringText = Get-Content -LiteralPath (Join-Path $ProjectDir 'modules/central-monitoring.bicep') -Raw
    foreach ($requiredText in @(
        'param deployCentralLogAnalytics bool = false',
        'param deploySentinel bool = false',
        "param existingLogAnalyticsWorkspaceResourceId string = ''"
    )) {
        if (-not $centralMonitoringText.Contains($requiredText)) {
            Stop-Test "central-monitoring.bicep is missing safe default: $requiredText"
        }
    }

    Write-Host '13/24 Confirm central monitoring guards against conflicting new/existing workspace inputs and Sentinel-without-workspace...'
    foreach ($requiredText in @(
        'conflictingMonitoringInputs = newWorkspaceRequested && existingWorkspaceSupplied',
        'sentinelRequiresEffectiveWorkspace = deploySentinel && !newWorkspaceRequested && !existingWorkspaceSupplied',
        'createNewWorkspace = newWorkspaceRequested && !hasMonitoringConfigurationError',
        'useExistingWorkspace = existingWorkspaceSupplied && !hasMonitoringConfigurationError'
    )) {
        if (-not $centralMonitoringText.Contains($requiredText)) {
            Stop-Test "central-monitoring.bicep is missing guard logic: $requiredText"
        }
    }

    Write-Host '14/24 Confirm the central monitoring module exposes an effective workspace ID output...'
    if (-not ($centralMonitoringText -match '(?m)^output effectiveLogAnalyticsWorkspaceResourceId string')) {
        Stop-Test 'central-monitoring.bicep is missing the effectiveLogAnalyticsWorkspaceResourceId output.'
    }
    if (-not $mainBicepText.Contains('centralMonitoringEffectiveWorkspaceId string = centralMonitoring.outputs.effectiveLogAnalyticsWorkspaceResourceId')) {
        Stop-Test 'main.bicep is missing the centralMonitoringEffectiveWorkspaceId output.'
    }

    Write-Host '15/24 Confirm invalid central monitoring configurations fail deployment explicitly...'
    foreach ($requiredText in @(
        "resource conflictingMonitoringInputsGuard 'Microsoft.CentralMonitoringGuard/configurationError@",
        'if (conflictingMonitoringInputs)',
        "resource sentinelRequiresWorkspaceGuard 'Microsoft.CentralMonitoringGuard/configurationError@",
        'if (sentinelRequiresEffectiveWorkspace)'
    )) {
        if (-not $centralMonitoringText.Contains($requiredText)) {
            Stop-Test "central-monitoring.bicep is missing configuration-error guard: $requiredText"
        }
    }

    Write-Host '16/24 Confirm teardown scripts protect a supplied existing workspace resource group and only remove a demo-created monitoring resource group...'
    $teardownShText = Get-Content -LiteralPath (Join-Path $ProjectDir 'scripts/teardown.sh') -Raw
    $teardownPs1Text = Get-Content -LiteralPath (Join-Path $ProjectDir 'scripts/teardown.ps1') -Raw
    foreach ($requiredText in @('deployCentralLogAnalytics', 'rg-${prefix}-monitoring', 'existingLogAnalyticsWorkspaceResourceId', 'is_protected_existing_workspace_group', 'monitoring_group_is_repo_owned', 'delete_resource_group_if_not_protected "${connectivity_subscription}" "rg-${prefix}-connectivity"')) {
        if (-not $teardownShText.Contains($requiredText)) {
            Stop-Test "scripts/teardown.sh is missing monitoring teardown safety text: $requiredText"
        }
    }
    foreach ($requiredText in @('deployCentralLogAnalytics', 'centralLogAnalyticsEnabled', 'rg-$prefix-monitoring', 'existingLogAnalyticsWorkspaceResourceId', 'Test-ProtectedExistingWorkspaceGroup', '$existingWorkspaceSupplied = $existingWorkspaceResourceId.Length -gt 0', '$monitoringGroupIsRepoOwned = $centralLogAnalyticsEnabled -and -not $existingWorkspaceSupplied', 'Remove-ResourceGroupIfNotProtected -Subscription $connectivitySubscription -Group $connectivityResourceGroup')) {
        if (-not $teardownPs1Text.Contains($requiredText)) {
            Stop-Test "scripts/teardown.ps1 is missing monitoring teardown safety text: $requiredText"
        }
    }
    if ($teardownPs1Text.Contains('IsNullOrWhiteSpace($existingWorkspaceResourceId)')) {
        Stop-Test 'scripts/teardown.ps1 must not use IsNullOrWhiteSpace on the raw existing workspace resource ID; it must match Bicep/Bash length-based presence semantics so a whitespace-only value is treated as supplied.'
    }

    Write-Host '17/24 Confirm a whitespace-only existing workspace resource ID never triggers deletion of the monitoring resource group...'
    $mockBinDir = Join-Path $TempDir 'mockbin'
    New-Item -ItemType Directory -Path $mockBinDir | Out-Null
    $azCallLog = Join-Path $TempDir 'az_calls_ps1.log'
    $mockAzPath = Join-Path $mockBinDir 'az'
    @'
#!/usr/bin/env bash
echo "$*" >> "${AZ_CALL_LOG}"
if [[ "$1" == 'group' && "$2" == 'exists' ]]; then
  echo 'true'
  exit 0
fi
exit 0
'@ | Set-Content -LiteralPath $mockAzPath -NoNewline
    if (Get-Command chmod -ErrorAction SilentlyContinue) { & chmod +x $mockAzPath }

    # PowerShell command resolution on Windows honors PATHEXT (.cmd, .exe, etc.), so an
    # extensionless mock named "az" is invisible to it there and Get-Command would silently
    # fall through to the real az.cmd on PATH. Provide a Windows-resolvable az.cmd mock with
    # identical logging/behavior so teardown.ps1 (which invokes az directly, not via bash)
    # is exercised against the mock on every platform.
    $mockAzCmdPath = Join-Path $mockBinDir 'az.cmd'
    @'
@echo off
echo %* >> "%AZ_CALL_LOG%"
if /I "%~1"=="group" if /I "%~2"=="exists" (
  echo true
  exit /b 0
)
exit /b 0
'@ | Set-Content -LiteralPath $mockAzCmdPath -NoNewline

    # Wrapper invoked by the nested PowerShell process: verifies az actually resolves to the
    # temporary mock directory (not a real, PATHEXT-resolved az.cmd elsewhere on PATH) before
    # ever calling teardown.ps1, and fails loudly rather than silently running a real teardown.
    $wrapperScript = Join-Path $TempDir 'invoke-teardown-with-mock-check.ps1'
    @'
param(
    [Parameter(Mandatory = $true)][string]$ParameterFile,
    [Parameter(Mandatory = $true)][string]$ExpectedMockDir,
    [Parameter(Mandatory = $true)][string]$TeardownScript
)
$azCommand = Get-Command az -ErrorAction SilentlyContinue
$resolvedSource = if ($azCommand) { $azCommand.Source } else { $null }
if (-not $resolvedSource -or -not $resolvedSource.StartsWith($ExpectedMockDir, [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Error "az resolved to '$resolvedSource' instead of the temporary mock directory '$ExpectedMockDir'."
    exit 1
}
& $TeardownScript $ParameterFile -Execute
'@ | Set-Content -LiteralPath $wrapperScript

    $whitespaceParamFile = Join-Path $TempDir 'whitespace.parameters.json'
    $templateJson = Get-Content -LiteralPath (Join-Path $ProjectDir 'parameters/demo.parameters.template.json') -Raw | ConvertFrom-Json
    $templateJson.parameters.tenantRootManagementGroupId.value = 'mg-root'
    $templateJson.parameters.connectivitySubscriptionId.value = '11111111-1111-1111-1111-111111111111'
    $templateJson.parameters.workloadSubscriptionId.value = '22222222-2222-2222-2222-222222222222'
    $templateJson.parameters.governanceAdminsGroupObjectId.value = '33333333-3333-3333-3333-333333333333'
    $templateJson.parameters.networkOperatorsGroupObjectId.value = '55555555-5555-5555-5555-555555555555'
    $templateJson.parameters.workloadContributorsGroupObjectId.value = '66666666-6666-6666-6666-666666666666'
    $templateJson.parameters.readOnlyAuditorsGroupObjectId.value = '77777777-7777-7777-7777-777777777777'
    $templateJson.parameters.deployCentralLogAnalytics.value = $true
    $templateJson.parameters.existingLogAnalyticsWorkspaceResourceId.value = '   '
    $templateJson | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $whitespaceParamFile

    if (Get-Command bash -ErrorAction SilentlyContinue) {
        if (Test-Path -LiteralPath $azCallLog) { Remove-Item -LiteralPath $azCallLog }
        New-Item -ItemType File -Path $azCallLog | Out-Null
        $originalPath = $env:PATH
        $env:PATH = "$mockBinDir$([System.IO.Path]::PathSeparator)$env:PATH"
        $env:AZ_CALL_LOG = $azCallLog
        $env:ESLZ_TEARDOWN_CONFIRMATION = 'DELETE-ESLZ-DEMO'
        'eslz-demo' | & bash (Join-Path $ProjectDir 'scripts/teardown.sh') $whitespaceParamFile --execute | Out-Null
        $env:PATH = $originalPath
        Remove-Item Env:\AZ_CALL_LOG -ErrorAction SilentlyContinue
        Remove-Item Env:\ESLZ_TEARDOWN_CONFIRMATION -ErrorAction SilentlyContinue
        $azCalls = Get-Content -LiteralPath $azCallLog -Raw
        if ($azCalls -match 'rg-eslz-demo-monitoring') {
            Stop-Test 'teardown.sh must never touch rg-eslz-demo-monitoring when existingLogAnalyticsWorkspaceResourceId is a whitespace-only value (Bicep treats it as supplied).'
        }
    }

    if (Get-Command bash -ErrorAction SilentlyContinue) {
        if (Test-Path -LiteralPath $azCallLog) { Remove-Item -LiteralPath $azCallLog }
        New-Item -ItemType File -Path $azCallLog | Out-Null
        $originalPath = $env:PATH
        $env:PATH = "$mockBinDir$([System.IO.Path]::PathSeparator)$env:PATH"
        $env:AZ_CALL_LOG = $azCallLog
        $env:ESLZ_TEARDOWN_CONFIRMATION = 'DELETE-ESLZ-DEMO'
        $ps1Script = Join-Path $ProjectDir 'scripts/teardown.ps1'
        $nestedOutput = & bash -c "echo 'eslz-demo' | pwsh -NoLogo -NoProfile -File '$wrapperScript' -ParameterFile '$whitespaceParamFile' -ExpectedMockDir '$mockBinDir' -TeardownScript '$ps1Script'" 2>&1
        $nestedExitCode = $LASTEXITCODE
        $env:PATH = $originalPath
        Remove-Item Env:\AZ_CALL_LOG -ErrorAction SilentlyContinue
        Remove-Item Env:\ESLZ_TEARDOWN_CONFIRMATION -ErrorAction SilentlyContinue
        if ($nestedExitCode -ne 0) {
            Stop-Test "teardown.ps1 safety test failed: az did not resolve to the temporary mock directory (or teardown.ps1 failed unexpectedly). Nested output: $nestedOutput"
        }
        $azCalls = Get-Content -LiteralPath $azCallLog -Raw
        if ($azCalls -match 'rg-eslz-demo-monitoring') {
            Stop-Test 'teardown.ps1 must never touch rg-eslz-demo-monitoring when existingLogAnalyticsWorkspaceResourceId is a whitespace-only value (Bicep treats it as supplied).'
        }
    }

    Write-Host '18/24 Parse every PowerShell lifecycle and test script...'
    & (Join-Path $ScriptDir 'validate-tag-policy-migration.ps1')
    $powerShellFiles = @(
        Get-ChildItem (Join-Path $ProjectDir 'scripts') -Filter '*.ps1'
        Get-ChildItem (Join-Path $ProjectDir 'tests') -Filter '*.ps1'
    )
    foreach ($powerShellFile in $powerShellFiles) {
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $powerShellFile.FullName,
            [ref]$tokens,
            [ref]$parseErrors
        )
        if ($parseErrors.Count -gt 0) {
            Stop-Test "PowerShell parse error in $($powerShellFile.Name): $($parseErrors[0].Message)"
        }
    }

    Write-Host '19/24 Validate reusable initiative composition...'
    & (Join-Path $ScriptDir 'validate-initiative-composition.ps1')

    Write-Host '20/24 Validate the v2 control catalog (schema-equivalent checks + matrix consistency)...'
    & (Join-Path $ScriptDir 'validate-control-catalog.ps1')

    Write-Host '21/24 Backend parity and structural-matrix regression tests (bash/python, bash/jq, pwsh/python, pwsh/native)...'
    if (Get-Command bash -ErrorAction SilentlyContinue) {
        & bash (Join-Path $ScriptDir 'uri-grammar-forced-fallback-tests.sh')
        if ($LASTEXITCODE -ne 0) {
            Stop-Test 'tests/uri-grammar-forced-fallback-tests.sh failed.'
        }
    } else {
        Write-Host '  (No bash interpreter found on PATH; relying on tests/test.sh to cover this step.)'
    }

    Write-Host '22/24 Validate Entra Conditional Access and PIM demo artifacts...'
    & (Join-Path $ProjectDir 'scripts/validate-identity-artifacts.ps1')

    Write-Host '23/24 Confirm identity validators reject invalid Conditional Access and PIM inputs...'
    $identitySrcDir = Join-Path $ProjectDir 'identity'
    $identityNegDir = Join-Path $TempDir 'identity-negative'
    $identityPopDir = Join-Path $TempDir 'identity-populated'
    $validatorPath = Join-Path $ProjectDir 'scripts/validate-identity-artifacts.ps1'

    function Set-JsonProperty {
        param([string]$FilePath, [scriptblock]$Mutate)
        $policy = Get-Content -LiteralPath $FilePath -Raw | ConvertFrom-Json
        & $Mutate $policy
        ($policy | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $FilePath
    }

    function Expect-IdentityValidationFailure {
        param([string]$Description, [string[]]$Arguments, [string]$ScriptPath = $validatorPath, [string]$ExpectedMessage)
        # Invoked as a separate pwsh process (rather than "& $ScriptPath
        # @Arguments") so that -Mode/-Path flags stored in $Arguments are
        # parsed as real command-line arguments. PowerShell's array
        # splatting only binds elements positionally when calling a script
        # or function directly - it does not re-parse "-Name" strings held
        # in an array as named parameters, so "-Mode", "populated" would
        # otherwise bind literally to the first positional parameter and
        # fail ValidateSet before any real validation logic ever runs.
        $failed = $false
        $errorText = ''
        $global:LASTEXITCODE = 0
        try {
            $errorText = (& pwsh -NoLogo -NoProfile -File $ScriptPath @Arguments 2>&1 | Out-String)
            if ($LASTEXITCODE -ne 0) { $failed = $true }
        } catch {
            $failed = $true
            $errorText = $_ | Out-String
        }
        if (-not $failed) {
            Stop-Test "validate-identity-artifacts.ps1 unexpectedly succeeded for case: $Description"
        }
        if ($ExpectedMessage) {
            $normalizedErrorText = (($errorText -replace '(?m)^\s*\|\s?', ' ') -replace '\s+', ' ').Trim()
            if ($normalizedErrorText -notlike "*$ExpectedMessage*") {
                Stop-Test "validate-identity-artifacts.ps1 failed for the wrong reason for case: $Description (expected message containing '$ExpectedMessage', got: $errorText)"
            }
        }
    }

    # A fully populated (fake, non-tenant) positive-control copy: every
    # REPLACE_WITH_* placeholder replaced with a syntactically valid GUID.
    # Used both to confirm -Mode populated accepts a genuinely valid input,
    # and as the base for populated-mode negative cases below.
    if (Test-Path -LiteralPath $identityPopDir) { Remove-Item -LiteralPath $identityPopDir -Recurse -Force }
    Copy-Item -LiteralPath $identitySrcDir -Destination $identityPopDir -Recurse
    Get-ChildItem -LiteralPath (Join-Path $identityPopDir 'conditional-access') -Filter '*.template.json' | ForEach-Object {
        Set-JsonProperty -FilePath $_.FullName -Mutate {
            param($policy)
            $policy.emergencyAccessExclusion.placeholder = '11111111-1111-1111-1111-111111111111'
            $policy.conditions.users.excludeGroups = @('11111111-1111-1111-1111-111111111111')
        }
    }
    Get-ChildItem -LiteralPath (Join-Path $identityPopDir 'pim') -Filter '*.template.json' | ForEach-Object {
        Set-JsonProperty -FilePath $_.FullName -Mutate {
            param($policy)
            $policy.emergencyAccessExclusion.placeholder = '22222222-2222-2222-2222-222222222222'
            $policy.activation.approvers = @('33333333-3333-3333-3333-333333333333')
        }
    }
    & $validatorPath -Mode populated -Path $identityPopDir | Out-Null

    # Case: -Mode populated must reject a PIM approver left as an unresolved
    # REPLACE_WITH_* placeholder.
    if (Test-Path -LiteralPath $identityNegDir) { Remove-Item -LiteralPath $identityNegDir -Recurse -Force }
    Copy-Item -LiteralPath $identityPopDir -Destination $identityNegDir -Recurse
    Set-JsonProperty -FilePath (Join-Path $identityNegDir 'pim/pim-activation-global-administrator.template.json') -Mutate {
        param($policy)
        $policy.activation.approvers = @('REPLACE_WITH_PIM_APPROVER_GROUP_OBJECT_ID')
    }
    Expect-IdentityValidationFailure -Description 'unresolved PIM approver placeholder in populated mode' -Arguments @('-Mode', 'populated', '-Path', $identityNegDir)

    # Case: -Mode populated must reject a PIM approver that isn't a valid GUID.
    if (Test-Path -LiteralPath $identityNegDir) { Remove-Item -LiteralPath $identityNegDir -Recurse -Force }
    Copy-Item -LiteralPath $identityPopDir -Destination $identityNegDir -Recurse
    Set-JsonProperty -FilePath (Join-Path $identityNegDir 'pim/pim-activation-global-administrator.template.json') -Mutate {
        param($policy)
        $policy.activation.approvers = @('sales-team')
    }
    Expect-IdentityValidationFailure -Description 'invalid non-GUID PIM approver in populated mode' -Arguments @('-Mode', 'populated', '-Path', $identityNegDir)

    # Case: default (template) mode must reject a PIM approver that is
    # already a populated GUID instead of an unpopulated REPLACE_WITH_*
    # placeholder.
    if (Test-Path -LiteralPath $identityNegDir) { Remove-Item -LiteralPath $identityNegDir -Recurse -Force }
    Copy-Item -LiteralPath $identitySrcDir -Destination $identityNegDir -Recurse
    Set-JsonProperty -FilePath (Join-Path $identityNegDir 'pim/pim-activation-global-administrator.template.json') -Mutate {
        param($policy)
        $policy.activation.approvers = @('44444444-4444-4444-4444-444444444444')
    }
    Expect-IdentityValidationFailure -Description 'populated PIM approver GUID in template mode' -Arguments @('-Path', $identityNegDir)

    # Case: ca-privileged-role-mfa must not accept a broadened includeUsers
    # subject alongside includeRoles.
    if (Test-Path -LiteralPath $identityNegDir) { Remove-Item -LiteralPath $identityNegDir -Recurse -Force }
    Copy-Item -LiteralPath $identitySrcDir -Destination $identityNegDir -Recurse
    Set-JsonProperty -FilePath (Join-Path $identityNegDir 'conditional-access/ca-privileged-role-mfa.template.json') -Mutate {
        param($policy)
        $policy.conditions.users | Add-Member -MemberType NoteProperty -Name 'includeUsers' -Value @('All') -Force
    }
    Expect-IdentityValidationFailure -Description 'broadened includeUsers on privileged-role-mfa' -Arguments @('-Path', $identityNegDir)

    # Case: ca-azure-mgmt-mfa must not accept a broadened 'All' application scope.
    if (Test-Path -LiteralPath $identityNegDir) { Remove-Item -LiteralPath $identityNegDir -Recurse -Force }
    Copy-Item -LiteralPath $identitySrcDir -Destination $identityNegDir -Recurse
    Set-JsonProperty -FilePath (Join-Path $identityNegDir 'conditional-access/ca-azure-mgmt-mfa.template.json') -Mutate {
        param($policy)
        $policy.conditions.applications.includeApplications = @('All')
    }
    Expect-IdentityValidationFailure -Description 'broadened application scope on azure-mgmt-mfa' -Arguments @('-Path', $identityNegDir)

    # Case: ca-block-legacy-auth must not drop a required legacy client type.
    if (Test-Path -LiteralPath $identityNegDir) { Remove-Item -LiteralPath $identityNegDir -Recurse -Force }
    Copy-Item -LiteralPath $identitySrcDir -Destination $identityNegDir -Recurse
    Set-JsonProperty -FilePath (Join-Path $identityNegDir 'conditional-access/ca-block-legacy-auth.template.json') -Mutate {
        param($policy)
        $policy.conditions.clientAppTypes = @('other')
    }
    Expect-IdentityValidationFailure -Description 'missing legacy client type on block-legacy-auth' -Arguments @('-Path', $identityNegDir)

    # Case: ca-privileged-role-mfa must not accept a broadened grant control
    # (a plain 'mfa' builtInControls entry alongside authenticationStrength
    # would let a non-phishing-resistant MFA satisfy an OR-combined policy).
    if (Test-Path -LiteralPath $identityNegDir) { Remove-Item -LiteralPath $identityNegDir -Recurse -Force }
    Copy-Item -LiteralPath $identitySrcDir -Destination $identityNegDir -Recurse
    Set-JsonProperty -FilePath (Join-Path $identityNegDir 'conditional-access/ca-privileged-role-mfa.template.json') -Mutate {
        param($policy)
        $policy.grantControls | Add-Member -MemberType NoteProperty -Name 'builtInControls' -Value @('mfa') -Force
    }
    Expect-IdentityValidationFailure -Description 'broadened grant controls on privileged-role-mfa' -Arguments @('-Path', $identityNegDir)

    # Case: ca-privileged-role-mfa must require the exact set of six
    # privileged directory role template IDs; an extra, unrecognized role
    # must fail.
    if (Test-Path -LiteralPath $identityNegDir) { Remove-Item -LiteralPath $identityNegDir -Recurse -Force }
    Copy-Item -LiteralPath $identitySrcDir -Destination $identityNegDir -Recurse
    Set-JsonProperty -FilePath (Join-Path $identityNegDir 'conditional-access/ca-privileged-role-mfa.template.json') -Mutate {
        param($policy)
        $policy.conditions.users.includeRoles = @($policy.conditions.users.includeRoles) + 'fedcba98-7654-3210-fedc-ba9876543210'
    }
    Expect-IdentityValidationFailure -Description 'extra unrecognized role added to privileged-role-mfa' -Arguments @('-Path', $identityNegDir)

    # Case: ca-privileged-role-mfa must reject a removed (dropped) required role.
    if (Test-Path -LiteralPath $identityNegDir) { Remove-Item -LiteralPath $identityNegDir -Recurse -Force }
    Copy-Item -LiteralPath $identitySrcDir -Destination $identityNegDir -Recurse
    Set-JsonProperty -FilePath (Join-Path $identityNegDir 'conditional-access/ca-privileged-role-mfa.template.json') -Mutate {
        param($policy)
        $policy.conditions.users.includeRoles = @($policy.conditions.users.includeRoles)[0..4]
    }
    Expect-IdentityValidationFailure -Description 'required role removed from privileged-role-mfa' -Arguments @('-Path', $identityNegDir)

    # Case: excludeGroups must equal exactly the declared emergency-access
    # placeholder; an arbitrary extra excluded group must fail.
    if (Test-Path -LiteralPath $identityNegDir) { Remove-Item -LiteralPath $identityNegDir -Recurse -Force }
    Copy-Item -LiteralPath $identitySrcDir -Destination $identityNegDir -Recurse
    Set-JsonProperty -FilePath (Join-Path $identityNegDir 'conditional-access/ca-privileged-role-mfa.template.json') -Mutate {
        param($policy)
        $policy.conditions.users.excludeGroups = @($policy.conditions.users.excludeGroups) + 'REPLACE_WITH_EXTRA_GROUP'
    }
    Expect-IdentityValidationFailure -Description 'arbitrary extra excludeGroups entry' -Arguments @('-Path', $identityNegDir)

    # Case: default (template) mode must reject a PIM
    # emergencyAccessExclusion.placeholder that is already a populated GUID
    # instead of an unpopulated REPLACE_WITH_* placeholder (the PIM schema
    # structurally allows either form; template mode must still narrow it to
    # the placeholder form).
    if (Test-Path -LiteralPath $identityNegDir) { Remove-Item -LiteralPath $identityNegDir -Recurse -Force }
    Copy-Item -LiteralPath $identitySrcDir -Destination $identityNegDir -Recurse
    Set-JsonProperty -FilePath (Join-Path $identityNegDir 'pim/pim-activation-global-administrator.template.json') -Mutate {
        param($policy)
        $policy.emergencyAccessExclusion.placeholder = '44444444-4444-4444-4444-444444444444'
    }
    Expect-IdentityValidationFailure -Description 'populated PIM emergency-access GUID in template mode' -Arguments @('-Path', $identityNegDir)

    # Case: -Mode populated must reject a PIM emergencyAccessExclusion.placeholder
    # left as an unresolved REPLACE_WITH_* placeholder.
    if (Test-Path -LiteralPath $identityNegDir) { Remove-Item -LiteralPath $identityNegDir -Recurse -Force }
    Copy-Item -LiteralPath $identityPopDir -Destination $identityNegDir -Recurse
    Set-JsonProperty -FilePath (Join-Path $identityNegDir 'pim/pim-activation-global-administrator.template.json') -Mutate {
        param($policy)
        $policy.emergencyAccessExclusion.placeholder = 'REPLACE_WITH_EMERGENCY_ACCESS_ACCOUNT_OBJECT_ID'
    }
    Expect-IdentityValidationFailure -Description 'unresolved PIM emergency-access placeholder in populated mode' -Arguments @('-Mode', 'populated', '-Path', $identityNegDir)

    # Case: PIM activation.authenticationContext must be a Graph
    # authenticationContextClassReference id ('c1'..'c25'), not a free-text
    # display name.
    if (Test-Path -LiteralPath $identityNegDir) { Remove-Item -LiteralPath $identityNegDir -Recurse -Force }
    Copy-Item -LiteralPath $identitySrcDir -Destination $identityNegDir -Recurse
    Set-JsonProperty -FilePath (Join-Path $identityNegDir 'pim/pim-activation-global-administrator.template.json') -Mutate {
        param($policy)
        $policy.activation.authenticationContext = 'Phishing-resistant MFA'
    }
    Expect-IdentityValidationFailure -Description 'invalid PIM authenticationContext display name' -Arguments @('-Path', $identityNegDir)

    # Case: every PIM activation.authenticationContext must have a matching,
    # declared Conditional Access policy enforcing that authentication
    # context; removing the enforcing policy (while the PIM template still
    # references it) must fail even though every individual template stays
    # schema-valid.
    if (Test-Path -LiteralPath $identityNegDir) { Remove-Item -LiteralPath $identityNegDir -Recurse -Force }
    Copy-Item -LiteralPath $identitySrcDir -Destination $identityNegDir -Recurse
    Remove-Item -LiteralPath (Join-Path $identityNegDir 'conditional-access/ca-pim-activation-mfa.template.json') -Force
    Expect-IdentityValidationFailure -Description 'PIM authenticationContext with no matching Conditional Access policy' -Arguments @('-Path', $identityNegDir)

    # Case: ca-pim-activation-mfa must declare the exact expected
    # authentication context set; broadening it (even with a duplicate,
    # already-known entry) must fail the exact-match check.
    if (Test-Path -LiteralPath $identityNegDir) { Remove-Item -LiteralPath $identityNegDir -Recurse -Force }
    Copy-Item -LiteralPath $identitySrcDir -Destination $identityNegDir -Recurse
    Set-JsonProperty -FilePath (Join-Path $identityNegDir 'conditional-access/ca-pim-activation-mfa.template.json') -Mutate {
        param($policy)
        $policy.conditions.applications.includeAuthenticationContextClassReferences = @('c1', 'c1')
    }
    Expect-IdentityValidationFailure -Description 'broadened authentication context set on ca-pim-activation-mfa' -Arguments @('-Path', $identityNegDir)

    # Case: ca-pim-activation-mfa must target only
    # includeAuthenticationContextClassReferences; conditions.applications is
    # a mutually exclusive Graph target shape, so re-adding
    # includeApplications alongside it must fail.
    if (Test-Path -LiteralPath $identityNegDir) { Remove-Item -LiteralPath $identityNegDir -Recurse -Force }
    Copy-Item -LiteralPath $identitySrcDir -Destination $identityNegDir -Recurse
    Set-JsonProperty -FilePath (Join-Path $identityNegDir 'conditional-access/ca-pim-activation-mfa.template.json') -Mutate {
        param($policy)
        $policy.conditions.applications | Add-Member -MemberType NoteProperty -Name 'includeApplications' -Value @('All') -Force
    }
    Expect-IdentityValidationFailure -Description 'includeApplications re-added alongside includeAuthenticationContextClassReferences on ca-pim-activation-mfa' -Arguments @('-Path', $identityNegDir)

    # Case: semantic string/enum comparisons must be case-sensitive, matching
    # Microsoft Graph's case-sensitive literals; an uppercased 'ALL' must not
    # be silently accepted as 'All'.
    if (Test-Path -LiteralPath $identityNegDir) { Remove-Item -LiteralPath $identityNegDir -Recurse -Force }
    Copy-Item -LiteralPath $identitySrcDir -Destination $identityNegDir -Recurse
    Set-JsonProperty -FilePath (Join-Path $identityNegDir 'conditional-access/ca-azure-mgmt-mfa.template.json') -Mutate {
        param($policy)
        $policy.conditions.users.includeUsers = @('ALL')
    }
    Expect-IdentityValidationFailure -Description "case-mutated 'ALL' includeUsers value" -Arguments @('-Path', $identityNegDir)

    # Case: an uppercased 'MFA' builtInControls entry must not be silently
    # accepted as the lowercase Graph literal 'mfa'.
    if (Test-Path -LiteralPath $identityNegDir) { Remove-Item -LiteralPath $identityNegDir -Recurse -Force }
    Copy-Item -LiteralPath $identitySrcDir -Destination $identityNegDir -Recurse
    Set-JsonProperty -FilePath (Join-Path $identityNegDir 'conditional-access/ca-azure-mgmt-mfa.template.json') -Mutate {
        param($policy)
        $policy.grantControls.builtInControls = @('MFA')
    }
    Expect-IdentityValidationFailure -Description "case-mutated 'MFA' builtInControls value" -Arguments @('-Path', $identityNegDir)

    # Case: an uppercased 'C1' PIM activation.authenticationContext must not
    # be silently accepted as the lowercase Graph claim value 'c1'.
    if (Test-Path -LiteralPath $identityNegDir) { Remove-Item -LiteralPath $identityNegDir -Recurse -Force }
    Copy-Item -LiteralPath $identitySrcDir -Destination $identityNegDir -Recurse
    Set-JsonProperty -FilePath (Join-Path $identityNegDir 'pim/pim-activation-global-administrator.template.json') -Mutate {
        param($policy)
        $policy.activation.authenticationContext = 'C1'
    }
    Expect-IdentityValidationFailure -Description "case-mutated 'C1' PIM authenticationContext value" -Arguments @('-Path', $identityNegDir)

    # Case: PIM activation.maximumActivationDurationHours must be a true
    # integer from 1 through 8; a fractional value must fail even though it
    # falls within the numeric range.
    if (Test-Path -LiteralPath $identityNegDir) { Remove-Item -LiteralPath $identityNegDir -Recurse -Force }
    Copy-Item -LiteralPath $identitySrcDir -Destination $identityNegDir -Recurse
    Set-JsonProperty -FilePath (Join-Path $identityNegDir 'pim/pim-activation-global-administrator.template.json') -Mutate {
        param($policy)
        $policy.activation.maximumActivationDurationHours = 2.5
    }
    Expect-IdentityValidationFailure -Description 'fractional PIM maximumActivationDurationHours value' -Arguments @('-Path', $identityNegDir)

    # Case: an unknown top-level property must be rejected by the Conditional
    # Access JSON Schema (additionalProperties: false), not just by the
    # hand-picked semantic field checks.
    if (Test-Path -LiteralPath $identityNegDir) { Remove-Item -LiteralPath $identityNegDir -Recurse -Force }
    Copy-Item -LiteralPath $identitySrcDir -Destination $identityNegDir -Recurse
    Set-JsonProperty -FilePath (Join-Path $identityNegDir 'conditional-access/ca-azure-mgmt-mfa.template.json') -Mutate {
        param($policy)
        $policy | Add-Member -MemberType NoteProperty -Name 'unknownField' -Value 'unexpected'
    }
    Expect-IdentityValidationFailure -Description 'unknown top-level property rejected by Conditional Access JSON Schema (additionalProperties: false)' -Arguments @('-Path', $identityNegDir)

    # Case: an unknown property nested under PIM activation must also be
    # rejected by the JSON Schema, proving additionalProperties: false is
    # enforced at nested object levels too, not just the document root.
    if (Test-Path -LiteralPath $identityNegDir) { Remove-Item -LiteralPath $identityNegDir -Recurse -Force }
    Copy-Item -LiteralPath $identitySrcDir -Destination $identityNegDir -Recurse
    Set-JsonProperty -FilePath (Join-Path $identityNegDir 'pim/pim-activation-global-administrator.template.json') -Mutate {
        param($policy)
        $policy.activation | Add-Member -MemberType NoteProperty -Name 'unknownField' -Value 'unexpected'
    }
    Expect-IdentityValidationFailure -Description 'unknown nested property rejected by PIM JSON Schema (additionalProperties: false)' -Arguments @('-Path', $identityNegDir)

    # Case: the JSON Schema's "type": "integer" constraint must reject a
    # string-typed value even when its content parses as a whole number,
    # distinct from the dedicated fractional-value check above (which
    # exercises the manual numeric-range check rather than schema typing).
    if (Test-Path -LiteralPath $identityNegDir) { Remove-Item -LiteralPath $identityNegDir -Recurse -Force }
    Copy-Item -LiteralPath $identitySrcDir -Destination $identityNegDir -Recurse
    Set-JsonProperty -FilePath (Join-Path $identityNegDir 'pim/pim-activation-global-administrator.template.json') -Mutate {
        param($policy)
        $policy.activation.maximumActivationDurationHours = '4'
    }
    Expect-IdentityValidationFailure -Description 'string-typed PIM maximumActivationDurationHours rejected by JSON Schema type: integer' -Arguments @('-Path', $identityNegDir)

    # Case: -Mode populated must reject unnormalized bypass attempts against
    # the tracked identity/ folder guard, even though Resolve-Path already
    # canonicalizes both sides of the comparison.
    Expect-IdentityValidationFailure -Description "populated mode bypass via unnormalized relative './identity' path" -Arguments @('-Mode', 'populated', '-Path', (Join-Path $ProjectDir './identity'))
    Expect-IdentityValidationFailure -Description "populated mode bypass via unnormalized absolute path with a nested '..' segment" -Arguments @('-Mode', 'populated', '-Path', (Join-Path $ProjectDir 'identity/conditional-access/../../identity'))

    # Case: a symbolic link that targets the tracked identity/ folder must
    # also be rejected by the populated-mode guard. Resolve-Path alone only
    # normalizes '.'/'..' segments; it does not dereference a symlink (or,
    # on Windows, a reparse-point junction) to its final filesystem target,
    # so the guard must explicitly walk and resolve every path component.
    # New-Item -ItemType SymbolicLink works without elevation on Linux/macOS;
    # on Windows it requires Administrator privilege or Developer Mode, so
    # this case is skipped there in favor of the junction case below (which
    # requires no elevation on Windows and has no Linux/macOS equivalent).
    if (-not $IsWindows) {
        $identitySymlinkDir = Join-Path $TempDir 'identity-symlink-alias'
        if (Test-Path -LiteralPath $identitySymlinkDir) { Remove-Item -LiteralPath $identitySymlinkDir -Force }
        New-Item -ItemType SymbolicLink -Path $identitySymlinkDir -Target $identitySrcDir | Out-Null
        Expect-IdentityValidationFailure -Description 'populated mode bypass via a symbolic link aliasing the tracked identity/ folder' -Arguments @('-Mode', 'populated', '-Path', $identitySymlinkDir)
        Remove-Item -LiteralPath $identitySymlinkDir -Force

        # Case: a *chained* symlink must also be rejected, where the final
        # link's target path itself contains a further symlinked component
        # (not just the leaf link itself). Resolving only the leaf link and
        # continuing with the original remaining path components is not
        # enough here, since the repo-root component embedded in the target
        # is itself a symlink that must also be dereferenced:
        #   identity-chain-alias -> <repoAliasDir>/identity
        #   <repoAliasDir>        -> <repo root>
        $repoAliasDir = Join-Path $TempDir 'repo-alias'
        if (Test-Path -LiteralPath $repoAliasDir) { Remove-Item -LiteralPath $repoAliasDir -Force }
        New-Item -ItemType SymbolicLink -Path $repoAliasDir -Target $ProjectDir | Out-Null
        $identityChainAliasDir = Join-Path $TempDir 'identity-chain-alias'
        if (Test-Path -LiteralPath $identityChainAliasDir) { Remove-Item -LiteralPath $identityChainAliasDir -Force }
        New-Item -ItemType SymbolicLink -Path $identityChainAliasDir -Target (Join-Path $repoAliasDir 'identity') | Out-Null
        Expect-IdentityValidationFailure -Description 'populated mode bypass via a chained symbolic link whose target path itself contains a further symlinked component' -Arguments @('-Mode', 'populated', '-Path', $identityChainAliasDir)
        Remove-Item -LiteralPath $identityChainAliasDir -Force
        Remove-Item -LiteralPath $repoAliasDir -Force

        # Case: an otherwise-legitimate external -Path root whose
        # conditional-access/ or pim/ subdirectory is itself a symbolic link
        # back into the tracked identity/ folder must be rejected. Checking
        # only the containment of the requested root is not sufficient: the
        # root can resolve outside identity/ while a nested directory
        # constructed beneath it aliases the tracked, unpopulated tree.
        # Each subdirectory is tested in isolation (the other subdirectory
        # is a genuine, non-symlinked copy from $identityPopDir) so that one
        # containment check rejecting first cannot mask another one
        # silently never being exercised. Schema/reference files are always
        # read from the tracked repository's canonical identity/schema/
        # tree, independent of -Path, so there is no schema containment
        # check to bypass -- see the schema-ignored regression below
        # instead.
        function New-IsolatedBypassDir {
            param([string]$TargetDir)
            if (Test-Path -LiteralPath $TargetDir) { Remove-Item -LiteralPath $TargetDir -Recurse -Force }
            Copy-Item -LiteralPath $identityPopDir -Destination $TargetDir -Recurse
        }

        $bypassCaDir = Join-Path $TempDir 'identity-bypass-ca-dir'
        New-IsolatedBypassDir -TargetDir $bypassCaDir
        Remove-Item -LiteralPath (Join-Path $bypassCaDir 'conditional-access') -Recurse -Force
        New-Item -ItemType SymbolicLink -Path (Join-Path $bypassCaDir 'conditional-access') -Target (Join-Path $identitySrcDir 'conditional-access') | Out-Null
        Expect-IdentityValidationFailure -Description 'populated mode bypass via a symbolic link aliasing the tracked conditional-access/ subdirectory (pim/ genuine)' -Arguments @('-Mode', 'populated', '-Path', $bypassCaDir) -ExpectedMessage 'the conditional-access/ directory'
        Remove-Item -LiteralPath $bypassCaDir -Recurse -Force

        $bypassPimDir = Join-Path $TempDir 'identity-bypass-pim-dir'
        New-IsolatedBypassDir -TargetDir $bypassPimDir
        Remove-Item -LiteralPath (Join-Path $bypassPimDir 'pim') -Recurse -Force
        New-Item -ItemType SymbolicLink -Path (Join-Path $bypassPimDir 'pim') -Target (Join-Path $identitySrcDir 'pim') | Out-Null
        Expect-IdentityValidationFailure -Description 'populated mode bypass via a symbolic link aliasing the tracked pim/ subdirectory (conditional-access/ genuine)' -Arguments @('-Mode', 'populated', '-Path', $bypassPimDir) -ExpectedMessage 'the pim/ directory'
        Remove-Item -LiteralPath $bypassPimDir -Recurse -Force

        # Case: an otherwise-legitimate external -Path root with a genuine,
        # external conditional-access/ and pim/ directory, but whose
        # individual files are themselves symbolic links back into the
        # tracked identity/ folder, must also be rejected. Directory-level
        # containment checks alone do not catch a symlinked leaf file. Each
        # artifact type's files are tested in isolation (the other
        # directory's files are genuine, non-symlinked copies), so that
        # Conditional Access's per-file containment check rejecting first
        # cannot mask the PIM per-file check silently never being exercised
        # -- this specifically locks in the fix applying
        # Resolve-FinalTarget/Assert-OutsideTrackedIdentity to every PIM
        # Get-Content call, not just Conditional Access's.
        $bypassCaFileDir = Join-Path $TempDir 'identity-bypass-ca-file'
        New-IsolatedBypassDir -TargetDir $bypassCaFileDir
        Get-ChildItem -LiteralPath (Join-Path $bypassCaFileDir 'conditional-access') -Filter '*.template.json' | ForEach-Object {
            $leafName = $_.Name
            Remove-Item -LiteralPath $_.FullName -Force
            New-Item -ItemType SymbolicLink -Path (Join-Path $bypassCaFileDir "conditional-access/$leafName") -Target (Join-Path $identitySrcDir "conditional-access/$leafName") | Out-Null
        }
        Expect-IdentityValidationFailure -Description 'populated mode bypass via symbolic-link Conditional Access template files (PIM files genuine)' -Arguments @('-Mode', 'populated', '-Path', $bypassCaFileDir) -ExpectedMessage 'outside the tracked identity/ folder'
        Remove-Item -LiteralPath $bypassCaFileDir -Recurse -Force

        $bypassPimFileDir = Join-Path $TempDir 'identity-bypass-pim-file'
        New-IsolatedBypassDir -TargetDir $bypassPimFileDir
        Get-ChildItem -LiteralPath (Join-Path $bypassPimFileDir 'pim') -Filter '*.template.json' | ForEach-Object {
            $leafName = $_.Name
            Remove-Item -LiteralPath $_.FullName -Force
            New-Item -ItemType SymbolicLink -Path (Join-Path $bypassPimFileDir "pim/$leafName") -Target (Join-Path $identitySrcDir "pim/$leafName") | Out-Null
        }
        Expect-IdentityValidationFailure -Description 'populated mode bypass via symbolic-link PIM template files (Conditional Access files genuine)' -Arguments @('-Mode', 'populated', '-Path', $bypassPimFileDir) -ExpectedMessage 'outside the tracked identity/ folder'
        Remove-Item -LiteralPath $bypassPimFileDir -Recurse -Force

        # Case: schema/reference files are always read from the tracked
        # repository's canonical identity/schema/ tree, never from a
        # caller-supplied -Path. A malicious or malformed schema/ directory
        # under an external populated root must therefore be silently
        # ignored rather than read -- validation must still succeed using
        # the tracked schemas.
        $schemaIgnoredDir = Join-Path $TempDir 'identity-schema-ignored'
        New-IsolatedBypassDir -TargetDir $schemaIgnoredDir
        Remove-Item -LiteralPath (Join-Path $schemaIgnoredDir 'schema') -Recurse -Force
        New-Item -ItemType Directory -Path (Join-Path $schemaIgnoredDir 'schema') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $schemaIgnoredDir 'schema/known-entra-ids.json') -Value '{"not":"a real schema"}'
        $global:LASTEXITCODE = 0
        & pwsh -NoLogo -NoProfile -File $validatorPath -Mode populated -Path $schemaIgnoredDir | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Stop-Test "validate-identity-artifacts.ps1 should ignore a caller-supplied schema/ directory and validate successfully using the tracked repository schemas, but it exited with code $LASTEXITCODE."
        }
        Remove-Item -LiteralPath $schemaIgnoredDir -Recurse -Force

        # Case: on a genuinely case-insensitive filesystem (default macOS
        # APFS, exFAT/vfat, some NTFS/SMB mounts), a casing variant of the
        # tracked identity/ folder (e.g. IDENTITY) transparently resolves to
        # the exact same directory with no symlink involved at all.
        # Test-FilesystemCaseInsensitive must detect this by probing the
        # real filesystem rather than assuming case-(in)sensitivity from
        # $IsWindows/$IsMacOS/$IsLinux. Tested here against a loopback-
        # mounted vfat (genuinely case-insensitive) filesystem containing
        # its own copy of the script and identity/ folder, so the resolved
        # project directory itself lives inside the case-insensitive
        # filesystem (mirroring a case-insensitive-volume checkout).
        # Skipped (not failed) if a case-insensitive filesystem cannot be
        # created in this environment (no mkfs.vfat, no root/passwordless
        # sudo, no loop device support), since this exercises real
        # filesystem behavior rather than a mocked assumption.
        $caseInsensitiveImg = Join-Path $TempDir 'case-insensitive-fs.img'
        $caseInsensitiveMnt = Join-Path $TempDir 'case-insensitive-mnt'
        $canMount = $false
        if ((Get-Command mkfs.vfat -ErrorAction SilentlyContinue) -and (Get-Command sudo -ErrorAction SilentlyContinue)) {
            & sudo -n true 2>$null
            $canMount = ($LASTEXITCODE -eq 0)
        }
        if ($canMount) {
            New-Item -ItemType Directory -Path $caseInsensitiveMnt -Force | Out-Null
            & dd if=/dev/zero of=$caseInsensitiveImg bs=1M count=16 2>$null 1>$null
            & mkfs.vfat $caseInsensitiveImg 2>$null 1>$null
            $uid = (& id -u).Trim()
            $gid = (& id -g).Trim()
            & sudo -n mount -o "loop,uid=$uid,gid=$gid" $caseInsensitiveImg $caseInsensitiveMnt 2>$null
            if ($LASTEXITCODE -eq 0) {
                $caseInsensitiveRepo = Join-Path $caseInsensitiveMnt 'repo'
                New-Item -ItemType Directory -Path (Join-Path $caseInsensitiveRepo 'scripts') -Force | Out-Null
                Copy-Item -LiteralPath $validatorPath -Destination (Join-Path $caseInsensitiveRepo 'scripts/validate-identity-artifacts.ps1')
                Copy-Item -LiteralPath $identitySrcDir -Destination (Join-Path $caseInsensitiveRepo 'identity') -Recurse
                $caseVariantMountPath = Join-Path $caseInsensitiveRepo 'IDENTITY'
                Expect-IdentityValidationFailure -Description 'populated mode bypass via a casing variant of the tracked identity/ folder on a genuinely case-insensitive filesystem' -ScriptPath (Join-Path $caseInsensitiveRepo 'scripts/validate-identity-artifacts.ps1') -Arguments @('-Mode', 'populated', '-Path', $caseVariantMountPath) -ExpectedMessage 'must validate the requested -Path outside the tracked identity/ folder'
                # Give the PowerShell child process's file handles on the
                # mount time to close before unmounting, retrying with a
                # lazy unmount as a fallback if the mount is still briefly
                # reported busy.
                [System.GC]::Collect()
                & sudo -n umount $caseInsensitiveMnt 2>$null 1>$null
                if ($LASTEXITCODE -ne 0) {
                    Start-Sleep -Seconds 1
                    & sudo -n umount $caseInsensitiveMnt 2>$null 1>$null
                }
                if ($LASTEXITCODE -ne 0) {
                    & sudo -n umount -l $caseInsensitiveMnt 2>$null 1>$null
                }
            } else {
                Write-Host '  (skipping case-insensitive filesystem test: unable to mount a loopback vfat filesystem in this environment)'
            }
        } else {
            Write-Host '  (skipping case-insensitive filesystem test: mkfs.vfat or passwordless sudo not available in this environment)'
        }
        if (Test-Path -LiteralPath $caseInsensitiveImg) { Remove-Item -LiteralPath $caseInsensitiveImg -Force }

        # Case: -Mode populated with no -Path supplied must still reject the
        # default (tracked identity/) target even when this script itself is
        # invoked through a symlinked repository checkout. The default path
        # must be resolved through Resolve-FinalTarget just like an explicit
        # -Path, or it would retain the unresolved alias while
        # $trackedIdentityDir is fully resolved, letting the two differ and
        # bypass the guard.
        $repoSymlinkDir = Join-Path $TempDir 'repo-symlink-checkout'
        if (Test-Path -LiteralPath $repoSymlinkDir) { Remove-Item -LiteralPath $repoSymlinkDir -Force }
        New-Item -ItemType SymbolicLink -Path $repoSymlinkDir -Target $ProjectDir | Out-Null
        $aliasedValidatorPath = Join-Path $repoSymlinkDir 'scripts/validate-identity-artifacts.ps1'
        Expect-IdentityValidationFailure -Description 'populated mode bypass via omitted -Path when the script is invoked through a symlinked repository checkout' -ScriptPath $aliasedValidatorPath -Arguments @('-Mode', 'populated') -ExpectedMessage 'must validate the requested -Path outside the tracked identity/ folder'
        Remove-Item -LiteralPath $repoSymlinkDir -Force
    } else {
        # Case: a Windows reparse-point junction that targets the tracked
        # identity/ folder must also be rejected. Junctions do not require
        # elevation on Windows, unlike symbolic links.
        $identityJunctionDir = Join-Path $TempDir 'identity-junction-alias'
        if (Test-Path -LiteralPath $identityJunctionDir) { Remove-Item -LiteralPath $identityJunctionDir -Force }
        New-Item -ItemType Junction -Path $identityJunctionDir -Target $identitySrcDir | Out-Null
        Expect-IdentityValidationFailure -Description 'populated mode bypass via a Windows junction aliasing the tracked identity/ folder' -Arguments @('-Mode', 'populated', '-Path', $identityJunctionDir)
        Remove-Item -LiteralPath $identityJunctionDir -Force

        # Case: an otherwise-legitimate external -Path root whose
        # conditional-access/ or pim/ subdirectory is itself a junction back
        # into the tracked identity/ folder must be rejected. Each
        # subdirectory is tested in isolation (the other subdirectory is a
        # genuine, non-symlinked copy from $identityPopDir) so that one
        # containment check rejecting first cannot mask another one
        # silently never being exercised. Schema/reference files are always
        # read from the tracked repository's canonical identity/schema/
        # tree, independent of -Path, so there is no schema containment
        # check to bypass here either.
        $bypassCaJunctionDir = Join-Path $TempDir 'identity-bypass-ca-junction'
        if (Test-Path -LiteralPath $bypassCaJunctionDir) { Remove-Item -LiteralPath $bypassCaJunctionDir -Recurse -Force }
        Copy-Item -LiteralPath $identityPopDir -Destination $bypassCaJunctionDir -Recurse
        Remove-Item -LiteralPath (Join-Path $bypassCaJunctionDir 'conditional-access') -Recurse -Force
        New-Item -ItemType Junction -Path (Join-Path $bypassCaJunctionDir 'conditional-access') -Target (Join-Path $identitySrcDir 'conditional-access') | Out-Null
        Expect-IdentityValidationFailure -Description 'populated mode bypass via a Windows junction aliasing the tracked conditional-access/ subdirectory (pim/ genuine)' -Arguments @('-Mode', 'populated', '-Path', $bypassCaJunctionDir) -ExpectedMessage 'the conditional-access/ directory'
        Remove-Item -LiteralPath $bypassCaJunctionDir -Recurse -Force

        $bypassPimJunctionDir = Join-Path $TempDir 'identity-bypass-pim-junction'
        if (Test-Path -LiteralPath $bypassPimJunctionDir) { Remove-Item -LiteralPath $bypassPimJunctionDir -Recurse -Force }
        Copy-Item -LiteralPath $identityPopDir -Destination $bypassPimJunctionDir -Recurse
        Remove-Item -LiteralPath (Join-Path $bypassPimJunctionDir 'pim') -Recurse -Force
        New-Item -ItemType Junction -Path (Join-Path $bypassPimJunctionDir 'pim') -Target (Join-Path $identitySrcDir 'pim') | Out-Null
        Expect-IdentityValidationFailure -Description 'populated mode bypass via a Windows junction aliasing the tracked pim/ subdirectory (conditional-access/ genuine)' -Arguments @('-Mode', 'populated', '-Path', $bypassPimJunctionDir) -ExpectedMessage 'the pim/ directory'
        Remove-Item -LiteralPath $bypassPimJunctionDir -Recurse -Force

        # Case: Windows drive-letter paths are case-insensitive at the
        # filesystem level, so a casing variant of the tracked identity/
        # folder (or a UNC-style equivalent) must still be treated as the
        # same directory and rejected by the populated-mode guard.
        $caseVariantPath = Join-Path $ProjectDir 'IDENTITY'
        Expect-IdentityValidationFailure -Description 'populated mode bypass via a case-variant of the tracked identity/ folder on a case-insensitive Windows filesystem' -Arguments @('-Mode', 'populated', '-Path', $caseVariantPath)
    }

    # Case: the tracked identity/schema/ tree used above is always resolved
    # relative to the *validator script file's own location* (never the
    # caller-supplied -Path). That location must therefore be derived from
    # the script file's fully resolved final target, not its unresolved
    # invocation path -- otherwise invoking the validator through a
    # symbolic link would silently make an external, permissive
    # identity/schema/ directory placed beside that link into the
    # "trusted" schema root. Both a direct link to the script file and a
    # chained link (a link to a link to the script file) must be fully
    # dereferenced. This uses only file symbolic links (never junctions,
    # which can only target directories, not files), so it is exercised on
    # every platform, including Windows, rather than being scoped to
    # $IsWindows. On Windows, creating a file symbolic link (unlike a
    # directory junction) requires either Administrator privilege or
    # Developer Mode; if the current process lacks that capability, the
    # capability probe below causes this case to be explicitly skipped
    # (not silently omitted) rather than failing for an unrelated reason.
    $canSymlinkFiles = $true
    $symlinkProbeTarget = Join-Path $TempDir 'symlink-capability-probe-target.txt'
    $symlinkProbeLink = Join-Path $TempDir 'symlink-capability-probe-link.txt'
    if (Test-Path -LiteralPath $symlinkProbeLink) { Remove-Item -LiteralPath $symlinkProbeLink -Force }
    if (Test-Path -LiteralPath $symlinkProbeTarget) { Remove-Item -LiteralPath $symlinkProbeTarget -Force }
    Set-Content -LiteralPath $symlinkProbeTarget -Value 'probe'
    try {
        New-Item -ItemType SymbolicLink -Path $symlinkProbeLink -Target $symlinkProbeTarget -ErrorAction Stop | Out-Null
    } catch {
        $canSymlinkFiles = $false
    }
    if (Test-Path -LiteralPath $symlinkProbeLink) { Remove-Item -LiteralPath $symlinkProbeLink -Force }
    Remove-Item -LiteralPath $symlinkProbeTarget -Force

    if ($canSymlinkFiles) {
        $scriptLinkRoot = Join-Path $TempDir 'identity-script-symlink-root'
        if (Test-Path -LiteralPath $scriptLinkRoot) { Remove-Item -LiteralPath $scriptLinkRoot -Recurse -Force }
        New-Item -ItemType Directory -Path (Join-Path $scriptLinkRoot 'identity/schema') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $scriptLinkRoot 'identity/schema/known-entra-ids.json') -Value '{"not":"a real schema"}'
        Set-Content -LiteralPath (Join-Path $scriptLinkRoot 'identity/schema/conditional-access-policy.schema.json') -Value '{"not":"a real schema"}'
        Set-Content -LiteralPath (Join-Path $scriptLinkRoot 'identity/schema/pim-activation-policy.schema.json') -Value '{"not":"a real schema"}'
        $scriptLinkDirect = Join-Path $scriptLinkRoot 'validator-direct.ps1'
        $scriptLinkChained = Join-Path $scriptLinkRoot 'validator-chained.ps1'
        New-Item -ItemType SymbolicLink -Path $scriptLinkDirect -Target $validatorPath | Out-Null
        # The chained link (a link to a link) exercises repeated
        # dereferencing of the resolved target on every platform.
        New-Item -ItemType SymbolicLink -Path $scriptLinkChained -Target $scriptLinkDirect | Out-Null

        foreach ($scriptLink in @($scriptLinkDirect, $scriptLinkChained)) {
            # Positive control: a genuinely valid populated artifact tree
            # must still validate successfully when invoked through the
            # linked script file, proving the canonical (not the
            # permissive external) schema was used.
            $global:LASTEXITCODE = 0
            & pwsh -NoLogo -NoProfile -File $scriptLink -Mode populated -Path $identityPopDir | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Stop-Test "validate-identity-artifacts.ps1 should ignore an external schema/ directory beside a script-file link ($scriptLink) and validate successfully using the tracked repository schemas, but it exited with code $LASTEXITCODE."
            }
        }

        # Negative control: an artifact that is genuinely invalid under
        # the canonical tracked schema must still be rejected -- and for
        # the genuine schema-driven reason -- when invoked through the
        # same script-file links, proving the permissive external schema
        # was not what was loaded.
        $scriptLinkNegDir = Join-Path $TempDir 'identity-script-symlink-neg'
        if (Test-Path -LiteralPath $scriptLinkNegDir) { Remove-Item -LiteralPath $scriptLinkNegDir -Recurse -Force }
        Copy-Item -LiteralPath $identityPopDir -Destination $scriptLinkNegDir -Recurse
        $pimAdminFile = Join-Path $scriptLinkNegDir 'pim/pim-activation-global-administrator.template.json'
        $pimAdminJson = Get-Content -LiteralPath $pimAdminFile -Raw | ConvertFrom-Json
        $pimAdminJson.activation.approvers = @('sales-team')
        $pimAdminJson | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $pimAdminFile

        Expect-IdentityValidationFailure -Description 'invalid PIM approver rejected through a direct script-file link' -Arguments @('-Mode', 'populated', '-Path', $scriptLinkNegDir) -ScriptPath $scriptLinkDirect -ExpectedMessage 'not a match for the indicated regular expression'
        Expect-IdentityValidationFailure -Description 'invalid PIM approver rejected through a chained script-file link' -Arguments @('-Mode', 'populated', '-Path', $scriptLinkNegDir) -ScriptPath $scriptLinkChained -ExpectedMessage 'not a match for the indicated regular expression'

        Remove-Item -LiteralPath $scriptLinkRoot -Recurse -Force
        Remove-Item -LiteralPath $scriptLinkNegDir -Recurse -Force
    } else {
        Write-Host '  (skipping validator script-file link trust-anchor tests: this process lacks file symbolic-link capability (Windows requires Administrator privilege or Developer Mode))'
    }

    if (Test-Path -LiteralPath $identityNegDir) { Remove-Item -LiteralPath $identityNegDir -Recurse -Force }
    if (Test-Path -LiteralPath $identityPopDir) { Remove-Item -LiteralPath $identityPopDir -Recurse -Force }

    Write-Host '24/24 Confirm security benchmark assignments trace to the control catalog and stay optional...'
    $controlCatalog = Get-Content -LiteralPath (Join-Path $ProjectDir 'policy/control-catalog.json') -Raw | ConvertFrom-Json
    $armParameterTemplate = Get-Content -LiteralPath (Join-Path $ProjectDir 'parameters/demo.parameters.template.json') -Raw | ConvertFrom-Json
    $benchmarkAssignments = @(
        @{
            DeploymentName = 'assign-mcsb-baseline'
            ControlId      = 'REQ-BASE-01'
            VariableName   = 'microsoftCloudSecurityBenchmarkPolicySetDefinitionId'
            ParameterName  = 'enableMicrosoftCloudSecurityBenchmark'
            DefaultEnabled = $true
        },
        @{
            DeploymentName = 'assign-cis-foundations'
            ControlId      = 'REQ-BASE-02'
            VariableName   = 'cisAzureFoundationsPolicySetDefinitionId'
            ParameterName  = 'enableCisAzureFoundationsBenchmark'
            DefaultEnabled = $false
        },
        @{
            DeploymentName = 'assign-nist-sp-800-53-r5'
            ControlId      = 'REQ-BASE-03'
            VariableName   = 'nistSp80053Rev5PolicySetDefinitionId'
            ParameterName  = 'enableNistSp80053Rev5'
            DefaultEnabled = $false
        }
    )
    foreach ($benchmark in $benchmarkAssignments) {
        $control = $controlCatalog.controls | Where-Object { $_.id -eq $benchmark.ControlId } | Select-Object -First 1
        if (-not $control) { Stop-Test "Control catalog is missing $($benchmark.ControlId)." }
        $deployment = Find-JsonObjects -Node $compiledJson -Predicate {
            param($node)
            $node.PSObject.Properties['type'] -and $node.type -eq 'Microsoft.Resources/deployments' -and
            $node.PSObject.Properties['name'] -and $node.name -eq $benchmark.DeploymentName
        } | Select-Object -First 1
        if (-not $deployment) { Stop-Test "Missing benchmark assignment deployment $($benchmark.DeploymentName)." }
        if ($compiledJson.parameters.($benchmark.ParameterName).defaultValue -ne $benchmark.DefaultEnabled) {
            Stop-Test "$($benchmark.ParameterName) must default to $($benchmark.DefaultEnabled)."
        }
        if ($armParameterTemplate.parameters.($benchmark.ParameterName).value -ne $benchmark.DefaultEnabled) {
            Stop-Test "$($benchmark.ParameterName) must be $($benchmark.DefaultEnabled) in the ARM parameter template."
        }
        if ($deployment.condition -ne "[parameters('$($benchmark.ParameterName)')]") {
            Stop-Test "$($benchmark.DeploymentName) must be gated by $($benchmark.ParameterName)."
        }
        if ($deployment.scope -notmatch 'demoRootManagementGroupId') {
            Stop-Test "$($benchmark.DeploymentName) must be assigned at the dedicated demo root."
        }
        $expectedDefinitionId = "[tenantResourceId('Microsoft.Authorization/policySetDefinitions', '$($control.mechanism.definitionId)')]"
        if ($compiledJson.variables.($benchmark.VariableName) -ne $expectedDefinitionId) {
            Stop-Test "$($benchmark.VariableName) must match the verified $($benchmark.ControlId) initiative ID."
        }
        if ($deployment.properties.parameters.policyDefinitionId.value -ne "[variables('$($benchmark.VariableName)')]") {
            Stop-Test "$($benchmark.DeploymentName) must assign the catalog-verified initiative."
        }
        if ($deployment.properties.parameters.definitionVersion.value -ne "$($control.mechanism.majorVersion).*.*") {
            Stop-Test "$($benchmark.DeploymentName) must pin the supported major version from the control catalog."
        }
        if ($deployment.properties.parameters.enforcementMode.value -ne "[parameters('denyPolicyEnforcementMode')]") {
            Stop-Test "$($benchmark.DeploymentName) must use the safe non-enforcing enforcement mode parameter."
        }
    }
    foreach ($auditOnlyDeploymentName in @('assign-mcsb-baseline', 'assign-cis-foundations')) {
        $auditOnlyDeployment = Find-JsonObjects -Node $compiledJson -Predicate {
            param($node)
            $node.PSObject.Properties['type'] -and $node.type -eq 'Microsoft.Resources/deployments' -and
            $node.PSObject.Properties['name'] -and $node.name -eq $auditOnlyDeploymentName
        } | Select-Object -First 1
        $identityAssignments = @($auditOnlyDeployment.properties.template.resources.PSObject.Properties.Value |
            Where-Object { $_.type -eq 'Microsoft.Authorization/policyAssignments' -and $_.PSObject.Properties['identity'] })
        if ($identityAssignments.Count -ne 0) {
            Stop-Test "$auditOnlyDeploymentName must not request a managed identity for an audit-only benchmark."
        }
    }
    $nistDeployment = Find-JsonObjects -Node $compiledJson -Predicate {
        param($node)
        $node.PSObject.Properties['type'] -and $node.type -eq 'Microsoft.Resources/deployments' -and
        $node.PSObject.Properties['name'] -and $node.name -eq 'assign-nist-sp-800-53-r5'
    } | Select-Object -First 1
    if ($nistDeployment.properties.parameters.identity.value.type -ne 'SystemAssigned') {
        Stop-Test 'The NIST overlay must use a system-assigned identity for its fixed remediation members.'
    }
    $nistControl = $controlCatalog.controls | Where-Object { $_.id -eq 'REQ-BASE-03' } | Select-Object -First 1
    if (Compare-Object @("[variables('contributorRoleDefinitionId')]") @($nistDeployment.properties.parameters.verifiedRoleDefinitionIds.value)) {
        Stop-Test 'The NIST overlay must grant only the catalog-verified role.'
    }
    if ($compiledJson.variables.contributorRoleDefinitionId -ne @($nistControl.roleDefinitionIds)[0]) {
        Stop-Test 'contributorRoleDefinitionId must match the verified REQ-BASE-03 role definition ID.'
    }
    $benchmarkOutput = $compiledJson.outputs.securityBenchmarkAssignments.value
    if ($benchmarkOutput.microsoftCloudSecurityBenchmark -ne "[parameters('enableMicrosoftCloudSecurityBenchmark')]" -or
        $benchmarkOutput.cisAzureFoundationsBenchmark -ne "[parameters('enableCisAzureFoundationsBenchmark')]" -or
        $benchmarkOutput.nistSp80053Rev5 -ne "[parameters('enableNistSp80053Rev5')]") {
        Stop-Test 'securityBenchmarkAssignments output must report every benchmark switch.'
    }
    Write-Host '    Confirm preview or superseded benchmark initiatives are never selected...'
    $bicepSourceText = (Get-ChildItem -LiteralPath $ProjectDir -Recurse -Include '*.bicep', '*.bicepparam' -File |
        Where-Object { $_.FullName -notmatch '\.test-artifacts' } |
        ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
    foreach ($previewDefinitionId in @(
        'e3ec7e09-768c-4b64-882c-fcada3772047',
        '60205a79-6280-4e20-a147-e2011e09dc78',
        'c3f5c4d9-9a1d-4a99-85c0-7f93e384d5c5'
    )) {
        if ($bicepSourceText.Contains($previewDefinitionId)) {
            Stop-Test "Preview or superseded benchmark initiative $previewDefinitionId must never be assigned."
        }
    }
    if ($bicepSourceText -match '(?i)azure security baseline') {
        Stop-Test 'Do not create a duplicate "Azure Security Baseline" initiative; per-service baselines are guidance only.'
    }
    Write-Host '    Confirm every enabled/disabled benchmark combination compiles with the expected assignments...'
    $benchmarkParameterTemplateText = Get-Content -LiteralPath (Join-Path $ProjectDir 'parameters/main.template.bicepparam') -Raw
    foreach ($benchmarkCase in @(
        @($true, $false, $false),
        @($false, $false, $false),
        @($true, $true, $true),
        @($false, $true, $false),
        @($false, $false, $true)
    )) {
        $caseValues = $benchmarkCase | ForEach-Object { $_.ToString().ToLowerInvariant() }
        $caseParametersPath = Join-Path $TempDir ("benchmark-" + ($caseValues -join '-') + '.bicepparam')
        $caseText = $benchmarkParameterTemplateText `
            -replace "(?m)^using '\.\./main\.bicep'$", "using '../../main.bicep'" `
            -replace '(?m)^param enableMicrosoftCloudSecurityBenchmark = .*$', "param enableMicrosoftCloudSecurityBenchmark = $($caseValues[0])" `
            -replace '(?m)^param enableCisAzureFoundationsBenchmark = .*$', "param enableCisAzureFoundationsBenchmark = $($caseValues[1])" `
            -replace '(?m)^param enableNistSp80053Rev5 = .*$', "param enableNistSp80053Rev5 = $($caseValues[2])"
        Set-Content -LiteralPath $caseParametersPath -Value $caseText
        & az bicep build-params --file $caseParametersPath --outfile "$caseParametersPath.json"
        if ($LASTEXITCODE -ne 0) { Stop-Test "Benchmark combination $($caseValues -join ',') failed to compile." }
        $caseParameters = Get-Content -LiteralPath "$caseParametersPath.json" -Raw | ConvertFrom-Json
        if ($caseParameters.parameters.enableMicrosoftCloudSecurityBenchmark.value -ne $benchmarkCase[0] -or
            $caseParameters.parameters.enableCisAzureFoundationsBenchmark.value -ne $benchmarkCase[1] -or
            $caseParameters.parameters.enableNistSp80053Rev5.value -ne $benchmarkCase[2]) {
            Stop-Test "Benchmark combination $($caseValues -join ',') did not compile to the expected parameter values."
        }
    }

    Write-Host '25/25 Confirm logging assignments use the verified workspace/identity/effect model at the demo root...'
    if (-not (Select-String -Path (Join-Path $ProjectDir 'main.bicep') -Pattern 'func hasCanonicalArmIdSegments' -Quiet) -or
        -not (Select-String -Path (Join-Path $ProjectDir 'main.bicep') -Pattern 'func isCanonicalNameSegment' -Quiet) -or
        -not (Select-String -Path (Join-Path $ProjectDir 'main.bicep') -Pattern 'func isWorkspaceResourceId\(value string\) bool => length\(split\(value, ''/''\)\) == 9 && hasCanonicalArmIdSegments\(value\)' -Quiet)) {
        Stop-Test 'Workspace resource ID validation must require a canonical absolute ARM ID and canonical segment names.'
    }
    $logActivityControl = $controlCatalog.controls | Where-Object { $_.id -eq 'REQ-LOG-01' } | Select-Object -First 1
    $logDiagnosticsControl = $controlCatalog.controls | Where-Object { $_.id -eq 'REQ-LOG-02' } | Select-Object -First 1
    if (-not $logActivityControl -or -not $logDiagnosticsControl) {
        Stop-Test 'Control catalog is missing REQ-LOG-01 and/or REQ-LOG-02.'
    }
    if ($compiledJson.parameters.activityLogExportPolicyEffect.defaultValue -ne 'Disabled' -or
        $compiledJson.parameters.activityLogExportLogsEnabled.defaultValue -ne 'True' -or
        $compiledJson.parameters.resourceDiagnosticsPolicyEffect.defaultValue -ne 'AuditIfNotExists' -or
        $compiledJson.parameters.resourceDiagnosticsCategoryGroup.defaultValue -ne 'audit' -or
        $compiledJson.parameters.deployLoggingRemediationRoleAssignments.defaultValue -ne $false) {
        Stop-Test 'Logging policy parameters must keep safe defaults (Disabled / AuditIfNotExists / audit).'
    }
    if ($armParameterTemplate.parameters.activityLogExportPolicyEffect.value -ne 'Disabled' -or
        $armParameterTemplate.parameters.activityLogExportLogsEnabled.value -ne 'True' -or
        $armParameterTemplate.parameters.resourceDiagnosticsPolicyEffect.value -ne 'AuditIfNotExists' -or
        $armParameterTemplate.parameters.resourceDiagnosticsCategoryGroup.value -ne 'audit' -or
        $armParameterTemplate.parameters.deployLoggingRemediationRoleAssignments.value -ne $false) {
        Stop-Test 'ARM parameter template logging defaults must match the safe baseline values.'
    }
    $expectedActivityDefinitionId = "[tenantResourceId('Microsoft.Authorization/policyDefinitions', '$($logActivityControl.mechanism.definitionId)')]"
    $expectedDiagnosticsAllLogsDefinitionId = "[tenantResourceId('Microsoft.Authorization/policySetDefinitions', '$($logDiagnosticsControl.mechanism.definitionId)')]"
    if ($compiledJson.variables.activityLogExportPolicyDefinitionId -ne $expectedActivityDefinitionId) {
        Stop-Test 'activityLogExportPolicyDefinitionId must match the verified REQ-LOG-01 built-in.'
    }
    if ($compiledJson.variables.resourceDiagnosticsAllLogsPolicySetDefinitionId -ne $expectedDiagnosticsAllLogsDefinitionId) {
        Stop-Test 'resourceDiagnosticsAllLogsPolicySetDefinitionId must match the verified REQ-LOG-02 built-in.'
    }
    if ($compiledJson.variables.resourceDiagnosticsAuditPolicySetDefinitionId -ne "[tenantResourceId('Microsoft.Authorization/policySetDefinitions', 'f5b29bc4-feca-4cc6-a58a-772dd5e290a5')]") {
        Stop-Test 'resourceDiagnosticsAuditPolicySetDefinitionId must match the verified audit-category initiative ID.'
    }
    if ($compiledJson.variables.resourceDiagnosticsPolicySetDefinitionId -ne "[if(equals(parameters('resourceDiagnosticsCategoryGroup'), 'allLogs'), variables('resourceDiagnosticsAllLogsPolicySetDefinitionId'), variables('resourceDiagnosticsAuditPolicySetDefinitionId'))]") {
        Stop-Test 'resourceDiagnosticsCategoryGroup must explicitly choose audit or allLogs built-in initiative IDs.'
    }
    if ($compiledJson.variables.loggingWorkspaceSubscriptionId -ne "[if(parameters('deployCentralLogAnalytics'), parameters('connectivitySubscriptionId'), variables('existingWorkspaceResourceIdParts')[2])]" -or
        $compiledJson.variables.loggingWorkspaceResourceGroupName -ne "[if(parameters('deployCentralLogAnalytics'), format('rg-{0}-monitoring', parameters('namePrefix')), variables('existingWorkspaceResourceIdParts')[4])]" -or
        $compiledJson.variables.loggingWorkspaceName -ne "[if(parameters('deployCentralLogAnalytics'), format('log-{0}-central', parameters('namePrefix')), variables('existingWorkspaceResourceIdParts')[8])]") {
        Stop-Test 'Logging destination workspace scope/name variables are not correctly wired for new-vs-existing workspace paths.'
    }
    if ($compiledJson.variables.monitoringContributorRoleDefinitionId -ne @($logActivityControl.roleDefinitionIds)[0] -or
        $compiledJson.variables.logAnalyticsContributorRoleDefinitionId -ne @($logDiagnosticsControl.roleDefinitionIds)[0]) {
        Stop-Test 'Logging remediation role variables must match the verified control-catalog roleDefinitionIds.'
    }
    $activityDeployment = Find-JsonObjects -Node $compiledJson -Predicate {
        param($node)
        $node.PSObject.Properties['type'] -and $node.type -eq 'Microsoft.Resources/deployments' -and
        $node.PSObject.Properties['name'] -and $node.name -eq 'assign-activity-logs'
    } | Select-Object -First 1
    $activityRemediatingDeployment = Find-JsonObjects -Node $compiledJson -Predicate {
        param($node)
        $node.PSObject.Properties['type'] -and $node.type -eq 'Microsoft.Resources/deployments' -and
        $node.PSObject.Properties['name'] -and $node.name -eq 'assign-activity-logs-remediating'
    } | Select-Object -First 1
    $diagnosticsDeployment = Find-JsonObjects -Node $compiledJson -Predicate {
        param($node)
        $node.PSObject.Properties['type'] -and $node.type -eq 'Microsoft.Resources/deployments' -and
        $node.PSObject.Properties['name'] -and $node.name -eq 'assign-resource-diagnostics'
    } | Select-Object -First 1
    $diagnosticsRemediatingDeployment = Find-JsonObjects -Node $compiledJson -Predicate {
        param($node)
        $node.PSObject.Properties['type'] -and $node.type -eq 'Microsoft.Resources/deployments' -and
        $node.PSObject.Properties['name'] -and $node.name -eq 'assign-resource-diagnostics-remediating'
    } | Select-Object -First 1
    $activityWorkspaceRbacDeployment = Find-JsonObjects -Node $compiledJson -Predicate {
        param($node)
        $node.PSObject.Properties['type'] -and $node.type -eq 'Microsoft.Resources/deployments' -and
        $node.PSObject.Properties['name'] -and $node.name -eq 'activity-log-workspace-destination-rbac'
    } | Select-Object -First 1
    $diagnosticsWorkspaceRbacDeployment = Find-JsonObjects -Node $compiledJson -Predicate {
        param($node)
        $node.PSObject.Properties['type'] -and $node.type -eq 'Microsoft.Resources/deployments' -and
        $node.PSObject.Properties['name'] -and $node.name -eq 'resource-diagnostics-workspace-destination-rbac'
    } | Select-Object -First 1
    if (-not $activityDeployment -or -not $activityRemediatingDeployment -or -not $diagnosticsDeployment -or -not $diagnosticsRemediatingDeployment) {
        Stop-Test 'Missing one or more logging assignment deployments (non-remediating/remediating).'
    }
    if (-not $activityWorkspaceRbacDeployment -or -not $diagnosticsWorkspaceRbacDeployment) {
        Stop-Test 'Missing workspace-scoped destination RBAC deployment for one or both logging assignments.'
    }
    foreach ($loggingDeployment in @($activityDeployment, $activityRemediatingDeployment, $diagnosticsDeployment, $diagnosticsRemediatingDeployment)) {
        if ($loggingDeployment.scope -notmatch 'demoRootManagementGroupId') {
            Stop-Test "$($loggingDeployment.name) must be assigned at the dedicated demo root."
        }
        if ($loggingDeployment.properties.parameters.enforcementMode.value -ne "[parameters('denyPolicyEnforcementMode')]") {
            Stop-Test "$($loggingDeployment.name) must use denyPolicyEnforcementMode."
        }
    }
    if ($compiledJson.variables.activityLogRemediationDeployRequested -ne "[equals(parameters('activityLogExportPolicyEffect'), 'DeployIfNotExists')]" -or
        $compiledJson.variables.resourceDiagnosticsRemediationDeployRequested -ne "[equals(parameters('resourceDiagnosticsPolicyEffect'), 'DeployIfNotExists')]") {
        Stop-Test 'Logging identity/remediation switching variables must be derived from DeployIfNotExists effects only.'
    }
    if ($activityDeployment.condition -ne "[not(variables('activityLogRemediationDeployRequested'))]" -or
        $activityRemediatingDeployment.condition -ne "[variables('activityLogRemediationDeployRequested')]" -or
        $diagnosticsDeployment.condition -ne "[not(variables('resourceDiagnosticsRemediationDeployRequested'))]" -or
        $diagnosticsRemediatingDeployment.condition -ne "[variables('resourceDiagnosticsRemediationDeployRequested')]") {
        Stop-Test 'Logging assignment deployments must switch between identity-free and remediating forms based on effect.'
    }
    if ($activityDeployment.properties.parameters.PSObject.Properties['location'] -or
        $activityDeployment.properties.parameters.PSObject.Properties['identity'] -or
        $activityDeployment.properties.parameters.PSObject.Properties['verifiedRoleDefinitionIds'] -or
        $activityDeployment.properties.parameters.PSObject.Properties['deployRemediationRoleAssignments'] -or
        $diagnosticsDeployment.properties.parameters.PSObject.Properties['location'] -or
        $diagnosticsDeployment.properties.parameters.PSObject.Properties['identity'] -or
        $diagnosticsDeployment.properties.parameters.PSObject.Properties['verifiedRoleDefinitionIds'] -or
        $diagnosticsDeployment.properties.parameters.PSObject.Properties['deployRemediationRoleAssignments']) {
        Stop-Test 'Disabled/Audit logging assignments must remain identity-free and non-remediating.'
    }
    foreach ($remediatingDeployment in @($activityRemediatingDeployment, $diagnosticsRemediatingDeployment)) {
        if ($remediatingDeployment.properties.parameters.location.value -ne "[parameters('deploymentLocation')]" -or
            $remediatingDeployment.properties.parameters.identity.value.type -ne 'SystemAssigned') {
            Stop-Test "$($remediatingDeployment.name) must include deploymentLocation and SystemAssigned identity for DeployIfNotExists."
        }
    }
    if ($activityDeployment.properties.parameters.policyDefinitionId.value -ne "[variables('activityLogExportPolicyDefinitionId')]") {
        Stop-Test 'Activity Log assignment must use the catalog-wired policy definition variable.'
    }
    if ($activityDeployment.properties.parameters.definitionVersion.value -ne '1.*.*' -or
        $activityRemediatingDeployment.properties.parameters.definitionVersion.value -ne '1.*.*') {
        Stop-Test 'Activity Log assignment must pin major version 1.*.*.'
    }
    if (Compare-Object @("[variables('monitoringContributorRoleDefinitionId')]", "[variables('logAnalyticsContributorRoleDefinitionId')]") @($activityRemediatingDeployment.properties.parameters.verifiedRoleDefinitionIds.value)) {
        Stop-Test 'Activity Log assignment remediation roles are invalid.'
    }
    if ($activityRemediatingDeployment.properties.parameters.deployRemediationRoleAssignments.value -ne "[variables('deployActivityLogRemediationRoleAssignments')]") {
        Stop-Test 'Activity Log remediation role-assignment gating must be parameterized and explicit.'
    }
    if (Compare-Object @(
        'Activity Log export requires a valid effective Log Analytics workspace resource ID and the configured subscription diagnostic settings must stream to that workspace.'
    ) @($activityDeployment.properties.parameters.nonComplianceMessages.value | ForEach-Object { $_.message })) {
        Stop-Test 'Activity Log noncompliance message must match the precise logging export guidance.'
    }
    $activityWorkspaceExpression = [string]$activityDeployment.properties.parameters.parameters.value.logAnalytics.value
    $activityRemediatingWorkspaceExpression = [string]$activityRemediatingDeployment.properties.parameters.parameters.value.logAnalytics.value
    if ($activityDeployment.properties.parameters.parameters.value.effect.value -ne "[parameters('activityLogExportPolicyEffect')]" -or
        $activityDeployment.properties.parameters.parameters.value.logsEnabled.value -ne "[parameters('activityLogExportLogsEnabled')]" -or
        $activityRemediatingDeployment.properties.parameters.parameters.value.effect.value -ne "[parameters('activityLogExportPolicyEffect')]" -or
        $activityRemediatingDeployment.properties.parameters.parameters.value.logsEnabled.value -ne "[parameters('activityLogExportLogsEnabled')]" -or
        ($activityWorkspaceExpression -notlike "*reference('centralMonitoring').outputs.effectiveLogAnalyticsWorkspaceResourceId.value*") -or
        ($activityWorkspaceExpression -notlike "*fail(*Activity Log and supported-resource diagnostics assignments require a valid effective Log Analytics workspace resource ID in the exact form /subscriptions/<guid>/resourceGroups/<name>/providers/Microsoft.OperationalInsights/workspaces/<name>*") -or
        ($activityWorkspaceExpression -notlike "*isWorkspaceResourceId*") -or
        ($activityRemediatingWorkspaceExpression -notlike "*reference('centralMonitoring').outputs.effectiveLogAnalyticsWorkspaceResourceId.value*") -or
        ($activityRemediatingWorkspaceExpression -notlike "*fail(*Activity Log and supported-resource diagnostics assignments require a valid effective Log Analytics workspace resource ID in the exact form /subscriptions/<guid>/resourceGroups/<name>/providers/Microsoft.OperationalInsights/workspaces/<name>*") -or
        ($activityRemediatingWorkspaceExpression -notlike "*isWorkspaceResourceId*")) {
        Stop-Test 'Activity Log assignment parameters must be wired to effect/logsEnabled and strict effective workspace resource ID validation.'
    }
    if ($diagnosticsDeployment.properties.parameters.policyDefinitionId.value -ne "[variables('resourceDiagnosticsPolicySetDefinitionId')]") {
        Stop-Test 'Resource diagnostics assignment must use the category-group-selected policy set variable.'
    }
    if ($diagnosticsDeployment.properties.parameters.definitionVersion.value -ne '1.*.*' -or
        $diagnosticsRemediatingDeployment.properties.parameters.definitionVersion.value -ne '1.*.*') {
        Stop-Test 'Resource diagnostics assignment must pin major version 1.*.*.'
    }
    if (Compare-Object @("[variables('logAnalyticsContributorRoleDefinitionId')]") @($diagnosticsRemediatingDeployment.properties.parameters.verifiedRoleDefinitionIds.value)) {
        Stop-Test 'Resource diagnostics assignment remediation roles are invalid.'
    }
    if ($diagnosticsRemediatingDeployment.properties.parameters.deployRemediationRoleAssignments.value -ne "[variables('deployResourceDiagnosticsRemediationRoleAssignments')]") {
        Stop-Test 'Resource diagnostics remediation role-assignment gating must be parameterized and explicit.'
    }
    if (Compare-Object @(
        'Supported-resource diagnostics export requires a valid effective Log Analytics workspace resource ID and compliant diagnostic settings for supported resource types.'
    ) @($diagnosticsDeployment.properties.parameters.nonComplianceMessages.value | ForEach-Object { $_.message })) {
        Stop-Test 'Resource diagnostics noncompliance message must match the precise logging guidance.'
    }
    $diagnosticsWorkspaceExpression = [string]$diagnosticsDeployment.properties.parameters.parameters.value.logAnalytics.value
    $diagnosticsRemediatingWorkspaceExpression = [string]$diagnosticsRemediatingDeployment.properties.parameters.parameters.value.logAnalytics.value
    if ($diagnosticsDeployment.properties.parameters.parameters.value.effect.value -ne "[parameters('resourceDiagnosticsPolicyEffect')]" -or
        ($diagnosticsWorkspaceExpression -notlike "*reference('centralMonitoring').outputs.effectiveLogAnalyticsWorkspaceResourceId.value*") -or
        ($diagnosticsWorkspaceExpression -notlike "*fail(*Activity Log and supported-resource diagnostics assignments require a valid effective Log Analytics workspace resource ID in the exact form /subscriptions/<guid>/resourceGroups/<name>/providers/Microsoft.OperationalInsights/workspaces/<name>*") -or
        ($diagnosticsWorkspaceExpression -notlike "*isWorkspaceResourceId*") -or
        ($diagnosticsRemediatingWorkspaceExpression -notlike "*reference('centralMonitoring').outputs.effectiveLogAnalyticsWorkspaceResourceId.value*") -or
        ($diagnosticsRemediatingWorkspaceExpression -notlike "*fail(*Activity Log and supported-resource diagnostics assignments require a valid effective Log Analytics workspace resource ID in the exact form /subscriptions/<guid>/resourceGroups/<name>/providers/Microsoft.OperationalInsights/workspaces/<name>*") -or
        ($diagnosticsRemediatingWorkspaceExpression -notlike "*isWorkspaceResourceId*")) {
        Stop-Test 'Resource diagnostics assignment parameters must be wired to effect and strict effective workspace resource ID validation.'
    }
    if ($activityWorkspaceRbacDeployment.condition -ne "[variables('deployActivityLogRemediationRoleAssignments')]" -or
        $diagnosticsWorkspaceRbacDeployment.condition -ne "[variables('deployResourceDiagnosticsRemediationRoleAssignments')]" -or
        $activityWorkspaceRbacDeployment.subscriptionId -ne "[variables('loggingWorkspaceSubscriptionId')]" -or
        $activityWorkspaceRbacDeployment.resourceGroup -ne "[variables('loggingWorkspaceResourceGroupName')]" -or
        $diagnosticsWorkspaceRbacDeployment.subscriptionId -ne "[variables('loggingWorkspaceSubscriptionId')]" -or
        $diagnosticsWorkspaceRbacDeployment.resourceGroup -ne "[variables('loggingWorkspaceResourceGroupName')]") {
        Stop-Test 'Workspace destination RBAC deployments must be explicitly gated and scoped to the resolved destination workspace location.'
    }
    if ($activityWorkspaceRbacDeployment.properties.parameters.workspaceName.value -ne "[variables('loggingWorkspaceName')]" -or
        $diagnosticsWorkspaceRbacDeployment.properties.parameters.workspaceName.value -ne "[variables('loggingWorkspaceName')]") {
        Stop-Test 'Workspace destination RBAC deployments must target the resolved destination workspace name.'
    }
    if (Compare-Object @("[variables('logAnalyticsContributorRoleDefinitionId')]") @($activityWorkspaceRbacDeployment.properties.parameters.roleDefinitionIds.value)) {
        Stop-Test 'Activity Log workspace destination RBAC must grant only Log Analytics Contributor at the destination workspace.'
    }
    if ($activityWorkspaceRbacDeployment.properties.template.resources.remediationRoleAssignments.scope -ne "[resourceId('Microsoft.OperationalInsights/workspaces', parameters('workspaceName'))]" -or
        $activityWorkspaceRbacDeployment.properties.template.resources.remediationRoleAssignments.properties.roleDefinitionId -ne "[tenantResourceId('Microsoft.Authorization/roleDefinitions', parameters('roleDefinitionIds')[copyIndex()])]") {
        Stop-Test 'Workspace destination RBAC must grant role assignments at the workspace scope using built-in role IDs.'
    }
    if ($compiledJson.outputs.loggingAssignments.value.activityLogExport.policyAssignmentId -ne "[if(variables('activityLogRemediationDeployRequested'), reference('activityLogExportRemediatingAssignment').outputs.policyAssignmentId.value, reference('activityLogExportAssignment').outputs.policyAssignmentId.value)]" -or
        $compiledJson.outputs.loggingAssignments.value.activityLogExport.identityPrincipalId -ne "[if(variables('activityLogRemediationDeployRequested'), reference('activityLogExportRemediatingAssignment').outputs.identityPrincipalId.value, '')]" -or
        $compiledJson.outputs.loggingAssignments.value.activityLogExport.roleAssignmentIds -ne "[if(variables('activityLogRemediationDeployRequested'), reference('activityLogExportRemediatingAssignment').outputs.roleAssignmentIds.value, createArray())]" -or
        $compiledJson.outputs.loggingAssignments.value.activityLogExport.remediationRoleAssignmentIds -ne "[if(variables('activityLogRemediationDeployRequested'), reference('activityLogExportRemediatingAssignment').outputs.roleAssignmentIds.value, createArray())]" -or
        $compiledJson.outputs.loggingAssignments.value.activityLogExport.effect -ne "[parameters('activityLogExportPolicyEffect')]" -or
        $compiledJson.outputs.loggingAssignments.value.resourceDiagnostics.policyAssignmentId -ne "[if(variables('resourceDiagnosticsRemediationDeployRequested'), reference('resourceDiagnosticsRemediatingAssignment').outputs.policyAssignmentId.value, reference('resourceDiagnosticsAssignment').outputs.policyAssignmentId.value)]" -or
        $compiledJson.outputs.loggingAssignments.value.resourceDiagnostics.identityPrincipalId -ne "[if(variables('resourceDiagnosticsRemediationDeployRequested'), reference('resourceDiagnosticsRemediatingAssignment').outputs.identityPrincipalId.value, '')]" -or
        $compiledJson.outputs.loggingAssignments.value.resourceDiagnostics.roleAssignmentIds -ne "[if(variables('resourceDiagnosticsRemediationDeployRequested'), reference('resourceDiagnosticsRemediatingAssignment').outputs.roleAssignmentIds.value, createArray())]" -or
        $compiledJson.outputs.loggingAssignments.value.resourceDiagnostics.remediationRoleAssignmentIds -ne "[if(variables('resourceDiagnosticsRemediationDeployRequested'), reference('resourceDiagnosticsRemediatingAssignment').outputs.roleAssignmentIds.value, createArray())]" -or
        $compiledJson.outputs.loggingAssignments.value.resourceDiagnostics.effect -ne "[parameters('resourceDiagnosticsPolicyEffect')]" -or
        $compiledJson.outputs.loggingAssignments.value.resourceDiagnostics.categoryGroup -ne "[parameters('resourceDiagnosticsCategoryGroup')]" -or
        $compiledJson.outputs.loggingAssignments.value.activityLogExport.workspaceDestinationRoleAssignmentIds -ne "[if(variables('deployActivityLogRemediationRoleAssignments'), reference('activityLogWorkspaceDestinationRbac').outputs.roleAssignmentIds.value, createArray())]" -or
        $compiledJson.outputs.loggingAssignments.value.resourceDiagnostics.workspaceDestinationRoleAssignmentIds -ne "[if(variables('deployResourceDiagnosticsRemediationRoleAssignments'), reference('resourceDiagnosticsWorkspaceDestinationRbac').outputs.roleAssignmentIds.value, createArray())]") {
        Stop-Test 'loggingAssignments output must expose effects, category-group, and gated workspace destination-role assignment outputs.'
    }
    Write-Host '    Confirm mirrored logging compile-matrix coverage across enabled/disabled effects, workspace paths, and category-group modes...'
    $loggingCases = @(
        @{
            Name = 'disabled-empty-default'
            deployCentralLogAnalytics = $false
            existingLogAnalyticsWorkspaceResourceId = ''
            activityLogExportPolicyEffect = 'Disabled'
            resourceDiagnosticsPolicyEffect = 'Disabled'
            resourceDiagnosticsCategoryGroup = 'audit'
            deployRoleAssignments = $false
            deployLoggingRemediationRoleAssignments = $false
        },
        @{
            Name = 'activity-deploy-existing-valid'
            deployCentralLogAnalytics = $false
            existingLogAnalyticsWorkspaceResourceId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-monitor/providers/Microsoft.OperationalInsights/workspaces/log-demo-central'
            activityLogExportPolicyEffect = 'DeployIfNotExists'
            resourceDiagnosticsPolicyEffect = 'Disabled'
            resourceDiagnosticsCategoryGroup = 'audit'
            deployRoleAssignments = $true
            deployLoggingRemediationRoleAssignments = $true
        },
        @{
            Name = 'diagnostics-deploy-existing-alllogs'
            deployCentralLogAnalytics = $false
            existingLogAnalyticsWorkspaceResourceId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-monitor/providers/Microsoft.OperationalInsights/workspaces/log-demo-central'
            activityLogExportPolicyEffect = 'Disabled'
            resourceDiagnosticsPolicyEffect = 'DeployIfNotExists'
            resourceDiagnosticsCategoryGroup = 'allLogs'
            deployRoleAssignments = $true
            deployLoggingRemediationRoleAssignments = $true
        },
        @{
            Name = 'diagnostics-auditif-existing'
            deployCentralLogAnalytics = $false
            existingLogAnalyticsWorkspaceResourceId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-monitor/providers/Microsoft.OperationalInsights/workspaces/log-demo-central'
            activityLogExportPolicyEffect = 'Disabled'
            resourceDiagnosticsPolicyEffect = 'AuditIfNotExists'
            resourceDiagnosticsCategoryGroup = 'audit'
            deployRoleAssignments = $true
            deployLoggingRemediationRoleAssignments = $true
        },
        @{
            Name = 'new-workspace-both-deploy'
            deployCentralLogAnalytics = $true
            existingLogAnalyticsWorkspaceResourceId = ''
            activityLogExportPolicyEffect = 'DeployIfNotExists'
            resourceDiagnosticsPolicyEffect = 'DeployIfNotExists'
            resourceDiagnosticsCategoryGroup = 'allLogs'
            deployRoleAssignments = $true
            deployLoggingRemediationRoleAssignments = $true
        },
        @{
            Name = 'enabled-empty-existing-id'
            deployCentralLogAnalytics = $false
            existingLogAnalyticsWorkspaceResourceId = ''
            activityLogExportPolicyEffect = 'DeployIfNotExists'
            resourceDiagnosticsPolicyEffect = 'AuditIfNotExists'
            resourceDiagnosticsCategoryGroup = 'audit'
            deployRoleAssignments = $true
            deployLoggingRemediationRoleAssignments = $true
        },
        @{
            Name = 'enabled-malformed-existing-id'
            deployCentralLogAnalytics = $false
            existingLogAnalyticsWorkspaceResourceId = '/subscriptions/not-a-guid/resourceGroups/rg-monitor/providers/Microsoft.OperationalInsights/workspaces/'
            activityLogExportPolicyEffect = 'DeployIfNotExists'
            resourceDiagnosticsPolicyEffect = 'DeployIfNotExists'
            resourceDiagnosticsCategoryGroup = 'audit'
            deployRoleAssignments = $true
            deployLoggingRemediationRoleAssignments = $true
        },
        @{
            Name = 'enabled-wrong-type-existing-id'
            deployCentralLogAnalytics = $false
            existingLogAnalyticsWorkspaceResourceId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-monitor/providers/Microsoft.Storage/storageAccounts/not-a-workspace'
            activityLogExportPolicyEffect = 'Disabled'
            resourceDiagnosticsPolicyEffect = 'AuditIfNotExists'
            resourceDiagnosticsCategoryGroup = 'allLogs'
            deployRoleAssignments = $true
            deployLoggingRemediationRoleAssignments = $true
        },
        @{
            Name = 'enabled-malformed-prefix-existing-id'
            deployCentralLogAnalytics = $false
            existingLogAnalyticsWorkspaceResourceId = 'junk/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-monitor/providers/Microsoft.OperationalInsights/workspaces/log-demo-central'
            activityLogExportPolicyEffect = 'DeployIfNotExists'
            resourceDiagnosticsPolicyEffect = 'Disabled'
            resourceDiagnosticsCategoryGroup = 'audit'
            deployRoleAssignments = $true
            deployLoggingRemediationRoleAssignments = $true
        },
        @{
            Name = 'enabled-forbidden-segment-existing-id'
            deployCentralLogAnalytics = $false
            existingLogAnalyticsWorkspaceResourceId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/./providers/Microsoft.OperationalInsights/workspaces/..'
            activityLogExportPolicyEffect = 'Disabled'
            resourceDiagnosticsPolicyEffect = 'AuditIfNotExists'
            resourceDiagnosticsCategoryGroup = 'allLogs'
            deployRoleAssignments = $true
            deployLoggingRemediationRoleAssignments = $true
        }
    )
    $workspaceModes = [System.Collections.Generic.HashSet[string]]::new()
    $categoryModes = [System.Collections.Generic.HashSet[string]]::new()
    $effectStates = [System.Collections.Generic.HashSet[string]]::new()
    $loggingParameterTemplateText = Get-Content -LiteralPath (Join-Path $ProjectDir 'parameters/main.template.bicepparam') -Raw
    foreach ($loggingCase in $loggingCases) {
        $caseParametersPath = Join-Path $TempDir ("logging-" + $loggingCase.Name + '.bicepparam')
        $caseText = $loggingParameterTemplateText -replace "(?m)^using '\.\./main\.bicep'$", "using '../../main.bicep'"
        foreach ($property in @('deployCentralLogAnalytics', 'existingLogAnalyticsWorkspaceResourceId', 'activityLogExportPolicyEffect', 'resourceDiagnosticsPolicyEffect', 'resourceDiagnosticsCategoryGroup', 'deployRoleAssignments', 'deployLoggingRemediationRoleAssignments')) {
            $value = $loggingCase.$property
            $valueLiteral = if ($value -is [bool]) { $value.ToString().ToLowerInvariant() } else { "'$value'" }
            $caseText = $caseText -replace "(?m)^param $property = .*$", "param $property = $valueLiteral"
        }
        Set-Content -LiteralPath $caseParametersPath -Value $caseText
        & az bicep build-params --file $caseParametersPath --outfile "$caseParametersPath.json"
        if ($LASTEXITCODE -ne 0) { Stop-Test "Logging matrix case $($loggingCase.Name) failed to compile." }
        $caseParameters = Get-Content -LiteralPath "$caseParametersPath.json" -Raw | ConvertFrom-Json
        foreach ($property in @('deployCentralLogAnalytics', 'existingLogAnalyticsWorkspaceResourceId', 'activityLogExportPolicyEffect', 'resourceDiagnosticsPolicyEffect', 'resourceDiagnosticsCategoryGroup', 'deployRoleAssignments', 'deployLoggingRemediationRoleAssignments')) {
            if ($caseParameters.parameters.$property.value -cne $loggingCase.$property) {
                Stop-Test "Logging matrix case $($loggingCase.Name) did not compile expected parameter value for $property."
            }
        }
        if ($loggingCase.deployCentralLogAnalytics) {
            [void]$workspaceModes.Add('new')
        } elseif ([string]::IsNullOrEmpty($loggingCase.existingLogAnalyticsWorkspaceResourceId)) {
            [void]$workspaceModes.Add('empty')
        } elseif ($loggingCase.existingLogAnalyticsWorkspaceResourceId -eq '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-monitor/providers/Microsoft.OperationalInsights/workspaces/log-demo-central') {
            [void]$workspaceModes.Add('existing-valid')
        } elseif ($loggingCase.existingLogAnalyticsWorkspaceResourceId -eq '/subscriptions/not-a-guid/resourceGroups/rg-monitor/providers/Microsoft.OperationalInsights/workspaces/') {
            [void]$workspaceModes.Add('existing-malformed')
        } elseif ($loggingCase.existingLogAnalyticsWorkspaceResourceId -eq '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-monitor/providers/Microsoft.Storage/storageAccounts/not-a-workspace') {
            [void]$workspaceModes.Add('existing-wrong-type')
        } elseif ($loggingCase.existingLogAnalyticsWorkspaceResourceId -eq 'junk/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-monitor/providers/Microsoft.OperationalInsights/workspaces/log-demo-central') {
            [void]$workspaceModes.Add('existing-malformed-prefix')
        } elseif ($loggingCase.existingLogAnalyticsWorkspaceResourceId -eq '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/./providers/Microsoft.OperationalInsights/workspaces/..') {
            [void]$workspaceModes.Add('existing-forbidden-segment')
        }
        [void]$categoryModes.Add($loggingCase.resourceDiagnosticsCategoryGroup)
        [void]$effectStates.Add("$($loggingCase.activityLogExportPolicyEffect)|$($loggingCase.resourceDiagnosticsPolicyEffect)")
    }
    if (Compare-Object @($workspaceModes) @('new', 'empty', 'existing-valid', 'existing-malformed', 'existing-wrong-type', 'existing-malformed-prefix', 'existing-forbidden-segment')) {
        Stop-Test 'Logging matrix coverage must include new, empty, valid-existing, malformed-existing, wrong-type-existing, malformed-prefix, and forbidden-segment workspace paths.'
    }
    if (Compare-Object @($categoryModes) @('audit', 'allLogs')) {
        Stop-Test 'Logging matrix coverage must include both resourceDiagnosticsCategoryGroup values: audit and allLogs.'
    }
    if (-not $effectStates.Contains('Disabled|Disabled') -or -not $effectStates.Contains('DeployIfNotExists|DeployIfNotExists')) {
        Stop-Test 'Logging matrix coverage must include both fully disabled and fully remediation-enabled effect combinations.'
    }

    Write-Host ''
    Write-Host 'All Windows PowerShell validation and safety tests passed.'
}
finally {
    # Safety net: if the loopback case-insensitive filesystem mount used by
    # the case-insensitivity regression test above is still mounted for any
    # reason (e.g. a lingering file handle delayed the earlier unmount),
    # force it loose here so cleanup of $TempDir does not fail with "Device
    # or resource busy".
    $leftoverMount = Join-Path $TempDir 'case-insensitive-mnt'
    if ((Get-Command mountpoint -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $leftoverMount)) {
        & mountpoint -q $leftoverMount 2>$null
        if ($LASTEXITCODE -eq 0) {
            & sudo -n umount -l $leftoverMount 2>$null 1>$null
        }
    }
    if (Test-Path -LiteralPath $TempDir) {
        Remove-Item -LiteralPath $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $ArtifactsParent) {
        Remove-Item -LiteralPath $ArtifactsParent -ErrorAction SilentlyContinue
    }
}
