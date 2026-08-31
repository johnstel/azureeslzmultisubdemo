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

    Write-Host '1/12 Validate repository versioning and branch guidance...'
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

    Write-Host '2/12 Build the complete tenant template...'
    $compiledTemplate = Join-Path $TempDir 'main.json'
    & az bicep build --file (Join-Path $ProjectDir 'main.bicep') --outfile $compiledTemplate
    if ($LASTEXITCODE -ne 0) { Stop-Test 'Bicep build failed.' }

    Write-Host '3/12 Validate both parameter templates...'
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

    Write-Host '4/12 Confirm there are exactly two unconditional subscription associations...'
    $compiledJson = Get-Content -LiteralPath $compiledTemplate -Raw | ConvertFrom-Json
    $subscriptionAssociations = Find-JsonObjects -Node $compiledJson -Predicate {
        param($node)
        $node.PSObject.Properties['type'] -and $node.type -eq 'Microsoft.Management/managementGroups/subscriptions'
    }
    $unconditionalAssociations = $subscriptionAssociations | Where-Object { -not $_.PSObject.Properties['condition'] }
    if (@($unconditionalAssociations).Count -ne 2) {
        Stop-Test "Expected 2 unconditional subscription association resources, found $(@($unconditionalAssociations).Count)."
    }

    Write-Host '5/12 Confirm no paid always-on resource types are declared...'
    $bicepFiles = @(
        Get-Item (Join-Path $ProjectDir 'main.bicep')
        Get-ChildItem (Join-Path $ProjectDir 'modules') -Filter '*.bicep' |
            Where-Object { $_.Name -ne 'policy-library.bicep' }
    )
    $prohibitedPattern = 'Microsoft\.(Compute/virtualMachines|OperationalInsights/workspaces|Network/(azureFirewalls|bastionHosts|natGateways|publicIPAddresses|virtualNetworkGateways)|Storage/storageAccounts)'
    foreach ($bicepFile in $bicepFiles) {
        if ((Get-Content -LiteralPath $bicepFile.FullName -Raw) -match $prohibitedPattern) {
            Stop-Test "A prohibited evidence resource type is declared in $($bicepFile.Name)."
        }
    }

    Write-Host '6/12 Confirm tenant-root scope is only used as the parent hierarchy input...'
    foreach ($bicepFile in Get-ChildItem $ProjectDir -Recurse -Filter '*.bicep') {
        if ((Get-Content -LiteralPath $bicepFile.FullName -Raw) -match 'scope:\s*managementGroup\(tenantRootManagementGroupId\)') {
            Stop-Test "A module or resource assigns governance directly at the tenant root in $($bicepFile.Name)."
        }
    }

    Write-Host '7/12 Confirm five Entra group parameters and guarded lifecycle scripts...'
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

    Write-Host '8/12 Confirm the region policy safely permits global resources...'
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

    Write-Host '9/12 Confirm the Critical Infrastructure branch is opt-in and correctly wired...'
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

    Write-Host '10/12 Confirm criticalInfrastructureSubscriptionIds validates duplicates and overlap...'
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

    Write-Host '11/12 Confirm teardown scripts move critical subscriptions and delete the Critical Infrastructure management group before Landing Zones...'
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

    Write-Host '12/12 Parse every PowerShell lifecycle and test script...'
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

    Write-Host ''
    Write-Host 'All Windows PowerShell validation and safety tests passed.'
}
finally {
    if (Test-Path -LiteralPath $TempDir) {
        Remove-Item -LiteralPath $TempDir -Recurse -Force
    }
}
