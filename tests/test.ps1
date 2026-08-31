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

    Write-Host '19/20 Validate the v2 control catalog (schema-equivalent checks + matrix consistency)...'
    & (Join-Path $ScriptDir 'validate-control-catalog.ps1')

    Write-Host '20/20 Forced-fallback regression tests for the shared source-URL grammar (bash/python, bash/jq-fallback, pwsh/python, pwsh/native-fallback)...'
    if (Get-Command bash -ErrorAction SilentlyContinue) {
        & bash (Join-Path $ScriptDir 'uri-grammar-forced-fallback-tests.sh')
        if ($LASTEXITCODE -ne 0) {
            Stop-Test 'tests/uri-grammar-forced-fallback-tests.sh failed.'
        }
    } else {
        Write-Host '  (No bash interpreter found on PATH; relying on tests/test.sh to cover this step.)'
    }

    Write-Host ''
    Write-Host 'All Windows PowerShell validation and safety tests passed.'
}
finally {
    if (Test-Path -LiteralPath $TempDir) {
        Remove-Item -LiteralPath $TempDir -Recurse -Force
    }
}
