[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir
$TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("azureeslz-test-" + [guid]::NewGuid().ToString('N'))
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

    Write-Host '1/20 Validate repository versioning and branch guidance...'
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

    Write-Host '2/20 Build the complete tenant template...'
    $compiledTemplate = Join-Path $TempDir 'main.json'
    $buildOutput = & az bicep build --file (Join-Path $ProjectDir 'main.bicep') --outfile $compiledTemplate 2>&1
    if ($LASTEXITCODE -ne 0) { Stop-Test 'Bicep build failed.' }
    if ($buildOutput -match 'BCP318') {
        Stop-Test 'main.bicep build must not emit a BCP318 nullable-module-output warning.'
    }

    Write-Host '3/20 Validate both parameter templates...'
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

    Write-Host '4/20 Confirm there are exactly two unconditional subscription associations...'
    $compiledJson = Get-Content -LiteralPath $compiledTemplate -Raw | ConvertFrom-Json
    $subscriptionAssociations = Find-JsonObjects -Node $compiledJson -Predicate {
        param($node)
        $node.PSObject.Properties['type'] -and $node.type -eq 'Microsoft.Management/managementGroups/subscriptions'
    }
    $unconditionalAssociations = $subscriptionAssociations | Where-Object { -not $_.PSObject.Properties['condition'] }
    if (@($unconditionalAssociations).Count -ne 2) {
        Stop-Test "Expected 2 unconditional subscription association resources, found $(@($unconditionalAssociations).Count)."
    }

    Write-Host '5/20 Confirm no paid always-on resource types are declared outside the opt-in central monitoring module...'
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

    Write-Host '6/20 Confirm tenant-root scope is only used as the parent hierarchy input...'
    foreach ($bicepFile in Get-ChildItem $ProjectDir -Recurse -Filter '*.bicep') {
        if ((Get-Content -LiteralPath $bicepFile.FullName -Raw) -match 'scope:\s*managementGroup\(tenantRootManagementGroupId\)') {
            Stop-Test "A module or resource assigns governance directly at the tenant root in $($bicepFile.Name)."
        }
    }

    Write-Host '7/20 Confirm five Entra group parameters and guarded lifecycle scripts...'
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

    Write-Host '8/20 Confirm the region policy safely permits global resources...'
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

    Write-Host '9/20 Confirm the Critical Infrastructure branch is opt-in and correctly wired...'
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

    Write-Host '10/20 Confirm criticalInfrastructureSubscriptionIds validates duplicates and overlap...'
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

    Write-Host '11/20 Confirm teardown scripts move critical subscriptions and delete the Critical Infrastructure management group before Landing Zones...'
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

    Write-Host '12/20 Confirm central monitoring defaults create no metered resources...'
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

    Write-Host '13/20 Confirm central monitoring guards against conflicting new/existing workspace inputs and Sentinel-without-workspace...'
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

    Write-Host '14/20 Confirm the central monitoring module exposes an effective workspace ID output...'
    if (-not ($centralMonitoringText -match '(?m)^output effectiveLogAnalyticsWorkspaceResourceId string')) {
        Stop-Test 'central-monitoring.bicep is missing the effectiveLogAnalyticsWorkspaceResourceId output.'
    }
    if (-not $mainBicepText.Contains('centralMonitoringEffectiveWorkspaceId string = centralMonitoring.outputs.effectiveLogAnalyticsWorkspaceResourceId')) {
        Stop-Test 'main.bicep is missing the centralMonitoringEffectiveWorkspaceId output.'
    }

    Write-Host '15/20 Confirm invalid central monitoring configurations fail deployment explicitly...'
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

    Write-Host '16/20 Confirm teardown scripts protect a supplied existing workspace resource group and only remove a demo-created monitoring resource group...'
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

    Write-Host '17/20 Confirm a whitespace-only existing workspace resource ID never triggers deletion of the monitoring resource group...'
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

    Write-Host '18/20 Parse every PowerShell lifecycle and test script...'
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

    Write-Host '19/20 Validate Entra Conditional Access and PIM demo artifacts...'
    & (Join-Path $ProjectDir 'scripts/validate-identity-artifacts.ps1')

    Write-Host '20/20 Confirm identity validators reject invalid Conditional Access and PIM inputs...'
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
        param([string]$Description, [string[]]$Arguments)
        $failed = $false
        $global:LASTEXITCODE = 0
        try {
            & $validatorPath @Arguments | Out-Null
            if ($LASTEXITCODE -ne 0) { $failed = $true }
        } catch {
            $failed = $true
        }
        if (-not $failed) {
            Stop-Test "validate-identity-artifacts.ps1 unexpectedly succeeded for case: $Description"
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

    if (Test-Path -LiteralPath $identityNegDir) { Remove-Item -LiteralPath $identityNegDir -Recurse -Force }
    if (Test-Path -LiteralPath $identityPopDir) { Remove-Item -LiteralPath $identityPopDir -Recurse -Force }

    Write-Host ''
    Write-Host 'All Windows PowerShell validation and safety tests passed.'
}
finally {
    if (Test-Path -LiteralPath $TempDir) {
        Remove-Item -LiteralPath $TempDir -Recurse -Force
    }
}
