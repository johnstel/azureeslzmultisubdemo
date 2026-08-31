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

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir
if ([string]::IsNullOrWhiteSpace($Path)) {
    $IdentityDir = Join-Path $ProjectDir 'identity'
} else {
    $IdentityDir = (Resolve-Path -LiteralPath $Path).ProviderPath
}

function Stop-Validation {
    param([string]$Message)
    throw $Message
}

if ($Mode -eq 'populated') {
    $trackedIdentityDir = (Resolve-Path -LiteralPath (Join-Path $ProjectDir 'identity')).ProviderPath
    if ($IdentityDir -eq $trackedIdentityDir -or $IdentityDir.StartsWith($trackedIdentityDir + [System.IO.Path]::DirectorySeparatorChar)) {
        Stop-Validation '-Mode populated must validate a path outside the tracked identity/ folder so real object IDs are never committed. Copy identity/ to a local, gitignored location first.'
    }
}

$knownIdsPath = Join-Path $ProjectDir 'identity/schema/known-entra-ids.json'
if (-not (Test-Path -LiteralPath $knownIdsPath)) { Stop-Validation "Missing reference file: $knownIdsPath" }
$knownIds = Get-Content -LiteralPath $knownIdsPath -Raw | ConvertFrom-Json

$guidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
function Test-Guid {
    param([string]$Value)
    return $Value -match $guidPattern
}

$phishingResistantId = $knownIds.authenticationStrengthPolicyIds.'Phishing-resistant MFA'
$azureMgmtAppId = $knownIds.wellKnownServicePrincipalAppIds.'Microsoft Azure Management'
$knownRoleIds = @($knownIds.directoryRoleTemplateIds.PSObject.Properties | ForEach-Object { $_.Value })
$knownAuthStrengthIds = @($knownIds.authenticationStrengthPolicyIds.PSObject.Properties | ForEach-Object { $_.Value })

function Test-EmergencyPlaceholder {
    param($Policy, [string]$Name)

    if ($Policy.emergencyAccessExclusion.required -ne $true) {
        Stop-Validation "$Name must declare emergencyAccessExclusion.required=true."
    }

    $placeholderValue = $Policy.emergencyAccessExclusion.placeholder
    if ($Mode -eq 'template') {
        if ($placeholderValue -notmatch '^REPLACE_WITH_.+$') {
            Stop-Validation "$Name emergencyAccessExclusion.placeholder must be an unpopulated REPLACE_WITH_* input in template mode, found '$placeholderValue'."
        }
    } else {
        if ($placeholderValue -match '^REPLACE_WITH_.+$') {
            Stop-Validation "$Name emergencyAccessExclusion.placeholder still contains an unpopulated REPLACE_WITH_* value; replace it with a real object ID before populated-mode validation."
        }
        if (-not (Test-Guid $placeholderValue)) {
            Stop-Validation "$Name emergencyAccessExclusion.placeholder must be a valid object ID (GUID) in populated mode, found '$placeholderValue'."
        }
    }
    return $placeholderValue
}

function Test-PlaceholderExcludedFrom {
    param([string[]]$ArrayValues, [string]$PlaceholderValue, [string]$Name, [string]$FieldName)

    if ($ArrayValues.Count -eq 0) {
        Stop-Validation "$Name $FieldName must not be empty; the emergency-access placeholder must be excluded."
    }
    if (-not ($ArrayValues -contains $PlaceholderValue)) {
        Stop-Validation "$Name $FieldName must include the declared emergencyAccessExclusion.placeholder."
    }
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
    if ($actualJson -ne $expectedJson) {
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

$caTemplates = @(Get-ChildItem -LiteralPath $caDir -Filter '*.template.json')
if ($caTemplates.Count -eq 0) { Stop-Validation "No Conditional Access templates found in $caDir" }

foreach ($templateFile in $caTemplates) {
    $name = $templateFile.Name
    $policy = Get-Content -LiteralPath $templateFile.FullName -Raw | ConvertFrom-Json

    if ($policy.state -ne 'enabledForReportingButNotEnforced') {
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
            if ($value -notin @('All', 'None', 'GuestsOrExternalUsers') -and -not (Test-Guid $value)) {
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
            if ($knownRoleIds -notcontains $value) {
                Stop-Validation "$name conditions.users.includeRoles entry '$value' is not a known directory role template ID from identity/schema/known-entra-ids.json."
            }
        }
    }

    $applications = @($policy.conditions.applications.includeApplications)
    if ($applications.Count -eq 0) { Stop-Validation "$name conditions.applications.includeApplications must not be empty." }

    $clientAppTypes = @($policy.conditions.clientAppTypes)
    if ($clientAppTypes.Count -eq 0) { Stop-Validation "$name conditions.clientAppTypes must not be empty." }

    # Grant controls: authenticationStrength must be modeled as its own
    # Graph relationship object (id + displayName), never as a
    # builtInControls string entry.
    $builtInControlsPresent = $null -ne $policy.grantControls.PSObject.Properties['builtInControls']
    $authStrengthPresent = $null -ne $policy.grantControls.PSObject.Properties['authenticationStrength']
    $builtInControls = @()
    if ($builtInControlsPresent) { $builtInControls = @($policy.grantControls.builtInControls) }
    if ($builtInControls -contains 'authenticationStrength') {
        Stop-Validation "$name grantControls.builtInControls must not contain 'authenticationStrength'; use the grantControls.authenticationStrength relationship object instead."
    }
    if (-not $builtInControlsPresent -and -not $authStrengthPresent) {
        Stop-Validation "$name grantControls must declare builtInControls or authenticationStrength."
    }
    $authStrengthId = $null
    if ($authStrengthPresent) {
        $authStrengthId = $policy.grantControls.authenticationStrength.id
        if ($knownAuthStrengthIds -notcontains $authStrengthId) {
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
            Assert-AbsentOrEmpty -ActualValues $includeUsers -Name $name -Description 'conditions.users.includeUsers'
            Assert-ExactStringArray -ActualValues $applications -ExpectedValues @('All') -Name $name -Description 'conditions.applications.includeApplications'
            Assert-ExactStringArray -ActualValues $clientAppTypes -ExpectedValues @('all') -Name $name -Description 'conditions.clientAppTypes'
            if (-not $authStrengthPresent) { Stop-Validation "$name grantControls.authenticationStrength must be set." }
            if ($authStrengthId -ne $phishingResistantId) {
                Stop-Validation "$name grantControls.authenticationStrength.id must reference the built-in Phishing-resistant MFA policy ($phishingResistantId)."
            }
            Assert-AbsentOrEmpty -ActualValues $builtInControls -Name $name -Description 'grantControls.builtInControls (only grantControls.authenticationStrength may satisfy this policy, so an OR-combined builtInControls entry cannot weaken the phishing-resistant requirement)'
        }
        'ca-azure-mgmt-mfa.template.json' {
            if (-not $includeUsersPresent) { Stop-Validation "$name must scope the subject to all users with conditions.users.includeUsers." }
            Assert-ExactStringArray -ActualValues $includeUsers -ExpectedValues @('All') -Name $name -Description 'conditions.users.includeUsers'
            Assert-AbsentOrEmpty -ActualValues $includeRoles -Name $name -Description 'conditions.users.includeRoles'
            Assert-ExactStringArray -ActualValues $applications -ExpectedValues @($azureMgmtAppId) -Name $name -Description 'conditions.applications.includeApplications'
            Assert-ExactStringArray -ActualValues $clientAppTypes -ExpectedValues @('all') -Name $name -Description 'conditions.clientAppTypes'
            Assert-ExactStringArray -ActualValues $builtInControls -ExpectedValues @('mfa') -Name $name -Description 'grantControls.builtInControls'
            if ($authStrengthPresent) { Stop-Validation "$name grantControls.authenticationStrength must be absent." }
        }
        'ca-block-legacy-auth.template.json' {
            if (-not $includeUsersPresent) { Stop-Validation "$name must scope the subject to all users with conditions.users.includeUsers." }
            Assert-ExactStringArray -ActualValues $includeUsers -ExpectedValues @('All') -Name $name -Description 'conditions.users.includeUsers'
            Assert-AbsentOrEmpty -ActualValues $includeRoles -Name $name -Description 'conditions.users.includeRoles'
            Assert-ExactStringArray -ActualValues $applications -ExpectedValues @('All') -Name $name -Description 'conditions.applications.includeApplications'
            Assert-ExactStringArray -ActualValues $clientAppTypes -ExpectedValues @('exchangeActiveSync', 'other') -Name $name -Description 'conditions.clientAppTypes'
            Assert-ExactStringArray -ActualValues $builtInControls -ExpectedValues @('block') -Name $name -Description 'grantControls.builtInControls'
            if ($authStrengthPresent) { Stop-Validation "$name grantControls.authenticationStrength must be absent." }
        }
    }

    if ([string]::IsNullOrWhiteSpace($policy.notes)) {
        Stop-Validation "$name must document rollout/licensing notes."
    }
}
Write-Host "Conditional Access templates validated (mode=$Mode): $($caTemplates.Count)"

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

    # Each approver identifier follows the same mode-aware placeholder rules
    # as emergencyAccessExclusion.placeholder: an unpopulated REPLACE_WITH_*
    # input in template mode, a real object ID (GUID) in populated mode.
    foreach ($approver in $approvers) {
        if ($Mode -eq 'template') {
            if ($approver -notmatch '^REPLACE_WITH_.+$') {
                Stop-Validation "$name activation.approvers entry '$approver' must be an unpopulated REPLACE_WITH_* input in template mode."
            }
        } else {
            if ($approver -match '^REPLACE_WITH_.+$') {
                Stop-Validation "$name activation.approvers entry '$approver' still contains an unpopulated REPLACE_WITH_* value; replace it with a real object ID before populated-mode validation."
            }
            if (-not (Test-Guid $approver)) {
                Stop-Validation "$name activation.approvers entry '$approver' must be a valid object ID (GUID) in populated mode, found '$approver'."
            }
        }
    }

    $duration = $policy.activation.maximumActivationDurationHours
    if ($duration -lt 1 -or $duration -gt 8) {
        Stop-Validation "$name activation.maximumActivationDurationHours must be an integer between 1 and 8, found '$duration'."
    }

    if ([string]::IsNullOrWhiteSpace($policy.activation.authenticationContext)) {
        Stop-Validation "$name activation.authenticationContext must be set."
    }

    Test-EmergencyPlaceholder -Policy $policy -Name $name | Out-Null

    if ([string]::IsNullOrWhiteSpace($policy.notes)) {
        Stop-Validation "$name must document rollout/licensing notes."
    }
}
Write-Host "PIM activation templates validated (mode=$Mode): $($pimTemplates.Count)"

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
            if ($allowedGuids -notcontains $match.Value) {
                Stop-Validation "A tenant-specific GUID ($($match.Value)) was found in $($jsonFile.Name). Replace it with a REPLACE_WITH_* placeholder, or add it to identity/schema/known-entra-ids.json only if it is a public Microsoft constant."
            }
        }
    }
}

Write-Host ''
Write-Host "Identity artifact validation passed (mode=$Mode): $($caTemplates.Count) Conditional Access template(s), $($pimTemplates.Count) PIM template(s)."
