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

try {
    if ($null -eq (Get-Command az -ErrorAction SilentlyContinue)) {
        Stop-Test 'Azure CLI is required for Bicep validation.'
    }

    Write-Host '1/23 Validate repository versioning and branch guidance...'
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

    Write-Host '2/23 Build the complete tenant template and validate policy assignment shapes...'
    $compiledTemplate = Join-Path $TempDir 'main.json'
    $buildOutput = & az bicep build --file (Join-Path $ProjectDir 'main.bicep') --outfile $compiledTemplate 2>&1
    if ($LASTEXITCODE -ne 0) { Stop-Test 'Bicep build failed.' }
    if ($buildOutput -match 'BCP318') {
        Stop-Test 'main.bicep build must not emit a BCP318 nullable-module-output warning.'
    }
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

    Write-Host '3/23 Validate both parameter templates...'
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
    & az bicep build-params `
        --file (Join-Path $ProjectDir 'parameters/main.template.bicepparam') `
        --outfile (Join-Path $TempDir 'main.parameters.json')
    if ($LASTEXITCODE -ne 0) { Stop-Test 'Bicep parameter build failed.' }

    Write-Host '4/23 Confirm there are exactly two unconditional subscription associations...'
    $subscriptionAssociations = Find-JsonObjects -Node $compiledJson -Predicate {
        param($node)
        $node.PSObject.Properties['type'] -and $node.type -eq 'Microsoft.Management/managementGroups/subscriptions'
    }
    $unconditionalAssociations = $subscriptionAssociations | Where-Object { -not $_.PSObject.Properties['condition'] }
    if (@($unconditionalAssociations).Count -ne 2) {
        Stop-Test "Expected 2 unconditional subscription association resources, found $(@($unconditionalAssociations).Count)."
    }

    Write-Host '5/23 Confirm no paid always-on resource types are declared outside the opt-in central monitoring module...'
    $bicepFiles = @(
        Get-Item (Join-Path $ProjectDir 'main.bicep')
        Get-ChildItem (Join-Path $ProjectDir 'modules') -Filter '*.bicep' |
            Where-Object { $_.Name -notin @('policy-library.bicep', 'central-monitoring.bicep', 'central-monitoring-workspace.bicep', 'central-monitoring-sentinel.bicep') }
    )
    $prohibitedPattern = 'Microsoft\.(Compute/virtualMachines|OperationalInsights/workspaces|Network/(azureFirewalls|bastionHosts|natGateways|publicIPAddresses|virtualNetworkGateways)|Storage/storageAccounts)'
    foreach ($bicepFile in $bicepFiles) {
        if ((Get-Content -LiteralPath $bicepFile.FullName -Raw) -match $prohibitedPattern) {
            Stop-Test "A prohibited evidence resource type is declared in $($bicepFile.Name)."
        }
    }

    Write-Host '6/23 Confirm tenant-root scope is only used as the parent hierarchy input...'
    foreach ($bicepFile in Get-ChildItem $ProjectDir -Recurse -Filter '*.bicep') {
        if ((Get-Content -LiteralPath $bicepFile.FullName -Raw) -match 'scope:\s*managementGroup\(tenantRootManagementGroupId\)') {
            Stop-Test "A module or resource assigns governance directly at the tenant root in $($bicepFile.Name)."
        }
    }

    Write-Host '7/23 Confirm five Entra group parameters and guarded lifecycle scripts...'
    $mainBicepText = Get-Content -LiteralPath (Join-Path $ProjectDir 'main.bicep') -Raw
    $groupPattern = '(?m)^param (governanceAdminsGroupObjectId|subscriptionOwnersGroupObjectId|networkOperatorsGroupObjectId|workloadContributorsGroupObjectId|readOnlyAuditorsGroupObjectId) string$'
    if (([regex]::Matches($mainBicepText, $groupPattern)).Count -ne 5) {
        Stop-Test 'Expected five Entra security-group parameters.'
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

    Write-Host '8/23 Confirm the region policy safely permits global resources...'
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

    Write-Host '9/23 Confirm the Critical Infrastructure branch is opt-in and correctly wired...'
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

    Write-Host '10/23 Confirm criticalInfrastructureSubscriptionIds validates duplicates and overlap...'
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

    Write-Host '11/23 Confirm teardown scripts move critical subscriptions and delete the Critical Infrastructure management group before Landing Zones...'
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

    Write-Host '12/23 Confirm central monitoring defaults create no metered resources...'
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

    Write-Host '13/23 Confirm central monitoring guards against conflicting new/existing workspace inputs and Sentinel-without-workspace...'
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

    Write-Host '14/23 Confirm the central monitoring module exposes an effective workspace ID output...'
    if (-not ($centralMonitoringText -match '(?m)^output effectiveLogAnalyticsWorkspaceResourceId string')) {
        Stop-Test 'central-monitoring.bicep is missing the effectiveLogAnalyticsWorkspaceResourceId output.'
    }
    if (-not $mainBicepText.Contains('centralMonitoringEffectiveWorkspaceId string = centralMonitoring.outputs.effectiveLogAnalyticsWorkspaceResourceId')) {
        Stop-Test 'main.bicep is missing the centralMonitoringEffectiveWorkspaceId output.'
    }

    Write-Host '15/23 Confirm invalid central monitoring configurations fail deployment explicitly...'
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

    Write-Host '16/23 Confirm teardown scripts protect a supplied existing workspace resource group and only remove a demo-created monitoring resource group...'
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

    Write-Host '17/23 Confirm a whitespace-only existing workspace resource ID never triggers deletion of the monitoring resource group...'
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
    $templateJson.parameters.subscriptionOwnersGroupObjectId.value = '44444444-4444-4444-4444-444444444444'
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

    Write-Host '18/23 Parse every PowerShell lifecycle and test script...'
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

    Write-Host '19/23 Validate reusable initiative composition...'
    & (Join-Path $ScriptDir 'validate-initiative-composition.ps1')

    Write-Host '20/23 Validate the v2 control catalog (schema-equivalent checks + matrix consistency)...'
    & (Join-Path $ScriptDir 'validate-control-catalog.ps1')

    Write-Host '21/23 Backend parity and structural-matrix regression tests (bash/python, bash/jq, pwsh/python, pwsh/native)...'
    if (Get-Command bash -ErrorAction SilentlyContinue) {
        & bash (Join-Path $ScriptDir 'uri-grammar-forced-fallback-tests.sh')
        if ($LASTEXITCODE -ne 0) {
            Stop-Test 'tests/uri-grammar-forced-fallback-tests.sh failed.'
        }
    } else {
        Write-Host '  (No bash interpreter found on PATH; relying on tests/test.sh to cover this step.)'
    }

    Write-Host '22/23 Validate Entra Conditional Access and PIM demo artifacts...'
    & (Join-Path $ProjectDir 'scripts/validate-identity-artifacts.ps1')

    Write-Host '23/23 Confirm identity validators reject invalid Conditional Access and PIM inputs...'
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
