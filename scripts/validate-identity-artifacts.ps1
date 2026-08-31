[CmdletBinding()]
param(
    [ValidateSet('template', 'populated')]
    [string]$Mode = 'template',

    [string]$Path
)

# Static, offline validation of the Entra Conditional Access and PIM demo
# artifacts. This script never contacts Microsoft Graph or any tenant; it
# only inspects JSON files on local disk.
#
# -Mode template (default): validates the committed templates under
#   identity/. Every emergencyAccessExclusion.placeholder (and every
#   excludeGroups entry that must equal it) must still be an unpopulated
#   REPLACE_WITH_* value, and no tenant-specific GUID may appear anywhere
#   (only the public, well-known Microsoft constants in
#   identity/schema/known-entra-ids.json are allowed).
# -Mode populated: validates a local, gitignored copy of these artifacts
#   after an operator has replaced every REPLACE_WITH_* placeholder with a
#   real object ID, in preparation for a future, separately gated apply
#   workflow. Every placeholder must then be a syntactically valid GUID, and
#   the tenant-GUID allowlist check is skipped because populated input is
#   expected to contain real tenant identifiers. -Path must point away from
#   the tracked identity/ folder in this mode.
# -Path: directory containing conditional-access/ and pim/ subdirectories to
#   validate. Defaults to <repo>/identity.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Resolves a path to its final filesystem target: normalizes '.'/'..'
# segments (like Resolve-Path) AND walks every path component, dereferencing
# any symbolic link or (on Windows) reparse-point junction encountered along
# the way to its ultimate target. This is the PowerShell equivalent of
# Bash's `cd "$dir" && pwd -P`, which the containment check below depends on
# to prevent an alias (lexical or filesystem-level) from bypassing the
# tracked identity/ folder guard in -Mode populated.
#
# A single left-to-right pass is not sufficient: once a link is dereferenced,
# its target may itself contain further symlinked components anywhere along
# its own path (for example identity-alias -> /tmp/repo-alias/identity where
# /tmp/repo-alias is itself a symlink to the repo root). Each outer iteration
# below re-walks the *entire* current path from its root and, on finding the
# first link, splices the resolved target in place of the walked prefix and
# restarts the walk from scratch; this repeats until a full pass finds no
# remaining links. A bounded iteration count guards against a symlink cycle.
function Resolve-FinalTarget {
    param([string]$Path)
    $current = (Resolve-Path -LiteralPath $Path).ProviderPath
    $maxIterations = 64
    for ($iteration = 0; $iteration -lt $maxIterations; $iteration++) {
        $root = [System.IO.Path]::GetPathRoot($current)
        $parts = $current.Substring($root.Length).Split(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.StringSplitOptions]::RemoveEmptyEntries)
        $walked = $root.TrimEnd([System.IO.Path]::DirectorySeparatorChar)
        if ([string]::IsNullOrEmpty($walked)) { $walked = [string][System.IO.Path]::DirectorySeparatorChar }
        $linkIndex = -1
        $linkTarget = $null
        for ($i = 0; $i -lt $parts.Length; $i++) {
            $walked = Join-Path $walked $parts[$i]
            $item = Get-Item -LiteralPath $walked -Force
            if ($item.LinkType) {
                # ResolveLinkTarget($true) follows the entire link chain
                # (symlink-to-symlink, or a junction) to its final target.
                $linkIndex = $i
                $linkTarget = $item.ResolveLinkTarget($true).FullName
                break
            }
        }
        if ($linkIndex -lt 0) {
            # A full pass found no links left to resolve: fully resolved.
            return $current
        }
        if ($linkIndex -eq $parts.Length - 1) {
            $current = $linkTarget
        } else {
            $remaining = ($parts[($linkIndex + 1)..($parts.Length - 1)]) -join [System.IO.Path]::DirectorySeparatorChar
            $current = Join-Path $linkTarget $remaining
        }
    }
    throw "Resolve-FinalTarget: too many levels of symbolic links resolving '$Path' (possible link cycle)."
}

# Resolve this script file itself to its final filesystem target before
# deriving the repository root. If the validator file is invoked through an
# external symlink/junction (or a chain of them), $MyInvocation.MyCommand.Path
# is that external path; naively taking Split-Path -Parent of it would
# derive $ScriptDir/$ProjectDir from the caller-controlled link's parent
# directory, and the "trusted" canonical schemas/known-entra-ids.json below
# would then be loaded from that external tree -- silently reintroducing the
# caller-controlled-schema bypass this validator is designed to prevent.
# Resolve-FinalTarget already fully dereferences chained/intermediate links
# (including within a resolved target's own path), so it is reused here for
# the script's own path, not just for artifact files further down.
$ScriptPath = Resolve-FinalTarget -Path $MyInvocation.MyCommand.Path
$ScriptDir = Split-Path -Parent $ScriptPath
$ProjectDir = Split-Path -Parent $ScriptDir

if ([string]::IsNullOrWhiteSpace($Path)) {
    # Always resolve the default path through Resolve-FinalTarget too, not
    # just an explicitly-supplied -Path: if this script itself is invoked
    # through a symlinked/junctioned repository checkout, $ProjectDir (and
    # thus this default) would otherwise retain that unresolved alias while
    # $trackedIdentityDir below is fully resolved, causing the two operands
    # to differ in representation even when they name the same directory
    # and letting the containment check below be bypassed.
    $IdentityDir = Resolve-FinalTarget -Path (Join-Path $ProjectDir 'identity')
} else {
    $IdentityDir = Resolve-FinalTarget -Path $Path
}

function Stop-Validation {
    param([string]$Message)
    throw $Message
}

# Detects whether the filesystem location containing $CanonicalPath is
# case-insensitive, by checking whether a case-swapped variant of its final
# path component also resolves to an existing entry there. This probes the
# actual filesystem rather than assuming case (in)sensitivity from
# $IsWindows/$IsMacOS/$IsLinux: macOS ships case-insensitive-by-default
# APFS but can be reformatted case-sensitive, Windows can host case-
# sensitive directories (WSL interop, per-directory case-sensitivity since
# Windows 10), and Linux can mount case-insensitive volumes (exFAT, some
# SMB/NTFS mounts).
function Test-FilesystemCaseInsensitive {
    param([string]$CanonicalPath)
    $parent = Split-Path -Path $CanonicalPath -Parent
    $leaf = Split-Path -Path $CanonicalPath -Leaf
    $flippedLeaf = -join ($leaf.ToCharArray() | ForEach-Object {
        if ([System.Char]::IsUpper($_)) { [System.Char]::ToLowerInvariant($_) }
        elseif ([System.Char]::IsLower($_)) { [System.Char]::ToUpperInvariant($_) }
        else { $_ }
    })
    if ($flippedLeaf -ceq $leaf) {
        # No alphabetic characters to swap-case with: nothing usable to
        # probe. Conservatively report case-insensitive so the stricter
        # fold-case comparison is used rather than silently skipping it.
        return $true
    }
    return (Test-Path -LiteralPath (Join-Path $parent $flippedLeaf))
}

if ($Mode -eq 'populated') {
    $trackedIdentityDir = Resolve-FinalTarget -Path (Join-Path $ProjectDir 'identity')
    $caseInsensitive = Test-FilesystemCaseInsensitive -CanonicalPath $trackedIdentityDir
    $pathComparison = if ($caseInsensitive) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }

    # Fails if $ResolvedPath (already dereferenced via Resolve-FinalTarget) is
    # the tracked identity/ folder, or lies inside it. Called not just for
    # the requested -Path root, but for every subdirectory
    # (conditional-access/, pim/) and individual template file read from it
    # in populated mode: the root can legitimately resolve outside identity/
    # while a nested directory or file underneath it is itself a
    # symlink/junction back into the tracked, unpopulated tree, which would
    # otherwise let populated-mode validation silently read tracked
    # templates.
    function Assert-OutsideTrackedIdentity {
        param([string]$ResolvedPath, [string]$Description)
        $isSameDir = [string]::Equals($ResolvedPath, $trackedIdentityDir, $pathComparison)
        $isDescendant = $ResolvedPath.StartsWith($trackedIdentityDir + [System.IO.Path]::DirectorySeparatorChar, $pathComparison)
        if ($isSameDir -or $isDescendant) {
            Stop-Validation "-Mode populated must validate $Description outside the tracked identity/ folder so real object IDs are never committed. Copy identity/ to a local, gitignored location first."
        }
    }

    Assert-OutsideTrackedIdentity -ResolvedPath $IdentityDir -Description 'the requested -Path'
}


# Schema/reference files are always read from the tracked repository's
# canonical identity/schema/ tree -- deliberately independent of the
# caller-supplied -Path/$IdentityDir. The validators are the trust anchor
# for what a compliant artifact looks like, so accepting a caller-supplied
# schema would let external input redefine the very rules used to validate
# it. Any schema/ directory or files under a populated -Path are ignored.
$knownIdsPath = Join-Path $ProjectDir 'identity/schema/known-entra-ids.json'
if (-not (Test-Path -LiteralPath $knownIdsPath)) { Stop-Validation "Missing reference file: $knownIdsPath" }
$knownIds = Get-Content -LiteralPath $knownIdsPath -Raw | ConvertFrom-Json

$caSchemaPath = Join-Path $ProjectDir 'identity/schema/conditional-access-policy.schema.json'
$pimSchemaPath = Join-Path $ProjectDir 'identity/schema/pim-activation-policy.schema.json'
if (-not (Test-Path -LiteralPath $caSchemaPath)) { Stop-Validation "Missing reference file: $caSchemaPath" }
if (-not (Test-Path -LiteralPath $pimSchemaPath)) { Stop-Validation "Missing reference file: $pimSchemaPath" }

$caSchemaJson = Get-Content -LiteralPath $caSchemaPath -Raw
$pimSchemaJson = Get-Content -LiteralPath $pimSchemaPath -Raw

# Enforces the full JSON Schema (additionalProperties: false, type/pattern/
# enum/const, $ref, oneOf/anyOf/not, etc.) using PowerShell's built-in
# Test-Json cmdlet (Microsoft.PowerShell.Utility, no new tool/network
# dependency). This is a structural safety net alongside -- not a
# replacement for -- the mode-specific and cross-artifact semantic checks
# elsewhere in this script, which JSON Schema alone cannot express.
function Test-JsonSchemaCompliance {
    param([string]$Json, [string]$SchemaJson, [string]$Name, [string]$SchemaFileName)
    $errorMessages = @()
    $isValid = Test-Json -Json $Json -Schema $SchemaJson -ErrorVariable schemaErrors -ErrorAction SilentlyContinue
    if (-not $isValid) {
        foreach ($schemaError in $schemaErrors) { $errorMessages += "  - $($schemaError.Exception.Message)" }
        Stop-Validation "$Name failed JSON Schema validation ($SchemaFileName):`n$($errorMessages -join "`n")"
    }
}

$guidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
function Test-Guid {
    param([string]$Value)
    return $Value -match $guidPattern
}

$phishingResistantId = $knownIds.authenticationStrengthPolicyIds.'Phishing-resistant MFA'
$azureMgmtAppId = $knownIds.wellKnownServicePrincipalAppIds.'Microsoft Azure Management'
$knownRoleIds = @($knownIds.directoryRoleTemplateIds.PSObject.Properties | ForEach-Object { $_.Value })
$knownAuthStrengthIds = @($knownIds.authenticationStrengthPolicyIds.PSObject.Properties | ForEach-Object { $_.Value })
$knownAuthContextIds = @($knownIds.authenticationContextClassReferenceIds.PSObject.Properties | Where-Object { $_.Name -ne '$comment' } | ForEach-Object { $_.Value })
$authContextPattern = '^c([1-9]|1[0-9]|2[0-5])$'

function Test-EmergencyPlaceholder {
    param($Policy, [string]$Name)

    if ($Policy.emergencyAccessExclusion.required -ne $true) {
        Stop-Validation "$Name must declare emergencyAccessExclusion.required=true."
    }

    $placeholderValue = $Policy.emergencyAccessExclusion.placeholder
    if ($Mode -eq 'template') {
        if ($placeholderValue -cnotmatch '^REPLACE_WITH_.+$') {
            Stop-Validation "$Name emergencyAccessExclusion.placeholder must be an unpopulated REPLACE_WITH_* input in template mode, found '$placeholderValue'."
        }
    } else {
        if ($placeholderValue -cmatch '^REPLACE_WITH_.+$') {
            Stop-Validation "$Name emergencyAccessExclusion.placeholder still contains an unpopulated REPLACE_WITH_* value; replace it with a real object ID before populated-mode validation."
        }
        if (-not (Test-Guid $placeholderValue)) {
            Stop-Validation "$Name emergencyAccessExclusion.placeholder must be a valid object ID (GUID) in populated mode, found '$placeholderValue'."
        }
    }
    return $placeholderValue
}

# Confirms the given array (e.g. conditions.users.excludeGroups) equals
# *exactly* the single-element set containing the placeholder. This is an
# exact match, not a containment check: an arbitrary extra excludeGroups
# entry (beyond the one declared emergency-access placeholder) must fail, so
# a template cannot silently exclude additional, undeclared groups from a
# report-only safety control.
function Test-PlaceholderExcludedFrom {
    param([string[]]$ArrayValues, [string]$PlaceholderValue, [string]$Name, [string]$FieldName)

    Assert-ExactStringArray -ActualValues $ArrayValues -ExpectedValues @($PlaceholderValue) -Name $Name -Description $FieldName
}

# Compares the given array (sorted) against the sorted set of expected
# string values. Used to enforce exact (not merely containment) subject/
# application/client-type/grant-control semantics for each named policy, so
# a template cannot be silently broadened (e.g. an extra application, an
# added client type, or an additional grant control loosening an
# OR-combined requirement).
function Assert-ExactStringArray {
    param([string[]]$ActualValues, [string[]]$ExpectedValues, [string]$Name, [string]$Description)

    $actualSorted = @($ActualValues | Sort-Object)
    $expectedSorted = @($ExpectedValues | Sort-Object)
    $actualJson = ($actualSorted | ConvertTo-Json -Compress -AsArray)
    $expectedJson = ($expectedSorted | ConvertTo-Json -Compress -AsArray)
    if ($actualJson -cne $expectedJson) {
        Stop-Validation "$Name $Description must equal exactly $expectedJson (found $actualJson)."
    }
}

# Confirms the given array is absent/empty. Used to reject broadened grant
# controls or a principal scope mixing includeUsers and includeRoles on a
# policy that must only use one of them.
function Assert-AbsentOrEmpty {
    param([string[]]$ActualValues, [string]$Name, [string]$Description)

    if (@($ActualValues).Count -ne 0) {
        Stop-Validation "$Name $Description must be absent or empty."
    }
}


$caDir = Join-Path $IdentityDir 'conditional-access'
$pimDir = Join-Path $IdentityDir 'pim'

if (-not (Test-Path -LiteralPath $caDir)) { Stop-Validation "Missing directory: $caDir" }
if (-not (Test-Path -LiteralPath $pimDir)) { Stop-Validation "Missing directory: $pimDir" }

if ($Mode -eq 'populated') {
    Assert-OutsideTrackedIdentity -ResolvedPath (Resolve-FinalTarget -Path $caDir) -Description 'the conditional-access/ directory'
    Assert-OutsideTrackedIdentity -ResolvedPath (Resolve-FinalTarget -Path $pimDir) -Description 'the pim/ directory'
}

$caTemplates = @(Get-ChildItem -LiteralPath $caDir -Filter '*.template.json')
if ($caTemplates.Count -eq 0) { Stop-Validation "No Conditional Access templates found in $caDir" }

$caAuthContextValues = @()
foreach ($templateFile in $caTemplates) {
    $name = $templateFile.Name
    if ($Mode -eq 'populated') {
        Assert-OutsideTrackedIdentity -ResolvedPath (Resolve-FinalTarget -Path $templateFile.FullName) -Description $name
    }
    $rawJson = Get-Content -LiteralPath $templateFile.FullName -Raw
    $policy = $rawJson | ConvertFrom-Json
    Test-JsonSchemaCompliance -Json $rawJson -SchemaJson $caSchemaJson -Name $name -SchemaFileName (Split-Path -Leaf $caSchemaPath)

    if ($policy.state -cne 'enabledForReportingButNotEnforced') {
        Stop-Validation "$name must default to state=enabledForReportingButNotEnforced (report-only), found '$($policy.state)'."
    }

    $placeholder = Test-EmergencyPlaceholder -Policy $policy -Name $name
    $excludeGroups = @($policy.conditions.users.excludeGroups)
    Test-PlaceholderExcludedFrom -ArrayValues $excludeGroups -PlaceholderValue $placeholder -Name $name -FieldName 'conditions.users.excludeGroups'

    # Subject (conditions.users): must use Graph-compatible values. Either
    # includeUsers (only 'All', 'None', 'GuestsOrExternalUsers', or a GUID)
    # or includeRoles (only GUID directory role template IDs from the
    # known-IDs allowlist) must be present; free-text role display names
    # such as "Global Administrator" or the non-Graph value "All users" are
    # rejected.
    $includeUsersPresent = $null -ne $policy.conditions.users.PSObject.Properties['includeUsers']
    $includeRolesPresent = $null -ne $policy.conditions.users.PSObject.Properties['includeRoles']
    if (-not $includeUsersPresent -and -not $includeRolesPresent) {
        Stop-Validation "$name conditions.users must declare includeUsers or includeRoles."
    }

    $includeUsers = @()
    if ($includeUsersPresent) {
        $includeUsers = @($policy.conditions.users.includeUsers)
        if ($includeUsers.Count -eq 0) { Stop-Validation "$name conditions.users.includeUsers must not be empty." }
        foreach ($value in $includeUsers) {
            if ($value -cnotin @('All', 'None', 'GuestsOrExternalUsers') -and -not (Test-Guid $value)) {
                Stop-Validation "$name conditions.users.includeUsers entry '$value' must be 'All', 'None', 'GuestsOrExternalUsers', or a user object ID (GUID)."
            }
        }
    }

    $includeRoles = @()
    if ($includeRolesPresent) {
        $includeRoles = @($policy.conditions.users.includeRoles)
        if ($includeRoles.Count -eq 0) { Stop-Validation "$name conditions.users.includeRoles must not be empty." }
        foreach ($value in $includeRoles) {
            if (-not (Test-Guid $value)) {
                Stop-Validation "$name conditions.users.includeRoles entry '$value' must be a directory role template ID (GUID), not a display name or 'All users'."
            }
            if ($knownRoleIds -cnotcontains $value) {
                Stop-Validation "$name conditions.users.includeRoles entry '$value' is not a known directory role template ID from identity/schema/known-entra-ids.json."
            }
        }
    }

    $includeApplicationsPresent = $null -ne $policy.conditions.applications.PSObject.Properties['includeApplications']
    $authContextPresent = $null -ne $policy.conditions.applications.PSObject.Properties['includeAuthenticationContextClassReferences']
    if (-not $includeApplicationsPresent -and -not $authContextPresent) {
        Stop-Validation "$name conditions.applications must declare includeApplications or includeAuthenticationContextClassReferences."
    }
    if ($includeApplicationsPresent -and $authContextPresent) {
        Stop-Validation "$name conditions.applications must not declare both includeApplications and includeAuthenticationContextClassReferences (mutually exclusive Graph target shape)."
    }
    $applications = @()
    if ($includeApplicationsPresent) {
        $applications = @($policy.conditions.applications.includeApplications)
        if ($applications.Count -eq 0) { Stop-Validation "$name conditions.applications.includeApplications must not be empty." }
    }

    $clientAppTypes = @($policy.conditions.clientAppTypes)
    if ($clientAppTypes.Count -eq 0) { Stop-Validation "$name conditions.clientAppTypes must not be empty." }

    # Authentication context class references (optional): if declared,
    # every entry must be a valid Graph 'c1'..'c25' claim id, and known from
    # identity/schema/known-entra-ids.json. Collected across all templates
    # so a coherence check after both directories are processed can confirm
    # every PIM activation.authenticationContext has a matching, declared,
    # report-only Conditional Access policy actually enforcing it.
    $authContexts = @()
    if ($authContextPresent) {
        $authContexts = @($policy.conditions.applications.includeAuthenticationContextClassReferences)
        if ($authContexts.Count -eq 0) {
            Stop-Validation "$name conditions.applications.includeAuthenticationContextClassReferences must not be empty."
        }
        foreach ($value in $authContexts) {
            if ($value -cnotmatch $authContextPattern) {
                Stop-Validation "$name conditions.applications.includeAuthenticationContextClassReferences entry '$value' must be a Graph authenticationContextClassReference id ('c1'..'c25')."
            }
            if ($knownAuthContextIds -cnotcontains $value) {
                Stop-Validation "$name conditions.applications.includeAuthenticationContextClassReferences entry '$value' is not a known authenticationContextClassReference id from identity/schema/known-entra-ids.json."
            }
            $caAuthContextValues += $value
        }
    }

    # Grant controls: authenticationStrength must be modeled as its own
    # Graph relationship object (id + displayName), never as a
    # builtInControls string entry.
    $builtInControlsPresent = $null -ne $policy.grantControls.PSObject.Properties['builtInControls']
    $authStrengthPresent = $null -ne $policy.grantControls.PSObject.Properties['authenticationStrength']
    $builtInControls = @()
    if ($builtInControlsPresent) { $builtInControls = @($policy.grantControls.builtInControls) }
    if ($builtInControls -ccontains 'authenticationStrength') {
        Stop-Validation "$name grantControls.builtInControls must not contain 'authenticationStrength'; use the grantControls.authenticationStrength relationship object instead."
    }
    if (-not $builtInControlsPresent -and -not $authStrengthPresent) {
        Stop-Validation "$name grantControls must declare builtInControls or authenticationStrength."
    }
    $authStrengthId = $null
    if ($authStrengthPresent) {
        $authStrengthId = $policy.grantControls.authenticationStrength.id
        if ($knownAuthStrengthIds -cnotcontains $authStrengthId) {
            Stop-Validation "$name grantControls.authenticationStrength.id '$authStrengthId' is not a known built-in authenticationStrengthPolicy id from identity/schema/known-entra-ids.json."
        }
    }

    # Policy-specific semantic checks, keyed by the known template filenames.
    # Each check is an exact match, not a containment check: extra/broadened
    # principals, applications, client types, or grant controls must fail,
    # not just missing ones, so a template cannot silently widen its blast
    # radius.
    switch ($name) {
        'ca-privileged-role-mfa.template.json' {
            if (-not $includeRolesPresent) { Stop-Validation "$name must scope the subject with conditions.users.includeRoles (privileged directory roles)." }
            Assert-ExactStringArray -ActualValues $includeRoles -ExpectedValues @($knownRoleIds) -Name $name -Description 'conditions.users.includeRoles'
            Assert-AbsentOrEmpty -ActualValues $includeUsers -Name $name -Description 'conditions.users.includeUsers'
            Assert-ExactStringArray -ActualValues $applications -ExpectedValues @('All') -Name $name -Description 'conditions.applications.includeApplications'
            Assert-AbsentOrEmpty -ActualValues $authContexts -Name $name -Description 'conditions.applications.includeAuthenticationContextClassReferences'
            Assert-ExactStringArray -ActualValues $clientAppTypes -ExpectedValues @('all') -Name $name -Description 'conditions.clientAppTypes'
            if (-not $authStrengthPresent) { Stop-Validation "$name grantControls.authenticationStrength must be set." }
            if ($authStrengthId -cne $phishingResistantId) {
                Stop-Validation "$name grantControls.authenticationStrength.id must reference the built-in Phishing-resistant MFA policy ($phishingResistantId)."
            }
            Assert-AbsentOrEmpty -ActualValues $builtInControls -Name $name -Description 'grantControls.builtInControls (only grantControls.authenticationStrength may satisfy this policy, so an OR-combined builtInControls entry cannot weaken the phishing-resistant requirement)'
        }
        'ca-azure-mgmt-mfa.template.json' {
            if (-not $includeUsersPresent) { Stop-Validation "$name must scope the subject to all users with conditions.users.includeUsers." }
            Assert-ExactStringArray -ActualValues $includeUsers -ExpectedValues @('All') -Name $name -Description 'conditions.users.includeUsers'
            Assert-AbsentOrEmpty -ActualValues $includeRoles -Name $name -Description 'conditions.users.includeRoles'
            Assert-ExactStringArray -ActualValues $applications -ExpectedValues @($azureMgmtAppId) -Name $name -Description 'conditions.applications.includeApplications'
            Assert-AbsentOrEmpty -ActualValues $authContexts -Name $name -Description 'conditions.applications.includeAuthenticationContextClassReferences'
            Assert-ExactStringArray -ActualValues $clientAppTypes -ExpectedValues @('all') -Name $name -Description 'conditions.clientAppTypes'
            Assert-ExactStringArray -ActualValues $builtInControls -ExpectedValues @('mfa') -Name $name -Description 'grantControls.builtInControls'
            if ($authStrengthPresent) { Stop-Validation "$name grantControls.authenticationStrength must be absent." }
        }
        'ca-block-legacy-auth.template.json' {
            if (-not $includeUsersPresent) { Stop-Validation "$name must scope the subject to all users with conditions.users.includeUsers." }
            Assert-ExactStringArray -ActualValues $includeUsers -ExpectedValues @('All') -Name $name -Description 'conditions.users.includeUsers'
            Assert-AbsentOrEmpty -ActualValues $includeRoles -Name $name -Description 'conditions.users.includeRoles'
            Assert-ExactStringArray -ActualValues $applications -ExpectedValues @('All') -Name $name -Description 'conditions.applications.includeApplications'
            Assert-AbsentOrEmpty -ActualValues $authContexts -Name $name -Description 'conditions.applications.includeAuthenticationContextClassReferences'
            Assert-ExactStringArray -ActualValues $clientAppTypes -ExpectedValues @('exchangeActiveSync', 'other') -Name $name -Description 'conditions.clientAppTypes'
            Assert-ExactStringArray -ActualValues $builtInControls -ExpectedValues @('block') -Name $name -Description 'grantControls.builtInControls'
            if ($authStrengthPresent) { Stop-Validation "$name grantControls.authenticationStrength must be absent." }
        }
        'ca-pim-activation-mfa.template.json' {
            if (-not $includeUsersPresent) { Stop-Validation "$name must scope the subject to all users with conditions.users.includeUsers." }
            Assert-ExactStringArray -ActualValues $includeUsers -ExpectedValues @('All') -Name $name -Description 'conditions.users.includeUsers'
            Assert-AbsentOrEmpty -ActualValues $includeRoles -Name $name -Description 'conditions.users.includeRoles'
            Assert-AbsentOrEmpty -ActualValues $applications -Name $name -Description 'conditions.applications.includeApplications (this policy must target only the c1 authentication context, not a broader application scope; includeApplications and includeAuthenticationContextClassReferences are mutually exclusive)'
            if (-not $authContextPresent) { Stop-Validation "$name conditions.applications.includeAuthenticationContextClassReferences must be set (this policy exists to enforce the PIM activation authentication context)." }
            Assert-ExactStringArray -ActualValues $authContexts -ExpectedValues @('c1') -Name $name -Description 'conditions.applications.includeAuthenticationContextClassReferences'
            Assert-ExactStringArray -ActualValues $clientAppTypes -ExpectedValues @('all') -Name $name -Description 'conditions.clientAppTypes'
            if (-not $authStrengthPresent) { Stop-Validation "$name grantControls.authenticationStrength must be set." }
            if ($authStrengthId -cne $phishingResistantId) {
                Stop-Validation "$name grantControls.authenticationStrength.id must reference the built-in Phishing-resistant MFA policy ($phishingResistantId)."
            }
            Assert-AbsentOrEmpty -ActualValues $builtInControls -Name $name -Description 'grantControls.builtInControls (only grantControls.authenticationStrength may satisfy this policy, so an OR-combined builtInControls entry cannot weaken the phishing-resistant requirement)'
        }
    }

    if ([string]::IsNullOrWhiteSpace($policy.notes)) {
        Stop-Validation "$name must document rollout/licensing notes."
    }
}
Write-Host "Conditional Access templates validated (mode=$Mode): $($caTemplates.Count)"

$pimTemplates = @(Get-ChildItem -LiteralPath $pimDir -Filter '*.template.json')
if ($pimTemplates.Count -eq 0) { Stop-Validation "No PIM templates found in $pimDir" }

$pimAuthContextValues = @()
foreach ($templateFile in $pimTemplates) {
    $name = $templateFile.Name
    if ($Mode -eq 'populated') {
        Assert-OutsideTrackedIdentity -ResolvedPath (Resolve-FinalTarget -Path $templateFile.FullName) -Description $name
    }
    $rawJson = Get-Content -LiteralPath $templateFile.FullName -Raw
    $policy = $rawJson | ConvertFrom-Json
    Test-JsonSchemaCompliance -Json $rawJson -SchemaJson $pimSchemaJson -Name $name -SchemaFileName (Split-Path -Leaf $pimSchemaPath)

    if ($policy.assignmentType -cne 'eligible') {
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

    # Each approver identifier follows the same mode-aware placeholder rules
    # as emergencyAccessExclusion.placeholder: an unpopulated REPLACE_WITH_*
    # input in template mode, a real object ID (GUID) in populated mode.
    foreach ($approver in $approvers) {
        if ($Mode -eq 'template') {
            if ($approver -cnotmatch '^REPLACE_WITH_.+$') {
                Stop-Validation "$name activation.approvers entry '$approver' must be an unpopulated REPLACE_WITH_* input in template mode."
            }
        } else {
            if ($approver -cmatch '^REPLACE_WITH_.+$') {
                Stop-Validation "$name activation.approvers entry '$approver' still contains an unpopulated REPLACE_WITH_* value; replace it with a real object ID before populated-mode validation."
            }
            if (-not (Test-Guid $approver)) {
                Stop-Validation "$name activation.approvers entry '$approver' must be a valid object ID (GUID) in populated mode, found '$approver'."
            }
        }
    }

    $duration = $policy.activation.maximumActivationDurationHours
    $durationIsInteger = ($duration -is [int]) -or ($duration -is [long]) -or ($duration -is [int32]) -or ($duration -is [int64])
    if (-not $durationIsInteger -or $duration -lt 1 -or $duration -gt 8) {
        Stop-Validation "$name activation.maximumActivationDurationHours must be an integer between 1 and 8, found '$duration'."
    }

    $authContext = $policy.activation.authenticationContext
    if ($authContext -cnotmatch $authContextPattern) {
        Stop-Validation "$name activation.authenticationContext must be a Graph authenticationContextClassReference id ('c1'..'c25'), found '$authContext'."
    }
    if ($knownAuthContextIds -cnotcontains $authContext) {
        Stop-Validation "$name activation.authenticationContext '$authContext' is not a known authenticationContextClassReference id from identity/schema/known-entra-ids.json."
    }
    $pimAuthContextValues += $authContext

    Test-EmergencyPlaceholder -Policy $policy -Name $name | Out-Null

    if ([string]::IsNullOrWhiteSpace($policy.notes)) {
        Stop-Validation "$name must document rollout/licensing notes."
    }
}
Write-Host "PIM activation templates validated (mode=$Mode): $($pimTemplates.Count)"

# Coherence check: every PIM activation.authenticationContext must have a
# matching, declared Conditional Access policy (from the loop above) whose
# conditions.applications.includeAuthenticationContextClassReferences
# actually enforces that context. Otherwise a PIM policy could reference an
# authentication context that no report-only Conditional Access policy in
# this repository enforces, leaving the Graph workflow incoherent.
foreach ($pimContext in $pimAuthContextValues) {
    if ($caAuthContextValues -cnotcontains $pimContext) {
        Stop-Validation "PIM activation.authenticationContext '$pimContext' has no matching Conditional Access policy declaring it in conditions.applications.includeAuthenticationContextClassReferences; add one under $caDir so the PIM activation control is actually enforced."
    }
}

if ($Mode -eq 'template') {
    # Confirm no tenant-specific identifiers (GUIDs) leak into any identity
    # artifact, other than the well-known, publicly documented Microsoft
    # constants in identity/schema/known-entra-ids.json.
    $allowedGuids = @($knownRoleIds) + @($knownAuthStrengthIds) + @($knownIds.wellKnownServicePrincipalAppIds.PSObject.Properties | ForEach-Object { $_.Value })
    $guidScanPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    $jsonFiles = Get-ChildItem -LiteralPath $IdentityDir -Recurse -Filter '*.json'
    foreach ($jsonFile in $jsonFiles) {
        $guidMatches = [regex]::Matches((Get-Content -LiteralPath $jsonFile.FullName -Raw), $guidScanPattern)
        foreach ($match in $guidMatches) {
            if ($allowedGuids -cnotcontains $match.Value) {
                Stop-Validation "A tenant-specific GUID ($($match.Value)) was found in $($jsonFile.Name). Replace it with a REPLACE_WITH_* placeholder, or add it to identity/schema/known-entra-ids.json only if it is a public Microsoft constant."
            }
        }
    }
}

Write-Host ''
Write-Host "Identity artifact validation passed (mode=$Mode): $($caTemplates.Count) Conditional Access template(s), $($pimTemplates.Count) PIM template(s)."
