[CmdletBinding()]
param()

# Offline structural validation for policy/control-catalog.json.
# Re-implements the rules documented in policy/control-catalog.schema.json using
# native PowerShell only, since a generic JSON Schema validator module is not
# assumed to be present. Mirrors tests/validate-control-catalog.sh step for step.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir
$CatalogPath = Join-Path $ProjectDir 'policy/control-catalog.json'
$MatrixPath = Join-Path $ProjectDir 'docs/CONTROL-MATRIX.md'

function Stop-Test {
    param([string]$Message)
    throw $Message
}

$guidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$idPattern = '^REQ-[A-Z]+-[0-9]{2}$'

Write-Host '1/9 Validate catalog JSON syntax...'
$catalogText = Get-Content -LiteralPath $CatalogPath -Raw
$catalog = $catalogText | ConvertFrom-Json

Write-Host '2/9 Validate required top-level fields...'
foreach ($field in @('catalogVersion', 'generatedOn', 'classificationValues', 'enforcementPhaseValues', 'controls', 'overlapNotes')) {
    if (-not (Get-Member -InputObject $catalog -Name $field -MemberType NoteProperty)) {
        Stop-Test "Catalog is missing required top-level field: $field"
    }
}
if (@($catalog.classificationValues).Count -eq 0) { Stop-Test 'classificationValues must not be empty.' }
if (@($catalog.enforcementPhaseValues).Count -eq 0) { Stop-Test 'enforcementPhaseValues must not be empty.' }
if (@($catalog.controls).Count -eq 0) { Stop-Test 'controls must not be empty.' }

$classifications = @($catalog.classificationValues)
$phases = @($catalog.enforcementPhaseValues)
$controls = @($catalog.controls)

Write-Host '3/9 Validate required per-control fields and enums...'
foreach ($control in $controls) {
    foreach ($field in @('id', 'domain', 'customerRequirement', 'scope', 'classification', 'mechanism',
            'supportedEffects', 'requiredParameters', 'roleDefinitionIds', 'remediationIdentityRequired',
            'dependencies', 'enforcementPhase', 'evidenceSource')) {
        if (-not (Get-Member -InputObject $control -Name $field -MemberType NoteProperty)) {
            Stop-Test "Control $($control.id) is missing required field: $field"
        }
    }
    if ($classifications -notcontains $control.classification) {
        Stop-Test "Control $($control.id) uses undeclared classification: $($control.classification)"
    }
    if ($phases -notcontains $control.enforcementPhase) {
        Stop-Test "Control $($control.id) uses undeclared enforcementPhase: $($control.enforcementPhase)"
    }
    if (@($control.supportedEffects).Count -eq 0) {
        Stop-Test "Control $($control.id) has an empty supportedEffects array."
    }
    foreach ($field in @('displayName', 'builtIn', 'verifiedOn', 'verificationMethod')) {
        if (-not (Get-Member -InputObject $control.mechanism -Name $field -MemberType NoteProperty)) {
            Stop-Test "Control $($control.id) mechanism is missing required field: $field"
        }
    }
}

Write-Host '4/9 Validate no "unknown" version/GUID placeholders remain...'
foreach ($control in $controls) {
    $majorVersion = if (Get-Member -InputObject $control.mechanism -Name 'majorVersion' -MemberType NoteProperty) { $control.mechanism.majorVersion } else { $null }
    $verifiedVersion = if (Get-Member -InputObject $control.mechanism -Name 'verifiedVersion' -MemberType NoteProperty) { $control.mechanism.verifiedVersion } else { $null }
    if ($majorVersion -eq 'unknown' -or $verifiedVersion -eq 'unknown') {
        Stop-Test "Control $($control.id) still uses the literal placeholder 'unknown' for majorVersion/verifiedVersion."
    }
    $sourceUrl = if (Get-Member -InputObject $control.mechanism -Name 'sourceUrl' -MemberType NoteProperty) { $control.mechanism.sourceUrl } else { $null }
    if ($sourceUrl -and
        ($sourceUrl -match 'raw\.githubusercontent\.com') -and
        ($sourceUrl.EndsWith('/'))) {
        Stop-Test "Control $($control.id) points sourceUrl at a directory listing instead of a file."
    }
}

Write-Host '5/9 Validate control IDs are unique and correctly formatted...'
$ids = @($controls | ForEach-Object { $_.id })
$uniqueIds = $ids | Select-Object -Unique
if ($uniqueIds.Count -ne $ids.Count) { Stop-Test 'Control IDs are not unique.' }
foreach ($id in $ids) {
    if ($id -notmatch $idPattern) { Stop-Test "Control ID '$id' does not match the REQ-<DOMAIN>-<NN> pattern." }
}

Write-Host '6/9 Validate dependency references resolve to existing IDs...'
$idSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$ids)
foreach ($control in $controls) {
    foreach ($dependency in @($control.dependencies)) {
        if (-not $idSet.Contains($dependency)) {
            Stop-Test "Control $($control.id) depends on unknown ID: $dependency"
        }
    }
}

Write-Host '7/9 Validate GUID formats for definitionId and roleDefinitionIds...'
foreach ($control in $controls) {
    $verifiedDirectly = @('raw-json', 'initiative-json-member') -contains $control.mechanism.verificationMethod
    if ($control.mechanism.builtIn -eq $true -and $verifiedDirectly) {
        if (-not $control.mechanism.definitionId -or $control.mechanism.definitionId -notmatch $guidPattern) {
            Stop-Test "Control $($control.id) is a directly-verified built-in but definitionId is not a well-formed GUID."
        }
    }
    foreach ($roleId in @($control.roleDefinitionIds)) {
        if ($roleId -notmatch $guidPattern) {
            Stop-Test "Control $($control.id) has a roleDefinitionIds entry that is not a well-formed bare GUID: $roleId"
        }
    }
}

Write-Host '8/9 Validate remediation-identity requirements are backed by roles...'
foreach ($control in $controls) {
    if ($control.remediationIdentityRequired -eq $true) {
        $rolesVaryByMember = (Get-Member -InputObject $control -Name 'rolesVaryByMember' -MemberType NoteProperty) -and ($control.rolesVaryByMember -eq $true)
        if ((@($control.roleDefinitionIds).Count -eq 0) -and (-not $rolesVaryByMember)) {
            Stop-Test "Control $($control.id) sets remediationIdentityRequired=true but has neither roleDefinitionIds nor rolesVaryByMember=true."
        }
    }
}

Write-Host '9/9 Validate consistency between the JSON catalog and the human-readable matrix...'
$matrixText = Get-Content -LiteralPath $MatrixPath -Raw
$jsonCount = $controls.Count
$countMatch = [regex]::Match($matrixText, '\*\*Total control records:\*\* (\d+)')
if (-not $countMatch.Success) { Stop-Test 'Matrix is missing the "Total control records" line.' }
$matrixCount = [int]$countMatch.Groups[1].Value
if ($jsonCount -ne $matrixCount) {
    Stop-Test "Catalog has $jsonCount control records but the matrix states $matrixCount."
}
foreach ($id in $ids) {
    if ($matrixText -notmatch [regex]::Escape("| $id |")) {
        Stop-Test "Control $id is present in the JSON catalog but not found as a table row in $MatrixPath."
    }
}

Write-Host ''
Write-Host 'Control catalog validation passed.'
