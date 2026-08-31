[CmdletBinding()]
param()

# Static, offline validation of the Entra Conditional Access and PIM demo
# artifacts under identity/. This script never contacts Microsoft Graph or
# any tenant; it only inspects the JSON files that ship in this repository.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir
$IdentityDir = Join-Path $ProjectDir 'identity'

function Stop-Validation {
    param([string]$Message)
    throw $Message
}

$caDir = Join-Path $IdentityDir 'conditional-access'
$pimDir = Join-Path $IdentityDir 'pim'

if (-not (Test-Path -LiteralPath $caDir)) { Stop-Validation "Missing directory: $caDir" }
if (-not (Test-Path -LiteralPath $pimDir)) { Stop-Validation "Missing directory: $pimDir" }

$caTemplates = @(Get-ChildItem -LiteralPath $caDir -Filter '*.template.json')
if ($caTemplates.Count -eq 0) { Stop-Validation "No Conditional Access templates found in $caDir" }

foreach ($templateFile in $caTemplates) {
    $name = $templateFile.Name
    $policy = Get-Content -LiteralPath $templateFile.FullName -Raw | ConvertFrom-Json

    if ($policy.state -ne 'enabledForReportingButNotEnforced') {
        Stop-Validation "$name must default to state=enabledForReportingButNotEnforced (report-only), found '$($policy.state)'."
    }

    if ($policy.emergencyAccessExclusion.required -ne $true) {
        Stop-Validation "$name must declare emergencyAccessExclusion.required=true."
    }

    $placeholder = $policy.emergencyAccessExclusion.placeholder
    if ($placeholder -notmatch '^REPLACE_WITH_.+$') {
        Stop-Validation "$name emergencyAccessExclusion.placeholder must be a REPLACE_WITH_* input, found '$placeholder'."
    }

    $excludeGroups = @($policy.conditions.users.excludeGroups)
    if ($excludeGroups.Count -eq 0) {
        Stop-Validation "$name conditions.users.excludeGroups must not be empty; the emergency-access group must be excluded."
    }
    if (-not ($excludeGroups -contains $placeholder)) {
        Stop-Validation "$name conditions.users.excludeGroups must include the declared emergencyAccessExclusion.placeholder."
    }

    if ([string]::IsNullOrWhiteSpace($policy.notes)) {
        Stop-Validation "$name must document rollout/licensing notes."
    }
}
Write-Host "Conditional Access templates validated: $($caTemplates.Count)"

$pimTemplates = @(Get-ChildItem -LiteralPath $pimDir -Filter '*.template.json')
if ($pimTemplates.Count -eq 0) { Stop-Validation "No PIM templates found in $pimDir" }

foreach ($templateFile in $pimTemplates) {
    $name = $templateFile.Name
    $policy = Get-Content -LiteralPath $templateFile.FullName -Raw | ConvertFrom-Json

    if ($policy.assignmentType -ne 'eligible') {
        Stop-Validation "$name assignmentType must be 'eligible' (never permanent), found '$($policy.assignmentType)'."
    }

    if ($policy.activation.requireApproval -ne $true) { Stop-Validation "$name activation.requireApproval must be true." }
    if ($policy.activation.requireMultiFactorAuthentication -ne $true) { Stop-Validation "$name activation.requireMultiFactorAuthentication must be true." }
    if ($policy.activation.requireJustification -ne $true) { Stop-Validation "$name activation.requireJustification must be true." }
    if ($policy.notifications.notifyAdminsOnActivation -ne $true) { Stop-Validation "$name notifications.notifyAdminsOnActivation must be true." }
    if ($policy.notifications.notifyApproversOnActivationRequest -ne $true) { Stop-Validation "$name notifications.notifyApproversOnActivationRequest must be true." }
    if ($policy.notifications.notifyAssigneeOnActivation -ne $true) { Stop-Validation "$name notifications.notifyAssigneeOnActivation must be true." }

    $approvers = @($policy.activation.approvers)
    if ($approvers.Count -eq 0) { Stop-Validation "$name activation.approvers must not be empty." }

    $duration = $policy.activation.maximumActivationDurationHours
    if ($duration -lt 1 -or $duration -gt 8) {
        Stop-Validation "$name activation.maximumActivationDurationHours must be an integer between 1 and 8, found '$duration'."
    }

    if ([string]::IsNullOrWhiteSpace($policy.activation.authenticationContext)) {
        Stop-Validation "$name activation.authenticationContext must be set."
    }

    if ($policy.emergencyAccessExclusion.required -ne $true) {
        Stop-Validation "$name must declare emergencyAccessExclusion.required=true."
    }

    $placeholder = $policy.emergencyAccessExclusion.placeholder
    if ($placeholder -notmatch '^REPLACE_WITH_.+$') {
        Stop-Validation "$name emergencyAccessExclusion.placeholder must be a REPLACE_WITH_* input, found '$placeholder'."
    }

    if ([string]::IsNullOrWhiteSpace($policy.notes)) {
        Stop-Validation "$name must document rollout/licensing notes."
    }
}
Write-Host "PIM activation templates validated: $($pimTemplates.Count)"

# Confirm no tenant-specific identifiers (GUIDs) leak into any identity
# artifact, other than the well-known, publicly documented first-party
# "Microsoft Azure Management" application ID.
$guidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
$allowedGuid = '797f4846-ba00-4fd7-ba43-dac1f8f63013'
$jsonFiles = Get-ChildItem -LiteralPath $IdentityDir -Recurse -Filter '*.json'
foreach ($jsonFile in $jsonFiles) {
    $matches = [regex]::Matches((Get-Content -LiteralPath $jsonFile.FullName -Raw), $guidPattern)
    foreach ($match in $matches) {
        if ($match.Value -ne $allowedGuid) {
            Stop-Validation "A tenant-specific GUID ($($match.Value)) was found in $($jsonFile.Name). Replace it with a REPLACE_WITH_* placeholder."
        }
    }
}

Write-Host ''
Write-Host "Identity artifact validation passed: $($caTemplates.Count) Conditional Access template(s), $($pimTemplates.Count) PIM template(s)."
