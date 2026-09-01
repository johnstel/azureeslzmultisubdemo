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

$oldPath = $env:PATH
$oldCallLog = $env:AZ_CALL_LOG
$oldScenario = $env:AZ_MOCK_SCENARIO
$oldConfirmation = $env:ESLZ_TAG_MIGRATION_CONFIRMATION

try {
    New-Item -ItemType Directory -Path $MockBin -Force | Out-Null
    $parameterFile = Join-Path $TempDir 'parameters.json'
    @'
{
  "parameters": {
    "tenantRootManagementGroupId": { "value": "tenant-root" },
    "namePrefix": { "value": "eslz-demo" },
    "workloadArchetype": { "value": "corp" },
    "connectivitySubscriptionId": { "value": "11111111-1111-1111-1111-111111111111" },
    "workloadSubscriptionId": { "value": "22222222-2222-2222-2222-222222222222" }
  }
}
'@ | Set-Content -LiteralPath $parameterFile

    $mockPython = Join-Path $MockBin 'az-mock.py'
    @'
import json
import os
import sys

args = sys.argv[1:]
with open(os.environ["AZ_CALL_LOG"], "a", encoding="utf-8") as stream:
    stream.write(" ".join(args) + "\n")
scenario = os.environ.get("AZ_MOCK_SCENARIO", "present")
command = " ".join(arg for arg in args if arg not in ("--output", "json"))
demo = "/providers/Microsoft.Management/managementGroups/eslz-demo"
landing = demo + "-landingzones"
workload = demo + "-corp"
legacy_definition = demo + "/providers/Microsoft.Authorization/policyDefinitions/eslz-demo-require-workload-rg-tags"
initiative = landing + "/providers/Microsoft.Authorization/policySetDefinitions/eslz-demo-required-rg-tags"

def emit(value):
    print(json.dumps(value))

if command == "account show":
    subscription = "99999999-9999-9999-9999-999999999999" if scenario == "wrong-active-subscription" else "11111111-1111-1111-1111-111111111111"
    emit({"tenantId": "tenant-a", "id": subscription, "state": "Enabled"})
elif command.startswith("account show --subscription "):
    tenant = "tenant-b" if scenario == "wrong-subscription-tenant" and command.endswith("22222222-2222-2222-2222-222222222222") else "tenant-a"
    subscription = command.rsplit(" ", 1)[1]
    state = "Disabled" if scenario == "disabled-subscription" and subscription.startswith("2222") else "Enabled"
    emit({"tenantId": tenant, "id": subscription, "state": state})
elif command == "account management-group show --name tenant-root":
    emit({"id": "/providers/Microsoft.Management/managementGroups/tenant-root"})
elif command == "account management-group show --name eslz-demo":
    emit({"id": demo, "details": {"parent": {"id": "/providers/Microsoft.Management/managementGroups/tenant-root"}}})
elif command == "account management-group show --name eslz-demo-landingzones":
    emit({"id": landing, "details": {"parent": {"id": demo}}})
elif command == "account management-group show --name eslz-demo-corp":
    parent = demo if scenario == "wrong-ancestry" else landing
    emit({"id": workload, "details": {"parent": {"id": parent}}})
elif command == "policy set-definition show --name eslz-demo-required-rg-tags --management-group eslz-demo-landingzones":
    if scenario == "replacement-missing":
        print("ERROR: (ResourceNotFound) replacement missing", file=sys.stderr)
        sys.exit(3)
    emit({"id": initiative})
elif command == "policy assignment show --name demo-require-rg-tags --scope " + landing:
    if scenario == "replacement-assignment-missing":
        print("ERROR: (PolicyAssignmentNotFound) replacement assignment missing", file=sys.stderr)
        sys.exit(3)
    replacement_link = demo + "/providers/Microsoft.Authorization/policySetDefinitions/unrelated" if scenario == "replacement-link-wrong" else initiative
    emit({"id": landing + "/providers/Microsoft.Authorization/policyAssignments/demo-require-rg-tags", "properties": {"policyDefinitionId": replacement_link}})
elif command == "policy assignment show --name demo-require-rg-tags --scope " + workload:
    if scenario in ("assignment-absent", "both-absent"):
        print("ERROR: (PolicyAssignmentNotFound) legacy assignment absent", file=sys.stderr)
        sys.exit(3)
    if scenario == "assignment-read-error":
        print("ERROR: (AuthorizationFailed) access denied", file=sys.stderr)
        sys.exit(3)
    emit({"id": workload + "/providers/Microsoft.Authorization/policyAssignments/demo-require-rg-tags", "properties": {"policyDefinitionId": demo + "/providers/Microsoft.Authorization/policyDefinitions/unrelated" if scenario == "wrong-link" else legacy_definition}})
elif command == "policy definition show --name eslz-demo-require-workload-rg-tags --management-group eslz-demo":
    if scenario in ("definition-absent", "both-absent"):
        print("ERROR: (PolicyDefinitionNotFound) legacy definition absent", file=sys.stderr)
        sys.exit(3)
    if scenario == "definition-read-error":
        print("ERROR: (AuthorizationFailed) access denied", file=sys.stderr)
        sys.exit(3)
    emit({"id": legacy_definition})
elif " delete " in " " + command + " ":
    pass
else:
    print("ERROR: unexpected command: " + command, file=sys.stderr)
    sys.exit(4)
'@ | Set-Content -LiteralPath $mockPython

    $mockAzPath = Join-Path $MockBin 'az'
    @"
#!/usr/bin/env bash
python3 '$mockPython' "`$@"
"@ | Set-Content -LiteralPath $mockAzPath
    if (Get-Command chmod -ErrorAction SilentlyContinue) { & chmod +x $mockAzPath }
    $mockAzCmdPath = Join-Path $MockBin 'az.cmd'
    @"
@echo off
python "$mockPython" %*
"@ | Set-Content -LiteralPath $mockAzCmdPath

    $wrapperScript = Join-Path $TempDir 'invoke-migration-with-mock-check.ps1'
    @'
param(
    [Parameter(Mandatory = $true)][string]$ParameterFile,
    [Parameter(Mandatory = $true)][string]$ExpectedMockDir,
    [Parameter(Mandatory = $true)][string]$MigrationScript,
    [switch]$Execute
)
$azCommand = Get-Command az -ErrorAction SilentlyContinue
$resolvedSource = if ($azCommand) { $azCommand.Source } else { $null }
if (-not $resolvedSource -or -not $resolvedSource.StartsWith($ExpectedMockDir, [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Error "az resolved to '$resolvedSource' instead of the temporary mock directory '$ExpectedMockDir'."
    exit 1
}
if ($Execute) {
    & $MigrationScript -ParameterFile $ParameterFile -Execute
} else {
    & $MigrationScript -ParameterFile $ParameterFile
}
if (-not $?) { exit 1 }
'@ | Set-Content -LiteralPath $wrapperScript

    $env:PATH = "$MockBin$([IO.Path]::PathSeparator)$oldPath"
    $env:AZ_CALL_LOG = $CallLog

    $azCommand = Get-Command az -ErrorAction SilentlyContinue
    $resolvedSource = if ($azCommand) { $azCommand.Source } else { $null }
    if (-not $resolvedSource -or -not $resolvedSource.StartsWith($MockBin, [StringComparison]::OrdinalIgnoreCase)) {
        Stop-Test "az resolved to '$resolvedSource' instead of the isolated mock directory before migration tests."
    }

    function Invoke-MigrationCase {
        param([string]$Scenario, [string]$TypedConfirmation, [string]$Approval, [switch]$Execute)
        Set-Content -LiteralPath $CallLog -Value '' -NoNewline
        $env:AZ_MOCK_SCENARIO = $Scenario
        $env:ESLZ_TAG_MIGRATION_CONFIRMATION = $Approval
        $arguments = @(
            '-NoLogo', '-NoProfile', '-File', $wrapperScript,
            '-ParameterFile', $parameterFile,
            '-ExpectedMockDir', $MockBin,
            '-MigrationScript', $MigrationScript
        )
        if ($Execute) { $arguments += '-Execute' }
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = (Get-Command pwsh -ErrorAction Stop).Source
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($argument in $arguments) {
            [void]$startInfo.ArgumentList.Add($argument)
        }
        $process = [Diagnostics.Process]::Start($startInfo)
        $process.StandardInput.WriteLine($TypedConfirmation)
        $process.StandardInput.Close()
        $standardOutput = $process.StandardOutput.ReadToEnd()
        $standardError = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $script:caseOutput = "$standardOutput$standardError"
        $script:caseExitCode = $process.ExitCode
        $script:caseCalls = @(
            Get-Content -LiteralPath $CallLog | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
    }

    Invoke-MigrationCase -Scenario present -TypedConfirmation '' -Approval ''
    if ($caseExitCode -ne 0 -or $caseCalls.Count -ne 0 -or $caseOutput -notmatch 'Dry run only\.') {
        Stop-Test 'PowerShell migration preview must succeed without resolving or invoking Azure CLI.'
    }

    Invoke-MigrationCase -Scenario present -TypedConfirmation 'tenant-a/eslz-demo-corp' -Approval '' -Execute
    if ($caseExitCode -eq 0 -or -not ($caseCalls -match 'policy definition show') -or ($caseCalls -match ' delete ')) {
        Stop-Test "PowerShell migration must complete all reads, then reject missing approval without a delete. Exit=$caseExitCode Calls=$($caseCalls -join ' | ') Output=$caseOutput"
    }

    Invoke-MigrationCase -Scenario present -TypedConfirmation 'tenant-a/eslz-demo-corp' -Approval 'REMOVE-LEGACY-RG-TAG-POLICY' -Execute
    if ($caseExitCode -ne 0) { Stop-Test 'PowerShell migration failed with validated context and exact approval.' }
    $expectedDeletes = @(
        'policy assignment delete --name demo-require-rg-tags --scope /providers/Microsoft.Management/managementGroups/eslz-demo-corp'
        'policy definition delete --name eslz-demo-require-workload-rg-tags --management-group eslz-demo'
    )
    $actualDeletes = @($caseCalls | Where-Object { $_ -match ' delete ' })
    if (Compare-Object -ReferenceObject $expectedDeletes -DifferenceObject $actualDeletes -CaseSensitive) {
        Stop-Test 'PowerShell migration invoked a delete outside the two exact legacy artifacts.'
    }

    Invoke-MigrationCase -Scenario assignment-absent -TypedConfirmation 'tenant-a/eslz-demo-corp' -Approval 'REMOVE-LEGACY-RG-TAG-POLICY' -Execute
    $actualDeletes = @($caseCalls | Where-Object { $_ -match ' delete ' })
    if ($caseExitCode -ne 0 -or $actualDeletes.Count -ne 1 -or $actualDeletes[0] -cne $expectedDeletes[1]) {
        Stop-Test 'PowerShell migration must continue definition cleanup when the legacy assignment is verified absent.'
    }
    Invoke-MigrationCase -Scenario definition-absent -TypedConfirmation 'tenant-a/eslz-demo-corp' -Approval 'REMOVE-LEGACY-RG-TAG-POLICY' -Execute
    $actualDeletes = @($caseCalls | Where-Object { $_ -match ' delete ' })
    if ($caseExitCode -ne 0 -or $actualDeletes.Count -ne 1 -or $actualDeletes[0] -cne $expectedDeletes[0]) {
        Stop-Test 'PowerShell migration must continue assignment cleanup when the obsolete definition is verified absent.'
    }
    Invoke-MigrationCase -Scenario both-absent -TypedConfirmation '' -Approval '' -Execute
    if ($caseExitCode -ne 0 -or ($caseCalls -match ' delete ')) {
        Stop-Test 'PowerShell migration must report completion without approval when both exact legacy artifacts are verified absent.'
    }

    foreach ($scenario in @(
        'wrong-active-subscription', 'wrong-subscription-tenant', 'disabled-subscription', 'wrong-ancestry',
        'replacement-missing', 'replacement-assignment-missing', 'replacement-link-wrong',
        'wrong-link', 'assignment-read-error', 'definition-read-error'
    )) {
        Invoke-MigrationCase -Scenario $scenario -TypedConfirmation 'tenant-a/eslz-demo-corp' -Approval 'REMOVE-LEGACY-RG-TAG-POLICY' -Execute
        if ($caseExitCode -eq 0 -or ($caseCalls -match ' delete ')) {
            Stop-Test "PowerShell migration did not fail closed for $scenario."
        }
    }

    foreach ($automaticScript in @('deploy.sh', 'deploy.ps1', 'what-if.sh', 'what-if.ps1', 'teardown.sh', 'teardown.ps1')) {
        if ((Get-Content -LiteralPath (Join-Path $ProjectDir "scripts/$automaticScript") -Raw) -match 'migrate-legacy-rg-tags') {
            Stop-Test 'Legacy tag migration must never run automatically from another lifecycle script.'
        }
    }

    Write-Host 'Tag policy migration PowerShell validation passed.'
}
finally {
    $env:PATH = $oldPath
    $env:AZ_CALL_LOG = $oldCallLog
    $env:AZ_MOCK_SCENARIO = $oldScenario
    $env:ESLZ_TAG_MIGRATION_CONFIRMATION = $oldConfirmation
    Remove-Item -LiteralPath $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    $artifactsParent = Join-Path $ProjectDir '.test-artifacts'
    if ((Test-Path -LiteralPath $artifactsParent) -and
        @(Get-ChildItem -LiteralPath $artifactsParent -Force).Count -eq 0) {
        Remove-Item -LiteralPath $artifactsParent -Force -ErrorAction SilentlyContinue
    }
}
