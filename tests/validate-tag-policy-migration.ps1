[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir
$TempDir = Join-Path $ProjectDir ".test-artifacts/tag-migration-ps1-$PID"
$MockBin = Join-Path $TempDir 'mockbin'
$CallLog = Join-Path $TempDir 'az-calls.log'
$MigrationScript = Join-Path $ProjectDir 'scripts/migrate-legacy-rg-tags.ps1'

function Stop-Test {
    param([string]$Message)
    throw $Message
}

try {
    New-Item -ItemType Directory -Path $MockBin -Force | Out-Null
    $parameterFile = Join-Path $TempDir 'parameters.json'
    @'
{
  "parameters": {
    "namePrefix": { "value": "eslz-demo" },
    "workloadArchetype": { "value": "corp" }
  }
}
'@ | Set-Content -LiteralPath $parameterFile
    @'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${AZ_CALL_LOG}"
'@ | Set-Content -LiteralPath (Join-Path $MockBin 'az')
    & chmod +x (Join-Path $MockBin 'az')
    $oldPath = $env:PATH
    $oldCallLog = $env:AZ_CALL_LOG
    $oldConfirmation = $env:ESLZ_TAG_MIGRATION_CONFIRMATION
    $env:PATH = "$MockBin$([IO.Path]::PathSeparator)$oldPath"
    $env:AZ_CALL_LOG = $CallLog

    Set-Content -LiteralPath $CallLog -Value '' -NoNewline
    $previewOutput = (& $MigrationScript -ParameterFile $parameterFile 6>&1 | Out-String)
    if ((Get-Item $CallLog).Length -ne 0 -or $previewOutput -notmatch 'Dry run only\.') {
        Stop-Test 'PowerShell migration preview must not invoke Azure CLI.'
    }

    Set-Content -LiteralPath $CallLog -Value '' -NoNewline
    Remove-Item Env:ESLZ_TAG_MIGRATION_CONFIRMATION -ErrorAction SilentlyContinue
    & pwsh -NoLogo -NoProfile -File $MigrationScript -ParameterFile $parameterFile -Execute *> $null
    if ($LASTEXITCODE -eq 0 -or (Get-Item $CallLog).Length -ne 0) {
        Stop-Test 'PowerShell migration must reject execution without approval before invoking Azure CLI.'
    }

    Set-Content -LiteralPath $CallLog -Value '' -NoNewline
    $env:ESLZ_TAG_MIGRATION_CONFIRMATION = 'REMOVE-LEGACY-RG-TAG-POLICY'
    'eslz-demo-online' | & pwsh -NoLogo -NoProfile -File $MigrationScript -ParameterFile $parameterFile -Execute *> $null
    if ($LASTEXITCODE -eq 0 -or (Get-Item $CallLog).Length -ne 0) {
        Stop-Test 'PowerShell migration must reject a mismatched workload scope confirmation before invoking Azure CLI.'
    }

    Set-Content -LiteralPath $CallLog -Value '' -NoNewline
    $env:ESLZ_TAG_MIGRATION_CONFIRMATION = 'REMOVE-LEGACY-RG-TAG-POLICY'
    'eslz-demo-corp' | & pwsh -NoLogo -NoProfile -File $MigrationScript -ParameterFile $parameterFile -Execute *> $null
    if ($LASTEXITCODE -ne 0) {
        Stop-Test 'PowerShell migration failed with valid layered confirmations.'
    }
    $expectedCalls = @(
        'policy assignment delete --name demo-require-rg-tags --scope /providers/Microsoft.Management/managementGroups/eslz-demo-corp'
        'policy definition delete --name eslz-demo-require-workload-rg-tags --management-group eslz-demo'
    )
    $actualCalls = @(Get-Content -LiteralPath $CallLog)
    if (Compare-Object -ReferenceObject $expectedCalls -DifferenceObject $actualCalls -CaseSensitive) {
        Stop-Test 'PowerShell migration invoked commands outside the two exact legacy artifacts.'
    }

    $invalidParameterFile = Join-Path $TempDir 'invalid.parameters.json'
    $invalidParameters = Get-Content -LiteralPath $parameterFile -Raw | ConvertFrom-Json
    $invalidParameters.parameters.workloadArchetype.value = 'corp-unrelated'
    $invalidParameters | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $invalidParameterFile
    Set-Content -LiteralPath $CallLog -Value '' -NoNewline
    & pwsh -NoLogo -NoProfile -File $MigrationScript -ParameterFile $invalidParameterFile -Execute *> $null
    if ($LASTEXITCODE -eq 0 -or (Get-Item $CallLog).Length -ne 0) {
        Stop-Test 'PowerShell migration must reject an unrelated workload scope before invoking Azure CLI.'
    }

    foreach ($automaticScript in @('deploy.sh', 'deploy.ps1', 'what-if.sh', 'what-if.ps1', 'teardown.sh', 'teardown.ps1')) {
        if ((Get-Content -LiteralPath (Join-Path $ProjectDir "scripts/$automaticScript") -Raw) -match 'migrate-legacy-rg-tags') {
            Stop-Test 'Legacy tag migration must never run automatically from deploy, what-if, or teardown.'
        }
    }
    $teardownText = Get-Content -LiteralPath (Join-Path $ProjectDir 'scripts/teardown.ps1') -Raw
    foreach ($requiredTeardownText in @(
        "Remove-PolicyAssignment 'demo-require-rg-tags' `$landingZonesScope"
        "Remove-PolicyAssignment 'demo-require-rg-tags' `$workloadScope"
        '& az policy set-definition delete --name "$prefix-required-rg-tags"'
    )) {
        if (-not $teardownText.Contains($requiredTeardownText)) {
            Stop-Test "PowerShell teardown is missing exact tag artifact target: $requiredTeardownText"
        }
    }
    if ($teardownText.Contains('demo-require-workload-rg-tags')) {
        Stop-Test 'PowerShell teardown still targets the nonexistent legacy assignment name.'
    }

    Write-Host 'Tag policy migration PowerShell validation passed.'
}
finally {
    $env:PATH = $oldPath
    $env:AZ_CALL_LOG = $oldCallLog
    $env:ESLZ_TAG_MIGRATION_CONFIRMATION = $oldConfirmation
    Remove-Item -LiteralPath $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $ProjectDir '.test-artifacts') -Force -ErrorAction SilentlyContinue
}
