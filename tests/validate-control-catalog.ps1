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

Write-Host '1/10 Validate catalog JSON syntax...'
$catalogText = Get-Content -LiteralPath $CatalogPath -Raw
$catalog = $catalogText | ConvertFrom-Json

Write-Host '2/10 Validate required top-level fields...'
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

Write-Host '3/10 Validate required per-control fields and enums...'
$verificationMethods = @('raw-json', 'initiative-json-member', 'ms-learn-page', 'documentation-pattern', 'internal-design', 'in-repository-custom-definition', 'not-yet-selected', 'not-yet-created')
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
    foreach ($field in @('kind', 'displayName', 'builtIn', 'verifiedOn', 'verificationMethod')) {
        if (-not (Get-Member -InputObject $control.mechanism -Name $field -MemberType NoteProperty)) {
            Stop-Test "Control $($control.id) mechanism is missing required field: $field"
        }
    }
    if ($verificationMethods -notcontains $control.mechanism.verificationMethod) {
        Stop-Test "Control $($control.id) mechanism uses undeclared verificationMethod: $($control.mechanism.verificationMethod)"
    }
}

Write-Host '4/10 Validate no "unknown"/"n/a" version/GUID placeholders remain...'
foreach ($control in $controls) {
    $majorVersion = if (Get-Member -InputObject $control.mechanism -Name 'majorVersion' -MemberType NoteProperty) { $control.mechanism.majorVersion } else { $null }
    $verifiedVersion = if (Get-Member -InputObject $control.mechanism -Name 'verifiedVersion' -MemberType NoteProperty) { $control.mechanism.verifiedVersion } else { $null }
    if ($majorVersion -in @('unknown', 'n/a') -or $verifiedVersion -in @('unknown', 'n/a')) {
        Stop-Test "Control $($control.id) still uses the literal placeholder 'unknown' or 'n/a' for majorVersion/verifiedVersion; either verify a real version or omit the field entirely when it does not apply."
    }
    $sourceUrl = if (Get-Member -InputObject $control.mechanism -Name 'sourceUrl' -MemberType NoteProperty) { $control.mechanism.sourceUrl } else { $null }
    if ($sourceUrl -and
        ($sourceUrl -match 'raw\.githubusercontent\.com') -and
        ($sourceUrl.EndsWith('/'))) {
        Stop-Test "Control $($control.id) points sourceUrl at a directory listing instead of a file."
    }
}

Write-Host '5/10 Validate control IDs are unique and correctly formatted...'
$ids = @($controls | ForEach-Object { $_.id })
$uniqueIds = $ids | Select-Object -Unique
if ($uniqueIds.Count -ne $ids.Count) { Stop-Test 'Control IDs are not unique.' }
foreach ($id in $ids) {
    if ($id -notmatch $idPattern) { Stop-Test "Control ID '$id' does not match the REQ-<DOMAIN>-<NN> pattern." }
}

Write-Host '6/10 Validate dependency references resolve to existing IDs...'
$idSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$ids)
foreach ($control in $controls) {
    foreach ($dependency in @($control.dependencies)) {
        if (-not $idSet.Contains($dependency)) {
            Stop-Test "Control $($control.id) depends on unknown ID: $dependency"
        }
    }
}

Write-Host '7/10 Validate GUID formats for definitionId and roleDefinitionIds...'
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

Write-Host '8/10 Validate remediation-identity requirements are backed by roles...'
foreach ($control in $controls) {
    if ($control.remediationIdentityRequired -eq $true) {
        $rolesVaryByMember = (Get-Member -InputObject $control -Name 'rolesVaryByMember' -MemberType NoteProperty) -and ($control.rolesVaryByMember -eq $true)
        if ((@($control.roleDefinitionIds).Count -eq 0) -and (-not $rolesVaryByMember)) {
            Stop-Test "Control $($control.id) sets remediationIdentityRequired=true but has neither roleDefinitionIds nor rolesVaryByMember=true."
        }
    }
}

Write-Host '9/10 Validate the catalog against policy/control-catalog.schema.json...'
$SchemaPath = Join-Path $ProjectDir 'policy/control-catalog.schema.json'
$pythonCmd = Get-Command python3 -ErrorAction SilentlyContinue
$jsonschemaAvailable = $false
if ($pythonCmd) {
    & python3 -c 'import jsonschema' 2>$null
    $jsonschemaAvailable = ($LASTEXITCODE -eq 0)
}
if ($jsonschemaAvailable) {
    $pyScript = @'
import json
import sys

import jsonschema

catalog_path, schema_path = sys.argv[1:3]
with open(catalog_path, encoding="utf-8") as f:
    catalog = json.load(f)
with open(schema_path, encoding="utf-8") as f:
    schema = json.load(f)
jsonschema.validate(catalog, schema)
'@
    $tmpPy = New-TemporaryFile
    Set-Content -LiteralPath $tmpPy -Value $pyScript
    & python3 $tmpPy $CatalogPath $SchemaPath
    $schemaExit = $LASTEXITCODE
    Remove-Item -LiteralPath $tmpPy -ErrorAction SilentlyContinue
    if ($schemaExit -ne 0) { Stop-Test 'Catalog failed JSON Schema validation.' }
} else {
    Write-Host '  (python3 + jsonschema not available; relying on the hand-rolled field/enum checks in steps 3-8, which mirror the schema.)'
}

Write-Host '10/10 Validate every field represented in the human-readable matrix matches the JSON catalog...'
$matrixText = Get-Content -LiteralPath $MatrixPath -Raw
$jsonCount = $controls.Count
$countMatch = [regex]::Match($matrixText, '\*\*Total control records:\*\* (\d+)')
if (-not $countMatch.Success) { Stop-Test 'Matrix is missing the "Total control records" line.' }
$matrixCount = [int]$countMatch.Groups[1].Value
if ($jsonCount -ne $matrixCount) {
    Stop-Test "Catalog has $jsonCount control records but the matrix states $matrixCount."
}
foreach ($control in $controls) {
    $builtInText = if ($control.mechanism.builtIn) { 'Yes' } else { 'No' }
    $hasDefinitionId = (Get-Member -InputObject $control.mechanism -Name 'definitionId' -MemberType NoteProperty -ErrorAction SilentlyContinue) -and $control.mechanism.definitionId
    $definitionIdText = if ($hasDefinitionId) { "``$($control.mechanism.definitionId)``" } else { "``$([char]0x2014)``" }
    $hasVerifiedVersion = (Get-Member -InputObject $control.mechanism -Name 'verifiedVersion' -MemberType NoteProperty -ErrorAction SilentlyContinue) -and $control.mechanism.verifiedVersion
    $versionText = if ($hasVerifiedVersion) { $control.mechanism.verifiedVersion } else { [char]0x2014 }
    $effectsText = ($control.supportedEffects -join ', ')
    $expectedRow = "| $($control.id) | $($control.customerRequirement) | $($control.scope) | $($control.classification) | $($control.mechanism.displayName) (built-in: $builtInText) | $definitionIdText | $versionText | $effectsText | $($control.enforcementPhase) |"
    if (-not $matrixText.Contains($expectedRow)) {
        Stop-Test "Control $($control.id) row in $MatrixPath does not match the JSON catalog (scope, classification, mechanism, built-in ID, version, effects, or enforcement phase differs, or the row is missing)."
    }
}

Write-Host ''
Write-Host 'Control catalog validation passed.'
