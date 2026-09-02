[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$ParameterFile,

    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir
if ([string]::IsNullOrWhiteSpace($ParameterFile)) {
    $ParameterFile = Join-Path $ProjectDir 'parameters/demo.parameters.json'
}

$AssignmentName = 'demo-inherit-rg-tags'
$BuiltInId = '/providers/Microsoft.Authorization/policyDefinitions/ea3f2387-9b95-492a-a190-fcdc54f7b070'
$ExecutionConfirmation = 'REMEDIATE-MISSING-RESOURCE-TAGS'
$ExpectedReferences = [ordered]@{
    'inherit-cost-center' = 'CostCenter'
    'inherit-application-name' = 'ApplicationName'
    'inherit-owner' = 'Owner'
    'inherit-environment' = 'Environment'
    'inherit-data-classification' = 'DataClassification'
    'inherit-ssp-id' = 'SSP-ID'
}

function Stop-Remediation {
    param([string]$Message, [int]$ExitCode = 1)
    Write-Error $Message -ErrorAction Continue
    exit $ExitCode
}

if (-not (Test-Path -LiteralPath $ParameterFile -PathType Leaf)) {
    Stop-Remediation "Parameter file not found: $ParameterFile"
}
if ($null -eq (Get-Command az -ErrorAction SilentlyContinue)) {
    Stop-Remediation 'Azure CLI is required for validation.'
}

try {
    $parameters = Get-Content -LiteralPath $ParameterFile -Raw | ConvertFrom-Json
    $prefix = [string]$parameters.parameters.namePrefix.value
    $tagInheritanceEnabled = [bool]$parameters.parameters.enableTagInheritance.value
}
catch {
    Stop-Remediation "Unable to read required parameters: $($_.Exception.Message)"
}
if ($prefix -cnotmatch '^[a-z0-9][a-z0-9-]{2,23}$') {
    Stop-Remediation 'namePrefix must be 3-24 lowercase letters, numbers, or hyphens and start with a letter or number.'
}
if (-not $tagInheritanceEnabled) {
    Stop-Remediation 'enableTagInheritance must be true before remediation can be previewed.'
}

$DemoRootScope = "/providers/Microsoft.Management/managementGroups/$prefix"
$LandingZonesName = "$prefix-landingzones"
$LandingZonesScope = "/providers/Microsoft.Management/managementGroups/$LandingZonesName"
$InitiativeName = "$prefix-inherit-rg-tags"
$InitiativeId = "$DemoRootScope/providers/Microsoft.Authorization/policySetDefinitions/$InitiativeName"
$AssignmentId = "$LandingZonesScope/providers/Microsoft.Authorization/policyAssignments/$AssignmentName"

function Invoke-AzureRead {
    param([string]$Description, [string[]]$Arguments)
    $output = (& az @Arguments --output json 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
        Stop-Remediation "Cannot validate ${Description}: $output"
    }
    try {
        return ($output | ConvertFrom-Json)
    }
    catch {
        Stop-Remediation "Cannot parse ${Description}: $($_.Exception.Message)"
    }
}

function Test-LiveControls {
    $account = Invoke-AzureRead 'the active Azure account' @('account', 'show')
    $script:ActiveTenant = [string]$account.tenantId

    $landingZones = Invoke-AzureRead 'the Landing Zones management group' @(
        'account', 'management-group', 'show', '--name', $LandingZonesName
    )
    if ([string]$landingZones.id -ine $LandingZonesScope -or
        [string]$landingZones.details.parent.id -ine $DemoRootScope) {
        Stop-Remediation 'The Landing Zones management group ID or parent is not the expected deployment scope.'
    }

    $initiative = Invoke-AzureRead 'the tag-inheritance initiative' @(
        'policy', 'set-definition', 'show', '--name', $InitiativeName, '--management-group', $prefix
    )
    if ([string]$initiative.id -ine $InitiativeId) {
        Stop-Remediation 'The tag-inheritance initiative has an unexpected resource ID.'
    }
    $references = if ($initiative.PSObject.Properties['policyDefinitions']) {
        @($initiative.policyDefinitions)
    } else {
        @($initiative.properties.policyDefinitions)
    }
    if ($references.Count -ne $ExpectedReferences.Count) {
        Stop-Remediation 'The tag-inheritance initiative must contain exactly six references.'
    }
    foreach ($expected in $ExpectedReferences.GetEnumerator()) {
        $matchedReferences = @($references | Where-Object {
            [string]$_.policyDefinitionReferenceId -ceq $expected.Key
        })
        if ($matchedReferences.Count -ne 1 -or
            [string]$matchedReferences[0].parameters.tagName.value -cne $expected.Value -or
            [string]$matchedReferences[0].policyDefinitionId -ine $BuiltInId -or
            [string]$matchedReferences[0].definitionVersion -cne '1.*.*') {
            Stop-Remediation 'The initiative is not the exact six-reference missing-only tag control.'
        }
    }

    $assignment = Invoke-AzureRead 'the tag-inheritance assignment' @(
        'policy', 'assignment', 'show', '--name', $AssignmentName, '--scope', $LandingZonesScope
    )
    $policyDefinitionId = if ($assignment.PSObject.Properties['policyDefinitionId']) {
        [string]$assignment.policyDefinitionId
    } else {
        [string]$assignment.properties.policyDefinitionId
    }
    $notScopes = @(if ($assignment.PSObject.Properties['notScopes']) {
        @($assignment.notScopes)
    } else {
        @($assignment.properties.notScopes)
    })
    if ([string]$assignment.id -ine $AssignmentId -or
        $policyDefinitionId -ine $InitiativeId -or
        [string]$assignment.identity.type -cne 'SystemAssigned' -or
        [string]::IsNullOrWhiteSpace([string]$assignment.location) -or
        [string]$assignment.location -ieq 'global' -or
        $notScopes.Count -ne 0) {
        Stop-Remediation 'The assignment ID, scope, initiative, identity, or location is not the expected safe shape.'
    }
}

Test-LiveControls
$ExpectedConfirmation = "$ActiveTenant/$LandingZonesName/$AssignmentName"

Write-Host 'TAG-INHERITANCE REMEDIATION PLAN'
Write-Host "  Assignment: $AssignmentId"
Write-Host "  Scope: $LandingZonesScope"
Write-Host "  References: $($ExpectedReferences.Keys -join ', ')"

if (-not $Execute) {
    Write-Host 'Preview only; no remediation task was created. Re-run with -Execute after approval.'
    exit 0
}
if ($env:ESLZ_TAG_REMEDIATION_CONFIRMATION -cne $ExecutionConfirmation) {
    Stop-Remediation "-Execute requires ESLZ_TAG_REMEDIATION_CONFIRMATION=$ExecutionConfirmation." 2
}
if ($null -eq (Get-Command Start-AzPolicyRemediation -ErrorAction SilentlyContinue)) {
    Stop-Remediation 'Start-AzPolicyRemediation from Az.PolicyInsights is required for execution.'
}
$typedConfirmation = Read-Host "Type the validated tenant, scope, and assignment ($ExpectedConfirmation) to continue"
if ($typedConfirmation -cne $ExpectedConfirmation) {
    Stop-Remediation 'Confirmation did not match; remediation cancelled.' 2
}

Test-LiveControls
if ("$ActiveTenant/$LandingZonesName/$AssignmentName" -cne $ExpectedConfirmation) {
    Stop-Remediation 'Validated context changed after confirmation; remediation cancelled.'
}

foreach ($reference in $ExpectedReferences.Keys) {
    Start-AzPolicyRemediation `
        -ManagementGroupName $LandingZonesName `
        -Name "tag-$reference" `
        -PolicyAssignmentId $AssignmentId `
        -PolicyDefinitionReferenceId $reference | Out-Null
}

Write-Host 'Submitted six tag-inheritance remediation tasks.'
