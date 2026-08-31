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
    Write-Host '  (python3 + jsonschema not available; falling back to the full schema-equivalent native-PowerShell re-implementation below.)'

    $classificationEnum = @('azure-policy', 'entra-pim', 'defender-cspm-ciem', 'shared-service-architecture', 'manual-evidence')
    $phaseEnum = @('audit-only', 'deny-do-not-enforce', 'deployifnotexists-opt-in', 'manual-evidence')
    $dateRe = '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
    $schemaErrors = New-Object System.Collections.Generic.List[string]

    function Get-Prop {
        param($Object, [string]$Name)
        if ($null -eq $Object) { return $null }
        if (Get-Member -InputObject $Object -Name $Name -MemberType NoteProperty -ErrorAction SilentlyContinue) {
            return $Object.$Name
        }
        return $null
    }
    function Test-NonEmptyString {
        param($Value)
        return ($null -ne $Value) -and ($Value -is [string]) -and ($Value.Length -ge 1)
    }
    function Test-Prop {
        param($Object, [string]$Name)
        return [bool](Get-Member -InputObject $Object -Name $Name -MemberType NoteProperty -ErrorAction SilentlyContinue)
    }

    if (-not (Test-NonEmptyString (Get-Prop $catalog '$schema'))) { $schemaErrors.Add('top-level: missing/invalid $schema') }
    if (-not (Test-NonEmptyString (Get-Prop $catalog 'catalogVersion'))) { $schemaErrors.Add('top-level: missing/invalid catalogVersion') }
    $generatedOn = Get-Prop $catalog 'generatedOn'
    if (-not (Test-NonEmptyString $generatedOn) -or ($generatedOn -notmatch $dateRe)) { $schemaErrors.Add('top-level: missing/invalid generatedOn date') }
    if (-not (Test-NonEmptyString (Get-Prop $catalog 'purpose'))) { $schemaErrors.Add('top-level: missing/invalid purpose') }
    $sourceIssue = Get-Prop $catalog 'sourceIssue'
    if (-not (Test-NonEmptyString $sourceIssue) -or ($sourceIssue -notmatch '^https?://')) { $schemaErrors.Add('top-level: missing/invalid sourceIssue uri') }
    $classificationValues = @(Get-Prop $catalog 'classificationValues')
    if ($classificationValues.Count -lt 1) { $schemaErrors.Add('top-level: missing/invalid classificationValues') }
    if (($classificationValues | Select-Object -Unique).Count -ne $classificationValues.Count) { $schemaErrors.Add('top-level: classificationValues entries are not unique') }
    $phaseValues = @(Get-Prop $catalog 'enforcementPhaseValues')
    if ($phaseValues.Count -lt 1) { $schemaErrors.Add('top-level: missing/invalid enforcementPhaseValues') }
    if (($phaseValues | Select-Object -Unique).Count -ne $phaseValues.Count) { $schemaErrors.Add('top-level: enforcementPhaseValues entries are not unique') }
    if (-not (Test-Prop $catalog 'cautions')) { $schemaErrors.Add('top-level: missing/invalid cautions array') }
    foreach ($caution in @(Get-Prop $catalog 'cautions')) {
        if ($caution -isnot [string]) { $schemaErrors.Add('top-level: a cautions entry is not a string') }
    }
    if (-not (Test-Prop $catalog 'overlapNotes')) { $schemaErrors.Add('top-level: missing/invalid overlapNotes array') }
    foreach ($overlap in @(Get-Prop $catalog 'overlapNotes')) {
        if (-not (Test-NonEmptyString (Get-Prop $overlap 'topic')) -or -not (Test-NonEmptyString (Get-Prop $overlap 'note'))) {
            $schemaErrors.Add('overlapNotes: an entry is missing a non-empty topic/note')
        }
    }
    if ($controls.Count -lt 1) { $schemaErrors.Add('top-level: missing/invalid controls array') }

    foreach ($control in $controls) {
        $controlId = Get-Prop $control 'id'
        $cid = if ($controlId) { $controlId } else { '?' }
        if (-not (Test-NonEmptyString $controlId) -or ($controlId -notmatch $idPattern)) { $schemaErrors.Add("${cid}: invalid or malformed id") }
        if (-not (Test-NonEmptyString (Get-Prop $control 'domain'))) { $schemaErrors.Add("${cid}: missing/invalid domain") }
        if (-not (Test-NonEmptyString (Get-Prop $control 'customerRequirement'))) { $schemaErrors.Add("${cid}: missing/invalid customerRequirement") }
        if (-not (Test-NonEmptyString (Get-Prop $control 'scope'))) { $schemaErrors.Add("${cid}: missing/invalid scope") }
        $classification = Get-Prop $control 'classification'
        if ($classificationEnum -notcontains $classification) { $schemaErrors.Add("${cid}: undeclared classification '$classification'") }
        $mechanism = Get-Prop $control 'mechanism'
        if ($mechanism -isnot [PSCustomObject]) { $schemaErrors.Add("${cid}: missing mechanism object") }
        if (-not (Test-NonEmptyString (Get-Prop $mechanism 'kind'))) { $schemaErrors.Add("${cid}: mechanism.kind missing/invalid") }
        if ((Get-Prop $mechanism 'builtIn') -isnot [bool]) { $schemaErrors.Add("${cid}: mechanism.builtIn missing/invalid") }
        if (-not (Test-NonEmptyString (Get-Prop $mechanism 'displayName'))) { $schemaErrors.Add("${cid}: mechanism.displayName missing/invalid") }
        $verifiedOn = Get-Prop $mechanism 'verifiedOn'
        if (-not (Test-NonEmptyString $verifiedOn) -or ($verifiedOn -notmatch $dateRe)) { $schemaErrors.Add("${cid}: mechanism.verifiedOn missing/invalid date") }
        $verificationMethod = Get-Prop $mechanism 'verificationMethod'
        if ($verificationMethods -notcontains $verificationMethod) { $schemaErrors.Add("${cid}: undeclared mechanism.verificationMethod '$verificationMethod'") }
        $majorVersion = Get-Prop $mechanism 'majorVersion'
        if ((Test-Prop $mechanism 'majorVersion') -and (-not (Test-NonEmptyString $majorVersion) -or $majorVersion -in @('unknown', 'n/a'))) { $schemaErrors.Add("${cid}: mechanism.majorVersion invalid or placeholder") }
        $verifiedVersion = Get-Prop $mechanism 'verifiedVersion'
        if ((Test-Prop $mechanism 'verifiedVersion') -and (-not (Test-NonEmptyString $verifiedVersion) -or $verifiedVersion -in @('unknown', 'n/a'))) { $schemaErrors.Add("${cid}: mechanism.verifiedVersion invalid or placeholder") }
        $sourceUrl = Get-Prop $mechanism 'sourceUrl'
        if ((Test-Prop $mechanism 'sourceUrl') -and $sourceUrl -and ($sourceUrl -isnot [string])) { $schemaErrors.Add("${cid}: mechanism.sourceUrl must be string or null") }
        if ((Test-Prop $mechanism 'sourceUrl') -and $sourceUrl -and ($sourceUrl -match 'raw\.githubusercontent\.com') -and ($sourceUrl.EndsWith('/'))) { $schemaErrors.Add("${cid}: mechanism.sourceUrl points at a directory listing") }
        $builtIn = Get-Prop $mechanism 'builtIn'
        $definitionId = Get-Prop $mechanism 'definitionId'
        $verifiedDirectly = @('raw-json', 'initiative-json-member') -contains $verificationMethod
        if (($builtIn -eq $true) -and $verifiedDirectly -and (-not $definitionId -or $definitionId -notmatch $guidPattern)) {
            $schemaErrors.Add("${cid}: definitionId is not a well-formed GUID for a directly-verified built-in")
        }
        $effects = @(Get-Prop $control 'supportedEffects')
        if ($effects.Count -lt 1) { $schemaErrors.Add("${cid}: supportedEffects missing/empty") }
        foreach ($effect in $effects) { if (-not (Test-NonEmptyString $effect)) { $schemaErrors.Add("${cid}: a supportedEffects entry is not a non-empty string") } }
        if (-not (Test-Prop $control 'requiredParameters')) { $schemaErrors.Add("${cid}: requiredParameters must be an array") }
        $roleDefinitionIds = @(Get-Prop $control 'roleDefinitionIds')
        if (-not (Test-Prop $control 'roleDefinitionIds')) { $schemaErrors.Add("${cid}: roleDefinitionIds must be an array") }
        foreach ($roleId in $roleDefinitionIds) { if ($roleId -notmatch $guidPattern) { $schemaErrors.Add("${cid}: a roleDefinitionIds entry is not a well-formed bare GUID") } }
        $remediationIdentityRequired = Get-Prop $control 'remediationIdentityRequired'
        if ($remediationIdentityRequired -isnot [bool]) { $schemaErrors.Add("${cid}: remediationIdentityRequired missing/invalid") }
        $hasRolesVary = Test-Prop $control 'rolesVaryByMember'
        $rolesVaryByMember = Get-Prop $control 'rolesVaryByMember'
        if ($hasRolesVary -and $rolesVaryByMember -isnot [bool]) { $schemaErrors.Add("${cid}: rolesVaryByMember must be boolean") }
        $rolesVaryTrue = $hasRolesVary -and ($rolesVaryByMember -eq $true)
        if (($remediationIdentityRequired -eq $true) -and ($roleDefinitionIds.Count -eq 0) -and (-not $rolesVaryTrue)) {
            $schemaErrors.Add("${cid}: remediationIdentityRequired=true without a populated roleDefinitionIds array or rolesVaryByMember=true")
        }
        if (-not (Test-Prop $control 'dependencies')) { $schemaErrors.Add("${cid}: dependencies must be an array") }
        foreach ($dependency in @(Get-Prop $control 'dependencies')) { if ($dependency -notmatch $idPattern) { $schemaErrors.Add("${cid}: a dependencies entry is not a well-formed control id") } }
        $enforcementPhase = Get-Prop $control 'enforcementPhase'
        if ($phaseValues -notcontains $enforcementPhase) { $schemaErrors.Add("${cid}: undeclared enforcementPhase '$enforcementPhase'") }
        if (-not (Test-NonEmptyString (Get-Prop $control 'evidenceSource'))) { $schemaErrors.Add("${cid}: missing/invalid evidenceSource") }
    }

    if ($schemaErrors.Count -gt 0) {
        $formattedErrors = ($schemaErrors | ForEach-Object { "  - $_" }) -join "`n"
        Stop-Test "Catalog failed the offline schema-equivalent validation:`n${formattedErrors}"
    }
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
