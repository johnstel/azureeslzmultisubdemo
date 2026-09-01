[CmdletBinding()]
param(
    [string]$CatalogPathOverride,
    [string]$MatrixPathOverride,
    [ValidateSet('auto', 'python', 'native')]
    [string]$SchemaBackend = 'auto',
    [switch]$SchemaOnly
)

# Offline structural validation for policy/control-catalog.json.
# Re-implements the rules documented in policy/control-catalog.schema.json using
# native PowerShell only, since a generic JSON Schema validator module is not
# assumed to be present. Mirrors tests/validate-control-catalog.sh step for step.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir
$CatalogPath = if ($CatalogPathOverride) { $CatalogPathOverride } else { Join-Path $ProjectDir 'policy/control-catalog.json' }
$MatrixPath = if ($MatrixPathOverride) { $MatrixPathOverride } else { Join-Path $ProjectDir 'docs/CONTROL-MATRIX.md' }

function Stop-Test {
    param([string]$Message)
    throw $Message
}

$guidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$idPattern = '^REQ-[A-Z]+-[0-9]{2}$'

Write-Host '1/10 Validate catalog JSON syntax...'
$catalogText = Get-Content -LiteralPath $CatalogPath -Raw
$catalog = $catalogText | ConvertFrom-Json

if (-not $SchemaOnly) {
Write-Host '2/10 Validate required top-level fields...'
foreach ($field in @('$schema', 'catalogVersion', 'generatedOn', 'classificationValues', 'enforcementPhaseValues', 'controls', 'overlapNotes')) {
    if (-not (Get-Member -InputObject $catalog -Name $field -MemberType NoteProperty)) {
        Stop-Test "Catalog is missing required top-level field: $field"
    }
}
foreach ($field in @('classificationValues', 'enforcementPhaseValues', 'controls', 'overlapNotes')) {
    if ($catalog.$field -isnot [array]) {
        Stop-Test "Catalog field '$field' must be a JSON array, not a scalar or object."
    }
}
if (@($catalog.classificationValues).Count -eq 0) { Stop-Test 'classificationValues must not be empty.' }
if (@($catalog.enforcementPhaseValues).Count -eq 0) { Stop-Test 'enforcementPhaseValues must not be empty.' }
if (@($catalog.controls).Count -eq 0) { Stop-Test 'controls must not be empty.' }
if ([string]::IsNullOrEmpty($catalog.'$schema')) { Stop-Test '$schema must not be empty.' }
if ([string]::IsNullOrEmpty($catalog.catalogVersion)) { Stop-Test 'catalogVersion must not be empty.' }
foreach ($value in @($catalog.classificationValues)) {
    if ([string]::IsNullOrEmpty($value)) { Stop-Test 'classificationValues entries must be non-empty strings.' }
}
foreach ($value in @($catalog.enforcementPhaseValues)) {
    if ([string]::IsNullOrEmpty($value)) { Stop-Test 'enforcementPhaseValues entries must be non-empty strings.' }
}

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
    if ($classifications -cnotcontains $control.classification) {
        Stop-Test "Control $($control.id) uses undeclared classification: $($control.classification)"
    }
    if ($phases -cnotcontains $control.enforcementPhase) {
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
    if ($verificationMethods -cnotcontains $control.mechanism.verificationMethod) {
        Stop-Test "Control $($control.id) mechanism uses undeclared verificationMethod: $($control.mechanism.verificationMethod)"
    }
}

Write-Host '4/10 Validate no "unknown"/"n/a" version/GUID placeholders remain...'
foreach ($control in $controls) {
    $majorVersion = if (Get-Member -InputObject $control.mechanism -Name 'majorVersion' -MemberType NoteProperty) { $control.mechanism.majorVersion } else { $null }
    $verifiedVersion = if (Get-Member -InputObject $control.mechanism -Name 'verifiedVersion' -MemberType NoteProperty) { $control.mechanism.verifiedVersion } else { $null }
    if ($majorVersion -cin @('unknown', 'n/a') -or $verifiedVersion -cin @('unknown', 'n/a')) {
        Stop-Test "Control $($control.id) still uses the literal placeholder 'unknown' or 'n/a' for majorVersion/verifiedVersion; either verify a real version or omit the field entirely when it does not apply."
    }
    $sourceUrl = if (Get-Member -InputObject $control.mechanism -Name 'sourceUrl' -MemberType NoteProperty) { $control.mechanism.sourceUrl } else { $null }
    if ($sourceUrl -and
        ($sourceUrl -cmatch 'raw\.githubusercontent\.com') -and
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
} else {
    Write-Host '2-8/10 Skipped pre-schema catalog checks (-SchemaOnly).'
    $classifications = @($catalog.classificationValues)
    $phases = @($catalog.enforcementPhaseValues)
    $controls = @($catalog.controls)
}

Write-Host '9/10 Validate the catalog against policy/control-catalog.schema.json...'
$SchemaPath = Join-Path $ProjectDir 'policy/control-catalog.schema.json'
# -SchemaBackend selects which of the two schema-equivalent implementations
# runs (rather than silently auto-detecting), so callers -- notably
# tests/uri-grammar-forced-fallback-tests.sh -- can assert that a *specific*
# backend actually executed instead of accidentally exercising the native
# fallback twice under two different invocations that both happened to lack
# python3+jsonschema:
#   - 'python': require python3 + the jsonschema module; exit 2 (a distinct
#     "skipped, backend unavailable" code, not a validation failure) if
#     either is missing, rather than silently falling back to native.
#   - 'native': always use the native-PowerShell fallback, regardless of
#     what is on PATH.
#   - 'auto' (default): auto-detect, preserving prior behavior.
$pythonCmd = Get-Command python3 -ErrorAction SilentlyContinue
$jsonschemaAvailable = $false
if ($pythonCmd) {
    & python3 -c 'import jsonschema' 2>$null
    $jsonschemaAvailable = ($LASTEXITCODE -eq 0)
}
switch ($SchemaBackend) {
    'python' {
        if (-not $jsonschemaAvailable) {
            [Console]::Error.WriteLine("  SKIPPED: -SchemaBackend python requested but python3 and/or the jsonschema module is not available.")
            exit 2
        }
        $usePython = $true
    }
    'native' { $usePython = $false }
    default { $usePython = $jsonschemaAvailable }
}
if ($usePython) {
    $pyScript = @'
import json
import sys

import jsonschema

catalog_path, schema_path = sys.argv[1:3]
with open(catalog_path, encoding="utf-8") as f:
    catalog = json.load(f)
with open(schema_path, encoding="utf-8") as f:
    schema = json.load(f)
# The schema's "pattern" constraint on sourceIssue/mechanism.sourceUrl (a
# conservative, intentionally narrow source-URL grammar: HTTPS only,
# non-empty DNS labels with no leading/trailing hyphen, no userinfo/IP
# literal/port, and path/query/fragment restricted to safe ASCII URI
# characters with well-formed percent-escapes) is the single source of
# truth for URL validity -- jsonschema.validate() below enforces it exactly
# as declared, so no supplemental ad hoc URI check is layered on top here.
# The jq/PowerShell-native fallbacks read the *same* pattern strings out of
# this schema file (rather than a hand-copied duplicate) so all four
# validation paths can never diverge.
jsonschema.validate(catalog, schema, format_checker=jsonschema.FormatChecker())
'@
    $pyScript | & python3 - $CatalogPath $SchemaPath
    $schemaExit = $LASTEXITCODE
    if ($schemaExit -ne 0) { Stop-Test 'Catalog failed JSON Schema validation.' }
} else {
    Write-Host '  (using the full schema-equivalent native-PowerShell re-implementation below.)'

    $schemaDocument = Get-Content -LiteralPath $SchemaPath -Raw | ConvertFrom-Json
    $classificationEnum = @('azure-policy', 'entra-pim', 'defender-cspm-ciem', 'shared-service-architecture', 'manual-evidence')
    $phaseEnum = @('audit-only', 'deny-do-not-enforce', 'deployifnotexists-opt-in', 'manual-evidence')
    $dateRe = '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
    $schemaErrors = New-Object System.Collections.Generic.List[string]

    # Real `format: date` semantics: reject a value that matches $dateRe
    # syntactically but round-trips to a different calendar date (e.g.
    # "2026-02-30" normalizes to "2026-03-02"), catching invalid months/days
    # that a regex-only check would accept.
    function Test-ValidCalendarDate {
        param($Value)
        if (-not (Test-NonEmptyString $Value) -or ($Value -notmatch $dateRe)) { return $false }
        try {
            $parsed = [datetime]::ParseExact($Value, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
            return $parsed.ToString('yyyy-MM-dd') -eq $Value
        } catch {
            return $false
        }
    }
    # Real `format: uri` semantics for the absolute HTTPS source URLs used
    # throughout this catalog. Earlier revisions of this check hand-copied a
    # validation regex/parser here, in the jq fallback, and in the Python
    # heredoc above -- and those copies repeatedly drifted out of sync
    # across review rounds. To make divergence structurally impossible, the
    # grammar itself is no longer hand-copied here at all: it is read at
    # runtime from policy/control-catalog.schema.json's own declared
    # "pattern" for sourceIssue/mechanism.sourceUrl ($schemaDocument, loaded
    # above), so this fallback, the Python jsonschema path, and the jq
    # fallback all share the exact same grammar string as their single
    # source of truth. That grammar is intentionally narrower than generic
    # RFC 3986 syntax -- HTTPS only; non-empty DNS labels with no
    # leading/trailing hyphen (no IP literals, no unmatched IPv6-style
    # brackets); no userinfo or port; and a path/query/fragment restricted
    # to safe ASCII URI characters with well-formed two-hex-digit
    # percent-escapes (rejecting whitespace, backslash, angle brackets,
    # pipes, and other control characters) -- because it only needs to
    # cover this catalog's real evidence sources (github.com,
    # learn.microsoft.com, raw.githubusercontent.com).
    $urlPattern = $schemaDocument.properties.sourceIssue.pattern
    $mechanismUrlPattern = $schemaDocument.'$defs'.mechanism.properties.sourceUrl.pattern
    if ($urlPattern -ne $mechanismUrlPattern) {
        $schemaErrors.Add('top-level: schema sourceIssue and mechanism.sourceUrl patterns have diverged')
    }
    function Test-ValidHttpUri {
        param($Value, $Pattern)
        if (-not (Test-NonEmptyString $Value)) { return $false }
        return [regex]::IsMatch($Value, $Pattern)
    }

    function Get-Prop {
        param($Object, [string]$Name)
        if ($null -eq $Object) { return $null }
        if (Get-Member -InputObject $Object -Name $Name -MemberType NoteProperty -ErrorAction SilentlyContinue) {
            $value = $Object.$Name
            # The leading comma prevents PowerShell from unrolling an
            # array-typed value (including an empty array) back into $null as
            # it crosses the function's return boundary -- a well-known
            # PowerShell pipeline gotcha that would otherwise silently defeat
            # Test-IsArray below. Scalars must NOT be comma-wrapped, or every
            # caller expecting a plain string/bool/object would instead see a
            # 1-element array.
            if ($value -is [array]) { return , $value }
            return $value
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
    # Strict array-type check performed BEFORE any @(...) coercion. PowerShell's
    # @(...) operator silently wraps a scalar (e.g. a string) into a 1-element
    # array, which would otherwise let a malformed catalog where an array-typed
    # field (classificationValues, enforcementPhaseValues, supportedEffects,
    # requiredParameters, roleDefinitionIds, dependencies) was mistakenly
    # authored as a bare scalar pass undetected. ConvertFrom-Json preserves
    # JSON arrays (including single-element and empty arrays) as PowerShell
    # arrays, so "-is [array]" reliably distinguishes a true JSON array from a
    # scalar or from a missing/null property.
    function Test-IsArray {
        param($Value)
        return ($null -ne $Value) -and ($Value -is [array])
    }
    function Test-UniqueStrings {
        param($Values)
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($value in @($Values)) {
            if ($value -isnot [string] -or -not $seen.Add($value)) { return $false }
        }
        return $true
    }
    # Returns the value coerced to an array ONLY for iteration purposes, after
    # the caller has already separately asserted Test-IsArray for type-strictness.
    function Get-ArrayItems {
        param($Value)
        # The leading comma prevents PowerShell from unrolling an empty (or
        # single-element) array back into $null/a scalar as it crosses the
        # function's output/return boundary.
        if ($null -eq $Value) { return , @() }
        return , @($Value)
    }

    if (-not (Test-NonEmptyString (Get-Prop $catalog '$schema'))) { $schemaErrors.Add('top-level: missing/invalid $schema') }
    if (-not (Test-NonEmptyString (Get-Prop $catalog 'catalogVersion'))) { $schemaErrors.Add('top-level: missing/invalid catalogVersion') }
    $generatedOn = Get-Prop $catalog 'generatedOn'
    if (-not (Test-ValidCalendarDate $generatedOn)) { $schemaErrors.Add('top-level: missing/invalid generatedOn date') }
    if (-not (Test-NonEmptyString (Get-Prop $catalog 'purpose'))) { $schemaErrors.Add('top-level: missing/invalid purpose') }
    $sourceIssue = Get-Prop $catalog 'sourceIssue'
    if (-not (Test-ValidHttpUri $sourceIssue $urlPattern)) { $schemaErrors.Add('top-level: missing/invalid sourceIssue uri') }
    $classificationValuesRaw = Get-Prop $catalog 'classificationValues'
    $classificationValuesIsArray = Test-IsArray $classificationValuesRaw
    $classificationValues = Get-ArrayItems $classificationValuesRaw
    if (-not $classificationValuesIsArray -or $classificationValues.Count -lt 1) { $schemaErrors.Add('top-level: missing/invalid classificationValues') }
    if (-not (Test-UniqueStrings $classificationValues)) { $schemaErrors.Add('top-level: classificationValues entries are not unique') }
    foreach ($value in $classificationValues) {
        if (-not (Test-NonEmptyString $value)) { $schemaErrors.Add('top-level: a classificationValues entry is not a non-empty string') }
    }
    $phaseValuesRaw = Get-Prop $catalog 'enforcementPhaseValues'
    $phaseValuesIsArray = Test-IsArray $phaseValuesRaw
    $phaseValues = Get-ArrayItems $phaseValuesRaw
    if (-not $phaseValuesIsArray -or $phaseValues.Count -lt 1) { $schemaErrors.Add('top-level: missing/invalid enforcementPhaseValues') }
    if (-not (Test-UniqueStrings $phaseValues)) { $schemaErrors.Add('top-level: enforcementPhaseValues entries are not unique') }
    foreach ($value in $phaseValues) {
        if (-not (Test-NonEmptyString $value)) { $schemaErrors.Add('top-level: an enforcementPhaseValues entry is not a non-empty string') }
    }
    $cautionsRaw = Get-Prop $catalog 'cautions'
    if (-not (Test-IsArray $cautionsRaw)) { $schemaErrors.Add('top-level: missing/invalid cautions array') }
    $cautionItems = Get-ArrayItems $cautionsRaw
    foreach ($caution in $cautionItems) {
        if ($caution -isnot [string]) { $schemaErrors.Add('top-level: a cautions entry is not a string') }
    }
    $overlapNotesRaw = Get-Prop $catalog 'overlapNotes'
    if (-not (Test-IsArray $overlapNotesRaw)) { $schemaErrors.Add('top-level: missing/invalid overlapNotes array') }
    $overlapNoteItems = Get-ArrayItems $overlapNotesRaw
    foreach ($overlap in $overlapNoteItems) {
        if (-not (Test-NonEmptyString (Get-Prop $overlap 'topic')) -or -not (Test-NonEmptyString (Get-Prop $overlap 'note'))) {
            $schemaErrors.Add('overlapNotes: an entry is missing a non-empty topic/note')
        }
    }
    $controlsRaw = Get-Prop $catalog 'controls'
    if (-not (Test-IsArray $controlsRaw) -or (Get-ArrayItems $controlsRaw).Count -lt 1) { $schemaErrors.Add('top-level: missing/invalid controls array') }

    foreach ($control in $controls) {
        $controlId = Get-Prop $control 'id'
        $cid = if ($controlId) { $controlId } else { '?' }
        if (-not (Test-NonEmptyString $controlId) -or ($controlId -cnotmatch $idPattern)) { $schemaErrors.Add("${cid}: invalid or malformed id") }
        if (-not (Test-NonEmptyString (Get-Prop $control 'domain'))) { $schemaErrors.Add("${cid}: missing/invalid domain") }
        if (-not (Test-NonEmptyString (Get-Prop $control 'customerRequirement'))) { $schemaErrors.Add("${cid}: missing/invalid customerRequirement") }
        if (-not (Test-NonEmptyString (Get-Prop $control 'scope'))) { $schemaErrors.Add("${cid}: missing/invalid scope") }
        $classification = Get-Prop $control 'classification'
        if ($classificationEnum -cnotcontains $classification) { $schemaErrors.Add("${cid}: undeclared classification '$classification'") }
        $mechanism = Get-Prop $control 'mechanism'
        if ($mechanism -isnot [PSCustomObject]) { $schemaErrors.Add("${cid}: missing mechanism object") }
        if (-not (Test-NonEmptyString (Get-Prop $mechanism 'kind'))) { $schemaErrors.Add("${cid}: mechanism.kind missing/invalid") }
        if ((Get-Prop $mechanism 'builtIn') -isnot [bool]) { $schemaErrors.Add("${cid}: mechanism.builtIn missing/invalid") }
        if (-not (Test-NonEmptyString (Get-Prop $mechanism 'displayName'))) { $schemaErrors.Add("${cid}: mechanism.displayName missing/invalid") }
        $verifiedOn = Get-Prop $mechanism 'verifiedOn'
        if (-not (Test-ValidCalendarDate $verifiedOn)) { $schemaErrors.Add("${cid}: mechanism.verifiedOn missing/invalid date") }
        $verificationMethod = Get-Prop $mechanism 'verificationMethod'
        if ($verificationMethods -cnotcontains $verificationMethod) { $schemaErrors.Add("${cid}: undeclared mechanism.verificationMethod '$verificationMethod'") }
        $majorVersion = Get-Prop $mechanism 'majorVersion'
        if ((Test-Prop $mechanism 'majorVersion') -and (-not (Test-NonEmptyString $majorVersion) -or $majorVersion -cin @('unknown', 'n/a'))) { $schemaErrors.Add("${cid}: mechanism.majorVersion invalid or placeholder") }
        $verifiedVersion = Get-Prop $mechanism 'verifiedVersion'
        if ((Test-Prop $mechanism 'verifiedVersion') -and (-not (Test-NonEmptyString $verifiedVersion) -or $verifiedVersion -cin @('unknown', 'n/a'))) { $schemaErrors.Add("${cid}: mechanism.verifiedVersion invalid or placeholder") }
        $sourceUrl = Get-Prop $mechanism 'sourceUrl'
        # Uses "-ne $null" rather than truthiness so a falsy-but-not-null,
        # non-string sourceUrl (e.g. the boolean $false, or 0) is not silently
        # skipped by PowerShell's implicit boolean coercion of that value.
        if ((Test-Prop $mechanism 'sourceUrl') -and ($null -ne $sourceUrl) -and ($sourceUrl -isnot [string])) { $schemaErrors.Add("${cid}: mechanism.sourceUrl must be string or null") }
        if ((Test-Prop $mechanism 'sourceUrl') -and ($sourceUrl -is [string]) -and (-not (Test-ValidHttpUri $sourceUrl $mechanismUrlPattern))) { $schemaErrors.Add("${cid}: mechanism.sourceUrl is not a well-formed absolute HTTPS URL matching the catalog's source-URL grammar") }
        if ((Test-Prop $mechanism 'sourceUrl') -and ($sourceUrl -is [string]) -and ($sourceUrl -cmatch 'raw\.githubusercontent\.com') -and ($sourceUrl.EndsWith('/'))) { $schemaErrors.Add("${cid}: mechanism.sourceUrl points at a directory listing") }
        $builtIn = Get-Prop $mechanism 'builtIn'
        $definitionId = Get-Prop $mechanism 'definitionId'
        if ((Test-Prop $mechanism 'definitionId') -and ($null -ne $definitionId) -and ($definitionId -isnot [string])) { $schemaErrors.Add("${cid}: mechanism.definitionId must be string or null") }
        $mechanismCategory = Get-Prop $mechanism 'category'
        if ((Test-Prop $mechanism 'category') -and ($mechanismCategory -isnot [string])) { $schemaErrors.Add("${cid}: mechanism.category must be a string") }
        $mechanismNotes = Get-Prop $mechanism 'notes'
        if ((Test-Prop $mechanism 'notes') -and ($mechanismNotes -isnot [string])) { $schemaErrors.Add("${cid}: mechanism.notes must be a string") }
        $verifiedDirectly = @('raw-json', 'initiative-json-member') -ccontains $verificationMethod
        if (($builtIn -eq $true) -and $verifiedDirectly -and (-not $definitionId -or $definitionId -notmatch $guidPattern)) {
            $schemaErrors.Add("${cid}: definitionId is not a well-formed GUID for a directly-verified built-in")
        }
        $effectsRaw = Get-Prop $control 'supportedEffects'
        $effectsIsArray = Test-IsArray $effectsRaw
        $effects = Get-ArrayItems $effectsRaw
        if (-not $effectsIsArray -or $effects.Count -lt 1) { $schemaErrors.Add("${cid}: supportedEffects missing/empty") }
        foreach ($effect in $effects) { if (-not (Test-NonEmptyString $effect)) { $schemaErrors.Add("${cid}: a supportedEffects entry is not a non-empty string") } }
        $requiredParametersRaw = Get-Prop $control 'requiredParameters'
        if (-not (Test-Prop $control 'requiredParameters') -or -not (Test-IsArray $requiredParametersRaw)) { $schemaErrors.Add("${cid}: requiredParameters must be an array") }
        $requiredParameterItems = Get-ArrayItems $requiredParametersRaw
        foreach ($param in $requiredParameterItems) { if ($param -isnot [string]) { $schemaErrors.Add("${cid}: a requiredParameters entry is not a string") } }
        $roleDefinitionIdsRaw = Get-Prop $control 'roleDefinitionIds'
        if (-not (Test-Prop $control 'roleDefinitionIds') -or -not (Test-IsArray $roleDefinitionIdsRaw)) { $schemaErrors.Add("${cid}: roleDefinitionIds must be an array") }
        $roleDefinitionIds = Get-ArrayItems $roleDefinitionIdsRaw
        foreach ($roleId in $roleDefinitionIds) { if ($roleId -isnot [string] -or $roleId -notmatch $guidPattern) { $schemaErrors.Add("${cid}: a roleDefinitionIds entry is not a well-formed bare GUID") } }
        $remediationIdentityRequired = Get-Prop $control 'remediationIdentityRequired'
        if ($remediationIdentityRequired -isnot [bool]) { $schemaErrors.Add("${cid}: remediationIdentityRequired missing/invalid") }
        $hasRolesVary = Test-Prop $control 'rolesVaryByMember'
        $rolesVaryByMember = Get-Prop $control 'rolesVaryByMember'
        if ($hasRolesVary -and $rolesVaryByMember -isnot [bool]) { $schemaErrors.Add("${cid}: rolesVaryByMember must be boolean") }
        $rolesVaryTrue = $hasRolesVary -and ($rolesVaryByMember -eq $true)
        if (($remediationIdentityRequired -eq $true) -and ($roleDefinitionIds.Count -eq 0) -and (-not $rolesVaryTrue)) {
            $schemaErrors.Add("${cid}: remediationIdentityRequired=true without a populated roleDefinitionIds array or rolesVaryByMember=true")
        }
        $dependenciesRaw = Get-Prop $control 'dependencies'
        if (-not (Test-Prop $control 'dependencies') -or -not (Test-IsArray $dependenciesRaw)) { $schemaErrors.Add("${cid}: dependencies must be an array") }
        $dependencyItems = Get-ArrayItems $dependenciesRaw
        foreach ($dependency in $dependencyItems) { if ($dependency -isnot [string] -or $dependency -cnotmatch $idPattern) { $schemaErrors.Add("${cid}: a dependencies entry is not a well-formed control id") } }
        $enforcementPhase = Get-Prop $control 'enforcementPhase'
        if ($phaseEnum -cnotcontains $enforcementPhase) { $schemaErrors.Add("${cid}: undeclared enforcementPhase '$enforcementPhase'") }
        if (-not (Test-NonEmptyString (Get-Prop $control 'evidenceSource'))) { $schemaErrors.Add("${cid}: missing/invalid evidenceSource") }
        $controlNotes = Get-Prop $control 'notes'
        if ((Test-Prop $control 'notes') -and ($controlNotes -isnot [string])) { $schemaErrors.Add("${cid}: notes must be a string") }
    }

    if ($schemaErrors.Count -gt 0) {
        $formattedErrors = ($schemaErrors | ForEach-Object { "  - $_" }) -join "`n"
        Stop-Test "Catalog failed the offline schema-equivalent validation:`n${formattedErrors}"
    }
}

if ($SchemaOnly) {
    Write-Host 'Schema-only validation passed (-SchemaOnly; skipping matrix consistency checks).'
    exit 0
}

Write-Host '10/10 Validate every field represented in the human-readable matrix matches the JSON catalog...'
$matrixText = Get-Content -LiteralPath $MatrixPath -Raw
$jsonCount = $controls.Count
function Get-MatrixMetadata {
    param([string]$Name, [string]$Pattern)
    $matches = [regex]::Matches($matrixText, $Pattern, [System.Text.RegularExpressions.RegexOptions]::Multiline)
    if ($matches.Count -ne 1) {
        Stop-Test "Matrix must contain exactly one '$Name' metadata record in its canonical keyed form (found $($matches.Count))."
    }
    return $matches[0].Groups[1].Value
}
$matrixCatalogVersion = Get-MatrixMetadata 'Catalog version' '^- \*\*Catalog version:\*\* `([^`]+)`\r?$'
$matrixGeneratedOn = Get-MatrixMetadata 'Generated on' '^- \*\*Generated on:\*\* `([^`]+)`\r?$'
$matrixSourceIssue = Get-MatrixMetadata 'Source issue' '^- \*\*Source issue:\*\* (https://[^\s\r]+)\r?$'
$matrixCount = [int](Get-MatrixMetadata 'Total control records' '^- \*\*Total control records:\*\* ([0-9]+)\r?$')
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

# Bidirectional ID-set comparison: parse the actual "| REQ-XXX-NN | ..." table
# rows present in the matrix (not merely search for expected rows), so that a
# stale, duplicated, or otherwise-untracked extra row is caught even though it
# never matches any JSON-derived expected string.
$matrixIdMatches = [regex]::Matches($matrixText, '(?m)^\| (REQ-[A-Z]+-[0-9]{2}) \|')
$matrixIds = @($matrixIdMatches | ForEach-Object { $_.Groups[1].Value })
$uniqueMatrixIds = @($matrixIds | Select-Object -Unique)
if ($uniqueMatrixIds.Count -ne $matrixIds.Count) {
    $duplicates = @($matrixIds | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    Stop-Test "The matrix contains one or more duplicate control ID rows: $($duplicates -join ' ')"
}
$jsonIds = @($controls | ForEach-Object { $_.id })
$extraIds = @($uniqueMatrixIds | Where-Object { $jsonIds -notcontains $_ })
$missingIds = @($jsonIds | Where-Object { $uniqueMatrixIds -notcontains $_ })
if ($extraIds.Count -gt 0) { Stop-Test "The matrix contains stale/extra control ID row(s) not present in the JSON catalog: $($extraIds -join ' ')" }
if ($missingIds.Count -gt 0) { Stop-Test "The matrix is missing control ID row(s) present in the JSON catalog: $($missingIds -join ' ')" }

# Validate catalog-level metadata (version/generated date/source issue) is
# represented in the matrix header, not just the per-row content above.
$catalogVersion = $catalog.catalogVersion
$generatedOnValue = $catalog.generatedOn
$sourceIssueValue = $catalog.sourceIssue
if ($matrixCatalogVersion -ne $catalogVersion) { Stop-Test "Matrix Catalog version metadata ($matrixCatalogVersion) does not match catalogVersion ($catalogVersion)." }
if ($matrixGeneratedOn -ne $generatedOnValue) { Stop-Test "Matrix Generated on metadata ($matrixGeneratedOn) does not match generatedOn ($generatedOnValue)." }
if ($matrixSourceIssue -ne $sourceIssueValue) { Stop-Test "Matrix Source issue metadata ($matrixSourceIssue) does not match sourceIssue ($sourceIssueValue)." }

# Every declared classification value must be represented in the classification legend.
foreach ($classificationValue in $classifications) {
    if (-not $matrixText.Contains("``$classificationValue``")) {
        Stop-Test "Classification legend in the matrix is missing the declared classification value: $classificationValue."
    }
}

function Get-NormalizedText {
    param([string]$Text)
    return ([regex]::Replace($Text, '[\s`]+', ' ')).Trim()
}
# Overlap-notes pairs are validated structurally and bidirectionally below
# (exact {topic, note} multiset comparison), which subsumes a one-way
# substring check and additionally catches a stale topic reusing an existing
# note, or a topic whose note text was changed in only one place.

# --- Structural bidirectional checks: domain sections, cautions, overlap topics ---
# Unlike the substring checks above (which only prove every JSON entry is
# represented somewhere in the matrix), the checks below parse the matrix's
# own structure (headings, bullet lists) as real data and compare it against
# the JSON catalog as an exact, keyed set in both directions -- so a changed
# `domain`, or an extra/stale caution or overlap-topic bullet added directly to
# the matrix, is caught even though it never produces a literal-string diff
# against an "expected" value derived only from the JSON.
function Get-ExpectedHeading {
    param([string]$Domain)
    switch ($Domain) {
        'identity' { return 'Identity (Entra Conditional Access, PIM, access review)' }
        'deployment-restrictions' { return 'Deployment restrictions' }
        'tagging' { return 'Tagging' }
        'network-security' { return 'Network security' }
        'logging' { return 'Logging' }
        'data-protection' { return 'Data protection' }
        'security-baseline' { return 'MCSB / CIS / NIST / service baselines' }
        'defender-for-cloud' { return 'Defender for Cloud' }
        'backup' { return 'Backup' }
        'nerc-cip' { return 'NERC CIP' }
        default { return $null }
    }
}

# Parse "id -> heading" pairs for every control row actually present in the
# matrix (heading is whatever "## " section the row currently falls under).
$matrixLines = $matrixText -split "`r?`n"
$idToHeading = @{}
$currentHeading = ''
foreach ($line in $matrixLines) {
    if ($line -match '^## (.+)$') {
        $currentHeading = $Matches[1]
        continue
    }
    if ($line -match '^\| (REQ-[A-Z]+-[0-9]{2}) \|') {
        $idToHeading[$Matches[1]] = $currentHeading
    }
}

# Compare the exact multiset of headings between the classification legend and
# overlap-notes section with the catalog's known domains. Empty, duplicate,
# extra, stale, and missing domain sections all fail.
$matrixDomainHeadings = New-Object System.Collections.Generic.List[string]
$inDomains = $false
foreach ($line in $matrixLines) {
    if ($line -eq '## Classification legend') { $inDomains = $true; continue }
    if ($inDomains -and $line -match '^## Overlap notes') { break }
    if ($inDomains -and $line -match '^##\s*$') { $matrixDomainHeadings.Add('<EMPTY>'); continue }
    if ($inDomains -and $line -match '^## (.+)$') { $matrixDomainHeadings.Add($Matches[1]) }
}
$expectedDomainHeadings = New-Object System.Collections.Generic.List[string]
$seenDomains = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($control in $controls) {
    if ($seenDomains.Add([string]$control.domain)) {
        $heading = Get-ExpectedHeading $control.domain
        if ([string]::IsNullOrEmpty($heading)) {
            Stop-Test "Catalog declares an unrecognized domain `"$($control.domain)`" with no known matrix heading mapping."
        }
        $expectedDomainHeadings.Add($heading)
    }
}
$sortedMatrixDomainHeadings = @($matrixDomainHeadings | Sort-Object)
$sortedExpectedDomainHeadings = @($expectedDomainHeadings | Sort-Object)
$domainHeadingDiff = Compare-Object -ReferenceObject $sortedExpectedDomainHeadings -DifferenceObject $sortedMatrixDomainHeadings
if ($domainHeadingDiff) {
    Stop-Test "Matrix domain headings do not exactly match catalog domains (extra, empty, duplicate, stale, or missing section). Matrix: [$($sortedMatrixDomainHeadings -join ';')] Expected: [$($sortedExpectedDomainHeadings -join ';')]"
}
foreach ($control in $controls) {
    $expectedHeading = Get-ExpectedHeading $control.domain
    if ([string]::IsNullOrEmpty($expectedHeading)) {
        Stop-Test "Control $($control.id) declares an unrecognized domain `"$($control.domain)`" with no known matrix heading mapping."
    }
    $actualHeading = $idToHeading[$control.id]
    if ($actualHeading -ne $expectedHeading) {
        Stop-Test "Control $($control.id) has domain `"$($control.domain)`" (expected matrix heading `"$expectedHeading`") but its matrix row is under heading `"$actualHeading`"."
    }
}

# Exact bidirectional set comparison of "Important caveats" bullets against
# JSON .cautions[] (normalized so markdown emphasis/backticks don't cause
# false mismatches), catching both a missing caution and an extra/stale one.
$matrixCautionBullets = New-Object System.Collections.Generic.List[string]
$inCaveats = $false
foreach ($line in $matrixLines) {
    if ($line -match '^## Important caveats$') { $inCaveats = $true; continue }
    if ($inCaveats -and $line -match '^## ') { break }
    if ($inCaveats -and $line -match '^- (.+)$') { $matrixCautionBullets.Add($Matches[1]) }
}
$normalizedMatrixCautions = @($matrixCautionBullets | ForEach-Object { Get-NormalizedText $_ } | Sort-Object)
$normalizedJsonCautions = @(@($catalog.cautions) | ForEach-Object { Get-NormalizedText $_ } | Sort-Object)
$cautionsDiff = Compare-Object -ReferenceObject $normalizedJsonCautions -DifferenceObject $normalizedMatrixCautions
if ($cautionsDiff) {
    Stop-Test "The matrix's `"Important caveats`" bullets do not exactly match the JSON catalog's .cautions[] (an entry was added, removed, or reworded in only one place). Matrix: [$($normalizedMatrixCautions -join ';')] JSON: [$($normalizedJsonCautions -join ';')]"
}

# Exact bidirectional multiset comparison of Overlap-notes {topic, note}
# pairs: parse the "- **Topic:** note" bullets under "## Overlap notes" and
# compare the complete (topic, note) pair set (not merely the topic set with
# a separate one-way note substring search) against JSON .overlapNotes[]. A
# multiset (not de-duplicated) comparison is used so a duplicated bullet in
# either the matrix or the JSON is also caught. This catches a matrix bullet
# that reuses an existing topic but carries stale/reworded note text, which a
# topic-only comparison would miss.
$matrixOverlapPairs = New-Object System.Collections.Generic.List[string]
$inOverlap = $false
foreach ($line in $matrixLines) {
    if ($line -match '^## Overlap notes') { $inOverlap = $true; continue }
    if ($inOverlap -and $line -match '^## ') { break }
    if ($inOverlap -and $line -match '^- \*\*(.+?):\*\*\s*(.*)$') {
        $normalizedTopic = Get-NormalizedText $Matches[1]
        $normalizedNote = Get-NormalizedText $Matches[2]
        $matrixOverlapPairs.Add("$normalizedTopic`t$normalizedNote")
    }
}
$sortedMatrixOverlapPairs = @($matrixOverlapPairs | Sort-Object)
$sortedJsonOverlapPairs = @(@($catalog.overlapNotes) | ForEach-Object { "$(Get-NormalizedText $_.topic)`t$(Get-NormalizedText $_.note)" } | Sort-Object)
$overlapPairsDiff = Compare-Object -ReferenceObject $sortedJsonOverlapPairs -DifferenceObject $sortedMatrixOverlapPairs
if ($overlapPairsDiff) {
    Stop-Test "The matrix's `"Overlap notes`" {topic, note} bullets do not exactly match the JSON catalog's .overlapNotes[] (a topic/note pair was added, removed, or reworded in only one place). Matrix pairs: [$($sortedMatrixOverlapPairs -join ';')] JSON pairs: [$($sortedJsonOverlapPairs -join ';')]"
}

Write-Host ''
Write-Host 'Control catalog validation passed.'
