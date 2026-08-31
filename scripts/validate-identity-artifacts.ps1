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

    if ($includeUsersPresent) {
        $includeUsers = @($policy.conditions.users.includeUsers)
        if ($includeUsers.Count -eq 0) { Stop-Validation "$name conditions.users.includeUsers must not be empty." }
        foreach ($value in $includeUsers) {
            if ($value -notin @('All', 'None', 'GuestsOrExternalUsers') -and -not (Test-Guid $value)) {
                Stop-Validation "$name conditions.users.includeUsers entry '$value' must be 'All', 'None', 'GuestsOrExternalUsers', or a user object ID (GUID)."
            }
        }
    }

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
    switch ($name) {
        'ca-privileged-role-mfa.template.json' {
            if (-not $includeRolesPresent) { Stop-Validation "$name must scope the subject with conditions.users.includeRoles (privileged directory roles)." }
            if ($applications -notcontains 'All') { Stop-Validation "$name conditions.applications.includeApplications must include 'All'." }
            if ($clientAppTypes -notcontains 'all') { Stop-Validation "$name conditions.clientAppTypes must include 'all'." }
            if (-not $authStrengthPresent) { Stop-Validation "$name grantControls.authenticationStrength must be set." }
            if ($authStrengthId -ne $phishingResistantId) {
                Stop-Validation "$name grantControls.authenticationStrength.id must reference the built-in Phishing-resistant MFA policy ($phishingResistantId)."
            }
        }
        'ca-azure-mgmt-mfa.template.json' {
            if (-not $includeUsersPresent) { Stop-Validation "$name must scope the subject to all users with conditions.users.includeUsers." }
            $usersAll = (@($policy.conditions.users.includeUsers).Count -eq 1) -and (@($policy.conditions.users.includeUsers)[0] -eq 'All')
            if (-not $usersAll) { Stop-Validation "$name conditions.users.includeUsers must equal ['All']." }
            if ($applications -notcontains $azureMgmtAppId) {
                Stop-Validation "$name conditions.applications.includeApplications must include the Microsoft Azure Management application id ($azureMgmtAppId)."
            }
            if ($builtInControls -notcontains 'mfa') { Stop-Validation "$name grantControls.builtInControls must include 'mfa'." }
        }
        'ca-block-legacy-auth.template.json' {
            if (-not $includeUsersPresent) { Stop-Validation "$name must scope the subject to all users with conditions.users.includeUsers." }
            $usersAll = (@($policy.conditions.users.includeUsers).Count -eq 1) -and (@($policy.conditions.users.includeUsers)[0] -eq 'All')
            if (-not $usersAll) { Stop-Validation "$name conditions.users.includeUsers must equal ['All']." }
            $nonLegacy = @($clientAppTypes | Where-Object { $_ -ne 'exchangeActiveSync' -and $_ -ne 'other' })
            if ($nonLegacy.Count -gt 0) { Stop-Validation "$name conditions.clientAppTypes must only contain legacy client types (exchangeActiveSync, other)." }
            if ($builtInControls -notcontains 'block') { Stop-Validation "$name grantControls.builtInControls must include 'block'." }
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
