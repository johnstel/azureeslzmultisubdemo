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

function Invoke-OfflineParitySuite {
    $mockDir = Join-Path $TempDir 'mock-az'
    New-Item -ItemType Directory -Path $mockDir -Force | Out-Null
    $priorAz = if (Test-Path function:az) { ${function:az} } else { $null }
    $priorProjectDir = $env:PROJECT_DIR
    $priorRestJson = $env:MOCK_REST_JSON
    $priorAccountJson = $env:MOCK_ACCOUNT_JSON
    $priorLastExitCode = if (Test-Path variable:global:LASTEXITCODE) { $global:LASTEXITCODE } else { $null }
    try {
    $global:OfflinePolicyVersions = @{}
    foreach ($control in @((Get-Content -LiteralPath (Join-Path $ProjectDir 'policy/control-catalog.json') -Raw | ConvertFrom-Json).controls)) {
        if ($control.mechanism.builtIn -eq $true -and $control.mechanism.definitionId) {
            $global:OfflinePolicyVersions[[string]$control.mechanism.definitionId] = "$($control.mechanism.majorVersion).0.0"
        }
    }
    function global:az {
        param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
        $global:LASTEXITCODE = 0
        switch ($Arguments[0]) {
            'account' { if ($Arguments[1] -eq 'show') { $env:MOCK_ACCOUNT_JSON ?? '{"tenantId":"11111111-1111-1111-1111-111111111111","state":"Enabled"}' }; return }
            'bicep' { return }
            'group' {
                if ($Arguments[1] -eq 'exists') {
                    if ($env:MOCK_GROUP_EXISTS_ERROR -eq 'true') { $global:LASTEXITCODE = 1; return }
                    $env:MOCK_GROUP_EXISTS ?? 'false'
                }
                elseif ($Arguments[1] -eq 'show') {
                    if ($env:MOCK_GROUP_SHOW_ERROR -eq 'true') { $global:LASTEXITCODE = 1; return }
                    $env:MOCK_GROUP_OWNER ?? 'demo'
                }
                return
            }
            'role' { return }
            'provider' { 'Registered'; return }
            'rest' {
                if ($env:MOCK_WORKSPACE_ID -and (($Arguments -join ' ') -like "*$($env:MOCK_WORKSPACE_ID)/providers/Microsoft.Authorization/permissions*")) { $env:MOCK_WORKSPACE_REST_JSON }
                else { $env:MOCK_REST_JSON ?? '{"value":[{"actions":["microsoft.authorization/policyassignments/write","microsoft.authorization/policydefinitions/write","microsoft.authorization/policysetdefinitions/write","microsoft.authorization/roleassignments/write"],"notActions":[]}]}' }
                return
            }
            'policy' {
                $nameIndex = [array]::IndexOf($Arguments, '--name')
                if ($nameIndex -ge 0 -and $global:OfflinePolicyVersions.ContainsKey($Arguments[$nameIndex + 1])) { $global:OfflinePolicyVersions[$Arguments[$nameIndex + 1]] } else { '1.0.0' }
                return
            }
            'resource' {
                $idIndex = [array]::IndexOf($Arguments, '--ids')
                $resourceId = if ($idIndex -ge 0) { $Arguments[$idIndex + 1] } else { '' }
                if ($resourceId -match '/providers/(Microsoft\.[^/]+/[^/]+)') { $matches[1] } else { 'Microsoft.Network/routeTables' }
                return
            }
        }
    }

    $baseDocument = Get-Content -LiteralPath (Join-Path $ProjectDir 'parameters/demo.parameters.template.json') -Raw
    $cases = @(
        @{ Name = 'canonical-id-pass'; Expected = 'pass'; RestJson = '{"value":[{"actions":["microsoft.authorization/policyassignments/write","microsoft.authorization/policydefinitions/write","microsoft.authorization/policysetdefinitions/write","microsoft.authorization/roleassignments/write"],"notActions":[]}]}' },
        @{ Name = 'canonical-id-fail'; Expected = 'fail'; RestJson = '{"value":[{"actions":["microsoft.authorization/policyassignments/write","microsoft.authorization/roleassignments/write"],"notActions":[]}]}' ; Mutator = { param($doc) $doc.parameters.connectivitySubscriptionId.value = 'not-a-guid' } },
        @{ Name = 'profile-shape-fail'; Expected = 'fail'; RestJson = '{"value":[{"actions":["microsoft.authorization/policyassignments/write"],"notActions":[]}]}' ; Mutator = { param($doc) $doc.parameters.PSObject.Properties.Remove('deploySentinel') } },
        @{ Name = 'blank-members-fail'; Expected = 'fail'; RestJson = '{"value":[{"actions":["microsoft.authorization/policyassignments/write","microsoft.authorization/roleassignments/write"],"notActions":[]}]}' ; Mutator = { param($doc) $doc.parameters.approvedRouteTableResourceIds.value = @('') } },
        @{ Name = 'blank-members-fail'; Expected = 'fail'; RestJson = '{"value":[{"actions":["microsoft.authorization/policyassignments/write","microsoft.authorization/roleassignments/write"],"notActions":[]}]}' ; Mutator = { param($doc) $doc.parameters.approvedRouteTableResourceIds.value = @('', 'not-a-resource-id') } },
        @{ Name = 'ip-pass'; Expected = 'pass'; RestJson = '{"value":[{"actions":["microsoft.authorization/policyassignments/write","microsoft.authorization/policydefinitions/write","microsoft.authorization/policysetdefinitions/write","microsoft.authorization/roleassignments/write"],"notActions":[]}]}' ; Mutator = { param($doc) $doc.parameters.enableFirewallRouteGuardrails.value = $true; $doc.parameters.approvedFirewallResourceId.value = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-network/providers/Microsoft.Network/azureFirewalls/fw-01'; $doc.parameters.approvedFirewallPrivateIp.value = '10.0.0.4'; $doc.parameters.approvedRouteTableResourceIds.value = @('/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-network/providers/Microsoft.Network/routeTables/rt-01'); $doc.parameters.approvedRouteTablePrefixes.value = @('10.0.0.0/24') } },
        @{ Name = 'ip-fail'; Expected = 'fail'; RestJson = '{"value":[{"actions":["microsoft.authorization/policyassignments/write","microsoft.authorization/roleassignments/write"],"notActions":[]}]}' ; Mutator = { param($doc) $doc.parameters.enableFirewallRouteGuardrails.value = $true; $doc.parameters.approvedFirewallPrivateIp.value = '999.999.999.999'; $doc.parameters.approvedRouteTablePrefixes.value = @('10.0.0.0/24') } },
        @{ Name = 'logging-pass'; Expected = 'pass'; RestJson = '{"value":[{"actions":["microsoft.authorization/policyassignments/write","microsoft.authorization/policydefinitions/write","microsoft.authorization/policysetdefinitions/write","microsoft.authorization/roleassignments/write"],"notActions":[]}]}' ; Mutator = { param($doc) $doc.parameters.activityLogExportPolicyEffect.value = 'DeployIfNotExists'; $doc.parameters.deployRoleAssignments.value = $true; $doc.parameters.deployLoggingRemediationRoleAssignments.value = $true; $doc.parameters.deployCentralLogAnalytics.value = $true; $doc.parameters.existingLogAnalyticsWorkspaceResourceId.value = '' } },
        @{ Name = 'logging-fail'; Expected = 'fail'; RestJson = '{"value":[{"actions":["microsoft.authorization/policyassignments/write","microsoft.authorization/roleassignments/write"],"notActions":[]}]}' ; Mutator = { param($doc) $doc.parameters.activityLogExportPolicyEffect.value = 'DeployIfNotExists'; $doc.parameters.deployLoggingRemediationRoleAssignments.value = $true; $doc.parameters.deployCentralLogAnalytics.value = $false; $doc.parameters.existingLogAnalyticsWorkspaceResourceId.value = '' } },
        @{ Name = 'routing-pass'; Expected = 'pass'; RestJson = '{"value":[{"actions":["microsoft.authorization/policyassignments/write","microsoft.authorization/policydefinitions/write","microsoft.authorization/policysetdefinitions/write","microsoft.authorization/roleassignments/write"],"notActions":[]}]}' ; Mutator = { param($doc) $doc.parameters.enableFirewallRouteGuardrails.value = $true; $doc.parameters.approvedFirewallResourceId.value = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-network/providers/Microsoft.Network/azureFirewalls/fw-01'; $doc.parameters.approvedFirewallPrivateIp.value = '10.0.0.4'; $doc.parameters.approvedRouteTableResourceIds.value = @('/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-network/providers/Microsoft.Network/routeTables/rt-01'); $doc.parameters.approvedRouteTablePrefixes.value = @('10.0.0.0/24') } },
        @{ Name = 'routing-fail'; Expected = 'fail'; RestJson = '{"value":[{"actions":["microsoft.authorization/policyassignments/write","microsoft.authorization/roleassignments/write"],"notActions":[]}]}' ; Mutator = { param($doc) $doc.parameters.enableFirewallRouteGuardrails.value = $true; $doc.parameters.approvedFirewallResourceId.value = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-network/providers/Microsoft.Network/azureFirewalls/fw-01'; $doc.parameters.approvedFirewallPrivateIp.value = '10.0.0.4'; $doc.parameters.approvedRouteTableResourceIds.value = @('/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-network/providers/Microsoft.Network/routeTables/rt-01','/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-network/providers/Microsoft.Network/routeTables/rt-01'); $doc.parameters.approvedRouteTablePrefixes.value = @('10.0.0.0/24','10.0.0.0/24') } },
        @{ Name = 'permissions-pass'; Expected = 'pass'; RestJson = '{"value":[{"actions":["microsoft.authorization/policyassignments/write","microsoft.authorization/policydefinitions/write","microsoft.authorization/policysetdefinitions/write","microsoft.authorization/roleassignments/write"],"notActions":[]}]}' },
        @{ Name = 'permissions-fail'; Expected = 'fail'; RestJson = '{"value":[{"actions":["microsoft.authorization/policyassignments/write"],"notActions":["microsoft.authorization/roleassignments/write"]}]}' ; Mutator = { param($doc) $doc.parameters.deployRoleAssignments.value = $true } },
        @{ Name = 'permissions-internal-wildcard-fail'; Expected = 'fail'; RestJson = '{"value":[{"actions":["*"],"notActions":["Microsoft.Authorization/*/Write"]}]}' },
        @{ Name = 'permissions-data-actions-only-fail'; Expected = 'fail'; RestJson = '{"value":[{"actions":[],"dataActions":["*"],"notActions":[]}]}' },
        @{ Name = 'permissions-separate-grant-pass'; Expected = 'pass'; RestJson = '{"value":[{"actions":["*"],"notActions":["Microsoft.Authorization/*/Write"]},{"actions":["microsoft.authorization/policyassignments/write","microsoft.authorization/policydefinitions/write","microsoft.authorization/policysetdefinitions/write"],"notActions":[]}]}' },
        @{ Name = 'missing-policy-definition-write-fail'; Expected = 'fail'; RestJson = '{"value":[{"actions":["microsoft.authorization/policyassignments/write"],"notActions":[]}]}' },
        @{ Name = 'backup-blank-fail'; Expected = 'fail'; RestJson = '{"value":[{"actions":["microsoft.authorization/policyassignments/write"],"notActions":[]}]}' ; Mutator = { param($doc) $doc.parameters.approvedBackupVaults.value = @([pscustomobject]@{ vaultResourceId = ''; backupPolicyResourceId = '' }) } }
    )

    foreach ($case in $cases) {
        $doc = $baseDocument | ConvertFrom-Json
        $doc.parameters.tenantRootManagementGroupId.value = 'demo-root'
        $doc.parameters.connectivitySubscriptionId.value = '11111111-1111-1111-1111-111111111111'
        $doc.parameters.workloadSubscriptionId.value = '22222222-2222-2222-2222-222222222222'
        $doc.parameters.governanceAdminsGroupObjectId.value = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        $doc.parameters.networkOperatorsGroupObjectId.value = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
        $doc.parameters.workloadContributorsGroupObjectId.value = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
        $doc.parameters.readOnlyAuditorsGroupObjectId.value = 'dddddddd-dddd-dddd-dddd-dddddddddddd'
        $doc.parameters.governanceAdminsGroupObjectId.value = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        $doc.parameters.networkOperatorsGroupObjectId.value = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
        $doc.parameters.workloadContributorsGroupObjectId.value = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
        $doc.parameters.readOnlyAuditorsGroupObjectId.value = 'dddddddd-dddd-dddd-dddd-dddddddddddd'
        $doc.parameters.governanceAdminsGroupObjectId.value = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        $doc.parameters.networkOperatorsGroupObjectId.value = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
        $doc.parameters.workloadContributorsGroupObjectId.value = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
        $doc.parameters.readOnlyAuditorsGroupObjectId.value = 'dddddddd-dddd-dddd-dddd-dddddddddddd'
        if ($case.ContainsKey('Mutator') -and $null -ne $case.Mutator) {
            & $case.Mutator $doc
        }

        $workspaceId = '/subscriptions/33333333-3333-3333-3333-333333333333/resourceGroups/rg-external/providers/Microsoft.OperationalInsights/workspaces/ws-external'
        foreach ($workspacePermission in @(
            '{"value":[{"actions":["microsoft.authorization/roleassignments/write"],"notActions":[]}]}' ,
            '{"value":[{"actions":[],"notActions":[]}]}')) {
            $doc = $baseDocument | ConvertFrom-Json
            $doc.parameters.tenantRootManagementGroupId.value = 'demo-root'
            $doc.parameters.connectivitySubscriptionId.value = '11111111-1111-1111-1111-111111111111'
            $doc.parameters.workloadSubscriptionId.value = '22222222-2222-2222-2222-222222222222'
            $doc.parameters.governanceAdminsGroupObjectId.value = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            $doc.parameters.networkOperatorsGroupObjectId.value = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
            $doc.parameters.workloadContributorsGroupObjectId.value = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
            $doc.parameters.readOnlyAuditorsGroupObjectId.value = 'dddddddd-dddd-dddd-dddd-dddddddddddd'
            $doc.parameters.activityLogExportPolicyEffect.value = 'DeployIfNotExists'
            $doc.parameters.deployRoleAssignments.value = $true
            $doc.parameters.deployLoggingRemediationRoleAssignments.value = $true
            $doc.parameters.deployCentralLogAnalytics.value = $false
            $doc.parameters.existingLogAnalyticsWorkspaceResourceId.value = $workspaceId
            $path = Join-Path $TempDir 'workspace-dine.json'
            $doc | ConvertTo-Json -Depth 20 | Set-Content -Path $path -Encoding utf8
            $env:MOCK_REST_JSON = '{"value":[{"actions":["microsoft.authorization/policyassignments/write","microsoft.authorization/policydefinitions/write","microsoft.authorization/policysetdefinitions/write","microsoft.authorization/roleassignments/write"],"notActions":[]}]}'
            $env:MOCK_WORKSPACE_ID = $workspaceId
            $env:MOCK_WORKSPACE_REST_JSON = $workspacePermission
            $output = & (Join-Path $ProjectDir 'scripts/preflight.ps1') -ParameterFile $path 2>&1
            $passed = ($LASTEXITCODE -eq 0)
            if ($passed -ne ($workspacePermission -match 'roleassignments/write')) { throw "External workspace DINE permission fixture did not use the supplied workspace scope: $($output -join ' ')" }
        }
        Remove-Item env:MOCK_WORKSPACE_ID, env:MOCK_WORKSPACE_REST_JSON -ErrorAction SilentlyContinue
        $doc = $baseDocument | ConvertFrom-Json
        $doc.parameters.tenantRootManagementGroupId.value = 'demo-root'
        $doc.parameters.connectivitySubscriptionId.value = '11111111-1111-1111-1111-111111111111'
        $doc.parameters.workloadSubscriptionId.value = '22222222-2222-2222-2222-222222222222'
        $doc.parameters.governanceAdminsGroupObjectId.value = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        $doc.parameters.networkOperatorsGroupObjectId.value = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
        $doc.parameters.workloadContributorsGroupObjectId.value = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
        $doc.parameters.readOnlyAuditorsGroupObjectId.value = 'dddddddd-dddd-dddd-dddd-dddddddddddd'
        if ($case.ContainsKey('Mutator') -and $null -ne $case.Mutator) { & $case.Mutator $doc }
        $path = Join-Path $TempDir ($case.Name + '.json')
        $doc | ConvertTo-Json -Depth 20 | Set-Content -Path $path -Encoding utf8

        $env:PROJECT_DIR = $ProjectDir
        $env:MOCK_REST_JSON = $case.RestJson
        $output = & (Join-Path $ProjectDir 'scripts/preflight.ps1') -ParameterFile $path 2>&1
        $passed = ($LASTEXITCODE -eq 0)
        if (($case.Expected -eq 'pass' -and -not $passed) -or ($case.Expected -eq 'fail' -and $passed)) {
            throw "Offline parity case $($case.Name) expected $($case.Expected) but got $($passed.ToString().ToLowerInvariant()). Output: $($output -join ' ')"
        }
    }
    $collisionDocument = $baseDocument | ConvertFrom-Json
    $collisionDocument.parameters.tenantRootManagementGroupId.value = 'demo-root'
    $collisionDocument.parameters.connectivitySubscriptionId.value = '11111111-1111-1111-1111-111111111111'
    $collisionDocument.parameters.workloadSubscriptionId.value = '22222222-2222-2222-2222-222222222222'
    $collisionDocument.parameters.governanceAdminsGroupObjectId.value = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    $collisionDocument.parameters.networkOperatorsGroupObjectId.value = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
    $collisionDocument.parameters.workloadContributorsGroupObjectId.value = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
    $collisionDocument.parameters.readOnlyAuditorsGroupObjectId.value = 'dddddddd-dddd-dddd-dddd-dddddddddddd'
    $collisionDocument.parameters.namePrefix.value = 'demo'
    $collisionDocument.parameters.deployEvidenceResources.value = $true
    $collisionPath = Join-Path $TempDir 'collision.parameters.json'
    $collisionDocument | ConvertTo-Json -Depth 20 | Set-Content -Path $collisionPath -Encoding utf8
    foreach ($collisionCase in @(
        @{ Name = 'absent'; Expected = $true },
        @{ Name = 'existing'; Expected = $true; Exists = 'true'; Owner = 'demo' },
        @{ Name = 'unreadable'; Expected = $false; Exists = 'true'; ShowError = 'true' },
        @{ Name = 'mismatched'; Expected = $false; Exists = 'true'; Owner = 'external' },
        @{ Name = 'error'; Expected = $false; ExistsError = 'true' }
    )) {
        foreach ($name in 'MOCK_GROUP_EXISTS', 'MOCK_GROUP_OWNER', 'MOCK_GROUP_SHOW_ERROR', 'MOCK_GROUP_EXISTS_ERROR') { Remove-Item "env:$name" -ErrorAction SilentlyContinue }
        if ($collisionCase.ContainsKey('Exists')) { $env:MOCK_GROUP_EXISTS = $collisionCase.Exists }
        if ($collisionCase.ContainsKey('Owner')) { $env:MOCK_GROUP_OWNER = $collisionCase.Owner }
        if ($collisionCase.ContainsKey('ShowError')) { $env:MOCK_GROUP_SHOW_ERROR = $collisionCase.ShowError }
        if ($collisionCase.ContainsKey('ExistsError')) { $env:MOCK_GROUP_EXISTS_ERROR = $collisionCase.ExistsError }
        $env:MOCK_REST_JSON = '{"value":[{"actions":["microsoft.authorization/policyassignments/write","microsoft.authorization/policydefinitions/write","microsoft.authorization/policysetdefinitions/write","microsoft.authorization/roleassignments/write"],"notActions":[]}]}'
        $output = & (Join-Path $ProjectDir 'scripts/preflight.ps1') -ParameterFile $collisionPath 2>&1
        if (($LASTEXITCODE -eq 0) -ne $collisionCase.Expected) { throw "Resource-group collision fixture $($collisionCase.Name) failed. Output: $($output -join ' ')" }
    }
    foreach ($name in 'MOCK_GROUP_EXISTS', 'MOCK_GROUP_OWNER', 'MOCK_GROUP_SHOW_ERROR', 'MOCK_GROUP_EXISTS_ERROR') { Remove-Item "env:$name" -ErrorAction SilentlyContinue }

    Write-Host 'Offline parity suite passed.'
    }
    finally {
        if ($null -eq $priorAz) { Remove-Item function:az -ErrorAction SilentlyContinue }
        else { Set-Item function:az -Value $priorAz }
        foreach ($entry in @(
            @{ Name = 'PROJECT_DIR'; Value = $priorProjectDir },
            @{ Name = 'MOCK_REST_JSON'; Value = $priorRestJson },
            @{ Name = 'MOCK_ACCOUNT_JSON'; Value = $priorAccountJson })) {
            if ($null -eq $entry.Value) { Remove-Item "env:$($entry.Name)" -ErrorAction SilentlyContinue }
            else { Set-Item "env:$($entry.Name)" -Value $entry.Value }
        }
        if ($null -eq $priorLastExitCode) { Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue }
        else { $global:LASTEXITCODE = $priorLastExitCode }
        Remove-Variable -Name OfflinePolicyVersions -Scope Global -ErrorAction SilentlyContinue
    }
}

function Invoke-TeardownOfflineFixture {
    $fixtureDir = Join-Path $TempDir 'teardown-fixture'
    New-Item -ItemType Directory -Path $fixtureDir -Force | Out-Null
    $parameterPath = Join-Path $fixtureDir 'teardown.parameters.json'
    $parameterJson = @'
{
  "parameters": {
    "tenantRootManagementGroupId": { "value": "tenant-root" },
    "namePrefix": { "value": "demo" },
    "workloadArchetype": { "value": "workloads" },
    "connectivitySubscriptionId": { "value": "11111111-1111-1111-1111-111111111111" },
    "workloadSubscriptionId": { "value": "22222222-2222-2222-2222-222222222222" },
    "governanceAdminsGroupObjectId": { "value": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" },
    "networkOperatorsGroupObjectId": { "value": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" },
    "workloadContributorsGroupObjectId": { "value": "cccccccc-cccc-cccc-cccc-cccccccccccc" },
    "readOnlyAuditorsGroupObjectId": { "value": "dddddddd-dddd-dddd-dddd-dddddddddddd" },
    "deployCentralLogAnalytics": { "value": false },
    "deployRecoveryServicesVault": { "value": true },
    "deployRoleAssignments": { "value": true },
    "deployEvidenceResources": { "value": true },
    "enableFirewallRouteGuardrails": { "value": false },
    "enableCriticalInfrastructure": { "value": true },
    "criticalInfrastructureSubscriptionIds": { "value": ["55555555-5555-5555-5555-555555555555"] },
    "enableNercCipTechnicalOverlay": { "value": true },
    "existingLogAnalyticsWorkspaceResourceId": {
      "value": "/SUBSCRIPTIONS/11111111-1111-1111-1111-111111111111/RESOURCEGROUPS/rg-demo-connectivity/PROVIDERS/MICROSOFT.OPERATIONALINSIGHTS/WORKSPACES/ws-protected"
    },
    "approvedFirewallResourceId": {
      "value": "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-demo-connectivity/providers/Microsoft.Network/azureFirewalls/fw-protected"
    },
    "approvedRouteTableResourceIds": {
      "value": ["/subscriptions/22222222-2222-2222-2222-222222222222/RESOURCEGROUPS/rg-demo-workloads-demo/PROVIDERS/Microsoft.Network/routeTables/rt-protected"]
    },
    "approvedBackupVaults": {
      "value": [{"vaultResourceId": "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-demo-backup/providers/Microsoft.RecoveryServices/vaults/vault-protected", "backupPolicyResourceId": "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-demo-backup/providers/Microsoft.RecoveryServices/vaults/vault-protected/backupPolicies/policy-protected"}]
    },
    "policyExemptions": { "value": [] },
    "enableVmBackupRemediation": { "value": false }
  }
}
'@
    Set-Content -LiteralPath $parameterPath -Value $parameterJson -Encoding utf8

    $mockDir = Join-Path $fixtureDir 'mock-bin'
    New-Item -ItemType Directory -Path $mockDir -Force | Out-Null
    $mockAzPath = Join-Path $mockDir 'az'
    $mockAzScript = @'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${MOCK_AZ_LOG:-}" ]]; then
  printf '%s\n' "az $*" >> "${MOCK_AZ_LOG}"
fi
[[ $# -gt 0 ]] || exit 0
case "${1}" in
  group)
    case "${2:-}" in
      exists)
        if [[ -n "${MOCK_AZ_WAIT_FALLBACK_FILE:-}" && -f "${MOCK_AZ_WAIT_FALLBACK_FILE}" ]]; then
          printf '%s\n' invalid
          exit 0
        fi
        case "$*" in
          *"rg-demo-monitoring"*) printf 'true\n'; exit 0 ;;
          *"rg-demo-connectivity"*) printf 'true\n'; exit 0 ;;
          *"rg-demo-workloads-demo"*) printf 'true\n'; exit 0 ;;
          *"rg-demo-backup"*) printf 'true\n'; exit 0 ;;
          *) printf 'false\n'; exit 0 ;;
        esac
        ;;
      show)
        case "$*" in
          *"rg-demo-monitoring"*) printf '%s\n' "${MOCK_AZ_OWNER:-demo}"; exit 0 ;;
          *"rg-demo-connectivity"*) printf '%s\n' "${MOCK_AZ_OWNER:-demo}"; exit 0 ;;
          *"rg-demo-workloads-demo"*) printf '%s\n' "${MOCK_AZ_OWNER:-demo}"; exit 0 ;;
          *"rg-demo-backup"*) printf '%s\n' "${MOCK_AZ_OWNER:-demo}"; exit 0 ;;
          *) printf '%s\n' ''; exit 0 ;;
        esac
        ;;
      wait)
        if [[ -n "${MOCK_AZ_WAIT_FALLBACK_FILE:-}" ]]; then
          : > "${MOCK_AZ_WAIT_FALLBACK_FILE}"
          exit 1
        fi
        exit 0
        ;;
    esac
    ;;
  policy)
    if [[ "${2:-}" == "assignment" && "${3:-}" == "show" ]]; then
      case "$*" in
        *"demo-nerc-cip-technical"*) printf '%s\n' 'nerc-assignment-principal'; exit 0 ;;
      esac
      printf '%s\n' 'null'; exit 0
    fi
    if [[ "${2:-}" == "assignment" && "${3:-}" == "delete" ]]; then exit 0; fi
    if [[ "${2:-}" == "set-definition" && "${3:-}" == "delete" ]]; then exit 0; fi
    if [[ "${2:-}" == "definition" && "${3:-}" == "delete" ]]; then exit 0; fi
    ;;
  role)
    if [[ "${2:-}" == "assignment" && "${3:-}" == "list" ]]; then
      if [[ "$*" == *"nerc-assignment-principal"* && "$*" == *"ws-protected"* ]]; then
        printf '%s\n' 'NERC-ROLE-ASSIGNMENT-ID'
        exit 0
      fi
      printf '%s\n' ''
      exit 0
    fi
    if [[ "${2:-}" == "assignment" && "${3:-}" == "delete" ]]; then exit 0; fi
    ;;
  account)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
exit 0
'@
    Set-Content -LiteralPath $mockAzPath -Value $mockAzScript -Encoding utf8
    & bash -c "chmod +x '$mockAzPath'"
    $mockAzCmdPath = Join-Path $mockDir 'az.cmd'
    @'
@echo off
echo az %* >> "%MOCK_AZ_LOG%"
set "args=%*"
if "%MOCK_AZ_OWNER%"=="" (set "owner=demo") else (set "owner=%MOCK_AZ_OWNER%")
if /I "%~1 %~2 %~3"=="policy assignment show" (
  echo %args% | findstr /I /C:"demo-nerc-cip-technical" >nul
  if not errorlevel 1 (
    echo nerc-assignment-principal
  ) else (
    echo null
  )
  exit /b 0
)
if /I "%~1 %~2 %~3"=="role assignment list" (
  echo %args% | findstr /I /C:"nerc-assignment-principal" >nul || exit /b 0
  echo %args% | findstr /I /C:"ws-protected" >nul || exit /b 0
  echo NERC-ROLE-ASSIGNMENT-ID
  exit /b 0
)
if /I "%~1 %~2"=="group exists" (
  if not "%MOCK_AZ_WAIT_FALLBACK_FILE%"=="" if exist "%MOCK_AZ_WAIT_FALLBACK_FILE%" (echo invalid& exit /b 0)
  echo %args% | findstr /I /C:"rg-demo-monitoring" /C:"rg-demo-connectivity" /C:"rg-demo-workloads-demo" /C:"rg-demo-backup" >nul
  if errorlevel 1 (echo false) else (echo true)
  exit /b 0
)
if /I "%~1 %~2"=="group wait" (
  if not "%MOCK_AZ_WAIT_FALLBACK_FILE%"=="" (type nul > "%MOCK_AZ_WAIT_FALLBACK_FILE%"& exit /b 1)
  exit /b 0
)
if /I "%~1 %~2"=="group show" (
  echo %args% | findstr /I /C:"rg-demo-monitoring" /C:"rg-demo-connectivity" /C:"rg-demo-workloads-demo" /C:"rg-demo-backup" >nul
  if errorlevel 1 (echo.) else (echo %owner%)
  exit /b 0
)
exit /b 0
'@ | Set-Content -LiteralPath $mockAzCmdPath

    $pwshCommand = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($null -eq $pwshCommand) {
        Write-Host 'PowerShell teardown offline fixture skipped because pwsh is unavailable.'
        return
    }
    $scriptPath = Join-Path $ProjectDir 'scripts/teardown.ps1'
    $wrapperPath = Join-Path $fixtureDir 'invoke-teardown-with-mock-check.ps1'
    @'
param(
    [Parameter(Mandatory = $true)][string]$ParameterFile,
    [Parameter(Mandatory = $true)][string]$ExpectedMockDir,
    [Parameter(Mandatory = $true)][string]$TeardownScript,
    [Parameter(Mandatory = $true)][string]$Confirmation,
    [switch]$MissingConfirmation
)
$azCommand = Get-Command az -ErrorAction SilentlyContinue
if ($null -eq $azCommand -or -not $azCommand.Source.StartsWith($ExpectedMockDir, [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Error "az did not resolve to the fixture mock directory."
    exit 1
}
$global:FixtureTeardownConfirmation = $Confirmation
function global:Read-Host { param([string]$Prompt) $global:FixtureTeardownConfirmation }
if ($MissingConfirmation) { Remove-Item Env:ESLZ_TEARDOWN_CONFIRMATION -ErrorAction SilentlyContinue }
& $TeardownScript -ParameterFile $ParameterFile -Execute
exit $LASTEXITCODE
'@ | Set-Content -LiteralPath $wrapperPath

    $goodLog = Join-Path $fixtureDir 'good.log'
    $previousPath = $env:PATH
    $previousMockLog = $env:MOCK_AZ_LOG
    $previousConfirmation = $env:ESLZ_TEARDOWN_CONFIRMATION
    try {
        $env:PATH = "$mockDir$([System.IO.Path]::PathSeparator)$previousPath"
        $env:MOCK_AZ_LOG = $goodLog
        $env:ESLZ_TEARDOWN_CONFIRMATION = 'DELETE-ESLZ-DEMO'
        $goodOutput = & $pwshCommand.Source -NoLogo -NoProfile -ExecutionPolicy Bypass -File $wrapperPath -ParameterFile $parameterPath -ExpectedMockDir $mockDir -TeardownScript $scriptPath -Confirmation 'demo' 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "PowerShell teardown fixture unexpectedly failed with valid confirmation. Output: $($goodOutput -join ' ')"
        }
    }
    finally {
        $env:PATH = $previousPath
        if ($null -eq $previousMockLog) { Remove-Item Env:MOCK_AZ_LOG -ErrorAction SilentlyContinue } else { $env:MOCK_AZ_LOG = $previousMockLog }
        if ($null -eq $previousConfirmation) { Remove-Item Env:ESLZ_TEARDOWN_CONFIRMATION -ErrorAction SilentlyContinue } else { $env:ESLZ_TEARDOWN_CONFIRMATION = $previousConfirmation }
    }

    $lines = @(Get-Content -LiteralPath $goodLog -ErrorAction SilentlyContinue | Where-Object { $_ -like 'az *' })
    $roleDeleteIndex = -1
    $policyDeleteIndex = -1
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -eq 'az role assignment delete --ids NERC-ROLE-ASSIGNMENT-ID' -and $roleDeleteIndex -lt 0) { $roleDeleteIndex = $index }
        if ($lines[$index] -eq 'az policy assignment delete --name demo-nerc-cip-technical --scope /providers/Microsoft.Management/managementGroups/demo-criticalinfra' -and $policyDeleteIndex -lt 0) { $policyDeleteIndex = $index }
        if ($roleDeleteIndex -ge 0 -and $policyDeleteIndex -ge 0) { break }
    }
    if ($roleDeleteIndex -lt 0 -or $policyDeleteIndex -lt 0 -or ($roleDeleteIndex + 1) -ne $policyDeleteIndex) {
        throw "PowerShell teardown fixture expected NERC role delete immediately before NERC assignment delete. Log: $($lines -join ' | ')"
    }
    foreach ($line in $lines) {
        if ($line -match 'az group (delete|wait).*rg-demo-(connectivity|workloads-demo|backup)') {
            throw "PowerShell teardown fixture acted on a protected external resource group: $line"
        }
    }

    $mismatchedOwnerLog = Join-Path $fixtureDir 'mismatched-owner.log'
    $mismatchedOwnerPreviousPath = $env:PATH
    $mismatchedOwnerPreviousMockLog = $env:MOCK_AZ_LOG
    $mismatchedOwnerPreviousConfirmation = $env:ESLZ_TEARDOWN_CONFIRMATION
    $previousOwner = $env:MOCK_AZ_OWNER
    try {
        $env:PATH = "$mockDir$([System.IO.Path]::PathSeparator)$mismatchedOwnerPreviousPath"
        $env:MOCK_AZ_LOG = $mismatchedOwnerLog
        $env:MOCK_AZ_OWNER = 'external'
        $env:ESLZ_TEARDOWN_CONFIRMATION = 'DELETE-ESLZ-DEMO'
        $mismatchedOwnerOutput = & $pwshCommand.Source -NoLogo -NoProfile -ExecutionPolicy Bypass -File $wrapperPath -ParameterFile $parameterPath -ExpectedMockDir $mockDir -TeardownScript $scriptPath -Confirmation 'demo' 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "PowerShell teardown fixture failed for a mismatched resource-group owner marker. Output: $($mismatchedOwnerOutput -join ' ')"
        }
    }
    finally {
        $env:PATH = $mismatchedOwnerPreviousPath
        if ($null -eq $mismatchedOwnerPreviousMockLog) { Remove-Item Env:MOCK_AZ_LOG -ErrorAction SilentlyContinue } else { $env:MOCK_AZ_LOG = $mismatchedOwnerPreviousMockLog }
        if ($null -eq $mismatchedOwnerPreviousConfirmation) { Remove-Item Env:ESLZ_TEARDOWN_CONFIRMATION -ErrorAction SilentlyContinue } else { $env:ESLZ_TEARDOWN_CONFIRMATION = $mismatchedOwnerPreviousConfirmation }
        if ($null -eq $previousOwner) { Remove-Item Env:MOCK_AZ_OWNER -ErrorAction SilentlyContinue } else { $env:MOCK_AZ_OWNER = $previousOwner }
    }
    $mismatchedOwnerText = Get-Content -LiteralPath $mismatchedOwnerLog -Raw
    if ($mismatchedOwnerText -match 'az group (delete|wait).*--name rg-demo-(monitoring|connectivity|workloads-demo)') {
        throw "PowerShell teardown fixture acted on a mismatched-owner resource group: $mismatchedOwnerText"
    }

    $waitFallbackParameters = Join-Path $fixtureDir 'wait-fallback.parameters.json'
    $waitFallbackDocument = Get-Content -LiteralPath $parameterPath -Raw | ConvertFrom-Json
    $waitFallbackDocument.parameters.deployEvidenceResources.value = $false
    $waitFallbackDocument.parameters.deployCentralLogAnalytics.value = $true
    $waitFallbackDocument.parameters.deployRecoveryServicesVault.value = $false
    $waitFallbackDocument.parameters.existingLogAnalyticsWorkspaceResourceId.value = ''
    $waitFallbackDocument.parameters.approvedFirewallResourceId.value = ''
    $waitFallbackDocument.parameters.approvedRouteTableResourceIds.value = @()
    $waitFallbackDocument.parameters.approvedBackupVaults.value = @()
    $waitFallbackDocument | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $waitFallbackParameters -Encoding utf8
    $waitFallbackMarker = Join-Path $fixtureDir 'wait-fallback.marker'
    $waitFallbackPreviousPath = $env:PATH
    $waitFallbackPreviousLog = $env:MOCK_AZ_LOG
    $waitFallbackPreviousConfirmation = $env:ESLZ_TEARDOWN_CONFIRMATION
    $waitFallbackPreviousMarker = $env:MOCK_AZ_WAIT_FALLBACK_FILE
    try {
        $env:PATH = "$mockDir$([System.IO.Path]::PathSeparator)$waitFallbackPreviousPath"
        $env:MOCK_AZ_LOG = Join-Path $fixtureDir 'wait-fallback.log'
        $env:MOCK_AZ_WAIT_FALLBACK_FILE = $waitFallbackMarker
        $env:ESLZ_TEARDOWN_CONFIRMATION = 'DELETE-ESLZ-DEMO'
        $null = & $pwshCommand.Source -NoLogo -NoProfile -ExecutionPolicy Bypass -File $wrapperPath -ParameterFile $waitFallbackParameters -ExpectedMockDir $mockDir -TeardownScript $scriptPath -Confirmation 'demo' 2>&1
        if ($LASTEXITCODE -eq 0) { throw 'PowerShell teardown fixture accepted an invalid post-wait existence result.' }
    }
    finally {
        $env:PATH = $waitFallbackPreviousPath
        if ($null -eq $waitFallbackPreviousLog) { Remove-Item Env:MOCK_AZ_LOG -ErrorAction SilentlyContinue } else { $env:MOCK_AZ_LOG = $waitFallbackPreviousLog }
        if ($null -eq $waitFallbackPreviousConfirmation) { Remove-Item Env:ESLZ_TEARDOWN_CONFIRMATION -ErrorAction SilentlyContinue } else { $env:ESLZ_TEARDOWN_CONFIRMATION = $waitFallbackPreviousConfirmation }
        if ($null -eq $waitFallbackPreviousMarker) { Remove-Item Env:MOCK_AZ_WAIT_FALLBACK_FILE -ErrorAction SilentlyContinue } else { $env:MOCK_AZ_WAIT_FALLBACK_FILE = $waitFallbackPreviousMarker }
    }

    foreach ($case in @(
        @{ Name = 'missing-env'; Confirmation = $null; Input = 'demo' },
        @{ Name = 'wrong-confirm'; Confirmation = 'DELETE-ESLZ-DEMO'; Input = 'wrong-demo-root' }
    )) {
        $caseLog = Join-Path $fixtureDir "$($case.Name).log"
        Remove-Item -LiteralPath $caseLog -ErrorAction SilentlyContinue
        $casePreviousPath = $env:PATH
        $casePreviousMockLog = $env:MOCK_AZ_LOG
        $casePreviousConfirmation = $env:ESLZ_TEARDOWN_CONFIRMATION
        $caseExitCode = 0
        try {
            $env:PATH = "$mockDir$([System.IO.Path]::PathSeparator)$casePreviousPath"
            $env:MOCK_AZ_LOG = $caseLog
            if ($null -eq $case.Confirmation) {
                Remove-Item Env:ESLZ_TEARDOWN_CONFIRMATION -ErrorAction SilentlyContinue
            }
            else {
                $env:ESLZ_TEARDOWN_CONFIRMATION = $case.Confirmation
            }
            $missingConfirmationArgument = if ($null -eq $case.Confirmation) { @('-MissingConfirmation') } else { @() }
            $caseOutput = & $pwshCommand.Source -NoLogo -NoProfile -ExecutionPolicy Bypass -File $wrapperPath -ParameterFile $parameterPath -ExpectedMockDir $mockDir -TeardownScript $scriptPath -Confirmation $case.Input @missingConfirmationArgument 2>&1
            $caseExitCode = $LASTEXITCODE
        }
        finally {
            $env:PATH = $casePreviousPath
            if ($null -eq $casePreviousMockLog) { Remove-Item Env:MOCK_AZ_LOG -ErrorAction SilentlyContinue } else { $env:MOCK_AZ_LOG = $casePreviousMockLog }
            if ($null -eq $casePreviousConfirmation) { Remove-Item Env:ESLZ_TEARDOWN_CONFIRMATION -ErrorAction SilentlyContinue } else { $env:ESLZ_TEARDOWN_CONFIRMATION = $casePreviousConfirmation }
        }
        if ($caseExitCode -eq 0) {
            throw "PowerShell teardown fixture should fail for blocked confirmation: $($case.Name)"
        }
        $blockedText = if (Test-Path -LiteralPath $caseLog) { Get-Content -LiteralPath $caseLog -Raw } else { '' }
        if ($blockedText -match 'az (group delete|group wait|role assignment delete|policy assignment delete|policy definition delete|account management-group delete)') {
            throw "PowerShell teardown fixture emitted destructive calls for blocked confirmation: $($case.Name)"
        }
    }

    Write-Host 'PowerShell teardown offline fixture passed.'
}

if ($env:ESLZ_OFFLINE_TESTS -eq '1') {
    Invoke-OfflineParitySuite
    Invoke-TeardownOfflineFixture
    return
}

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
            $nameProperty -and $nameProperty.Value -in @('central-monitoring', 'central-monitoring-workspace', 'central-monitoring-sentinel', 'activity-log-workspace-destination-rbac', 'resource-diagnostics-workspace-destination-rbac', 'customer-owned-backup-vault')) {
            return $results
        }
        $existingProperty = $Node.PSObject.Properties['existing']
        $isExistingReference = ($null -ne $existingProperty -and $existingProperty.Value -eq $true)
        $prohibitedPattern = '^Microsoft\.(Compute/virtualMachines|OperationalInsights/workspaces|Network/(azureFirewalls|bastionHosts|natGateways|publicIPAddresses|virtualNetworkGateways)|RecoveryServices/vaults|Storage/storageAccounts)$'
        if (-not $isExistingReference -and $typeProperty -and $apiVersionProperty -and $typeProperty.Value -match $prohibitedPattern) {
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
    $realAzCommand = Get-Command az -ErrorAction SilentlyContinue
    if ($null -eq $realAzCommand) {
        Stop-Test 'Azure CLI is required for Bicep validation.'
    }
    $realAzSource = $realAzCommand.Source

    Invoke-OfflineParitySuite
    if ((Get-Command az -ErrorAction SilentlyContinue).Source -ne $realAzSource) {
        Stop-Test 'Offline preflight tests must restore the real Azure CLI command.'
    }

    Write-Host '1/30 Validate repository versioning and branch guidance...'
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

    Write-Host '2/30 Build the complete tenant template and validate policy assignment shapes...'
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
    $expectedEvidenceTags = @{
        'connectivity-evidence' = @{
            CostCenter = 'Demo'; ApplicationName = 'Connectivity Evidence'; Owner = 'Platform Team'
            Environment = 'Sandbox'; DataClassification = 'Non-sensitive'; 'SSP-ID' = 'Demo'
            Purpose = 'Landing Zone Evidence'
        }
        'workload-evidence' = @{
            CostCenter = 'Demo'; ApplicationName = 'Landing Zone Demo'; Owner = 'Workload Team'
            Environment = 'Sandbox'; DataClassification = 'Non-sensitive'; 'SSP-ID' = 'Demo'
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
        $resourceGroupTags = @($evidenceDeployment.properties.template.resources |
            Where-Object { $_.type -eq 'Microsoft.Resources/resourceGroups' })[0].tags
        $evidenceTags = if ($evidenceDeploymentName -eq 'connectivity-evidence') {
            $evidenceDeployment.properties.template.variables.commonTags
        } else {
            $resourceGroupTags
        }
        foreach ($expectedTag in $expectedEvidenceTags[$evidenceDeploymentName].Keys) {
            if (-not $evidenceTags.PSObject.Properties[$expectedTag] -or
                $evidenceTags.PSObject.Properties[$expectedTag].Value -cne $expectedEvidenceTags[$evidenceDeploymentName][$expectedTag]) {
                Stop-Test "$evidenceDeploymentName resource group has an invalid $expectedTag tag."
            }
        }
        $expectedLifecycleTag = if ($evidenceDeploymentName -eq 'connectivity-evidence') {
            "[union(variables('commonTags'), createObject('ESLZLifecycleOwner', parameters('namePrefix')))]"
        } else {
            "[parameters('namePrefix')]"
        }
        if (($evidenceDeploymentName -eq 'connectivity-evidence' -and $resourceGroupTags -cne $expectedLifecycleTag) -or
            ($evidenceDeploymentName -eq 'workload-evidence' -and $resourceGroupTags.ESLZLifecycleOwner -cne $expectedLifecycleTag)) {
            Stop-Test "$evidenceDeploymentName resource group must bind ESLZLifecycleOwner to namePrefix."
        }
    }
    $inheritanceInitiative = Find-JsonObjects -Node $compiledJson -Predicate {
        param($node)
        $node.PSObject.Properties['type'] -and $node.type -eq 'Microsoft.Resources/deployments' -and
        $node.PSObject.Properties['name'] -and $node.name -eq 'tag-inheritance-initiative'
    } | Select-Object -First 1
    $inheritanceAssignment = Find-JsonObjects -Node $compiledJson -Predicate {
        param($node)
        $node.PSObject.Properties['type'] -and $node.type -eq 'Microsoft.Resources/deployments' -and
        $node.PSObject.Properties['name'] -and $node.name -eq 'assign-tag-inheritance'
    } | Select-Object -First 1
    if ($null -eq $inheritanceInitiative -or $null -eq $inheritanceAssignment) {
        Stop-Test 'Tag-inheritance initiative or remediating assignment deployment is missing.'
    }
    $inheritanceReferences = @($inheritanceInitiative.properties.parameters.policyDefinitionReferences.value)
    if ($inheritanceReferences.Count -ne 6 -or
        (Compare-Object -ReferenceObject $requiredTags -DifferenceObject @($inheritanceReferences.parameters.tagName.value) -CaseSensitive)) {
        Stop-Test 'Tag-inheritance initiative must contain the exact six case-sensitive tag names.'
    }
    foreach ($inheritanceReference in $inheritanceReferences) {
        if ($inheritanceReference.policyDefinitionId -cne "[variables('inheritResourceGroupTagPolicyDefinitionId')]" -or
            $inheritanceReference.definitionVersion -cne '1.*.*' -or
            -not $inheritanceReference.policyDefinitionReferenceId.StartsWith('inherit-')) {
            Stop-Test 'Every tag-inheritance control must use the pinned verified built-in and a stable reference ID.'
        }
    }
    if (-not $inheritanceInitiative.scope.Contains('demoRootManagementGroupId') -or
        -not $inheritanceAssignment.scope.Contains('landingZonesManagementGroupId') -or
        $inheritanceAssignment.properties.parameters.location.value -cne "[parameters('deploymentLocation')]" -or
        $inheritanceAssignment.properties.parameters.identity.value.type -cne 'SystemAssigned' -or
        @($inheritanceAssignment.properties.parameters.verifiedRoleDefinitionIds.value).Count -ne 1 -or
        $inheritanceAssignment.properties.parameters.verifiedRoleDefinitionIds.value[0] -cne "[variables('contributorRoleDefinitionId')]" -or
        $inheritanceAssignment.properties.parameters.enforcementMode.value -cne "[parameters('denyPolicyEnforcementMode')]" -or
        $inheritanceAssignment.condition -cne "[parameters('enableTagInheritance')]" -or
        $compiledJson.parameters.enableTagInheritance.defaultValue -ne $false -or
        $compiledJson.outputs.tagInheritanceRemediation.value.enabled -cne "[parameters('enableTagInheritance')]") {
        Stop-Test 'Tag-inheritance scope, identity, location, role, or safe enforcement wiring is invalid.'
    }
    $remediationResources = @(Find-JsonObjects -Node $compiledJson -Predicate {
        param($node)
        $node.PSObject.Properties['type'] -and $node.type -eq 'Microsoft.PolicyInsights/remediations'
    })
    if ($remediationResources.Count -ne 0 -or
        $compiledJson.outputs.tagInheritanceRemediation.value.remediationStarted -ne $false) {
        Stop-Test 'The safe template must expose remediation inputs without starting a remediation task.'
    }
    $catalog = Get-Content -LiteralPath (Join-Path $ProjectDir 'policy/control-catalog.json') -Raw | ConvertFrom-Json
    $inheritanceControls = @($catalog.controls | Where-Object { $_.id -match '^REQ-TAG-(0[7-9]|1[0-2])$' })
    if ($inheritanceControls.Count -ne 6) {
        Stop-Test 'The control catalog must contain all six tag-inheritance controls.'
    }
    foreach ($inheritanceControl in $inheritanceControls) {
        if ($inheritanceControl.mechanism.definitionId -cne 'ea3f2387-9b95-492a-a190-fcdc54f7b070' -or
            $inheritanceControl.mechanism.verificationMethod -cne 'raw-json' -or
            @($inheritanceControl.supportedEffects).Count -ne 1 -or
            $inheritanceControl.supportedEffects[0] -cne 'Modify' -or
            @($inheritanceControl.roleDefinitionIds).Count -ne 1 -or
            $inheritanceControl.roleDefinitionIds[0] -cne 'b24988ac-6180-42a0-ab88-20f7382dd24c' -or
            $inheritanceControl.remediationIdentityRequired -ne $true -or
            -not $inheritanceControl.notes.Contains('only adds a missing tag') -or
            -not $inheritanceControl.notes.Contains('never overwrites an existing tag value')) {
            Stop-Test "Verified built-in Modify semantics are invalid for $($inheritanceControl.id)."
        }
    }
    & (Join-Path $ScriptDir 'validate-remediating-policy-assignment.ps1')

    Write-Host '3/30 Validate the safe-demo and customer-control parameter templates...'
    $parameterTemplatePath = Join-Path $ProjectDir 'parameters/demo.parameters.template.json'
    $parameterTemplate = Get-Content -LiteralPath $parameterTemplatePath -Raw | ConvertFrom-Json
    if ($parameterTemplate.parameters.deployRoleAssignments.value -ne $false) {
        Stop-Test 'deployRoleAssignments must default to false.'
    }
    if ($parameterTemplate.parameters.deployEvidenceResources.value -ne $false) {
        Stop-Test 'deployEvidenceResources must default to false.'
    }
    if ($parameterTemplate.parameters.enableTagInheritance.value -ne $false) {
        Stop-Test 'enableTagInheritance must default to false.'
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
    if ($parameterTemplate.parameters.resourceDiagnosticsPolicyEffect.value -ne 'Disabled' -or
        $parameterTemplate.parameters.policyExemptions.value.Count -ne 0) {
        Stop-Test 'Safe-demo diagnostics and policy exemptions must remain disabled and empty by default.'
    }
    $safeDemoParametersPath = Join-Path $TempDir 'main.parameters.json'
    & az bicep build-params `
        --file (Join-Path $ProjectDir 'parameters/main.template.bicepparam') `
        --outfile $safeDemoParametersPath
    if ($LASTEXITCODE -ne 0) { Stop-Test 'Safe-demo Bicep parameter build failed.' }
    $compiledParametersPath = Join-Path $TempDir 'customer-control.parameters.json'
    & az bicep build-params `
        --file (Join-Path $ProjectDir 'parameters/customer-control.template.bicepparam') `
        --outfile $compiledParametersPath
    if ($LASTEXITCODE -ne 0) { Stop-Test 'Customer-control Bicep parameter build failed.' }
    $safeDemoParameters = Get-Content -LiteralPath $safeDemoParametersPath -Raw | ConvertFrom-Json
    $compiledParameters = Get-Content -LiteralPath $compiledParametersPath -Raw | ConvertFrom-Json
    if ($compiledParameters.parameters.networkIngressPolicyEffect.value -ne 'Audit') {
        Stop-Test 'networkIngressPolicyEffect must default to Audit in the Bicep parameter template.'
    }
    if ($safeDemoParameters.parameters.enableTagInheritance.value -ne $false) {
        Stop-Test 'enableTagInheritance must default to false in the safe-demo Bicep parameter template.'
    }
    if ($compiledParameters.parameters.resourceDiagnosticsPolicyEffect.value -ne 'Disabled' -or
        $compiledParameters.parameters.existingLogAnalyticsWorkspaceResourceId.value -ne '' -or
        $compiledParameters.parameters.policyExemptions.value.Count -ne 0) {
        Stop-Test 'Customer-control diagnostics require an explicit workspace and policy exemptions must remain opt-in.'
    }
    $demoProfileShape = @($parameterTemplate.parameters.PSObject.Properties | Sort-Object Name | ForEach-Object {
        $valueType = if ($null -eq $_.Value.value) { 'null' } else { $_.Value.value.GetType().FullName }
        '{0}:{1}' -f $_.Name, $valueType
    })
    $safeDemoProfileShape = @($safeDemoParameters.parameters.PSObject.Properties | Sort-Object Name | ForEach-Object {
        $valueType = if ($null -eq $_.Value.value) { 'null' } else { $_.Value.value.GetType().FullName }
        '{0}:{1}' -f $_.Name, $valueType
    })
    $customerControlProfileShape = @($compiledParameters.parameters.PSObject.Properties | Sort-Object Name | ForEach-Object {
        $valueType = if ($null -eq $_.Value.value) { 'null' } else { $_.Value.value.GetType().FullName }
        '{0}:{1}' -f $_.Name, $valueType
    })
    if ((Compare-Object $demoProfileShape $safeDemoProfileShape) -or
        (Compare-Object $demoProfileShape $customerControlProfileShape)) {
        Stop-Test 'Safe-demo JSON and both Bicep profiles must expose identical parameter names and value types.'
    }
    $monitoringPositivePath = Join-Path $TempDir 'monitoring-positive.bicepparam'
    $monitoringNegativePath = Join-Path $TempDir 'monitoring-negative.bicepparam'
    $customerControlText = Get-Content -LiteralPath (Join-Path $ProjectDir 'parameters/customer-control.template.bicepparam') -Raw
    $customerControlText = $customerControlText.Replace("using '../main.bicep'", "using '../../main.bicep'")
    [regex]::Replace(
        [regex]::Replace(
            $customerControlText,
            '(?m)^param resourceDiagnosticsPolicyEffect = .*$',
            "param resourceDiagnosticsPolicyEffect = 'AuditIfNotExists'"
        ),
        '(?m)^param existingLogAnalyticsWorkspaceResourceId = .*$',
        "param existingLogAnalyticsWorkspaceResourceId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-monitoring/providers/Microsoft.OperationalInsights/workspaces/logmonitoring'"
    ) | Set-Content -LiteralPath $monitoringPositivePath
    [regex]::Replace(
        $customerControlText,
        '(?m)^param resourceDiagnosticsPolicyEffect = .*$',
        "param resourceDiagnosticsPolicyEffect = 'AuditIfNotExists'"
    ) | Set-Content -LiteralPath $monitoringNegativePath
    & az bicep build-params --file $monitoringPositivePath --outfile "$monitoringPositivePath.json"
    if ($LASTEXITCODE -ne 0) { Stop-Test 'Workspace-backed diagnostics profile failed to compile.' }
    & az bicep build-params --file $monitoringNegativePath --outfile "$monitoringNegativePath.json"
    if ($LASTEXITCODE -ne 0) { Stop-Test 'Workspace-free diagnostics guard profile failed to compile.' }
    if (-not (Select-String -Path (Join-Path $ProjectDir 'main.bicep') -SimpleMatch -Pattern 'var loggingPoliciesRequireWorkspace = loggingAssignmentsRequireWorkspace && !effectiveMonitoringWorkspaceIdIsValid' -Quiet) -or
        -not (Select-String -Path (Join-Path $ProjectDir 'main.bicep') -SimpleMatch -Pattern "fail('Activity Log and supported-resource diagnostics assignments require a valid effective Log Analytics workspace resource ID" -Quiet)) {
        Stop-Test 'Audit/Deploy diagnostics must remain guarded by a valid effective workspace ID.'
    }
    $monitoringPositive = Get-Content -LiteralPath "$monitoringPositivePath.json" -Raw | ConvertFrom-Json
    $monitoringNegative = Get-Content -LiteralPath "$monitoringNegativePath.json" -Raw | ConvertFrom-Json
    if ($monitoringPositive.parameters.resourceDiagnosticsPolicyEffect.value -ne 'AuditIfNotExists' -or
        $monitoringNegative.parameters.resourceDiagnosticsPolicyEffect.value -ne 'AuditIfNotExists' -or
        $monitoringPositive.parameters.existingLogAnalyticsWorkspaceResourceId.value -eq '' -or
        $monitoringNegative.parameters.existingLogAnalyticsWorkspaceResourceId.value -ne '') {
        Stop-Test 'Monitoring guard fixtures must cover workspace-backed and workspace-free diagnostics activation.'
    }
    foreach ($tagInheritanceEnabled in @($false, $true)) {
        $tagParameterPath = Join-Path $TempDir "tag-inheritance-$($tagInheritanceEnabled.ToString().ToLowerInvariant()).bicepparam"
        $tagParameterText = Get-Content -LiteralPath (Join-Path $ProjectDir 'parameters/main.template.bicepparam') -Raw
        $tagParameterText = $tagParameterText.Replace(
            "using '../main.bicep'",
            "using '../../main.bicep'"
        )
        $tagParameterText = [regex]::Replace(
            $tagParameterText,
            '(?m)^param enableTagInheritance = .*$',
            "param enableTagInheritance = $($tagInheritanceEnabled.ToString().ToLowerInvariant())"
        )
        Set-Content -LiteralPath $tagParameterPath -Value $tagParameterText
        $tagParameterJsonPath = "$tagParameterPath.json"
        & az bicep build-params --file $tagParameterPath --outfile $tagParameterJsonPath
        if ($LASTEXITCODE -ne 0) {
            Stop-Test "Tag-inheritance $tagInheritanceEnabled parameter shape failed to compile."
        }
        $tagParameterJson = Get-Content -LiteralPath $tagParameterJsonPath -Raw | ConvertFrom-Json
        if ($tagParameterJson.parameters.enableTagInheritance.value -ne $tagInheritanceEnabled) {
            Stop-Test "Tag-inheritance $tagInheritanceEnabled parameter shape did not compile as expected."
        }
    }

    Write-Host '    Confirm tag remediation workflows remain preview-first and explicitly guarded...'
    $bashTagRemediation = Join-Path $ProjectDir 'scripts/remediate-resource-tags.sh'
    $powerShellTagRemediation = Join-Path $ProjectDir 'scripts/remediate-resource-tags.ps1'
    & bash -n $bashTagRemediation
    if ($LASTEXITCODE -ne 0) { Stop-Test 'Bash tag-remediation workflow has invalid syntax.' }
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $powerShellTagRemediation,
        [ref]$null,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -ne 0) { Stop-Test 'PowerShell tag-remediation workflow has invalid syntax.' }
    $bashRemediationText = Get-Content -LiteralPath $bashTagRemediation -Raw
    $powerShellRemediationText = Get-Content -LiteralPath $powerShellTagRemediation -Raw
    foreach ($requiredText in @(
        'ESLZ_TAG_REMEDIATION_CONFIRMATION',
        'IFS= read -r typed_confirmation',
        'validate_live_controls',
        'az policy remediation create'
    )) {
        if (-not $bashRemediationText.Contains($requiredText)) {
            Stop-Test "Bash tag-remediation workflow is missing $requiredText."
        }
    }
    foreach ($requiredText in @(
        'Start-AzPolicyRemediation',
        '$typedConfirmation = Read-Host',
        'Test-LiveControls'
    )) {
        if (-not $powerShellRemediationText.Contains($requiredText)) {
            Stop-Test "PowerShell tag-remediation workflow is missing $requiredText."
        }
    }
    $unsupportedRemediationCommand = [string]::Concat('New-AzPolicy', 'Remediation')
    & rg -q -F $unsupportedRemediationCommand $ProjectDir
    if ($LASTEXITCODE -eq 0) {
        Stop-Test 'The unsupported PowerShell remediation command remains in the repository.'
    }
    if ($LASTEXITCODE -ne 1) { Stop-Test 'Unable to scan for unsupported PowerShell remediation commands.' }
    $bashPreviewIndex = $bashRemediationText.IndexOf('if [[ "${MODE}" != ''--execute'' ]]', [System.StringComparison]::Ordinal)
    $bashEnvironmentIndex = $bashRemediationText.LastIndexOf('ESLZ_TAG_REMEDIATION_CONFIRMATION', [System.StringComparison]::Ordinal)
    $bashTypedIndex = $bashRemediationText.IndexOf('IFS= read -r typed_confirmation', [System.StringComparison]::Ordinal)
    $bashRevalidationIndex = $bashRemediationText.LastIndexOf('validate_live_controls', [System.StringComparison]::Ordinal)
    $bashCreateIndex = $bashRemediationText.IndexOf('az policy remediation create', [System.StringComparison]::Ordinal)
    if ($bashPreviewIndex -lt 0 -or $bashPreviewIndex -gt $bashEnvironmentIndex -or
        $bashEnvironmentIndex -gt $bashTypedIndex -or $bashTypedIndex -gt $bashRevalidationIndex -or
        $bashRevalidationIndex -gt $bashCreateIndex) {
        Stop-Test 'Bash tag remediation must preview, unlock, type-confirm, revalidate, then create.'
    }
    $powerShellPreviewIndex = $powerShellRemediationText.IndexOf('if (-not $Execute)', [System.StringComparison]::Ordinal)
    $powerShellEnvironmentIndex = $powerShellRemediationText.LastIndexOf('ESLZ_TAG_REMEDIATION_CONFIRMATION', [System.StringComparison]::Ordinal)
    $powerShellTypedIndex = $powerShellRemediationText.IndexOf('$typedConfirmation = Read-Host', [System.StringComparison]::Ordinal)
    $powerShellRevalidationIndex = $powerShellRemediationText.LastIndexOf('Test-LiveControls', [System.StringComparison]::Ordinal)
    $powerShellCreateIndex = $powerShellRemediationText.IndexOf('Start-AzPolicyRemediation `', [System.StringComparison]::Ordinal)
    if ($powerShellPreviewIndex -lt 0 -or $powerShellPreviewIndex -gt $powerShellEnvironmentIndex -or
        $powerShellEnvironmentIndex -gt $powerShellTypedIndex -or
        $powerShellTypedIndex -gt $powerShellRevalidationIndex -or
        $powerShellRevalidationIndex -gt $powerShellCreateIndex) {
        Stop-Test 'PowerShell tag remediation must preview, unlock, type-confirm, revalidate, then create.'
    }
    if ($parameterTemplate.parameters.privateAccessPublicNetworkPolicyEffect.value -ne 'Audit' -or
        (Compare-Object @($parameterTemplate.parameters.privateAccessServiceCategories.value) @('Storage', 'KeyVault')) -or
        $parameterTemplate.parameters.enableFirewallRouteGuardrails.value -ne $false -or
        $parameterTemplate.parameters.approvedFirewallResourceId.value -ne '' -or
        $parameterTemplate.parameters.approvedFirewallPrivateIp.value -ne '' -or
        @($parameterTemplate.parameters.approvedRouteTableResourceIds.value).Count -ne 0 -or
        @($parameterTemplate.parameters.approvedRouteTablePrefixes.value).Count -ne 0 -or
        $parameterTemplate.parameters.enableNercCipTechnicalOverlay.value -ne $false -or
        @($parameterTemplate.parameters.nercCipApprovedLocations.value).Count -ne 0 -or
        $parameterTemplate.parameters.nercCipDataClassificationTagValue.value -ne '' -or
        $parameterTemplate.parameters.nercCipSspIdTagValue.value -ne '' -or
        $parameterTemplate.parameters.nercCipVaultDoubleEncryptionRequired.value -ne $true -or
        $parameterTemplate.parameters.nercCipVaultCheckAlwaysOnSoftDeleteOnly.value -ne $true -or
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
        $compiledParameters.parameters.enableNercCipTechnicalOverlay.value -ne $false -or
        @($compiledParameters.parameters.nercCipApprovedLocations.value).Count -ne 0 -or
        $compiledParameters.parameters.nercCipDataClassificationTagValue.value -ne '' -or
        $compiledParameters.parameters.nercCipSspIdTagValue.value -ne '' -or
        $compiledParameters.parameters.nercCipVaultDoubleEncryptionRequired.value -ne $true -or
        $compiledParameters.parameters.nercCipVaultCheckAlwaysOnSoftDeleteOnly.value -ne $true -or
        $compiledParameters.parameters.deployLoggingRemediationRoleAssignments.value -ne $false) {
        Stop-Test 'Private-access and firewall-route Bicep template parameters must retain safe defaults.'
    }

    $compiledJson = Get-Content -LiteralPath $compiledTemplate -Raw | ConvertFrom-Json
    if ($compiledJson.resources -is [System.Management.Automation.PSCustomObject]) {
        $compiledJson.resources = @($compiledJson.resources.PSObject.Properties | ForEach-Object { $_.Value })
    }
    Write-Host '4/30 Confirm there are exactly two unconditional subscription associations...'
    $subscriptionAssociations = Find-JsonObjects -Node $compiledJson -Predicate {
        param($node)
        $node.PSObject.Properties['type'] -and $node.type -eq 'Microsoft.Management/managementGroups/subscriptions'
    }
    $unconditionalAssociations = $subscriptionAssociations | Where-Object { -not $_.PSObject.Properties['condition'] }
    if (@($unconditionalAssociations).Count -ne 2) {
        Stop-Test "Expected 2 unconditional subscription association resources, found $(@($unconditionalAssociations).Count)."
    }

    Write-Host '5/30 Confirm no paid always-on resource types are declared outside the opt-in central monitoring, logging destination RBAC, and backup vault modules...'
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

    Write-Host '6/30 Confirm tenant-root scope is only used as the parent hierarchy input...'
    foreach ($bicepFile in Get-ChildItem $ProjectDir -Recurse -Filter '*.bicep') {
        if ((Get-Content -LiteralPath $bicepFile.FullName -Raw) -match 'scope:\s*managementGroup\(tenantRootManagementGroupId\)') {
            Stop-Test "A module or resource assigns governance directly at the tenant root in $($bicepFile.Name)."
        }
    }

    Write-Host '7/30 Confirm group-only RBAC, idempotent main, one-shot Owner eligibility, and guarded lifecycle scripts...'
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
    foreach ($deploymentScript in @('scripts/deploy.sh', 'scripts/deploy.ps1')) {
        $lines = Get-Content -LiteralPath (Join-Path $ProjectDir $deploymentScript)
        $preflightLine = (($lines | Select-String -Pattern 'preflight\.(sh|ps1)' | Select-Object -First 1).LineNumber)
        $whatIfLine = (($lines | Select-String -Pattern 'what-if\.(sh|ps1)' | Select-Object -First 1).LineNumber)
        $confirmationLine = (($lines | Select-String -Pattern 'DEPLOY-ESLZ-DEMO' | Select-Object -First 1).LineNumber)
        if ($null -eq $preflightLine -or $null -eq $whatIfLine -or $null -eq $confirmationLine -or
            $preflightLine -ge $confirmationLine -or $whatIfLine -ge $confirmationLine) {
            Stop-Test "$deploymentScript must run preflight and tenant what-if before the deployment confirmation gate."
        }
    }
    foreach ($teardownScript in @('scripts/teardown.sh', 'scripts/teardown.ps1')) {
        $text = Get-Content -LiteralPath (Join-Path $ProjectDir $teardownScript) -Raw
        foreach ($requiredText in @(
            'policy exemption delete',
            'role assignment list --assignee',
            'Supplied workspace, firewall, key, vault, policy, and other external IDs are never deleted'
        )) {
            if (-not $text.Contains($requiredText)) {
                Stop-Test "$teardownScript is missing v2 lifecycle coverage: $requiredText"
            }
        }
    }
    foreach ($assignmentName in @('demo-firewall-routes', 'demo-vm-backup-${approvedVaultIndex}')) {
        if ((Get-Content -LiteralPath (Join-Path $ProjectDir 'main.bicep') -Raw) -notmatch [regex]::Escape("assignmentName: '$assignmentName'")) {
            Stop-Test "main.bicep is missing $assignmentName."
        }
    }
    if (-not (Get-Content -LiteralPath (Join-Path $ProjectDir 'scripts/teardown.sh') -Raw).Contains('demo-firewall-routes') -or
        -not (Get-Content -LiteralPath (Join-Path $ProjectDir 'scripts/teardown.ps1') -Raw).Contains('demo-firewall-routes')) {
        Stop-Test 'Teardown scripts do not clean up demo-firewall-routes.'
    }
    if (-not (Get-Content -LiteralPath (Join-Path $ProjectDir 'scripts/teardown.sh') -Raw).Contains('demo-vm-backup-${backup_index}') -or
        -not (Get-Content -LiteralPath (Join-Path $ProjectDir 'scripts/teardown.ps1') -Raw).Contains('demo-vm-backup-$index')) {
        Stop-Test 'Teardown scripts do not clean up dynamic demo-vm-backup assignments.'
    }
    if (-not (Get-Content -LiteralPath (Join-Path $ProjectDir 'modules/root-deployment-restrictions.bicep') -Raw).Contains("assignmentName: 'demo-deploy-restrictions'")) {
        Stop-Test 'Nested root-deployment-restrictions assignment inventory is missing.'
    }
    if (-not (Get-Content -LiteralPath (Join-Path $ProjectDir 'scripts/teardown.sh') -Raw).Contains('demo-deploy-restrictions|${demo_root_scope}')) {
        Stop-Test 'Bash teardown does not clean up demo-deploy-restrictions at the demo-root scope.'
    }
    if (-not (Get-Content -LiteralPath (Join-Path $ProjectDir 'scripts/teardown.ps1') -Raw).Contains("@('demo-deploy-restrictions', `$demoRootScope)")) {
        Stop-Test 'PowerShell teardown does not clean up demo-deploy-restrictions at the demo-root scope.'
    }
    foreach ($requiredText in @('exemptionScopeType', 'deployEvidenceResources')) {
        foreach ($teardownScript in @('scripts/teardown.sh', 'scripts/teardown.ps1')) {
            if (-not (Get-Content -LiteralPath (Join-Path $ProjectDir $teardownScript) -Raw).Contains($requiredText)) {
                Stop-Test "$teardownScript is missing lifecycle ownership handling for $requiredText."
            }
        }
    }

    Write-Host '8/30 Confirm region policy and workload network guardrails are safe by default...'
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
    $nercCipOverlayInitiative = @($compiledJson.resources | Where-Object { $_.name -eq 'nerc-cip-technical-overlay-initiative' })
    $nercCipOverlayAssignment = @($compiledJson.resources | Where-Object { $_.name -eq 'assign-nerc-cip-technical-overlay' })
    $nercCipOverlayWorkspaceRbac = @($compiledJson.resources | Where-Object { $_.name -eq 'nerc-cip-overlay-workspace-destination-rbac' })
    if ($nercCipOverlayInitiative.Count -ne 1 -or
        $nercCipOverlayAssignment.Count -ne 1 -or
        $nercCipOverlayWorkspaceRbac.Count -ne 1) {
        Stop-Test 'NERC CIP technical overlay initiative, assignment, and destination workspace RBAC deployment must each be present exactly once.'
    }
    $nercCipOverlayReferences = @($nercCipOverlayInitiative[0].properties.parameters.policyDefinitionReferences.value)
    $nercCipOverlayReferenceIds = @($nercCipOverlayReferences | ForEach-Object { $_.policyDefinitionReferenceId } | Sort-Object)
    if (
        $nercCipOverlayInitiative[0].scope -notmatch 'demoRootManagementGroupId' -or
        $nercCipOverlayReferenceIds.Count -lt 25 -or
        @($nercCipOverlayReferenceIds | Where-Object { $_ -eq 'critical-public-management-ingress' }).Count -ne 1 -or
        @($nercCipOverlayReferenceIds | Where-Object { $_ -eq 'critical-require-subnet-nsg' }).Count -ne 1 -or
        @($nercCipOverlayReferenceIds | Where-Object { $_ -eq 'critical-paas-public-network-access' }).Count -ne 1 -or
        @($nercCipOverlayReferenceIds | Where-Object { $_ -eq 'critical-vault-customer-managed-key' }).Count -ne 1 -or
        @($nercCipOverlayReferenceIds | Where-Object { $_ -eq 'critical-activity-log-export' }).Count -ne 1 -or
        @($nercCipOverlayReferenceIds | Where-Object { $_ -eq 'critical-network-ingress' }).Count -ne 0 -or
        @($nercCipOverlayReferenceIds | Where-Object { $_ -eq 'critical-private-access' }).Count -ne 0 -or
        @($nercCipOverlayReferenceIds | Where-Object { $_ -eq 'critical-data-protection' }).Count -ne 0 -or
        @($nercCipOverlayReferenceIds | Where-Object { $_ -eq 'critical-backup-posture' }).Count -ne 0 -or
        @($nercCipOverlayReferenceIds | Where-Object { $_ -eq 'critical-resource-diagnostics' }).Count -ne 0 -or
        @($nercCipOverlayReferences | Where-Object {
            ([string]$_.policyDefinitionId).Contains('/policySetDefinitions/')
        }).Count -ne 0 -or
        ([string]$nercCipOverlayAssignment[0].condition) -notmatch 'enableNercCipTechnicalOverlay' -or
        ([string]$nercCipOverlayAssignment[0].condition) -notmatch 'validatedNercCipOverlayInputs' -or
        $nercCipOverlayAssignment[0].scope -notmatch 'criticalInfrastructureManagementGroupId' -or
        $nercCipOverlayAssignment[0].scope -match 'workloadManagementGroupId' -or
        [string]$nercCipOverlayAssignment[0].properties.parameters.location.value -ne "[parameters('deploymentLocation')]" -or
        [string]$nercCipOverlayAssignment[0].properties.parameters.identity.value.type -ne 'SystemAssigned' -or
        (Compare-Object @($nercCipOverlayAssignment[0].properties.parameters.verifiedRoleDefinitionIds.value) @("[variables('monitoringContributorRoleDefinitionId')]")) -or
        [string]$nercCipOverlayAssignment[0].properties.parameters.deployRemediationRoleAssignments.value -ne "[variables('deployActivityLogRemediationRoleAssignments')]" -or
        $nercCipOverlayAssignment[0].properties.parameters.enforcementMode.value -ne "[parameters('denyPolicyEnforcementMode')]" -or
        [string]$nercCipOverlayAssignment[0].properties.parameters.parameters.value.allowedLocations.value -notmatch 'validatedNercCipApprovedLocations' -or
        [string]$nercCipOverlayAssignment[0].properties.parameters.parameters.value.dataClassificationTagValue.value -notmatch 'nercCipDataClassificationTagValue' -or
        [string]$nercCipOverlayAssignment[0].properties.parameters.parameters.value.sspIdTagValue.value -ne "[trim(parameters('nercCipSspIdTagValue'))]" -or
        [string]$nercCipOverlayAssignment[0].properties.parameters.parameters.value.vaultDoubleEncryption.value -ne "[parameters('nercCipVaultDoubleEncryptionRequired')]" -or
        [string]$nercCipOverlayAssignment[0].properties.parameters.parameters.value.vaultCheckAlwaysOnSoftDeleteOnly.value -ne "[parameters('nercCipVaultCheckAlwaysOnSoftDeleteOnly')]" -or
        [string]$nercCipOverlayAssignment[0].properties.parameters.parameters.value.diagnosticsEffect.value -ne "[parameters('activityLogExportPolicyEffect')]" -or
        [string]$nercCipOverlayWorkspaceRbac[0].condition -ne "[and(and(parameters('enableNercCipTechnicalOverlay'), variables('validatedNercCipOverlayInputs')), variables('deployActivityLogRemediationRoleAssignments'))]" -or
        [string]$nercCipOverlayWorkspaceRbac[0].subscriptionId -ne "[variables('loggingWorkspaceSubscriptionId')]" -or
        [string]$nercCipOverlayWorkspaceRbac[0].resourceGroup -ne "[variables('loggingWorkspaceResourceGroupName')]" -or
        [string]$nercCipOverlayWorkspaceRbac[0].properties.parameters.workspaceName.value -ne "[variables('loggingWorkspaceName')]" -or
        [string]$nercCipOverlayWorkspaceRbac[0].properties.parameters.principalId.value -ne "[reference('nercCipTechnicalOverlayAssignment').outputs.identityPrincipalId.value]" -or
        (Compare-Object @($nercCipOverlayWorkspaceRbac[0].properties.parameters.roleDefinitionIds.value) @("[variables('logAnalyticsContributorRoleDefinitionId')]")) -or
        $compiledJson.outputs.nercCipTechnicalOverlay.value.workspaceDestinationAccessEnabled -ne "[and(and(parameters('enableNercCipTechnicalOverlay'), variables('validatedNercCipOverlayInputs')), variables('deployActivityLogRemediationRoleAssignments'))]" -or
        $compiledJson.outputs.nercCipTechnicalOverlay.value.workspaceDestinationRoleAssignmentIds -ne "[if(and(and(parameters('enableNercCipTechnicalOverlay'), variables('validatedNercCipOverlayInputs')), variables('deployActivityLogRemediationRoleAssignments')), reference('nercCipOverlayWorkspaceDestinationRbac').outputs.roleAssignmentIds.value, createArray())]") {
        Stop-Test 'NERC CIP technical overlay must stay opt-in, critical-only, and parameter-wired to stricter inputs.'
    }
    $nercCipMessageReferenceIds = @(
        $nercCipOverlayAssignment[0].properties.parameters.nonComplianceMessages.value |
        ForEach-Object { $_.policyDefinitionReferenceId } |
        Sort-Object
    )
    if (@($nercCipMessageReferenceIds | Where-Object { $_ -eq 'critical-public-management-ingress' }).Count -ne 1 -or
        @($nercCipMessageReferenceIds | Where-Object { $_ -eq 'critical-require-subnet-nsg' }).Count -ne 1 -or
        @($nercCipMessageReferenceIds | Where-Object { $_ -eq 'critical-paas-public-network-access' }).Count -ne 1 -or
        @($nercCipMessageReferenceIds | Where-Object { $_ -eq 'critical-vault-customer-managed-key' }).Count -ne 1 -or
        @($nercCipMessageReferenceIds | Where-Object { $_ -eq 'critical-activity-log-export' }).Count -ne 1 -or
        @($nercCipOverlayAssignment[0].properties.parameters.nonComplianceMessages.value |
            Where-Object { [string]::IsNullOrEmpty($_.message) }).Count -ne 0) {
        Stop-Test 'NERC CIP technical overlay must include non-empty noncompliance messages for each reference.'
    }
    foreach ($requiredValidationText in @(
        'enableNercCipTechnicalOverlay requires enableCriticalInfrastructure to be true so the overlay remains Critical-scope only.',
        'enableNercCipTechnicalOverlay requires at least one criticalInfrastructureSubscriptionIds entry.',
        'enableNercCipTechnicalOverlay requires a canonical effective monitoring workspace resource ID from deployCentralLogAnalytics or existingLogAnalyticsWorkspaceResourceId.',
        'enableNercCipTechnicalOverlay requires activityLogExportPolicyEffect to be DeployIfNotExists so centralized Activity Log export remains active.',
        'enableNercCipTechnicalOverlay requires deployRoleAssignments and deployLoggingRemediationRoleAssignments to be true so the overlay assignment identity can receive least-privilege remediation access.',
        'enableNercCipTechnicalOverlay requires enableFirewallRouteGuardrails to be true with approved firewall and route-table evidence.',
        'enableNercCipTechnicalOverlay requires approvedBackupVaults records for backup coverage evidence.',
        'enableNercCipTechnicalOverlay requires backupRetentionStandardId so backup controls map to a documented standard.',
        'enableNercCipTechnicalOverlay requires non-empty nercCipDataClassificationTagValue and nercCipSspIdTagValue inputs.',
        'nercCipApprovedLocations must contain only string region values.',
        'nercCipApprovedLocations must not contain empty or whitespace-only values.',
        'nercCipApprovedLocations must contain case-insensitively unique region values.'
    )) {
        if (-not $mainBicepText.Contains($requiredValidationText)) {
            Stop-Test "NERC CIP overlay guard validation is missing: $requiredValidationText"
        }
    }
    if ($compiledJson.parameters.nercCipVaultDoubleEncryptionRequired.defaultValue -ne $true -or
        $compiledJson.parameters.nercCipVaultCheckAlwaysOnSoftDeleteOnly.defaultValue -ne $true -or
        $parameterTemplate.parameters.nercCipVaultDoubleEncryptionRequired.value -ne $true -or
        $parameterTemplate.parameters.nercCipVaultCheckAlwaysOnSoftDeleteOnly.value -ne $true -or
        $compiledParameters.parameters.nercCipVaultDoubleEncryptionRequired.value -ne $true -or
        $compiledParameters.parameters.nercCipVaultCheckAlwaysOnSoftDeleteOnly.value -ne $true) {
        Stop-Test 'NERC CIP stricter backup defaults must stay true in compiled and parameter templates.'
    }
    $nercCipLocationValidationFixture = Get-Content -LiteralPath (Join-Path $ScriptDir 'fixtures/nerc-cip-approved-locations-validation-cases.json') -Raw | ConvertFrom-Json
    foreach ($case in $nercCipLocationValidationFixture.cases) {
        $values = @($case.value)
        $allStrings = @($values | Where-Object { $_ -isnot [string] }).Count -eq 0
        $normalized = @($values | ForEach-Object {
            if ($_ -is [string]) { $_.Trim().ToLowerInvariant() } else { '' }
        })
        $valid = $allStrings -and
            $normalized.Count -gt 0 -and
            (@($normalized | Where-Object { [string]::IsNullOrEmpty($_) }).Count -eq 0) -and
            (@($normalized | Sort-Object -Unique).Count -eq $normalized.Count)
        if ($valid -ne $case.valid) {
            Stop-Test "NERC CIP approved-location validation case failed: $($values -join ',')"
        }
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

    Write-Host '9/30 Confirm the Critical Infrastructure branch is opt-in and correctly wired...'
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

    Write-Host '10/30 Confirm Defender for Cloud plans are explicit, independent, safe-by-default opt-ins with no auto-granted role and current AMA audit controls exist...'
    $mainBicepText = Get-Content -LiteralPath (Join-Path $ProjectDir 'main.bicep') -Raw
    if ($mainBicepText -notmatch '(?m)^param enableDefenderCspm bool = false$') {
        Stop-Test 'enableDefenderCspm parameter must default to false.'
    }
    if ($mainBicepText -notmatch '(?m)^param enableDefenderForServers bool = false$') {
        Stop-Test 'enableDefenderForServers parameter must default to false.'
    }
    if ($mainBicepText -notmatch '(?m)^param enableDefenderForStorage bool = false$') {
        Stop-Test 'enableDefenderForStorage parameter must default to false.'
    }
    if ($compiledJson.parameters.enableDefenderCspm.defaultValue -ne $false -or
        $compiledJson.parameters.enableDefenderForServers.defaultValue -ne $false -or
        $compiledJson.parameters.enableDefenderForStorage.defaultValue -ne $false) {
        Stop-Test 'Compiled enableDefender* defaults must all be false.'
    }
    if ($parameterTemplate.parameters.enableDefenderCspm.value -ne $false -or
        $parameterTemplate.parameters.enableDefenderForServers.value -ne $false -or
        $parameterTemplate.parameters.enableDefenderForStorage.value -ne $false) {
        Stop-Test 'ARM parameter template enableDefender* values must all be false.'
    }
    if ($compiledParameters.parameters.enableDefenderCspm.value -ne $false -or
        $compiledParameters.parameters.enableDefenderForServers.value -ne $false -or
        $compiledParameters.parameters.enableDefenderForStorage.value -ne $false) {
        Stop-Test 'Compiled Bicep parameter template enableDefender* values must all be false.'
    }
    if ($mainBicepText -notmatch '(?m)^param enableDefenderCiem bool = true$') {
        Stop-Test 'enableDefenderCiem parameter must default to true.'
    }
    if ($mainBicepText -notmatch "(?m)^param defenderForServersSubPlan string = 'P2'$") {
        Stop-Test 'defenderForServersSubPlan parameter must default to P2.'
    }
    if ($mainBicepText -notmatch '(?m)^param defenderForServersAgentlessVmScanningEnabled bool = true$') {
        Stop-Test 'defenderForServersAgentlessVmScanningEnabled parameter must default to true.'
    }
    $defenderPlanBicepText = Get-Content -LiteralPath (Join-Path $ProjectDir 'modules/defender-plan-assignment.bicep') -Raw
    if ($defenderPlanBicepText -notmatch "(?m)^param plan 'cspm' \| 'servers' \| 'storage'$") {
        Stop-Test 'defender-plan-assignment.bicep must restrict plan to the cspm/servers/storage enum.'
    }
    if ($defenderPlanBicepText -notmatch "type: enablePlan \? 'SystemAssigned' : 'None'") {
        Stop-Test 'defender-plan-assignment.bicep must toggle identity.type between SystemAssigned and None based on enablePlan.'
    }
    if ($defenderPlanBicepText -notmatch "value: enablePlan \? 'DeployIfNotExists' : 'Disabled'") {
        Stop-Test 'defender-plan-assignment.bicep must toggle effect between DeployIfNotExists and Disabled based on enablePlan.'
    }
    if ($defenderPlanBicepText -match 'roleDefinitionId') {
        Stop-Test 'defender-plan-assignment.bicep must never reference a roleDefinitionId; it must never auto-grant a role.'
    }
    if ($defenderPlanBicepText -match 'Microsoft\.Authorization/roleAssignments') {
        Stop-Test 'defender-plan-assignment.bicep must never create a role assignment.'
    }
    if ($defenderPlanBicepText -notmatch "definitionId: '72f8cee7-2937-403d-84a1-a4e3e57f3c21'" -or
        $defenderPlanBicepText -notmatch "definitionId: '5eb6d64a-4086-4d7a-92da-ec51aed0332d'" -or
        $defenderPlanBicepText -notmatch "definitionId: 'cfdc5972-75b3-4418-8ae1-7f5c36839390'") {
        Stop-Test 'defender-plan-assignment.bicep is missing one of the verified CSPM/Servers/Storage built-in definition IDs.'
    }
    if (([regex]::Matches($defenderPlanBicepText, "definitionVersion: '1\.\*\.\*'")).Count -ne 3) {
        Stop-Test 'defender-plan-assignment.bicep must pin all three plans to definitionVersion 1.*.*.'
    }
    if ($mainBicepText -match '475aae12-b88a-4572-8b36-9b712b2b3a17' -or $defenderPlanBicepText -match '475aae12-b88a-4572-8b36-9b712b2b3a17') {
        Stop-Test 'The deprecated Log Analytics (MMA) auto-provisioning policy definition must never be referenced.'
    }
    if ($mainBicepText -notmatch 'c02729e5-e5e7-4458-97fa-2b5ad0661f28') {
        Stop-Test 'main.bicep must reference the Windows Azure Monitor Agent audit built-in (REQ-DEF-07).'
    }
    if ($mainBicepText -notmatch '1afdc4b6-581a-45fb-b630-f1e6051e3e7a') {
        Stop-Test 'main.bicep must reference the Linux Azure Monitor Agent audit built-in (REQ-DEF-08).'
    }
    $defenderPlanDeployments = Find-JsonObjects -Node $compiledJson -Predicate {
        param($node)
        $node.PSObject.Properties['type'] -and $node.type -eq 'Microsoft.Resources/deployments' -and
        $node.PSObject.Properties['name'] -and ($node.name -in @('assign-defender-cspm', 'assign-defender-servers', 'assign-defender-storage'))
    }
    if (@($defenderPlanDeployments).Count -ne 3) {
        Stop-Test 'Expected exactly three Defender plan assignment module deployments (cspm/servers/storage).'
    }
    # Each of the three deployments must map to its own distinct plan/scope/
    # opt-in wiring; an "any of the three" style assertion could pass even if,
    # for example, the CSPM deployment were accidentally wired to the Storage
    # GUID.
    $cspmDeployment = $defenderPlanDeployments | Where-Object { $_.name -eq 'assign-defender-cspm' } | Select-Object -First 1
    $serversDeployment = $defenderPlanDeployments | Where-Object { $_.name -eq 'assign-defender-servers' } | Select-Object -First 1
    $storageDeployment = $defenderPlanDeployments | Where-Object { $_.name -eq 'assign-defender-storage' } | Select-Object -First 1
    if ($cspmDeployment.properties.parameters.plan.value -ne 'cspm' -or
        $cspmDeployment.properties.parameters.enablePlan.value -ne "[parameters('enableDefenderCspm')]" -or
        $cspmDeployment.properties.parameters.cspmEntraPermissionsManagementEnabled.value -ne "[parameters('enableDefenderCiem')]" -or
        $cspmDeployment.scope -notmatch 'demoRootManagementGroupId') {
        Stop-Test 'assign-defender-cspm must be scoped to the demo root management group and wired to enableDefenderCspm/enableDefenderCiem.'
    }
    if ($serversDeployment.properties.parameters.plan.value -ne 'servers' -or
        $serversDeployment.properties.parameters.enablePlan.value -ne "[parameters('enableDefenderForServers')]" -or
        $serversDeployment.properties.parameters.serversSubPlan.value -ne "[parameters('defenderForServersSubPlan')]" -or
        $serversDeployment.properties.parameters.serversAgentlessVmScanningEnabled.value -ne "[parameters('defenderForServersAgentlessVmScanningEnabled')]" -or
        $serversDeployment.scope -notmatch 'landingZonesManagementGroupId') {
        Stop-Test 'assign-defender-servers must be scoped to the Landing Zones management group and wired to enableDefenderForServers/defenderForServersSubPlan/defenderForServersAgentlessVmScanningEnabled.'
    }
    if ($storageDeployment.properties.parameters.plan.value -ne 'storage' -or
        $storageDeployment.properties.parameters.enablePlan.value -ne "[parameters('enableDefenderForStorage')]" -or
        $storageDeployment.properties.parameters.storageOnUploadMalwareScanningEnabled.value -ne "[parameters('enableDefenderStorageMalwareScanning')]" -or
        $storageDeployment.properties.parameters.storageCapGBPerMonthPerStorageAccount.value -ne "[parameters('defenderStorageMalwareScanningCapGBPerMonthPerStorageAccount')]" -or
        $storageDeployment.scope -notmatch 'landingZonesManagementGroupId') {
        Stop-Test 'assign-defender-storage must be scoped to the Landing Zones management group and wired to enableDefenderForStorage/enableDefenderStorageMalwareScanning/defenderStorageMalwareScanningCapGBPerMonthPerStorageAccount.'
    }
    if ($mainBicepText -notmatch "(?m)^param enableDefenderStorageMalwareScanning bool = false$") {
        Stop-Test 'enableDefenderStorageMalwareScanning parameter must default to false so enabling the base Storage plan never silently enables the metered malware-scanning extension.'
    }
    if ($mainBicepText -notmatch "(?m)^param defenderStorageMalwareScanningCapGBPerMonthPerStorageAccount int = 10000$") {
        Stop-Test 'defenderStorageMalwareScanningCapGBPerMonthPerStorageAccount parameter must default to 10000.'
    }
    if ($compiledJson.parameters.enableDefenderStorageMalwareScanning.defaultValue -ne $false) {
        Stop-Test 'The compiled template must default enableDefenderStorageMalwareScanning to false.'
    }
    $demoParametersTemplate = Get-Content -LiteralPath (Join-Path $ProjectDir 'parameters/demo.parameters.template.json') -Raw | ConvertFrom-Json
    if ($demoParametersTemplate.parameters.enableDefenderStorageMalwareScanning.value -ne $false) {
        Stop-Test 'parameters/demo.parameters.template.json must default enableDefenderStorageMalwareScanning to false.'
    }
    # The module itself must map each verified plan to its own distinct
    # definitionId/definitionVersion/parameter-object entry ("switch"), not a
    # shared/ambiguous shape.
    $cspmPlanDefinition = $cspmDeployment.properties.template.variables.planDefinitions.cspm
    $cspmPlanParameters = $cspmDeployment.properties.template.variables.planParameters.cspm
    if ($cspmPlanDefinition.definitionId -ne '72f8cee7-2937-403d-84a1-a4e3e57f3c21' -or
        $cspmPlanDefinition.definitionVersion -ne '1.*.*' -or
        -not $cspmPlanParameters.PSObject.Properties['isSensitiveDataDiscoveryEnabled'] -or
        -not $cspmPlanParameters.PSObject.Properties['isContainerRegistriesVulnerabilityAssessmentsEnabled'] -or
        -not $cspmPlanParameters.PSObject.Properties['isAgentlessDiscoveryForKubernetesEnabled'] -or
        -not $cspmPlanParameters.PSObject.Properties['isAgentlessVmScanningEnabled'] -or
        -not $cspmPlanParameters.PSObject.Properties['isEntraPermissionsManagementEnabled']) {
        Stop-Test 'The compiled CSPM plan definition/parameter switch is missing an expected field.'
    }
    $serversPlanDefinition = $serversDeployment.properties.template.variables.planDefinitions.servers
    $serversPlanParameters = $serversDeployment.properties.template.variables.planParameters.servers
    if ($serversPlanDefinition.definitionId -ne '5eb6d64a-4086-4d7a-92da-ec51aed0332d' -or
        $serversPlanDefinition.definitionVersion -ne '1.*.*' -or
        -not $serversPlanParameters.PSObject.Properties['subPlan'] -or
        -not $serversPlanParameters.PSObject.Properties['isAgentlessVmScanningEnabled'] -or
        -not $serversPlanParameters.PSObject.Properties['isMdeDesignatedSubscriptionEnabled']) {
        Stop-Test 'The compiled Servers plan definition/parameter switch is missing an expected field.'
    }
    $storagePlanDefinition = $storageDeployment.properties.template.variables.planDefinitions.storage
    $storagePlanParameters = $storageDeployment.properties.template.variables.planParameters.storage
    if ($storagePlanDefinition.definitionId -ne 'cfdc5972-75b3-4418-8ae1-7f5c36839390' -or
        $storagePlanDefinition.definitionVersion -ne '1.*.*' -or
        -not $storagePlanParameters.PSObject.Properties['isOnUploadMalwareScanningEnabled'] -or
        -not $storagePlanParameters.PSObject.Properties['capGBPerMonthPerStorageAccount'] -or
        -not $storagePlanParameters.PSObject.Properties['isSensitiveDataDiscoveryEnabled']) {
        Stop-Test 'The compiled Storage plan definition/parameter switch is missing an expected field.'
    }
    # Assert the exact compiled identity/effect/policyDefinitionId/definitionVersion
    # wiring on the nested assignment resource itself (not just the shared
    # module's source text) for every one of the three plan deployments, so a
    # regression in any single plan's compiled shape is caught even if the
    # module source text still looks correct.
    $expectedIdentityTypeExpr = "[if(parameters('enablePlan'), 'SystemAssigned', 'None')]"
    $expectedPolicyDefinitionIdExpr = "[variables('policyDefinitionId')]"
    $expectedDefinitionVersionExpr = "[variables('selectedPlan').definitionVersion]"
    $expectedParametersExpr = "[union(createObject('effect', createObject('value', if(parameters('enablePlan'), 'DeployIfNotExists', 'Disabled'))), variables('planParameters')[parameters('plan')])]"
    foreach ($deploymentEntry in @(
        @{ Name = 'assign-defender-cspm'; Deployment = $cspmDeployment },
        @{ Name = 'assign-defender-servers'; Deployment = $serversDeployment },
        @{ Name = 'assign-defender-storage'; Deployment = $storageDeployment }
    )) {
        $assignmentResource = $deploymentEntry.Deployment.properties.template.resources.assignment
        if ($assignmentResource.identity.type -ne $expectedIdentityTypeExpr -or
            $assignmentResource.properties.policyDefinitionId -ne $expectedPolicyDefinitionIdExpr -or
            $assignmentResource.properties.definitionVersion -ne $expectedDefinitionVersionExpr -or
            $assignmentResource.properties.parameters -ne $expectedParametersExpr) {
            Stop-Test "$($deploymentEntry.Name) does not compile the expected identity/effect/policyDefinitionId/definitionVersion wiring on its nested assignment resource."
        }
    }
    $expectedValidatedServersAgentlessVmScanningEnabledExpr = "[if(and(and(equals(parameters('plan'), 'servers'), equals(parameters('serversSubPlan'), 'P1')), parameters('serversAgentlessVmScanningEnabled')), fail('serversAgentlessVmScanningEnabled must be false when serversSubPlan is P1; agentless VM scanning is only supported on the Servers P2 sub-plan.'), parameters('serversAgentlessVmScanningEnabled'))]"
    if ($serversDeployment.properties.template.variables.validatedServersAgentlessVmScanningEnabled -ne $expectedValidatedServersAgentlessVmScanningEnabledExpr) {
        Stop-Test 'assign-defender-servers must compile the exact P1/agentless-scanning fail() rejection expression (validatedServersAgentlessVmScanningEnabled).'
    }
    $expectedServersIsAgentlessVmScanningEnabledExpr = "[if(variables('validatedServersAgentlessVmScanningEnabled'), 'true', 'false')]"
    if ($serversDeployment.properties.template.variables.planParameters.servers.isAgentlessVmScanningEnabled.value -ne $expectedServersIsAgentlessVmScanningEnabledExpr) {
        Stop-Test 'assign-defender-servers must wire isAgentlessVmScanningEnabled through the validated variable rather than the raw parameter.'
    }
    # The built-in's own parameter metadata documents capGBPerMonthPerStorageAccount
    # as "an integer, 10GB or higher" or "-1 for unlimited scanning"; values from
    # 0 through 9 (or anything below -1) must be rejected explicitly rather than
    # forwarded unchanged.
    $expectedValidatedStorageCapExpr = "[if(or(equals(parameters('storageCapGBPerMonthPerStorageAccount'), -1), greaterOrEquals(parameters('storageCapGBPerMonthPerStorageAccount'), 10)), parameters('storageCapGBPerMonthPerStorageAccount'), fail('storageCapGBPerMonthPerStorageAccount must be -1 (unlimited) or at least 10 GB per storage account per month.'))]"
    if ($storageDeployment.properties.template.variables.validatedStorageCapGBPerMonthPerStorageAccount -ne $expectedValidatedStorageCapExpr) {
        Stop-Test 'assign-defender-storage must compile the exact -1-or->=10 fail() rejection expression for storageCapGBPerMonthPerStorageAccount.'
    }
    $expectedStorageCapParameterExpr = "[variables('validatedStorageCapGBPerMonthPerStorageAccount')]"
    if ($storageDeployment.properties.template.variables.planParameters.storage.capGBPerMonthPerStorageAccount.value -ne $expectedStorageCapParameterExpr) {
        Stop-Test 'assign-defender-storage must wire capGBPerMonthPerStorageAccount through the validated variable rather than the raw parameter.'
    }
    $amaAuditDeployments = Find-JsonObjects -Node $compiledJson -Predicate {
        param($node)
        $node.PSObject.Properties['type'] -and $node.type -eq 'Microsoft.Resources/deployments' -and
        $node.PSObject.Properties['name'] -and ($node.name -in @('assign-defender-ama-audit-windows', 'assign-defender-ama-audit-linux'))
    }
    if (@($amaAuditDeployments).Count -ne 2) {
        Stop-Test 'Expected exactly two Azure Monitor Agent audit policy assignment module deployments (Windows/Linux).'
    }
    $windowsAmaDeployment = $amaAuditDeployments | Where-Object { $_.name -eq 'assign-defender-ama-audit-windows' } | Select-Object -First 1
    $linuxAmaDeployment = $amaAuditDeployments | Where-Object { $_.name -eq 'assign-defender-ama-audit-linux' } | Select-Object -First 1
    if ($windowsAmaDeployment.properties.parameters.policyDefinitionId.value -ne "[variables('windowsAmaAuditPolicyDefinitionId')]" -or
        $linuxAmaDeployment.properties.parameters.policyDefinitionId.value -ne "[variables('linuxAmaAuditPolicyDefinitionId')]") {
        Stop-Test 'The Windows/Linux AMA audit assignments must each be wired to their own dedicated policyDefinitionId variable.'
    }
    if ($compiledJson.variables.windowsAmaAuditPolicyDefinitionId -ne "[tenantResourceId('Microsoft.Authorization/policyDefinitions', 'c02729e5-e5e7-4458-97fa-2b5ad0661f28')]" -or
        $compiledJson.variables.linuxAmaAuditPolicyDefinitionId -ne "[tenantResourceId('Microsoft.Authorization/policyDefinitions', '1afdc4b6-581a-45fb-b630-f1e6051e3e7a')]") {
        Stop-Test 'The Windows/Linux AMA audit policy definition IDs must each resolve to their own verified built-in GUID.'
    }
    foreach ($deployment in $amaAuditDeployments) {
        if ($deployment.properties.parameters.definitionVersion.value -ne '3.*.*') {
            Stop-Test "Azure Monitor Agent audit assignment '$($deployment.name)' must pin definitionVersion to 3.*.*."
        }
        if ($deployment.properties.template.resources.assignment.PSObject.Properties['identity']) {
            Stop-Test "Azure Monitor Agent audit assignment '$($deployment.name)' must never create a managed identity."
        }
        if ($deployment.properties.parameters.parameters.value.effect.value -ne 'AuditIfNotExists') {
            Stop-Test "Azure Monitor Agent audit assignment '$($deployment.name)' must explicitly pass effect: AuditIfNotExists rather than silently inheriting the built-in's own default."
        }
        if ($deployment.scope -notmatch 'landingZonesManagementGroupId') {
            Stop-Test "Azure Monitor Agent audit assignment '$($deployment.name)' must be scoped to the Landing Zones management group."
        }
    }
    # The free vulnerability-assessment audit assignment must independently
    # pin its own verified GUID/version/scope and must never attach an
    # identity (it has no paid-plan dependency and performs no remediation).
    $vulnAssessmentDeployment = Find-JsonObjects -Node $compiledJson -Predicate {
        param($node)
        $node.PSObject.Properties['type'] -and $node.type -eq 'Microsoft.Resources/deployments' -and
        $node.PSObject.Properties['name'] -and $node.name -eq 'assign-vuln-assessment-audit'
    } | Select-Object -First 1
    if (-not $vulnAssessmentDeployment) {
        Stop-Test 'Expected an assign-vuln-assessment-audit module deployment.'
    }
    if ($vulnAssessmentDeployment.properties.parameters.policyDefinitionId.value -ne "[variables('vulnerabilityAssessmentAuditPolicyDefinitionId')]" -or
        $vulnAssessmentDeployment.properties.parameters.definitionVersion.value -ne '3.*.*' -or
        $vulnAssessmentDeployment.properties.parameters.parameters.value.effect.value -ne 'AuditIfNotExists' -or
        $vulnAssessmentDeployment.properties.template.resources.assignment.PSObject.Properties['identity'] -or
        $vulnAssessmentDeployment.scope -notmatch 'landingZonesManagementGroupId') {
        Stop-Test 'assign-vuln-assessment-audit must be scoped to the Landing Zones management group, wired to its own vulnerabilityAssessmentAuditPolicyDefinitionId variable, pinned to definitionVersion 3.*.*, explicitly set effect: AuditIfNotExists, and must never attach an identity.'
    }
    if ($compiledJson.variables.vulnerabilityAssessmentAuditPolicyDefinitionId -ne "[tenantResourceId('Microsoft.Authorization/policyDefinitions', '501541f7-f7e7-4cd6-868c-4190fdad3ac9')]") {
        Stop-Test 'vulnerabilityAssessmentAuditPolicyDefinitionId must resolve to its own verified built-in GUID.'
    }
    $catalogText = Get-Content -LiteralPath (Join-Path $ProjectDir 'policy/control-catalog.json') -Raw
    if ($catalogText -notmatch '"REQ-DEF-09"') {
        Stop-Test 'policy/control-catalog.json must include the REQ-DEF-09 Foundational CSPM record.'
    }
    $readmeText = Get-Content -LiteralPath (Join-Path $ProjectDir 'README.md') -Raw
    if ($readmeText -notmatch 'Foundational CSPM') {
        Stop-Test 'README.md must document Foundational CSPM.'
    }

    Write-Host '11/30 Confirm criticalInfrastructureSubscriptionIds validates duplicates and overlap...'
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

    Write-Host '12/30 Confirm teardown scripts move critical subscriptions and delete the Critical Infrastructure management group before Landing Zones...'
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

    Write-Host '13/30 Confirm central monitoring defaults create no metered resources...'
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

    Write-Host '14/30 Confirm central monitoring guards against conflicting new/existing workspace inputs and Sentinel-without-workspace...'
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

    Write-Host '15/30 Confirm the central monitoring module exposes an effective workspace ID output...'
    if (-not ($centralMonitoringText -match '(?m)^output effectiveLogAnalyticsWorkspaceResourceId string')) {
        Stop-Test 'central-monitoring.bicep is missing the effectiveLogAnalyticsWorkspaceResourceId output.'
    }
    if (-not $mainBicepText.Contains('centralMonitoringEffectiveWorkspaceId string = centralMonitoring.outputs.effectiveLogAnalyticsWorkspaceResourceId')) {
        Stop-Test 'main.bicep is missing the centralMonitoringEffectiveWorkspaceId output.'
    }

    Write-Host '16/30 Confirm invalid central monitoring configurations fail deployment explicitly...'
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

    Write-Host '17/30 Confirm teardown scripts protect a supplied existing workspace resource group and only remove a demo-created monitoring resource group...'
    $teardownShText = Get-Content -LiteralPath (Join-Path $ProjectDir 'scripts/teardown.sh') -Raw
    $teardownPs1Text = Get-Content -LiteralPath (Join-Path $ProjectDir 'scripts/teardown.ps1') -Raw
    foreach ($requiredText in @('deployCentralLogAnalytics', 'rg-${prefix}-monitoring', 'existingLogAnalyticsWorkspaceResourceId', 'is_protected_external_resource_group', 'monitoring_group_is_repo_owned', 'delete_resource_group_if_not_protected "${connectivity_subscription}" "rg-${prefix}-connectivity"')) {
        if (-not $teardownShText.Contains($requiredText)) {
            Stop-Test "scripts/teardown.sh is missing monitoring teardown safety text: $requiredText"
        }
    }
    foreach ($requiredText in @('deployCentralLogAnalytics', 'centralLogAnalyticsEnabled', 'rg-$prefix-monitoring', 'existingLogAnalyticsWorkspaceResourceId', 'Test-ProtectedExternalResourceGroup', '$existingWorkspaceSupplied = $existingWorkspaceResourceId.Length -gt 0', '$monitoringGroupIsRepoOwned = $centralLogAnalyticsEnabled -and -not $existingWorkspaceSupplied', 'Remove-ResourceGroupIfNotProtected -Subscription $connectivitySubscription -Group $connectivityResourceGroup')) {
        if (-not $teardownPs1Text.Contains($requiredText)) {
            Stop-Test "scripts/teardown.ps1 is missing monitoring teardown safety text: $requiredText"
        }
    }
    if ($teardownPs1Text.Contains('IsNullOrWhiteSpace($existingWorkspaceResourceId)')) {
        Stop-Test 'scripts/teardown.ps1 must not use IsNullOrWhiteSpace on the raw existing workspace resource ID; it must match Bicep/Bash length-based presence semantics so a whitespace-only value is treated as supplied.'
    }

    Write-Host '18/30 Confirm a whitespace-only existing workspace resource ID never triggers deletion of the monitoring resource group...'
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
if [[ "$1" == 'policy' && "$2" == 'assignment' && "$3" == 'show' ]]; then
  echo '11111111-1111-1111-1111-111111111111'
  exit 0
fi
if [[ "$1" == 'role' && "$2" == 'assignment' && "$3" == 'list' ]]; then
  echo '/subscriptions/11111111-1111-1111-1111-111111111111/providers/Microsoft.Authorization/roleAssignments/demo-owned'
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
if /I "%~1"=="policy" if /I "%~2"=="assignment" if /I "%~3"=="show" (
  echo 11111111-1111-1111-1111-111111111111
  exit /b 0
)
if /I "%~1"=="role" if /I "%~2"=="assignment" if /I "%~3"=="list" (
  echo /subscriptions/11111111-1111-1111-1111-111111111111/providers/Microsoft.Authorization/roleAssignments/demo-owned
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
    $templateJson.parameters.existingLogAnalyticsWorkspaceResourceId.value = '/subscriptions/99999999-9999-9999-9999-999999999999/resourceGroups/external-monitoring/providers/Microsoft.OperationalInsights/workspaces/external-log'
    $templateJson.parameters.deployEvidenceResources.value = $false
    $templateJson.parameters.enableCriticalInfrastructure.value = $true
    $templateJson.parameters.criticalInfrastructureSubscriptionIds.value = @('88888888-8888-8888-8888-888888888888')
    $templateJson.parameters.enableNercCipTechnicalOverlay.value = $true
    $templateJson.parameters.nercCipApprovedLocations.value = @('eastus')
    $templateJson.parameters.nercCipDataClassificationTagValue.value = 'Non-sensitive'
    $templateJson.parameters.nercCipSspIdTagValue.value = 'Demo'
    $templateJson.parameters.enableVmBackupRemediation.value = $true
    $templateJson.parameters.enableFirewallRouteGuardrails.value = $true
    $templateJson.parameters.approvedBackupVaults.value = @([pscustomobject]@{
        vaultResourceId = '/subscriptions/99999999-9999-9999-9999-999999999999/resourceGroups/external-vault/providers/Microsoft.RecoveryServices/vaults/vault'
        backupPolicyResourceId = '/subscriptions/99999999-9999-9999-9999-999999999999/resourceGroups/external-vault/providers/Microsoft.RecoveryServices/vaults/vault/backupPolicies/daily'
    })
    $templateJson.parameters.policyExemptions.value = @(@{
        exemptionName = 'child-exemption'; exemptionScopeType = 'resourceGroup'
        subscriptionId = '22222222-2222-2222-2222-222222222222'; resourceGroupName = 'child-rg'
        policyAssignmentId = '/providers/Microsoft.Management/managementGroups/eslz-demo/providers/Microsoft.Authorization/policyAssignments/demo-audit-public-ip'
    })
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
        foreach ($requiredCall in @(
            'policy exemption delete --name child-exemption --scope /subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/child-rg',
            'policy assignment delete --name demo-nerc-cip-technical --scope /providers/Microsoft.Management/managementGroups/eslz-demo-criticalinfra',
            'policy assignment delete --name demo-firewall-routes --scope /providers/Microsoft.Management/managementGroups/eslz-demo-corp',
            'policy assignment delete --name demo-vm-backup-0 --scope /providers/Microsoft.Management/managementGroups/eslz-demo-landingzones',
            'management-group subscription add --name mg-root --subscription 88888888-8888-8888-8888-888888888888'
        )) {
            if (-not $azCalls.Contains($requiredCall)) { Stop-Test "teardown.sh missing mocked lifecycle call: $requiredCall" }
        }
    }

    if (Test-Path -LiteralPath $azCallLog) { Remove-Item -LiteralPath $azCallLog }
    New-Item -ItemType File -Path $azCallLog | Out-Null
    $originalPath = $env:PATH
    $env:PATH = "$mockBinDir$([System.IO.Path]::PathSeparator)$env:PATH"
    $env:AZ_CALL_LOG = $azCallLog
    $env:ESLZ_TEARDOWN_CONFIRMATION = 'DELETE-ESLZ-DEMO'
    $ps1Script = Join-Path $ProjectDir 'scripts/teardown.ps1'
    $nestedOutput = 'eslz-demo' | & pwsh -NoLogo -NoProfile -File $wrapperScript -ParameterFile $whitespaceParamFile -ExpectedMockDir $mockBinDir -TeardownScript $ps1Script 2>&1
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
    foreach ($requiredCall in @(
        'policy exemption delete --name child-exemption --scope /subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/child-rg',
        'policy assignment delete --name demo-nerc-cip-technical --scope /providers/Microsoft.Management/managementGroups/eslz-demo-criticalinfra',
        'policy assignment delete --name demo-firewall-routes --scope /providers/Microsoft.Management/managementGroups/eslz-demo-corp',
        'policy assignment delete --name demo-vm-backup-0 --scope /providers/Microsoft.Management/managementGroups/eslz-demo-landingzones',
        'management-group subscription add --name mg-root --subscription 88888888-8888-8888-8888-888888888888'
    )) {
        if (-not $azCalls.Contains($requiredCall)) { Stop-Test "teardown.ps1 missing mocked lifecycle call: $requiredCall" }
    }
    $whitespaceOnlyParameterFile = Join-Path $TempDir 'whitespace-only.parameters.json'
    $templateJson.parameters.existingLogAnalyticsWorkspaceResourceId.value = '   '
    $templateJson | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $whitespaceOnlyParameterFile
    if (Test-Path -LiteralPath $azCallLog) { Remove-Item -LiteralPath $azCallLog }
    New-Item -ItemType File -Path $azCallLog | Out-Null
    $originalPath = $env:PATH
    $env:PATH = "$mockBinDir$([System.IO.Path]::PathSeparator)$env:PATH"
    $env:AZ_CALL_LOG = $azCallLog
    $env:ESLZ_TEARDOWN_CONFIRMATION = 'DELETE-ESLZ-DEMO'
    $whitespaceOutput = 'eslz-demo' | & pwsh -NoLogo -NoProfile -File $wrapperScript -ParameterFile $whitespaceOnlyParameterFile -ExpectedMockDir $mockBinDir -TeardownScript $ps1Script 2>&1
    $whitespaceExitCode = $LASTEXITCODE
    $env:PATH = $originalPath
    Remove-Item Env:\AZ_CALL_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:\ESLZ_TEARDOWN_CONFIRMATION -ErrorAction SilentlyContinue
    if ($whitespaceExitCode -ne 0) {
        Stop-Test "teardown.ps1 whitespace fixture failed: $whitespaceOutput"
    }
    if ((Get-Content -LiteralPath $azCallLog -Raw) -match 'rg-eslz-demo-monitoring') {
        Stop-Test 'teardown.ps1 must not touch monitoring resources for a whitespace-only supplied workspace value.'
    }

    Write-Host '19/30 Parse every PowerShell lifecycle and test script...'
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

    Write-Host '20/30 Validate reusable initiative composition...'
    & (Join-Path $ScriptDir 'validate-initiative-composition.ps1')

    Write-Host '21/30 Validate the v2 control catalog (schema-equivalent checks + matrix consistency)...'
    & (Join-Path $ScriptDir 'validate-control-catalog.ps1')

    Write-Host '22/30 Backend parity and structural-matrix regression tests (bash/python, bash/jq, pwsh/python, pwsh/native)...'
    if (Get-Command bash -ErrorAction SilentlyContinue) {
        & bash (Join-Path $ScriptDir 'uri-grammar-forced-fallback-tests.sh')
        if ($LASTEXITCODE -ne 0) {
            Stop-Test 'tests/uri-grammar-forced-fallback-tests.sh failed.'
        }
    } else {
        Write-Host '  (No bash interpreter found on PATH; relying on tests/test.sh to cover this step.)'
    }

    Write-Host '23/30 Validate Entra Conditional Access and PIM demo artifacts...'
    & (Join-Path $ProjectDir 'scripts/validate-identity-artifacts.ps1')

    Write-Host '24/30 Confirm identity validators reject invalid Conditional Access and PIM inputs...'
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

    Write-Host '25/30 Confirm security benchmark assignments trace to the control catalog and stay optional...'
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
        if ($deployment.scope -cne "[format('Microsoft.Management/managementGroups/{0}', variables('demoRootManagementGroupId'))]") {
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

    Write-Host '26/30 Confirm logging assignments use the verified workspace/identity/effect model at the demo root...'
    if (-not (Select-String -Path (Join-Path $ProjectDir 'main.bicep') -Pattern 'func hasCanonicalArmIdSegments' -Quiet) -or
        -not (Select-String -Path (Join-Path $ProjectDir 'main.bicep') -Pattern 'func hasDisallowedResourceGroupAsciiChars' -Quiet) -or
        -not (Select-String -Path (Join-Path $ProjectDir 'main.bicep') -Pattern 'func isResourceGroupName\(value string\) bool => .*length\(value\) <= 90.*!hasDisallowedResourceGroupAsciiChars\(value\)' -Quiet) -or
        -not (Select-String -Path (Join-Path $ProjectDir 'main.bicep') -Pattern 'func isLogAnalyticsWorkspaceName\(value string\) bool => .*length\(value\) >= 4.*length\(value\) <= 63.*!startsWith\(value, ''-''\).*empty\(stripAlphaNumeric\(replace\(value, ''-'', ''''\)\)\)' -Quiet) -or
        -not (Select-String -Path (Join-Path $ProjectDir 'main.bicep') -Pattern 'func isWorkspaceResourceId\(value string\) bool => .*hasCanonicalArmIdSegments\(value\).*isResourceGroupName\(split\(value, ''/''\)\[4\]\).*isLogAnalyticsWorkspaceName\(split\(value, ''/''\)\[8\]\)' -Quiet)) {
        Stop-Test 'Workspace resource ID validation must require canonical absolute ARM IDs plus Azure-legal resource group and workspace name rules.'
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
        $armParameterTemplate.parameters.resourceDiagnosticsPolicyEffect.value -ne 'Disabled' -or
        $armParameterTemplate.parameters.resourceDiagnosticsCategoryGroup.value -ne 'audit' -or
        $armParameterTemplate.parameters.deployLoggingRemediationRoleAssignments.value -ne $false) {
        Stop-Test 'ARM parameter template must disable diagnostics until an effective workspace is configured.'
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
    if ($compiledJson.variables.loggingAssignmentsRequireWorkspace -ne "[or(or(equals(parameters('activityLogExportPolicyEffect'), 'DeployIfNotExists'), equals(parameters('resourceDiagnosticsPolicyEffect'), 'DeployIfNotExists')), equals(parameters('resourceDiagnosticsPolicyEffect'), 'AuditIfNotExists'))]" -or
        $compiledJson.variables.activityLogRemediationDeployRequested -ne "[equals(parameters('activityLogExportPolicyEffect'), 'DeployIfNotExists')]" -or
        $compiledJson.variables.resourceDiagnosticsRemediationDeployRequested -ne "[equals(parameters('resourceDiagnosticsPolicyEffect'), 'DeployIfNotExists')]" -or
        $compiledJson.variables.deployActivityLogRemediationRoleAssignments -ne "[and(and(parameters('deployRoleAssignments'), parameters('deployLoggingRemediationRoleAssignments')), variables('activityLogRemediationDeployRequested'))]" -or
        $compiledJson.variables.deployResourceDiagnosticsRemediationRoleAssignments -ne "[and(and(parameters('deployRoleAssignments'), parameters('deployLoggingRemediationRoleAssignments')), variables('resourceDiagnosticsRemediationDeployRequested'))]") {
        Stop-Test 'Logging workspace validation/remediation gating expressions must exactly match the expected compiled conditions.'
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
    $validWorkspaceResourceId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-monitor/providers/Microsoft.OperationalInsights/workspaces/log-demo-central'
    $malformedWorkspaceResourceId = '/subscriptions/not-a-guid/resourceGroups/rg-monitor/providers/Microsoft.OperationalInsights/workspaces/'
    $wrongTypeWorkspaceResourceId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-monitor/providers/Microsoft.Storage/storageAccounts/not-a-workspace'
    $malformedPrefixWorkspaceResourceId = 'junk/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-monitor/providers/Microsoft.OperationalInsights/workspaces/log-demo-central'
    $forbiddenSegmentWorkspaceResourceId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/./providers/Microsoft.OperationalInsights/workspaces/..'
    $illegalResourceGroupWorkspaceResourceId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg#bad/providers/Microsoft.OperationalInsights/workspaces/log-demo-central'
    $illegalWorkspaceNameResourceId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-monitor/providers/Microsoft.OperationalInsights/workspaces/-bad-'
    $unicodeResourceGroupWorkspaceResourceId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-ßeta/providers/Microsoft.OperationalInsights/workspaces/log-demo-central'
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
            existingLogAnalyticsWorkspaceResourceId = $validWorkspaceResourceId
            activityLogExportPolicyEffect = 'DeployIfNotExists'
            resourceDiagnosticsPolicyEffect = 'Disabled'
            resourceDiagnosticsCategoryGroup = 'audit'
            deployRoleAssignments = $true
            deployLoggingRemediationRoleAssignments = $true
        },
        @{
            Name = 'diagnostics-deploy-existing-alllogs'
            deployCentralLogAnalytics = $false
            existingLogAnalyticsWorkspaceResourceId = $validWorkspaceResourceId
            activityLogExportPolicyEffect = 'Disabled'
            resourceDiagnosticsPolicyEffect = 'DeployIfNotExists'
            resourceDiagnosticsCategoryGroup = 'allLogs'
            deployRoleAssignments = $true
            deployLoggingRemediationRoleAssignments = $true
        },
        @{
            Name = 'diagnostics-auditif-existing'
            deployCentralLogAnalytics = $false
            existingLogAnalyticsWorkspaceResourceId = $validWorkspaceResourceId
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
            existingLogAnalyticsWorkspaceResourceId = $malformedWorkspaceResourceId
            activityLogExportPolicyEffect = 'DeployIfNotExists'
            resourceDiagnosticsPolicyEffect = 'DeployIfNotExists'
            resourceDiagnosticsCategoryGroup = 'audit'
            deployRoleAssignments = $true
            deployLoggingRemediationRoleAssignments = $true
        },
        @{
            Name = 'enabled-wrong-type-existing-id'
            deployCentralLogAnalytics = $false
            existingLogAnalyticsWorkspaceResourceId = $wrongTypeWorkspaceResourceId
            activityLogExportPolicyEffect = 'Disabled'
            resourceDiagnosticsPolicyEffect = 'AuditIfNotExists'
            resourceDiagnosticsCategoryGroup = 'allLogs'
            deployRoleAssignments = $true
            deployLoggingRemediationRoleAssignments = $true
        },
        @{
            Name = 'enabled-malformed-prefix-existing-id'
            deployCentralLogAnalytics = $false
            existingLogAnalyticsWorkspaceResourceId = $malformedPrefixWorkspaceResourceId
            activityLogExportPolicyEffect = 'DeployIfNotExists'
            resourceDiagnosticsPolicyEffect = 'Disabled'
            resourceDiagnosticsCategoryGroup = 'audit'
            deployRoleAssignments = $true
            deployLoggingRemediationRoleAssignments = $true
        },
        @{
            Name = 'enabled-forbidden-segment-existing-id'
            deployCentralLogAnalytics = $false
            existingLogAnalyticsWorkspaceResourceId = $forbiddenSegmentWorkspaceResourceId
            activityLogExportPolicyEffect = 'Disabled'
            resourceDiagnosticsPolicyEffect = 'AuditIfNotExists'
            resourceDiagnosticsCategoryGroup = 'allLogs'
            deployRoleAssignments = $true
            deployLoggingRemediationRoleAssignments = $true
        },
        @{
            Name = 'enabled-illegal-rg-name-existing-id'
            deployCentralLogAnalytics = $false
            existingLogAnalyticsWorkspaceResourceId = $illegalResourceGroupWorkspaceResourceId
            activityLogExportPolicyEffect = 'DeployIfNotExists'
            resourceDiagnosticsPolicyEffect = 'Disabled'
            resourceDiagnosticsCategoryGroup = 'audit'
            deployRoleAssignments = $true
            deployLoggingRemediationRoleAssignments = $true
        },
        @{
            Name = 'enabled-illegal-workspace-name-existing-id'
            deployCentralLogAnalytics = $false
            existingLogAnalyticsWorkspaceResourceId = $illegalWorkspaceNameResourceId
            activityLogExportPolicyEffect = 'Disabled'
            resourceDiagnosticsPolicyEffect = 'AuditIfNotExists'
            resourceDiagnosticsCategoryGroup = 'allLogs'
            deployRoleAssignments = $true
            deployLoggingRemediationRoleAssignments = $true
        },
        @{
            Name = 'enabled-unicode-rg-name-existing-id'
            deployCentralLogAnalytics = $false
            existingLogAnalyticsWorkspaceResourceId = $unicodeResourceGroupWorkspaceResourceId
            activityLogExportPolicyEffect = 'Disabled'
            resourceDiagnosticsPolicyEffect = 'AuditIfNotExists'
            resourceDiagnosticsCategoryGroup = 'audit'
            deployRoleAssignments = $true
            deployLoggingRemediationRoleAssignments = $true
        }
    )
    $workspaceModes = [System.Collections.Generic.HashSet[string]]::new()
    $categoryModes = [System.Collections.Generic.HashSet[string]]::new()
    $effectStates = [System.Collections.Generic.HashSet[string]]::new()
    $loggingParameterTemplateText = Get-Content -LiteralPath (Join-Path $ProjectDir 'parameters/main.template.bicepparam') -Raw
    function Test-ResourceGroupName {
        param([string]$Value)
        if ($Value -cne $Value.Trim() -or $Value.Length -lt 1 -or $Value.Length -gt 90 -or $Value.EndsWith('.')) { return $false }
        return $Value -cmatch '^[\p{L}\p{Nd}_.()\-]+$'
    }
    function Test-LogAnalyticsWorkspaceName {
        param([string]$Value)
        if ($Value -cne $Value.Trim() -or $Value.Length -lt 4 -or $Value.Length -gt 63) { return $false }
        if ($Value.StartsWith('-') -or $Value.EndsWith('-')) { return $false }
        return $Value -cmatch '^[A-Za-z0-9-]+$'
    }
    function Test-WorkspaceResourceIdOffline {
        param([string]$Value)
        if ($Value -cne $Value.Trim() -or -not $Value.StartsWith('/') -or $Value.EndsWith('/')) { return $false }
        $parts = $Value.Split('/')
        if ($parts.Length -ne 9 -or $parts[0] -ne '') { return $false }
        foreach ($part in $parts[1..8]) {
            if ($part -eq '' -or $part -cne $part.Trim()) { return $false }
        }
        if ($parts[1].ToLowerInvariant() -ne 'subscriptions' -or $parts[2] -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { return $false }
        if ($parts[3].ToLowerInvariant() -ne 'resourcegroups' -or -not (Test-ResourceGroupName -Value $parts[4])) { return $false }
        if ($parts[5].ToLowerInvariant() -ne 'providers' -or $parts[6].ToLowerInvariant() -ne 'microsoft.operationalinsights' -or $parts[7].ToLowerInvariant() -ne 'workspaces') { return $false }
        return Test-LogAnalyticsWorkspaceName -Value $parts[8]
    }
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
        if (-not $loggingCase.deployCentralLogAnalytics -and -not [string]::IsNullOrEmpty($loggingCase.existingLogAnalyticsWorkspaceResourceId)) {
            $expectedValidWorkspaceId = @($validWorkspaceResourceId, $unicodeResourceGroupWorkspaceResourceId) -contains $loggingCase.existingLogAnalyticsWorkspaceResourceId
            if ((Test-WorkspaceResourceIdOffline -Value $loggingCase.existingLogAnalyticsWorkspaceResourceId) -ne $expectedValidWorkspaceId) {
                Stop-Test "Logging matrix case $($loggingCase.Name) did not match offline workspace-ID rejection expectations."
            }
        }
        if ($loggingCase.deployCentralLogAnalytics) {
            [void]$workspaceModes.Add('new')
        } elseif ([string]::IsNullOrEmpty($loggingCase.existingLogAnalyticsWorkspaceResourceId)) {
            [void]$workspaceModes.Add('empty')
        } elseif ($loggingCase.existingLogAnalyticsWorkspaceResourceId -eq $validWorkspaceResourceId) {
            [void]$workspaceModes.Add('existing-valid')
        } elseif ($loggingCase.existingLogAnalyticsWorkspaceResourceId -eq $malformedWorkspaceResourceId) {
            [void]$workspaceModes.Add('existing-malformed')
        } elseif ($loggingCase.existingLogAnalyticsWorkspaceResourceId -eq $wrongTypeWorkspaceResourceId) {
            [void]$workspaceModes.Add('existing-wrong-type')
        } elseif ($loggingCase.existingLogAnalyticsWorkspaceResourceId -eq $malformedPrefixWorkspaceResourceId) {
            [void]$workspaceModes.Add('existing-malformed-prefix')
        } elseif ($loggingCase.existingLogAnalyticsWorkspaceResourceId -eq $forbiddenSegmentWorkspaceResourceId) {
            [void]$workspaceModes.Add('existing-forbidden-segment')
        } elseif ($loggingCase.existingLogAnalyticsWorkspaceResourceId -eq $illegalResourceGroupWorkspaceResourceId) {
            [void]$workspaceModes.Add('existing-illegal-rg-name')
        } elseif ($loggingCase.existingLogAnalyticsWorkspaceResourceId -eq $illegalWorkspaceNameResourceId) {
            [void]$workspaceModes.Add('existing-illegal-workspace-name')
        } elseif ($loggingCase.existingLogAnalyticsWorkspaceResourceId -eq $unicodeResourceGroupWorkspaceResourceId) {
            [void]$workspaceModes.Add('existing-unicode-rg-name')
        }
        [void]$categoryModes.Add($loggingCase.resourceDiagnosticsCategoryGroup)
        [void]$effectStates.Add("$($loggingCase.activityLogExportPolicyEffect)|$($loggingCase.resourceDiagnosticsPolicyEffect)")
    }
    if (Compare-Object @($workspaceModes) @('new', 'empty', 'existing-valid', 'existing-malformed', 'existing-wrong-type', 'existing-malformed-prefix', 'existing-forbidden-segment', 'existing-illegal-rg-name', 'existing-illegal-workspace-name', 'existing-unicode-rg-name')) {
        Stop-Test 'Logging matrix coverage must include new, empty, valid-existing, malformed-existing, wrong-type-existing, malformed-prefix, forbidden-segment, illegal-resource-group-name, illegal-workspace-name, and unicode-resource-group-name workspace paths.'
    }
    if (Compare-Object @($categoryModes) @('audit', 'allLogs')) {
        Stop-Test 'Logging matrix coverage must include both resourceDiagnosticsCategoryGroup values: audit and allLogs.'
    }
    if (-not $effectStates.Contains('Disabled|Disabled') -or -not $effectStates.Contains('DeployIfNotExists|DeployIfNotExists')) {
        Stop-Test 'Logging matrix coverage must include both fully disabled and fully remediation-enabled effect combinations.'
    }

    Write-Host '27/30 Confirm storage, Key Vault, and customer-managed key controls are verified and audit-first...'
    if ($compiledJson.parameters.dataProtectionPolicyEffect.defaultValue -ne 'Audit' -or
        (Compare-Object @($compiledJson.parameters.dataProtectionPolicyEffect.allowedValues) @('Audit', 'Deny', 'Disabled'))) {
        Stop-Test 'Compiled dataProtectionPolicyEffect must allow Audit, Deny, and Disabled and default to Audit.'
    }
    if ($compiledJson.parameters.storageMinimumTlsVersion.defaultValue -ne 'TLS1_2' -or
        (Compare-Object @($compiledJson.parameters.storageMinimumTlsVersion.allowedValues) @('TLS1_0', 'TLS1_1', 'TLS1_2'))) {
        Stop-Test 'Compiled storageMinimumTlsVersion must allow TLS1_0, TLS1_1, and TLS1_2 and default to TLS1_2.'
    }
    if (@($compiledJson.parameters.approvedCustomerManagedKeyVaultUris.defaultValue).Count -ne 0 -or
        @($compiledJson.parameters.approvedCustomerManagedKeyNames.defaultValue).Count -ne 0) {
        Stop-Test 'Approved customer-managed key inputs must default to empty arrays.'
    }
    if ($parameterTemplate.parameters.dataProtectionPolicyEffect.value -ne 'Audit' -or
        $parameterTemplate.parameters.storageMinimumTlsVersion.value -ne 'TLS1_2' -or
        @($parameterTemplate.parameters.approvedCustomerManagedKeyVaultUris.value).Count -ne 0 -or
        @($parameterTemplate.parameters.approvedCustomerManagedKeyNames.value).Count -ne 0) {
        Stop-Test 'The JSON parameter template must keep audit-first data-protection defaults with no approved key inputs.'
    }
    if ($compiledParameters.parameters.dataProtectionPolicyEffect.value -ne 'Audit') {
        Stop-Test 'dataProtectionPolicyEffect must default to Audit in the Bicep parameter template.'
    }

    $dataProtectionInitiative = @($compiledJson.resources | Where-Object { $_.name -eq 'data-protection-initiative' })
    $dataProtectionAssignment = @($compiledJson.resources | Where-Object { $_.name -eq 'assign-data-protection' })
    if ($dataProtectionInitiative.Count -ne 1 -or $dataProtectionAssignment.Count -ne 1) {
        Stop-Test 'Expected exactly one data-protection initiative and one data-protection assignment.'
    }
    if ($dataProtectionInitiative[0].scope -cne "[format('Microsoft.Management/managementGroups/{0}', variables('demoRootManagementGroupId'))]") {
        Stop-Test 'The data-protection initiative must be created at the dedicated demo root.'
    }
    if ($dataProtectionAssignment[0].scope -cne "[format('Microsoft.Management/managementGroups/{0}', variables('landingZonesManagementGroupId'))]") {
        Stop-Test 'The data-protection initiative must be assigned at the Landing Zones management group.'
    }

    $expectedDataProtectionReferenceIds = @(
        'key-vault-deletion-protection',
        'key-vault-diagnostics-readiness',
        'key-vault-network-access',
        'key-vault-rbac-authorization',
        'key-vault-soft-delete',
        'storage-approved-customer-managed-key',
        'storage-customer-managed-key',
        'storage-minimum-tls',
        'storage-network-access',
        'storage-public-blob-access',
        'storage-secure-transfer',
        'storage-shared-key-access'
    )
    $dataProtectionReferences = @($dataProtectionInitiative[0].properties.parameters.policyDefinitionReferences.value)
    if (Compare-Object ($dataProtectionReferences | ForEach-Object { $_.policyDefinitionReferenceId } | Sort-Object) ($expectedDataProtectionReferenceIds | Sort-Object)) {
        Stop-Test 'The data-protection initiative does not compose exactly the expected storage and Key Vault controls.'
    }

    $dataProtectionAssignmentParameters = $dataProtectionAssignment[0].properties.parameters.parameters.value
    foreach ($expectedBinding in @(
        @{ Name = 'effect'; Value = "[parameters('dataProtectionPolicyEffect')]" },
        @{ Name = 'auditOnlyEffect'; Value = "[variables('dataProtectionAuditOnlyEffect')]" },
        @{ Name = 'purgeProtectionEffect'; Value = "[variables('dataProtectionPurgeProtectionEffect')]" },
        @{ Name = 'auditIfNotExistsEffect'; Value = "[variables('dataProtectionAuditIfNotExistsEffect')]" },
        @{ Name = 'minimumTlsVersion'; Value = "[parameters('storageMinimumTlsVersion')]" },
        @{ Name = 'approvedKeyVaultUris'; Value = "[parameters('approvedCustomerManagedKeyVaultUris')]" },
        @{ Name = 'approvedKeyNames'; Value = "[parameters('approvedCustomerManagedKeyNames')]" }
    )) {
        if ($dataProtectionAssignmentParameters.($expectedBinding.Name).value -ne $expectedBinding.Value) {
            Stop-Test "The data-protection assignment does not bind $($expectedBinding.Name) to its template input."
        }
    }
    $dataProtectionMessages = @($dataProtectionAssignment[0].properties.parameters.nonComplianceMessages.value)
    if ($dataProtectionMessages.Count -ne $expectedDataProtectionReferenceIds.Count -or
        (Compare-Object ($dataProtectionMessages | ForEach-Object { $_.policyDefinitionReferenceId } | Sort-Object) ($expectedDataProtectionReferenceIds | Sort-Object)) -or
        @($dataProtectionMessages | Where-Object { [string]::IsNullOrWhiteSpace($_.message) }).Count -ne 0) {
        Stop-Test 'Every data-protection control must have its own non-empty non-compliance message.'
    }

    # Every built-in referenced by the initiative must be one of the GUIDs
    # recorded in the verified control catalog, so a control can never be wired
    # to an unverified or invented definition ID.
    $controlCatalog = Get-Content -LiteralPath (Join-Path $ProjectDir 'policy/control-catalog.json') -Raw | ConvertFrom-Json
    $verifiedBuiltInIds = @($controlCatalog.controls |
        Where-Object { $_.mechanism.builtIn -eq $true -and $_.mechanism.definitionId } |
        ForEach-Object { $_.mechanism.definitionId })
    $referencedBuiltInIds = @($dataProtectionReferences |
        Where-Object { $_.policyDefinitionId.StartsWith("[tenantResourceId('Microsoft.Authorization/policyDefinitions', ") } |
        ForEach-Object { [regex]::Match($_.policyDefinitionId, '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}').Value } |
        Sort-Object -Unique)
    if ($referencedBuiltInIds.Count -ne 11) {
        Stop-Test "Expected 11 distinct verified built-in definitions in the data-protection initiative, found $($referencedBuiltInIds.Count)."
    }
    foreach ($referencedBuiltInId in $referencedBuiltInIds) {
        if ($referencedBuiltInId -notin $verifiedBuiltInIds) {
            Stop-Test "Data-protection built-in $referencedBuiltInId is not a verified control-catalog definition ID."
        }
    }

    # Every built-in member must be pinned to the exact major version verified in
    # the control catalog, and the in-repository custom member must stay unpinned
    # because definitionVersion applies only to built-in definitions.
    $expectedDefinitionVersions = [ordered]@{
        'storage-secure-transfer'                = '2.*.*'
        'storage-minimum-tls'                    = '1.*.*'
        'storage-public-blob-access'             = '3.*.*'
        'storage-network-access'                 = '1.*.*'
        'storage-shared-key-access'              = '2.*.*'
        'key-vault-soft-delete'                  = '3.*.*'
        'key-vault-deletion-protection'          = '2.*.*'
        'key-vault-rbac-authorization'           = '1.*.*'
        'key-vault-network-access'               = '3.*.*'
        'key-vault-diagnostics-readiness'        = '5.*.*'
        'storage-customer-managed-key'           = '1.*.*'
        'storage-approved-customer-managed-key'  = $null
    }
    foreach ($dataProtectionReference in $dataProtectionReferences) {
        $referenceId = $dataProtectionReference.policyDefinitionReferenceId
        if (-not $expectedDefinitionVersions.Contains($referenceId)) {
            Stop-Test "Unexpected data-protection policy definition reference '$referenceId'."
        }
        $actualDefinitionVersion = $null
        if ($dataProtectionReference.PSObject.Properties['definitionVersion']) {
            $actualDefinitionVersion = $dataProtectionReference.definitionVersion
        }
        if ($actualDefinitionVersion -ne $expectedDefinitionVersions[$referenceId]) {
            Stop-Test "Data-protection reference '$referenceId' must pin definitionVersion '$($expectedDefinitionVersions[$referenceId])' but pins '$actualDefinitionVersion'."
        }
        $referenceBuiltInId = [regex]::Match($dataProtectionReference.policyDefinitionId, '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}').Value
        if (-not $referenceBuiltInId) {
            if ($null -ne $actualDefinitionVersion) {
                Stop-Test "Custom data-protection reference '$referenceId' must not declare definitionVersion."
            }
            continue
        }
        $catalogMajor = @($controlCatalog.controls |
            Where-Object { $_.mechanism.builtIn -eq $true -and $_.mechanism.definitionId -eq $referenceBuiltInId } |
            ForEach-Object { $_.mechanism.majorVersion })
        if ($catalogMajor.Count -lt 1 -or $actualDefinitionVersion -ne "$($catalogMajor[0]).*.*") {
            Stop-Test "Data-protection reference '$referenceId' must pin the catalog-verified major for built-in $referenceBuiltInId."
        }
    }

    # Purge protection is only ever audited or denied, never turned off, and the
    # audit-only and readiness controls can never be escalated to Deny.
    $dataProtectionInitiativeParameters = $dataProtectionInitiative[0].properties.parameters.initiativeParameters.value
    if ((Compare-Object @($dataProtectionInitiativeParameters.effect.allowedValues) @('Audit', 'Deny', 'Disabled')) -or
        $dataProtectionInitiativeParameters.effect.defaultValue -ne 'Audit' -or
        (Compare-Object @($dataProtectionInitiativeParameters.auditOnlyEffect.allowedValues) @('Audit', 'Disabled')) -or
        (Compare-Object @($dataProtectionInitiativeParameters.auditIfNotExistsEffect.allowedValues) @('AuditIfNotExists', 'Disabled'))) {
        Stop-Test 'Data-protection effects must stay audit-first, with no Deny option for audit-only or readiness controls.'
    }
    if ((Compare-Object @($dataProtectionInitiativeParameters.purgeProtectionEffect.allowedValues) @('Audit', 'Deny')) -or
        $dataProtectionInitiativeParameters.purgeProtectionEffect.defaultValue -ne 'Audit') {
        Stop-Test 'The Key Vault purge protection effect must only ever allow Audit or Deny.'
    }
    if ($compiledJson.variables.dataProtectionPurgeProtectionEffect -cne "[if(equals(parameters('dataProtectionPolicyEffect'), 'Deny'), 'Deny', 'Audit')]") {
        Stop-Test 'A Disabled data-protection effect must still map to Audit for Key Vault purge protection.'
    }
    $deletionProtectionReference = @($dataProtectionReferences | Where-Object { $_.policyDefinitionReferenceId -eq 'key-vault-deletion-protection' })
    if ($deletionProtectionReference[0].parameters.effect.value -ne "[[parameters('purgeProtectionEffect')]") {
        Stop-Test 'Key Vault purge protection must bind the Audit/Deny-only purge protection effect and must never be disabled.'
    }
    $storageCmkReference = @($dataProtectionReferences | Where-Object { $_.policyDefinitionReferenceId -eq 'storage-customer-managed-key' })
    if ($storageCmkReference[0].parameters.effect.value -ne "[[parameters('auditOnlyEffect')]") {
        Stop-Test 'The storage customer-managed key audit must stay bound to the audit-only effect.'
    }

    # The in-repository customer-managed key control must stay parameterized and
    # must report nothing until the customer supplies an approved key inventory.
    $storageCmkDefinition = @($policyDefinitions | Where-Object {
        $_.properties.displayName -eq 'Demo - audit storage customer-managed keys against approved Key Vaults and keys'
    })
    if ($storageCmkDefinition.Count -ne 1) {
        Stop-Test 'Expected exactly one approved customer-managed key audit definition.'
    }
    if (@($storageCmkDefinition[0].properties.parameters.approvedKeyVaultUris.defaultValue).Count -ne 0 -or
        @($storageCmkDefinition[0].properties.parameters.approvedKeyNames.defaultValue).Count -ne 0 -or
        $storageCmkDefinition[0].properties.parameters.effect.defaultValue -ne 'Audit') {
        Stop-Test 'The approved customer-managed key audit must default to Audit with empty approved inputs.'
    }
    $storageCmkRuleText = $storageCmkDefinition[0].properties.policyRule.if | ConvertTo-Json -Depth 100 -Compress
    foreach ($requiredExpression in @(
        "length(parameters('approvedKeyVaultUris'))",
        "length(parameters('approvedKeyNames'))",
        'encryption.keyvaultproperties.keyvaulturi',
        'encryption.keyvaultproperties.keyname'
    )) {
        if (-not $storageCmkRuleText.Contains($requiredExpression)) {
            Stop-Test "The approved customer-managed key audit is missing expression: $requiredExpression"
        }
    }

    # Restricting public access must never be implemented by deploying a Key
    # Vault, a key, a private endpoint, or a private DNS zone in this template,
    # and the data-protection controls must never request a managed identity
    # (which would imply remediation rights or paid/data-plane changes).
    $prohibitedDataProtectionResources = Find-JsonObjects -Node $compiledJson -Predicate {
        param($node)
        $node.PSObject.Properties['type'] -and
        $node.PSObject.Properties['apiVersion'] -and
        ($node.type -is [string]) -and
        ($node.type -match '^Microsoft\.(KeyVault/vaults(/keys|/secrets)?|Network/(privateEndpoints|privateDnsZones))$')
    }
    if (@($prohibitedDataProtectionResources).Count -ne 0) {
        Stop-Test 'The data-protection controls must not declare a Key Vault, key, secret, private endpoint, or private DNS zone.'
    }
    $dataProtectionDeployments = @($dataProtectionInitiative[0], $dataProtectionAssignment[0])
    # Compiled nested templates use symbolic-name resource maps, so the nested
    # resources are enumerated as property values rather than array elements.
    $dataProtectionNestedResources = @($dataProtectionDeployments | ForEach-Object {
        $nested = $_.properties.template.resources
        if ($nested -is [System.Collections.IEnumerable] -and $nested -isnot [string]) { $nested } else { $nested.PSObject.Properties.Value }
    })
    if (@($dataProtectionNestedResources).Count -ne 2 -or
        (Compare-Object @($dataProtectionNestedResources | ForEach-Object { $_.type } | Sort-Object) @(
            'Microsoft.Authorization/policyAssignments',
            'Microsoft.Authorization/policySetDefinitions'))) {
        Stop-Test 'The data-protection initiative and assignment must declare only policy resources.'
    }
    foreach ($dataProtectionResource in ($dataProtectionDeployments + $dataProtectionNestedResources)) {
        if ($dataProtectionResource.PSObject.Properties['identity']) {
            Stop-Test 'The data-protection initiative and assignment must not request a system-assigned or user-assigned identity.'
        }
        if ($dataProtectionResource.PSObject.Properties['type'] -and
            $dataProtectionResource.type -match '^Microsoft\.(ManagedIdentity|KeyVault|Storage|Network|OperationalInsights)/') {
            Stop-Test "The data-protection controls must not declare $($dataProtectionResource.type)."
        }
    }

    Write-Host '28/30 Confirm backup coverage and vault posture controls stay audit-first and dependency-gated...'
    $backupDefaults = @{
        enableVmBackupRemediation          = $false
        enableVaultDiagnostics             = $false
        deployRecoveryServicesVault        = $false
        allowCrossSubscriptionBackupVaults = $false
        grantVaultDiagnosticsWorkspaceAccess = $false
        backupRetentionStandardId          = ''
        vmBackupInclusionTagName           = ''
        vmBackupCoveragePolicyEffect       = 'AuditIfNotExists'
        vmBackupConfigurationEffect        = 'AuditIfNotExists'
        vaultDiagnosticsEffect             = 'AuditIfNotExists'
        vaultPublicNetworkPolicyEffect     = 'Audit'
        vaultEncryptionPolicyEffect        = 'Audit'
        vaultImmutabilityPolicyEffect      = 'Audit'
        vaultSoftDeletePolicyEffect        = 'Audit'
        vaultMultiUserAuthorizationPolicyEffect = 'Audit'
        vaultDoubleEncryptionRequired      = $false
        vaultCheckLockedImmutabilityOnly   = $true
        vaultCheckAlwaysOnSoftDeleteOnly   = $false
        vaultImmutabilityState             = 'Unlocked'
        vaultSoftDeleteState               = 'Enabled'
        denyPolicyEnforcementMode          = 'DoNotEnforce'
    }
    foreach ($backupParameterName in $backupDefaults.Keys) {
        if ($compiledJson.parameters.$backupParameterName.defaultValue -ne $backupDefaults[$backupParameterName]) {
            Stop-Test "$backupParameterName must keep the audit-first safe default $($backupDefaults[$backupParameterName])."
        }
    }
    foreach ($backupListParameter in @('approvedBackupVaults', 'approvedVaultRegions')) {
        if (@($compiledJson.parameters.$backupListParameter.defaultValue).Count -ne 0) {
            Stop-Test "$backupListParameter must default to an empty list so no backup is configured."
        }
    }
    $backupControls = @(
        @{ ControlId = 'REQ-BKP-01'; VariableName = 'vmBackupCoveragePolicyDefinitionId'; Kind = 'policyDefinitions' },
        @{ ControlId = 'REQ-BKP-02'; VariableName = 'configureVmBackupPolicyDefinitionId'; Kind = 'policyDefinitions' },
        @{ ControlId = 'REQ-BKP-04'; VariableName = 'vaultPublicNetworkPolicyDefinitionId'; Kind = 'policyDefinitions' },
        @{ ControlId = 'REQ-BKP-05'; VariableName = 'vaultEncryptionPolicyDefinitionId'; Kind = 'policyDefinitions' },
        @{ ControlId = 'REQ-BKP-06'; VariableName = 'vaultImmutabilityPolicyDefinitionId'; Kind = 'policyDefinitions' },
        @{ ControlId = 'REQ-BKP-08'; VariableName = 'vaultSoftDeletePolicyDefinitionId'; Kind = 'policyDefinitions' },
        @{ ControlId = 'REQ-BKP-09'; VariableName = 'vaultMultiUserAuthorizationPolicyDefinitionId'; Kind = 'policyDefinitions' },
        @{ ControlId = 'REQ-BKP-07'; VariableName = 'resourceDiagnosticsToLogAnalyticsPolicySetDefinitionId'; Kind = 'policySetDefinitions' }
    )
    $backupMajorVersions = @{}
    foreach ($backupControl in $backupControls) {
        $control = $controlCatalog.controls | Where-Object { $_.id -eq $backupControl.ControlId } | Select-Object -First 1
        if (-not $control) { Stop-Test "Control catalog is missing $($backupControl.ControlId)." }
        $expectedId = "[tenantResourceId('Microsoft.Authorization/$($backupControl.Kind)', '$($control.mechanism.definitionId)')]"
        if ($compiledJson.variables.($backupControl.VariableName) -ne $expectedId) {
            Stop-Test "$($backupControl.VariableName) must trace to the verified $($backupControl.ControlId) built-in."
        }
        $backupMajorVersions[$backupControl.ControlId] = "$($control.mechanism.majorVersion).*.*"
    }
    $backupInitiative = Find-JsonObjects -Node $compiledJson -Predicate {
        param($node)
        $node.PSObject.Properties['name'] -and $node.name -eq 'backup-posture-initiative'
    } | Select-Object -First 1
    $backupPostureAssignment = Find-JsonObjects -Node $compiledJson -Predicate {
        param($node)
        $node.PSObject.Properties['name'] -and $node.name -eq 'assign-backup-posture'
    } | Select-Object -First 1
    if (-not $backupInitiative -or -not $backupPostureAssignment) {
        Stop-Test 'Backup posture initiative and assignment must exist.'
    }
    $backupReferences = @($backupInitiative.properties.parameters.policyDefinitionReferences.value)
    $expectedBackupReferenceVersions = @{
        'vm-backup-coverage'             = $backupMajorVersions['REQ-BKP-01']
        'vault-public-network-access'    = $backupMajorVersions['REQ-BKP-04']
        'vault-customer-managed-key'     = $backupMajorVersions['REQ-BKP-05']
        'vault-immutability'             = $backupMajorVersions['REQ-BKP-06']
        'vault-soft-delete'              = $backupMajorVersions['REQ-BKP-08']
        'vault-multi-user-authorization' = $backupMajorVersions['REQ-BKP-09']
    }
    foreach ($referenceId in $expectedBackupReferenceVersions.Keys) {
        $reference = $backupReferences | Where-Object { $_.policyDefinitionReferenceId -eq $referenceId } | Select-Object -First 1
        if (-not $reference -or $reference.definitionVersion -ne $expectedBackupReferenceVersions[$referenceId]) {
            Stop-Test "Backup initiative reference $referenceId must be pinned to the cataloged major version."
        }
    }
    $softDeleteReference = $backupReferences | Where-Object { $_.policyDefinitionReferenceId -eq 'vault-soft-delete' } | Select-Object -First 1
    if (Compare-Object @($softDeleteReference.parameters.PSObject.Properties.Name | Microsoft.PowerShell.Utility\Sort-Object) `
            @('checkAlwaysOnSoftDeleteOnly', 'effect') -SyncWindow 0) {
        Stop-Test 'The vault soft-delete reference must supply the built-in effect and checkAlwaysOnSoftDeleteOnly parameters.'
    }
    if ($backupPostureAssignment.scope -notmatch 'landingZonesManagementGroupId' -or
        $backupPostureAssignment.PSObject.Properties['condition']) {
        Stop-Test 'The backup posture audit must always be assigned at the landing zones scope.'
    }
    $publicNetworkMessage = [string](@($backupPostureAssignment.properties.parameters.nonComplianceMessages.value |
        Where-Object { $_.policyDefinitionReferenceId -eq 'vault-public-network-access' })[0].message)
    if ($publicNetworkMessage -notmatch 'publicNetworkAccess' -or $publicNetworkMessage -notmatch 'does not prove') {
        Stop-Test 'The public-network-access message must claim only what the built-in evaluates.'
    }
    $expectedActiveConditions = @{
        vmBackupRemediationActive = "[and(parameters('enableVmBackupRemediation'), variables('validatedVmBackupRemediation'))]"
        vaultDiagnosticsActive    = "[and(parameters('enableVaultDiagnostics'), variables('validatedVaultDiagnostics'))]"
        customerOwnedVaultActive  = "[and(parameters('deployRecoveryServicesVault'), variables('validatedRecoveryServicesVaultCreation'))]"
        vaultDiagnosticsRemediationActive = "[and(variables('vaultDiagnosticsActive'), equals(parameters('vaultDiagnosticsEffect'), 'DeployIfNotExists'))]"
        vaultDiagnosticsAuditActive = "[and(variables('vaultDiagnosticsActive'), not(equals(parameters('vaultDiagnosticsEffect'), 'DeployIfNotExists')))]"
        vaultDiagnosticsWorkspaceAccessActive = "[and(and(parameters('grantVaultDiagnosticsWorkspaceAccess'), variables('vaultDiagnosticsRemediationActive')), variables('validatedVaultDiagnosticsWorkspaceAccess'))]"
        vaultDiagnosticsWorkspaceIdValid = "[__bicep.isLogAnalyticsWorkspaceId(variables('vaultDiagnosticsWorkspaceResourceId'))]"
    }
    foreach ($activeVariable in $expectedActiveConditions.Keys) {
        if ($compiledJson.variables.$activeVariable -ne $expectedActiveConditions[$activeVariable]) {
            Stop-Test "$activeVariable must compile to the exact opt-in and validation condition."
        }
    }
    $vmBackupAssignments = Find-JsonObjects -Node $compiledJson -Predicate {
        param($node)
        $node.PSObject.Properties['copy'] -and $node.copy.PSObject.Properties['name'] -and
        $node.copy.name -eq 'vmBackupConfigurationAssignments'
    } | Select-Object -First 1
    if (-not $vmBackupAssignments -or
        $vmBackupAssignments.condition -ne "[variables('vmBackupRemediationActive')]" -or
        $vmBackupAssignments.copy.count -ne "[length(variables('validatedApprovedBackupVaults'))]" -or
        $vmBackupAssignments.scope -notmatch 'landingZonesManagementGroupId' -or
        $vmBackupAssignments.properties.parameters.definitionVersion.value -ne $backupMajorVersions['REQ-BKP-02'] -or
        $vmBackupAssignments.properties.parameters.enforcementMode.value -ne "[parameters('denyPolicyEnforcementMode')]" -or
        $vmBackupAssignments.properties.parameters.parameters.value.backupPolicyId.value -ne
            "[variables('validatedApprovedBackupVaults')[copyIndex()].backupPolicyResourceId]" -or
        $vmBackupAssignments.properties.parameters.parameters.value.vaultLocation.value -ne
            "[variables('validatedApprovedBackupVaults')[copyIndex()].region]" -or
        $vmBackupAssignments.properties.parameters.parameters.value.inclusionTagValue.value -ne
            "[variables('validatedApprovedBackupVaults')[copyIndex()].inclusionTagValues]") {
        Stop-Test 'VM backup remediation must stay opt-in, per approved vault, and pinned to the cataloged built-in.'
    }
    $vmBackupControl = $controlCatalog.controls | Where-Object { $_.id -eq 'REQ-BKP-02' } | Select-Object -First 1
    if (Compare-Object @(
            $compiledJson.variables.virtualMachineContributorRoleDefinitionId,
            $compiledJson.variables.backupContributorRoleDefinitionId
        ) @($vmBackupControl.roleDefinitionIds) -SyncWindow 0) {
        Stop-Test 'VM backup remediation roles must match the verified control catalog role definition IDs.'
    }
    $vaultDiagnosticsAssignment = Find-JsonObjects -Node $compiledJson -Predicate {
        param($node)
        $node.PSObject.Properties['name'] -and $node.name -eq 'assign-vault-diagnostics'
    } | Select-Object -First 1
    if (-not $vaultDiagnosticsAssignment -or
        $vaultDiagnosticsAssignment.condition -ne "[variables('vaultDiagnosticsRemediationActive')]" -or
        (Compare-Object @($vaultDiagnosticsAssignment.properties.parameters.parameters.value.resourceTypeList.value) `
            @('microsoft.recoveryservices/vaults') -SyncWindow 0) -or
        ([string]$vaultDiagnosticsAssignment.properties.parameters.parameters.value.logAnalytics.value) -notmatch 'centralMonitoring') {
        Stop-Test 'Vault diagnostics remediation must stay opt-in, vault-scoped, and bound to the central workspace.'
    }
    $vaultDiagnosticsAuditAssignment = Find-JsonObjects -Node $compiledJson -Predicate {
        param($node)
        $node.PSObject.Properties['name'] -and $node.name -eq 'assign-vault-diagnostics-audit'
    } | Select-Object -First 1
    $auditAssignmentResources = @(
        $vaultDiagnosticsAuditAssignment.properties.template.resources.PSObject.Properties.Value
    )
    if (-not $vaultDiagnosticsAuditAssignment -or
        $vaultDiagnosticsAuditAssignment.condition -ne "[variables('vaultDiagnosticsAuditActive')]" -or
        $vaultDiagnosticsAuditAssignment.scope -notmatch 'landingZonesManagementGroupId' -or
        $vaultDiagnosticsAuditAssignment.properties.parameters.PSObject.Properties['identity'] -or
        $vaultDiagnosticsAuditAssignment.properties.parameters.PSObject.Properties['verifiedRoleDefinitionIds'] -or
        @($auditAssignmentResources | Where-Object { $_.PSObject.Properties['identity'] }).Count -ne 0 -or
        @($auditAssignmentResources | Where-Object { $_.type -eq 'Microsoft.Authorization/roleAssignments' }).Count -ne 0 -or
        $vaultDiagnosticsAuditAssignment.properties.parameters.definitionVersion.value -ne $backupMajorVersions['REQ-BKP-07'] -or
        (Compare-Object @($vaultDiagnosticsAuditAssignment.properties.parameters.parameters.value.resourceTypeList.value) `
            @('microsoft.recoveryservices/vaults') -SyncWindow 0)) {
        Stop-Test 'An audit-only or disabled vault diagnostics assignment must have no identity and grant no role.'
    }
    $workspaceIdFunction = [string]$compiledJson.functions[0].members.isLogAnalyticsWorkspaceId.output.value
    foreach ($requiredWorkspaceIdCheck in @(
        "'subscriptions'", "'resourcegroups'", "'providers'",
        "'microsoft.operationalinsights'", "'workspaces'", 'trim(', 'isGuid', 'isResourceNameSegment'
    )) {
        if (-not $workspaceIdFunction.Contains($requiredWorkspaceIdCheck)) {
            Stop-Test "The workspace resource-ID guard must enforce $requiredWorkspaceIdCheck."
        }
    }
    $workspaceRbacDeployment = Find-JsonObjects -Node $compiledJson -Predicate {
        param($node)
        $node.PSObject.Properties['name'] -and $node.name -eq 'vault-diagnostics-workspace-rbac'
    } | Select-Object -First 1
    $workspaceRoleAssignments = @(
        $workspaceRbacDeployment.properties.template.resources.PSObject.Properties.Value |
        Where-Object { $_.type -eq 'Microsoft.Authorization/roleAssignments' -and $_.properties.principalType -eq 'ServicePrincipal' }
    )
    if (-not $workspaceRbacDeployment -or
        $workspaceRbacDeployment.condition -ne "[variables('vaultDiagnosticsWorkspaceAccessActive')]" -or
        $workspaceRbacDeployment.subscriptionId -ne "[variables('vaultDiagnosticsWorkspaceIdParts')[2]]" -or
        $workspaceRbacDeployment.resourceGroup -ne "[variables('vaultDiagnosticsWorkspaceIdParts')[4]]" -or
        (Compare-Object @($workspaceRbacDeployment.properties.parameters.roleDefinitionIds.value) `
            @("[variables('logAnalyticsContributorRoleDefinitionId')]") -SyncWindow 0) -or
        $workspaceRoleAssignments.Count -ne 1) {
        Stop-Test 'The gated workspace role assignment must stay opt-in and grant only the verified diagnostics role at the workspace scope.'
    }
    $customerOwnedVault = Find-JsonObjects -Node $compiledJson -Predicate {
        param($node)
        $node.PSObject.Properties['name'] -and $node.name -eq 'customer-owned-backup-vault'
    } | Select-Object -First 1
    if (-not $customerOwnedVault -or $customerOwnedVault.condition -ne "[variables('customerOwnedVaultActive')]") {
        Stop-Test 'The optional customer-owned vault deployment must stay behind an explicit switch.'
    }
    $backupGuardExpectations = @{
        validatedApprovedBackupVaults        = @('fail(', 'allowCrossSubscriptionBackupVaults', 'approvedBackupVaultKeys', 'approvedBackupVaultTargetKeys')
        validatedVmBackupRemediation         = @('fail(')
        validatedVaultDiagnostics            = @('fail(')
        validatedRecoveryServicesVaultCreation = @('fail(', 'backupRetentionStandardId', 'approvedVaultRegions')
        vmBackupRemediationInputsValid       = @('vmBackupInclusionTagName', 'backupRetentionStandardId')
        crossSubscriptionApprovedBackupVaults = @('backupEligibleSubscriptionIds')
    }
    foreach ($backupGuardVariable in $backupGuardExpectations.Keys) {
        foreach ($expectedFragment in $backupGuardExpectations[$backupGuardVariable]) {
            if (-not ([string]$compiledJson.variables.$backupGuardVariable).Contains($expectedFragment)) {
                Stop-Test "$backupGuardVariable must validate $expectedFragment before backup governance is enabled."
            }
        }
    }
    $backupRemediationResources = Find-JsonObjects -Node $compiledJson -Predicate {
        param($node)
        $node.PSObject.Properties['type'] -and $node.type -eq 'Microsoft.PolicyInsights/remediations'
    }
    if (@($backupRemediationResources).Count -ne 0 -or
        $compiledJson.outputs.backupRemediation.value.remediationTasksStarted -ne $false -or
        $compiledJson.outputs.backupRemediation.value.vmBackupEnforcementMode -ne "[parameters('denyPolicyEnforcementMode')]" -or
        ([string]$compiledJson.outputs.backupRemediation.value.vmBackupAutomaticProtectionOnResourceWrite) -notmatch 'DeployIfNotExists' -or
        ([string]$compiledJson.outputs.backupRemediation.value.vmBackupAutomaticProtectionOnResourceWrite) -notmatch 'Default' -or
        $compiledJson.outputs.backupRemediation.value.vaultDiagnosticsEnforcementMode -ne "[parameters('denyPolicyEnforcementMode')]" -or
        ([string]$compiledJson.outputs.backupRemediation.value.vaultDiagnosticsAutomaticSettingsOnResourceWrite) -notmatch 'vaultDiagnosticsRemediationActive' -or
        ([string]$compiledJson.outputs.backupRemediation.value.vaultDiagnosticsAutomaticSettingsOnResourceWrite) -notmatch 'Default' -or
        ([string]$compiledJson.outputs.backupRemediation.value.vaultDiagnosticsPrincipalId) -notmatch 'identityPrincipalId' -or
        ([string]$compiledJson.outputs.backupRemediation.value.vaultDiagnosticsWorkspaceAccessGranted) -notmatch 'vaultDiagnosticsWorkspaceAccessActive' -or
        ([string]$compiledJson.outputs.backupRemediation.value.vaultDiagnosticsWorkspaceRoleAssignmentIds) -notmatch 'roleAssignmentIds' -or
        ([string]$compiledJson.outputs.backupRemediation.value.vaultDiagnosticsIdentityAttached) -notmatch 'vaultDiagnosticsRemediationActive' -or
        ([string]$compiledJson.outputs.backupRemediation.value.vaultDiagnosticsRoleDefinitionIds) -notmatch 'vaultDiagnosticsRemediationActive') {
        Stop-Test 'Backup governance must never start remediation tasks and must report automatic DeployIfNotExists protection and diagnostics cost impact.'
    }
    foreach ($backupValidationMessage in @(
        'enableVmBackupRemediation requires approvedBackupVaults entries with valid vault and backup policy IDs',
        'deployRecoveryServicesVault must stay false when approvedBackupVaults records are supplied',
        'enableVaultDiagnostics requires deployCentralLogAnalytics to be true',
        'recoveryServicesVaultLocation must be one of approvedVaultRegions',
        'deployRecoveryServicesVault requires a documented backupRetentionStandardId',
        'Set allowCrossSubscriptionBackupVaults to true to approve that central backup subscription',
        'must use case-insensitively unique workload and region pairs',
        'must not share an inclusion tag value',
        'must map to exactly one region',
        'grantVaultDiagnosticsWorkspaceAccess requires enableVaultDiagnostics to be true',
        'grantVaultDiagnosticsWorkspaceAccess requires a canonical absolute effective Log Analytics workspace resource ID',
        'grantVaultDiagnosticsWorkspaceAccess requires vaultDiagnosticsEffect to be DeployIfNotExists')) {
        if (-not $mainBicepText.Contains($backupValidationMessage)) {
            Stop-Test "Backup input validation is missing: $backupValidationMessage"
        }
    }
    $controlCatalogText = Get-Content -LiteralPath (Join-Path $ProjectDir 'policy/control-catalog.json') -Raw
    if ($controlCatalogText.Contains('no dedicated Azure Policy built-in')) {
        Stop-Test 'The catalog still claims that vault soft delete has no dedicated Azure Policy built-in.'
    }
    $backupGuardFixture = Get-Content -LiteralPath (Join-Path $ScriptDir 'fixtures/backup-vault-placement-cases.json') -Raw | ConvertFrom-Json
    $compiledCopyExpressions = @{}
    foreach ($copyVariable in @($compiledJson.variables.copy)) {
        $compiledCopyExpressions[$copyVariable.name] = $copyVariable.input
    }
    foreach ($guardExpression in $backupGuardFixture.compiledGuardExpressions.PSObject.Properties) {
        if ($compiledJson.variables.($guardExpression.Name) -ne $guardExpression.Value) {
            Stop-Test "Compiled guard variable $($guardExpression.Name) no longer matches the bound fixture expression."
        }
    }
    foreach ($guardCopyExpression in $backupGuardFixture.compiledGuardCopyExpressions.PSObject.Properties) {
        if ($compiledCopyExpressions[$guardCopyExpression.Name] -ne $guardCopyExpression.Value) {
            Stop-Test "Compiled guard copy variable $($guardCopyExpression.Name) no longer matches the bound fixture expression."
        }
    }
    foreach ($guardFunction in $backupGuardFixture.compiledGuardFunctions.PSObject.Properties) {
        if ($compiledJson.functions[0].members.($guardFunction.Name).output.value -ne $guardFunction.Value) {
            Stop-Test "Compiled guard function $($guardFunction.Name) no longer matches the bound fixture expression."
        }
    }
    $backupGuardCases = @($backupGuardFixture.guardCases)
    if ($backupGuardCases.Count -lt 32 -or
        @($backupGuardCases | Where-Object {
            $_.guardVariable -eq 'validatedVaultDiagnosticsWorkspaceAccess'
        }).Count -lt 13 -or
        @($backupGuardCases | ForEach-Object { $_.guardVariable } | Microsoft.PowerShell.Utility\Sort-Object -Unique).Count -lt 4) {
        Stop-Test 'The backup guard fixture must keep covering every dependency guard with negative cases.'
    }
    foreach ($backupGuardCase in $backupGuardCases) {
        $boundGuard = [string]$backupGuardFixture.compiledGuardExpressions.($backupGuardCase.guardVariable)
        if ([string]::IsNullOrEmpty($boundGuard) -or -not $boundGuard.Contains([string]$backupGuardCase.rejectionMessage)) {
            Stop-Test "Backup guard case is no longer bound to a compiled rejection: $($backupGuardCase.name)"
        }
        foreach ($requiredExpression in @($backupGuardCase.requiredExpressions)) {
            if (-not $boundGuard.Contains([string]$requiredExpression)) {
                Stop-Test "Backup guard case lost its compiled sub-expression $requiredExpression : $($backupGuardCase.name)"
            }
        }
    }
    foreach ($acceptedCase in @($backupGuardFixture.acceptedCases)) {
        $acceptedVaultIds = @($acceptedCase.entries | ForEach-Object { $_.vaultResourceId.ToLowerInvariant() })
        $acceptedVaultRegionPairs = @($acceptedCase.entries | ForEach-Object {
            "$($_.vaultResourceId.ToLowerInvariant())|$($_.region.ToLowerInvariant())"
        })
        if (@($acceptedVaultIds | Microsoft.PowerShell.Utility\Sort-Object -Unique).Count -ne
            @($acceptedVaultRegionPairs | Microsoft.PowerShell.Utility\Sort-Object -Unique).Count) {
            Stop-Test "Accepted backup case reuses one single-region vault across regions: $($acceptedCase.name)"
        }
    }
    $backupVaultTemplate = Join-Path $TempDir 'backup-vault.json'
    & az bicep build --file (Join-Path $ProjectDir 'modules/backup-vault.bicep') --outfile $backupVaultTemplate
    if ($LASTEXITCODE -ne 0) { Stop-Test 'The optional backup vault module failed to compile.' }
    $backupVaultJson = Get-Content -LiteralPath $backupVaultTemplate -Raw | ConvertFrom-Json
    if ($backupVaultJson.parameters.deployRecoveryServicesVault.defaultValue -ne $false -or
        $backupVaultJson.parameters.publicNetworkAccess.defaultValue -ne 'Disabled' -or
        $backupVaultJson.parameters.storageRedundancy.defaultValue -ne 'LocallyRedundant' -or
        $backupVaultJson.parameters.immutabilityState.defaultValue -ne 'Unlocked' -or
        $backupVaultJson.parameters.dailyRetentionInDays.minValue -ne 7 -or
        ([string]$backupVaultJson.variables.vaultTags) -notmatch 'Metered' -or
        ([string]$backupVaultJson.variables.vaultTags) -notmatch 'Customer-owned') {
        Stop-Test 'The optional customer-owned vault module must stay opt-in, private, and tagged as metered.'
    }
    $vaultDeclarations = Find-JsonObjects -Node $backupVaultJson -Predicate {
        param($node)
        $node.PSObject.Properties['type'] -and $node.type -eq 'Microsoft.RecoveryServices/vaults'
    }
    $protectedItemDeclarations = Find-JsonObjects -Node $backupVaultJson -Predicate {
        param($node)
        $node.PSObject.Properties['type'] -and
        $node.type -eq 'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/protectedItems'
    }
    if (@($vaultDeclarations).Count -ne 1 -or @($protectedItemDeclarations).Count -ne 0) {
        Stop-Test 'The optional vault module must declare exactly one vault and never protect live items.'
    }
    $backupParametersPath = Join-Path $TempDir 'backup-existing-vault.bicepparam'
    $approvedVaultPrefix = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-backup/providers/Microsoft.RecoveryServices/vaults'
    $approvedVaultEastUs2 = "$approvedVaultPrefix/rsv-workload-eastus2"
    $approvedVaultCentralUs = "$approvedVaultPrefix/rsv-workload-centralus"
    $approvedBackupVaultLiteral = "param approvedBackupVaults = [{workload: 'corp', region: 'eastus2', vaultResourceId: '$approvedVaultEastUs2', backupPolicyResourceId: '$approvedVaultEastUs2/backupPolicies/vm-daily', inclusionTagValues: ['corp-daily']}, {workload: 'corp', region: 'centralus', vaultResourceId: '$approvedVaultCentralUs', backupPolicyResourceId: '$approvedVaultCentralUs/backupPolicies/vm-daily', inclusionTagValues: ['corp-daily']}]"
    $backupParametersText = $benchmarkParameterTemplateText `
        -replace "(?m)^using '\.\./main\.bicep'$", "using '../../main.bicep'" `
        -replace '(?m)^param approvedVaultRegions = .*$', "param approvedVaultRegions = ['eastus2', 'centralus']" `
        -replace '(?m)^param backupRetentionStandardId = .*$', "param backupRetentionStandardId = 'RETENTION-STD-001'" `
        -replace '(?m)^param vmBackupInclusionTagName = .*$', "param vmBackupInclusionTagName = 'BackupPolicy'" `
        -replace '(?m)^param enableVmBackupRemediation = .*$', 'param enableVmBackupRemediation = true' `
        -replace '(?m)^param approvedBackupVaults = .*$', $approvedBackupVaultLiteral
    Set-Content -LiteralPath $backupParametersPath -Value $backupParametersText
    & az bicep build-params --file $backupParametersPath --outfile "$backupParametersPath.json"
    if ($LASTEXITCODE -ne 0) { Stop-Test 'The approved existing-vault integration path failed to compile.' }
    $backupParametersJson = Get-Content -LiteralPath "$backupParametersPath.json" -Raw | ConvertFrom-Json
    $compiledApprovedVaults = @($backupParametersJson.parameters.approvedBackupVaults.value)
    if ($backupParametersJson.parameters.enableVmBackupRemediation.value -ne $true -or
        $backupParametersJson.parameters.deployRecoveryServicesVault.value -ne $false -or
        $backupParametersJson.parameters.allowCrossSubscriptionBackupVaults.value -ne $false -or
        $backupParametersJson.parameters.grantVaultDiagnosticsWorkspaceAccess.value -ne $false -or
        $compiledApprovedVaults.Count -ne 2 -or
        (Compare-Object @($compiledApprovedVaults | ForEach-Object { $_.region } | Microsoft.PowerShell.Utility\Sort-Object) `
            @('centralus', 'eastus2') -SyncWindow 0) -or
        @($compiledApprovedVaults | ForEach-Object { $_.vaultResourceId } |
            Microsoft.PowerShell.Utility\Sort-Object -Unique).Count -ne 2 -or
        @($compiledApprovedVaults | Where-Object {
            -not ([string]$_.backupPolicyResourceId).StartsWith("$($_.vaultResourceId)/backupPolicies/")
        }).Count -ne 0) {
        Stop-Test 'The approved existing-vault integration path did not compile to the expected parameter values.'
    }
    Write-Host '29/30 Confirm preflight rejects unsafe v2 dependency combinations before Azure access...'
    $preflightParameterFile = Join-Path $TempDir 'preflight-unsafe.parameters.json'
    $preflightParameters = Get-Content -LiteralPath (Join-Path $ProjectDir 'parameters/demo.parameters.template.json') -Raw | ConvertFrom-Json
    $preflightParameters.parameters.tenantRootManagementGroupId.value = 'demo-root'
    $preflightParameters.parameters.connectivitySubscriptionId.value = '11111111-1111-4111-8111-111111111111'
    $preflightParameters.parameters.workloadSubscriptionId.value = '22222222-2222-4222-8222-222222222222'
    $preflightParameters.parameters.governanceAdminsGroupObjectId.value = '33333333-3333-4333-8333-333333333333'
    $preflightParameters.parameters.networkOperatorsGroupObjectId.value = '44444444-4444-4444-8444-444444444444'
    $preflightParameters.parameters.workloadContributorsGroupObjectId.value = '55555555-5555-4555-8555-555555555555'
    $preflightParameters.parameters.readOnlyAuditorsGroupObjectId.value = '66666666-6666-4666-8666-666666666666'
    $preflightParameters.parameters.enableCriticalInfrastructure.value = $true
    $preflightParameters.parameters.criticalInfrastructureSubscriptionIds.value = @()
    $preflightParameters | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $preflightParameterFile -Encoding utf8
    foreach ($preflightScript in @(
            (Join-Path $ProjectDir 'scripts/preflight.sh'),
            (Join-Path $ProjectDir 'scripts/preflight.ps1'))) {
        $preflightOutput = if ($preflightScript -like '*.sh') {
            & bash $preflightScript $preflightParameterFile 2>&1
        }
        else {
            & $preflightScript -ParameterFile $preflightParameterFile 2>&1
        }
        if ($LASTEXITCODE -eq 0) {
            Stop-Test "Preflight accepted critical infrastructure without a supplied subscription: $preflightScript"
        }
        if ((ConvertTo-TestMessage $preflightOutput) -notmatch 'enableCriticalInfrastructure requires one or more') {
            Stop-Test "Preflight did not report the critical-infrastructure prerequisite: $preflightScript"
        }
    }

    Write-Host '30/30 Confirm the privileged access review is read-only, criteria-driven, and offline-testable...'
    $accessReviewScript = Join-Path $ProjectDir 'scripts/review-privileged-access.ps1'
    $accessReviewCriteria = Join-Path $ProjectDir 'policy/access-review-criteria.json'
    $accessReviewAssignments = Join-Path $ProjectDir 'tests/fixtures/privileged-access-assignments.json'
    $accessReviewExpectedFile = Join-Path $ProjectDir 'tests/fixtures/privileged-access-expected-report.json'
    $accessReviewObservations = Join-Path $ProjectDir 'tests/fixtures/privileged-access-observations.json'
    $accessReviewObservationsExpectedFile = Join-Path $ProjectDir 'tests/fixtures/privileged-access-expected-observations-report.json'
    $accessReviewTenant = '44444444-4444-4444-8444-444444444444'
    $accessReviewSubscription = '22222222-2222-4222-8222-222222222222'
    $accessReviewSecondSubscription = '66666666-6666-4666-8666-666666666666'
    foreach ($accessReviewFile in @($accessReviewScript, $accessReviewCriteria, $accessReviewAssignments,
            $accessReviewExpectedFile, $accessReviewObservations, $accessReviewObservationsExpectedFile)) {
        if (-not (Test-Path -LiteralPath $accessReviewFile -PathType Leaf)) {
            Stop-Test "Missing privileged access review artifact: $accessReviewFile"
        }
    }
    $accessReviewScriptText = Get-Content -LiteralPath $accessReviewScript -Raw
    if ($accessReviewScriptText -match 'az (role assignment (create|delete|update)|ad (app|sp|group) (create|delete|update)|deployment|rest --method)') {
        Stop-Test 'The privileged access review script must stay read-only.'
    }

    $accessReviewOut = Join-Path $TempDir 'access-review'
    & pwsh -NoLogo -NoProfile -NonInteractive -File $accessReviewScript `
        -TenantId $accessReviewTenant `
        -SubscriptionId $accessReviewSubscription `
        -ManagementGroupId 'demo-root' `
        -AssignmentsFile $accessReviewAssignments `
        -OutputDirectory $accessReviewOut | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Stop-Test 'The privileged access review failed against the offline fixture.'
    }
    $accessReviewReportFile = @(Get-ChildItem -LiteralPath $accessReviewOut -Filter 'privileged-access-review-*.json')
    if ($accessReviewReportFile.Count -ne 1) {
        Stop-Test 'The privileged access review must write exactly one JSON report per run.'
    }
    $accessReviewMarkdown = [System.IO.Path]::ChangeExtension($accessReviewReportFile[0].FullName, '.md')
    if (-not (Test-Path -LiteralPath $accessReviewMarkdown -PathType Leaf)) {
        Stop-Test 'The privileged access review produced no Markdown report.'
    }
    $accessReviewReportText = Get-Content -LiteralPath $accessReviewReportFile[0].FullName -Raw
    $accessReviewReport = $accessReviewReportText | ConvertFrom-Json -Depth 20
    $accessReviewExpected = Get-Content -LiteralPath $accessReviewExpectedFile -Raw | ConvertFrom-Json -Depth 20
    # ConvertFrom-Json coerces ISO-8601 strings to [datetime], so assert the
    # stored UTC timestamp against the raw report text instead.
    if ($accessReviewReportText -notmatch '"generatedOn": "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"') {
        Stop-Test 'The privileged access review report must record a UTC generation timestamp.'
    }
    $accessReviewReport.PSObject.Properties.Remove('generatedOn')
    $accessReviewActualJson = $accessReviewReport | ConvertTo-Json -Depth 20 -Compress
    $accessReviewExpectedJson = $accessReviewExpected | ConvertTo-Json -Depth 20 -Compress
    if ($accessReviewActualJson -cne $accessReviewExpectedJson) {
        Stop-Test "The privileged access review classification changed unexpectedly: $accessReviewActualJson"
    }
    if ($accessReviewReport.mode -ne 'offline-file' -or $accessReviewReport.findings.Count -lt 1) {
        Stop-Test 'The offline privileged access review produced no findings.'
    }
    foreach ($accessReviewFinding in $accessReviewReport.findings) {
        if ($accessReviewFinding.reviewAction -ne 'manual-review-required') {
            Stop-Test 'Every privileged access finding must require a manual review decision.'
        }
        if ($accessReviewFinding.principalType -eq 'ServicePrincipal' -and $accessReviewFinding.roleDefinitionName -eq 'Owner' -and
            ($accessReviewFinding.severity -ne 'high' -or $accessReviewFinding.reasons -notcontains 'direct-non-human-principal-assignment')) {
            Stop-Test 'A direct service-principal Owner grant must be surfaced as a high-severity finding.'
        }
    }

    # Every direct service-principal or managed-identity grant must appear in
    # the inventory, including narrow, lower-privilege ones ranked low.
    $accessReviewNonHuman = @($accessReviewReport.findings |
        Where-Object { $_.principalType -in @('ServicePrincipal', 'MSI') })
    if ($accessReviewNonHuman.Count -ne $accessReviewReport.summary.nonHumanAssignmentCount) {
        Stop-Test 'Every direct service-principal and managed-identity grant must be surfaced as a finding.'
    }
    $accessReviewNarrowGrant = @($accessReviewReport.findings |
        Where-Object { $_.principalId -eq '88888888-8888-4888-8888-888888888888' -and
            $_.roleDefinitionName -eq 'Storage Blob Data Reader' })
    if ($accessReviewNarrowGrant.Count -ne 1 -or $accessReviewNarrowGrant[0].severity -ne 'low' -or
        $accessReviewNarrowGrant[0].scopeType -ne 'resource' -or
        $accessReviewNarrowGrant[0].reasons -notcontains 'direct-non-human-principal-assignment') {
        Stop-Test 'A narrow service-principal grant must be surfaced as a low-severity finding, not dropped.'
    }

    # Subscription queries use inherited results, so one management-group
    # assignment is observed repeatedly; it must collapse to a single finding
    # while the observing subscriptions stay attributed.
    $accessReviewObservationsOut = Join-Path $TempDir 'access-review-observations'
    & pwsh -NoLogo -NoProfile -NonInteractive -File $accessReviewScript `
        -TenantId $accessReviewTenant `
        -SubscriptionId "$accessReviewSubscription,$accessReviewSecondSubscription" `
        -ManagementGroupId 'demo-root' `
        -AssignmentsFile $accessReviewObservations `
        -OutputDirectory $accessReviewObservationsOut | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Stop-Test 'The privileged access review failed against the inheritance fixture.'
    }
    $accessReviewObservationsReport = Get-Content -LiteralPath (
        @(Get-ChildItem -LiteralPath $accessReviewObservationsOut -Filter 'privileged-access-review-*.json')[0].FullName) -Raw |
        ConvertFrom-Json -Depth 20
    $accessReviewObservationsExpected = Get-Content -LiteralPath $accessReviewObservationsExpectedFile -Raw |
        ConvertFrom-Json -Depth 20
    $accessReviewObservationsReport.PSObject.Properties.Remove('generatedOn')
    if (($accessReviewObservationsReport | ConvertTo-Json -Depth 20 -Compress) -cne
        ($accessReviewObservationsExpected | ConvertTo-Json -Depth 20 -Compress)) {
        Stop-Test 'The deduplicated inheritance classification changed unexpectedly.'
    }
    if ($accessReviewObservationsReport.summary.assignmentsCollected -ne 10 -or
        $accessReviewObservationsReport.summary.assignmentsEvaluated -ne 5 -or
        $accessReviewObservationsReport.summary.duplicateObservationsCollapsed -ne 5) {
        Stop-Test 'Repeated inherited observations were not deduplicated by assignment identity.'
    }
    foreach ($accessReviewInherited in @($accessReviewObservationsReport.findings |
            Where-Object { $_.scopeType -eq 'managementGroup' })) {
        if (@($accessReviewInherited.observedInSubscriptions) -join ',' -ne
            "$accessReviewSubscription,$accessReviewSecondSubscription") {
            Stop-Test 'An inherited finding must record every requested subscription that observed it.'
        }
    }
    $accessReviewOwnerCounts = @($accessReviewObservationsReport.summary.subscriptionOwnerCounts)
    if ($accessReviewOwnerCounts.Count -ne 2 -or
        $accessReviewOwnerCounts[0].subscriptionId -ne $accessReviewSubscription -or
        $accessReviewOwnerCounts[0].ownerPrincipalCount -ne 3 -or
        $accessReviewOwnerCounts[0].directOwnerPrincipalCount -ne 1 -or
        $accessReviewOwnerCounts[0].inheritedOwnerPrincipalCount -ne 2 -or
        $accessReviewOwnerCounts[1].subscriptionId -ne $accessReviewSecondSubscription -or
        $accessReviewOwnerCounts[1].ownerPrincipalCount -ne 2 -or
        $accessReviewOwnerCounts[1].directOwnerPrincipalCount -ne 0 -or
        $accessReviewOwnerCounts[1].inheritedOwnerPrincipalCount -ne 2) {
        Stop-Test 'Inherited Owner grants were not attributed to the requested subscriptions that observed them.'
    }
    # An Owner scoped to a resource group does not confer Owner over the
    # subscription, so it stays a finding but never inflates the Owner totals.
    $accessReviewChildOwners = @($accessReviewObservationsReport.findings |
        Where-Object { $_.roleDefinitionName -eq 'Owner' -and $_.scopeType -eq 'resourceGroup' })
    if ($accessReviewChildOwners.Count -ne 1 -or
        (@($accessReviewChildOwners[0].observedInSubscriptions) -join ',') -ne $accessReviewSubscription) {
        Stop-Test 'A resource-group-scoped Owner grant must remain a finding in the inventory.'
    }
    $accessReviewObservedOwners = @($accessReviewObservationsReport.findings |
        Where-Object { $_.roleDefinitionName -eq 'Owner' -and
            ($_.observedInSubscriptions -contains $accessReviewSubscription) } |
        ForEach-Object { $_.principalId } | Sort-Object -Unique)
    if ($accessReviewObservedOwners.Count -ne 4 -or $accessReviewOwnerCounts[0].ownerPrincipalCount -ne 3) {
        Stop-Test 'A child-scoped Owner grant must not count towards the subscription Owner total.'
    }
    foreach ($accessReviewOwnerCount in $accessReviewOwnerCounts) {
        if ($accessReviewOwnerCount.ownerPrincipalCount -ne
            ($accessReviewOwnerCount.directOwnerPrincipalCount + $accessReviewOwnerCount.inheritedOwnerPrincipalCount)) {
            Stop-Test 'Subscription Owner totals must be the sum of their direct and inherited parts.'
        }
    }

    $accessReviewStrictCriteria = Join-Path $TempDir 'access-review-strict-criteria.json'
    $accessReviewCriteriaDocument = Get-Content -LiteralPath $accessReviewCriteria -Raw | ConvertFrom-Json -Depth 20
    $accessReviewCriteriaDocument.maxOwnersPerSubscription = 1
    $accessReviewCriteriaDocument | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $accessReviewStrictCriteria -Encoding utf8NoBOM
    $accessReviewStrictOut = Join-Path $TempDir 'access-review-strict'
    & pwsh -NoLogo -NoProfile -NonInteractive -File $accessReviewScript `
        -TenantId $accessReviewTenant `
        -SubscriptionId $accessReviewSubscription `
        -CriteriaFile $accessReviewStrictCriteria `
        -AssignmentsFile $accessReviewAssignments `
        -OutputDirectory $accessReviewStrictOut | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Stop-Test 'The privileged access review failed with a stricter Owner threshold.'
    }
    $accessReviewStrictReport = Get-Content -LiteralPath (
        @(Get-ChildItem -LiteralPath $accessReviewStrictOut -Filter 'privileged-access-review-*.json')[0].FullName) -Raw |
        ConvertFrom-Json -Depth 20
    if ((Compare-Object `
            -ReferenceObject @($accessReviewStrictReport.summary.subscriptionsExceedingOwnerThreshold) `
            -DifferenceObject @($accessReviewSubscription)) -or
        $accessReviewStrictReport.criteria.maxOwnersPerSubscription -ne 1 -or
        $accessReviewStrictReport.summary.subscriptionOwnerCounts[0].ownerPrincipalCount -ne 2 -or
        -not $accessReviewStrictReport.summary.subscriptionOwnerCounts[0].exceedsThreshold) {
        Stop-Test 'The configurable Owner-count threshold was not honoured.'
    }

    $accessReviewNegativeOut = Join-Path $TempDir 'access-review-negative'
    $accessReviewBadAssignments = Join-Path $TempDir 'access-review-bad-assignments.json'
    $accessReviewAssignmentsDocument = @(Get-Content -LiteralPath $accessReviewAssignments -Raw | ConvertFrom-Json -Depth 20)
    $accessReviewAssignmentsDocument[0].PSObject.Properties.Remove('principalType')
    $accessReviewAssignmentsDocument | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $accessReviewBadAssignments -Encoding utf8NoBOM
    $accessReviewBadObservations = Join-Path $TempDir 'access-review-bad-observations.json'
    $accessReviewObservationsDocument = Get-Content -LiteralPath $accessReviewObservations -Raw | ConvertFrom-Json -Depth 20
    $accessReviewObservationsDocument.observations[0].source.kind = 'resourceGroup'
    $accessReviewObservationsDocument | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $accessReviewBadObservations -Encoding utf8NoBOM
    $accessReviewBadCriteria = Join-Path $TempDir 'access-review-bad-criteria.json'
    $accessReviewCriteriaDocument = Get-Content -LiteralPath $accessReviewCriteria -Raw | ConvertFrom-Json -Depth 20
    $accessReviewCriteriaDocument.highPrivilegeRoleNames = @()
    $accessReviewCriteriaDocument | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $accessReviewBadCriteria -Encoding utf8NoBOM
    $accessReviewNegativeCases = @(
        @{ Description = 'a missing tenant context'; Arguments = @(
            '-SubscriptionId', $accessReviewSubscription,
            '-AssignmentsFile', $accessReviewAssignments) },
        @{ Description = 'a non-canonical subscription GUID'; Arguments = @(
            '-TenantId', $accessReviewTenant,
            '-SubscriptionId', 'not-a-guid',
            '-AssignmentsFile', $accessReviewAssignments) },
        @{ Description = 'a duplicate subscription'; Arguments = @(
            '-TenantId', $accessReviewTenant,
            '-SubscriptionId', "$accessReviewSubscription,$accessReviewSubscription",
            '-AssignmentsFile', $accessReviewAssignments) },
        @{ Description = 'an assignment without a principal type'; Arguments = @(
            '-TenantId', $accessReviewTenant,
            '-SubscriptionId', $accessReviewSubscription,
            '-AssignmentsFile', $accessReviewBadAssignments) },
        @{ Description = 'an observation with an unsupported source kind'; Arguments = @(
            '-TenantId', $accessReviewTenant,
            '-SubscriptionId', $accessReviewSubscription,
            '-AssignmentsFile', $accessReviewBadObservations) },
        @{ Description = 'an empty high-privilege role list'; Arguments = @(
            '-TenantId', $accessReviewTenant,
            '-SubscriptionId', $accessReviewSubscription,
            '-CriteriaFile', $accessReviewBadCriteria,
            '-AssignmentsFile', $accessReviewAssignments) }
    )
    foreach ($accessReviewCase in $accessReviewNegativeCases) {
        $accessReviewArguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $accessReviewScript) +
            $accessReviewCase.Arguments + @('-OutputDirectory', $accessReviewNegativeOut)
        & pwsh @accessReviewArguments 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Stop-Test "The privileged access review accepted $($accessReviewCase.Description)."
        }
    }

    $nercMatrixPath = Join-Path $ProjectDir 'docs/NERC-CIP-MATRIX.md'
    if (-not (Test-Path -LiteralPath $nercMatrixPath -PathType Leaf)) {
        Stop-Test 'Missing NERC CIP responsibility and evidence matrix.'
    }
    $nercMatrixText = Get-Content -LiteralPath $nercMatrixPath -Raw
    foreach ($requiredSnippet in @(
            'registered entity remains responsible',
            'Required customer applicability decision',
            'Audit-readiness checklist',
            '| NERC CIP requirement/family | v2 technical control mapping | Responsibility | Policy/service evidence | Evidence location | Evidence owner | Collection method | Review cadence | Known manual gap |',
            'REQ-DEPLOY-01/02/04',
            'REQ-TAG-05/06',
            'REQ-NET-04/05',
            'REQ-DATA-01..07',
            'REQ-LOG-01 Activity Log export control (composed in REQ-CIP-01 overlay)',
            'REQ-DEF-07/08',
            'REQ-BKP-01..09',
            'REQ-ID-01/02 MFA baselines',
            'REQ-ID-04 PIM-ready time-bound privileged access',
            'REQ-ID-05 privileged-access inventory and Owner-count review',
            'REQ-ID-06 CIEM findings',
            'optional Defender plan signals from REQ-DEF-02/03/04',
            'Microsoft Sentinel onboarding/analytics/incident workflow evidence',
            'service-principal/access-review governance dependency issue: https://github.com/johnstel/azureeslzmultisubdemo/issues/21',
            'learn.microsoft.com/en-us/azure/compliance/offerings/offering-nerc',
            'learn.microsoft.com/en-us/azure/compliance/offerings/offering-nerc#shared-responsibility-in-the-cloud',
            'nerc.com/standards/reliability-standards/cip',
            'issues/22')) {
        if ($nercMatrixText -notmatch [regex]::Escape($requiredSnippet)) {
            Stop-Test "The NERC CIP matrix is missing required content: $requiredSnippet"
        }
    }
    foreach ($staleSnippet in @(
            'technical control-matrix dependency issue: https://github.com/johnstel/azureeslzmultisubdemo/issues/21',
            'REQ-DEF-04 Sentinel onboarding controls')) {
        if ($nercMatrixText -match [regex]::Escape($staleSnippet)) {
            Stop-Test "The NERC CIP matrix still contains stale text: $staleSnippet"
        }
    }

    $controlMatrixText = Get-Content -LiteralPath (Join-Path $ProjectDir 'docs/CONTROL-MATRIX.md') -Raw
    if ($controlMatrixText -notmatch [regex]::Escape('REQ-CIP-01 | Compose an opt-in, stricter technical control overlay for subscriptions under the Critical Infrastructure management-group branch. | critical-infrastructure | shared-service-architecture | Demo - NERC CIP technical overlay (critical only) (built-in: No) | `—` | — | Audit, Deny, DeployIfNotExists, Disabled | manual-evidence |')) {
        Stop-Test 'The CONTROL-MATRIX REQ-CIP-01 row must reflect the implemented critical-only overlay.'
    }
    if ($controlMatrixText -match [regex]::Escape('REQ-CIP-01 | Compose an opt-in, stricter technical control overlay for subscriptions under the Critical Infrastructure management-group branch. | critical-infrastructure | shared-service-architecture | Demo - NERC CIP technical overlay (to be composed from existing verified controls)')) {
        Stop-Test 'The CONTROL-MATRIX still contains stale REQ-CIP-01 future-state text.'
    }

    $controlCatalog = Get-Content -LiteralPath (Join-Path $ProjectDir 'policy/control-catalog.json') -Raw | ConvertFrom-Json -Depth 40
    $cipOverlay = @($controlCatalog.controls | Where-Object { $_.id -eq 'REQ-CIP-01' })
    if ($cipOverlay.Count -ne 1) {
        Stop-Test 'Expected exactly one REQ-CIP-01 record in policy/control-catalog.json.'
    }
    $cipOverlayRoles = @($cipOverlay[0].roleDefinitionIds | Sort-Object)
    $cipOverlayExpectedDependencies = @(
        'REQ-BKP-01',
        'REQ-BKP-04',
        'REQ-BKP-05',
        'REQ-BKP-06',
        'REQ-BKP-08',
        'REQ-BKP-09',
        'REQ-DATA-01',
        'REQ-DATA-02',
        'REQ-DATA-03',
        'REQ-DATA-04',
        'REQ-DATA-05',
        'REQ-DATA-06',
        'REQ-DATA-07',
        'REQ-DATA-08',
        'REQ-DATA-10',
        'REQ-DATA-11',
        'REQ-DATA-12',
        'REQ-DATA-13',
        'REQ-DEF-06',
        'REQ-DEF-07',
        'REQ-DEF-08',
        'REQ-DEPLOY-01',
        'REQ-LOG-01',
        'REQ-NET-01',
        'REQ-NET-02',
        'REQ-NET-04',
        'REQ-NET-05',
        'REQ-NET-06',
        'REQ-TAG-05',
        'REQ-TAG-06'
    ) | Sort-Object
    if ($cipOverlay[0].mechanism.displayName -ne 'Demo - NERC CIP technical overlay (critical only)' -or
        $cipOverlay[0].mechanism.verificationMethod -ne 'in-repository-custom-definition' -or
        $cipOverlay[0].remediationIdentityRequired -ne $true -or
        (Compare-Object $cipOverlayRoles @(
                '749f88d5-cbae-40b8-bcfc-e573ddc772fa',
                '92aaf0da-9dab-42b6-94a3-d43ce8d16293'
            )) -or
        (Compare-Object @($cipOverlay[0].dependencies | Sort-Object) $cipOverlayExpectedDependencies) -or
        ([string]$cipOverlay[0].evidenceSource).Contains('does not itself create any policy resource') -or
        ([string]$cipOverlay[0].notes).Contains('No policyDefinition/policySetDefinition exists yet')) {
        Stop-Test 'REQ-CIP-01 in policy/control-catalog.json must reflect the implemented overlay identity and remediation evidence model.'
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
