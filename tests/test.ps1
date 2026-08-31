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

    Write-Host '1/14 Validate repository versioning and branch guidance...'
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

    Write-Host '2/14 Build the complete tenant template...'
    $compiledTemplate = Join-Path $TempDir 'main.json'
    & az bicep build --file (Join-Path $ProjectDir 'main.bicep') --outfile $compiledTemplate
    if ($LASTEXITCODE -ne 0) { Stop-Test 'Bicep build failed.' }

    Write-Host '3/14 Validate both parameter templates...'
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

    Write-Host '4/14 Confirm there are exactly two unconditional subscription associations...'
    $compiledJson = Get-Content -LiteralPath $compiledTemplate -Raw | ConvertFrom-Json
    $subscriptionAssociations = Find-JsonObjects -Node $compiledJson -Predicate {
        param($node)
        $node.PSObject.Properties['type'] -and $node.type -eq 'Microsoft.Management/managementGroups/subscriptions'
    }
    $unconditionalAssociations = $subscriptionAssociations | Where-Object { -not $_.PSObject.Properties['condition'] }
    if (@($unconditionalAssociations).Count -ne 2) {
        Stop-Test "Expected 2 unconditional subscription association resources, found $(@($unconditionalAssociations).Count)."
    }

    Write-Host '5/14 Confirm no paid always-on resource types are declared...'
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

    Write-Host '6/14 Confirm tenant-root scope is only used as the parent hierarchy input...'
    foreach ($bicepFile in Get-ChildItem $ProjectDir -Recurse -Filter '*.bicep') {
        if ((Get-Content -LiteralPath $bicepFile.FullName -Raw) -match 'scope:\s*managementGroup\(tenantRootManagementGroupId\)') {
            Stop-Test "A module or resource assigns governance directly at the tenant root in $($bicepFile.Name)."
        }
    }

    Write-Host '7/14 Confirm five Entra group parameters and guarded lifecycle scripts...'
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

    Write-Host '8/14 Confirm the region policy safely permits global resources...'
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

    Write-Host '9/14 Confirm the Critical Infrastructure branch is opt-in and correctly wired...'
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

    Write-Host '10/14 Confirm criticalInfrastructureSubscriptionIds validates duplicates and overlap...'
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

    Write-Host '11/14 Confirm teardown scripts move critical subscriptions and delete the Critical Infrastructure management group before Landing Zones...'
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

    Write-Host '12/14 Parse every PowerShell lifecycle and test script...'
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

    Write-Host '13/14 Validate Entra Conditional Access and PIM demo artifacts...'
    & (Join-Path $ProjectDir 'scripts/validate-identity-artifacts.ps1')

    Write-Host '14/14 Confirm identity validators reject invalid Conditional Access and PIM inputs...'
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
