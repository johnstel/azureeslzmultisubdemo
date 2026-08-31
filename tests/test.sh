#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TEMP_DIR}"' EXIT

command -v az >/dev/null 2>&1 || {
  printf 'ERROR: Azure CLI is required for Bicep validation.\n' >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  printf 'ERROR: jq is required for structural tests.\n' >&2
  exit 1
}
command -v rg >/dev/null 2>&1 || {
  printf 'ERROR: ripgrep is required for safety tests.\n' >&2
  exit 1
}

printf '1/14 Validate repository versioning and branch guidance...\n'
version_value="$(tr -d '\r\n' < "${PROJECT_DIR}/VERSION")"
[[ "${version_value}" == '2.0.0-dev' ]] || {
  printf 'ERROR: VERSION must be exactly 2.0.0-dev.\n' >&2
  exit 1
}
rg -q '\*\*Version status:\*\* `main` is the \*\*v2 development line\*\* \(`2\.0\.0-dev`\)\.' "${PROJECT_DIR}/README.md"
rg -q 'https://github\.com/johnstel/azureeslzmultisubdemo/releases/tag/v1\.0\.0' "${PROJECT_DIR}/README.md"
rg -q 'https://github\.com/johnstel/azureeslzmultisubdemo/tree/release/v1' "${PROJECT_DIR}/README.md"
rg -q 'https://github\.com/johnstel/azureeslzmultisubdemo/issues\?q=milestone%3A%22v2\.0\.0%22' "${PROJECT_DIR}/README.md"

printf '2/14 Build the complete tenant template...\n'
az bicep build --file "${PROJECT_DIR}/main.bicep" --outfile "${TEMP_DIR}/main.json"

printf '3/14 Validate the ARM parameter template...\n'
jq -e '
  .parameters.deployRoleAssignments.value == false and
  .parameters.deployEvidenceResources.value == false and
  .parameters.denyPolicyEnforcementMode.value == "DoNotEnforce"
' "${PROJECT_DIR}/parameters/demo.parameters.template.json" >/dev/null
az bicep build-params \
  --file "${PROJECT_DIR}/parameters/main.template.bicepparam" \
  --outfile "${TEMP_DIR}/main.parameters.json"

printf '4/14 Confirm there are exactly two unconditional subscription associations...\n'
association_count="$(jq '[.. | objects | select(.type? == "Microsoft.Management/managementGroups/subscriptions") | select(has("condition") | not)] | length' "${TEMP_DIR}/main.json")"
[[ "${association_count}" -eq 2 ]] || {
  printf 'ERROR: Expected 2 unconditional subscription association resources, found %s.\n' "${association_count}" >&2
  exit 1
}

printf '5/14 Confirm no paid always-on resource types are declared...\n'
if rg -n \
  "Microsoft\\.(Compute/virtualMachines|OperationalInsights/workspaces|Network/(azureFirewalls|bastionHosts|natGateways|publicIPAddresses|virtualNetworkGateways)|Storage/storageAccounts)" \
  "${PROJECT_DIR}/main.bicep" "${PROJECT_DIR}/modules" \
  -g '*.bicep' | rg -v 'policy-library\.bicep'; then
  printf 'ERROR: A prohibited evidence resource type is declared.\n' >&2
  exit 1
fi

printf '6/14 Confirm tenant-root scope is only used as the parent hierarchy input...\n'
if rg -n 'scope:\\s*managementGroup\\(tenantRootManagementGroupId\\)' "${PROJECT_DIR}" -g '*.bicep'; then
  printf 'ERROR: A module or resource assigns governance directly at the tenant root.\n' >&2
  exit 1
fi

printf '7/14 Confirm five distinct Entra group parameters and guarded scripts...\n'
group_param_count="$(rg -c '^param (governanceAdminsGroupObjectId|subscriptionOwnersGroupObjectId|networkOperatorsGroupObjectId|workloadContributorsGroupObjectId|readOnlyAuditorsGroupObjectId) string$' "${PROJECT_DIR}/main.bicep")"
[[ "${group_param_count}" -eq 5 ]] || {
  printf 'ERROR: Expected five Entra security-group parameters.\n' >&2
  exit 1
}
rg -q 'DEPLOY-ESLZ-DEMO' "${PROJECT_DIR}/scripts/deploy.sh"
rg -q 'DELETE-ESLZ-DEMO' "${PROJECT_DIR}/scripts/teardown.sh"
rg -q 'DEPLOY-ESLZ-DEMO' "${PROJECT_DIR}/scripts/deploy.ps1"
rg -q 'DELETE-ESLZ-DEMO' "${PROJECT_DIR}/scripts/teardown.ps1"

printf '8/14 Confirm region policy safely permits global resources...\n'
rg -q "field: 'location'" "${PROJECT_DIR}/modules/policy-library.bicep"
rg -q "notEquals: 'global'" "${PROJECT_DIR}/modules/policy-library.bicep"
rg -q "notEquals: 'Microsoft.AzureActiveDirectory/b2cDirectories'" "${PROJECT_DIR}/modules/policy-library.bicep"

printf '9/14 Confirm the Critical Infrastructure branch is opt-in and correctly wired...\n'
rg -q "^param enableCriticalInfrastructure bool = false$" "${PROJECT_DIR}/modules/hierarchy.bicep"
rg -q "^param criticalInfrastructureSubscriptionIds array = \\[\\]$" "${PROJECT_DIR}/modules/hierarchy.bicep"
rg -q "displayName: 'Critical Infrastructure'" "${PROJECT_DIR}/modules/hierarchy.bicep"
jq -e '
  .parameters.enableCriticalInfrastructure.defaultValue == false and
  .parameters.criticalInfrastructureSubscriptionIds.defaultValue == []
' "${TEMP_DIR}/main.json" >/dev/null
critical_mg_count="$(jq '
  [.. | objects
    | select(.type? == "Microsoft.Management/managementGroups")
    | select(.properties.displayName? == "Critical Infrastructure")
    | select(.condition == "[parameters(\u0027enableCriticalInfrastructure\u0027)]")
    | select(.properties.details.parent.id? | test("landingZonesManagementGroupId"))
  ] | length
' "${TEMP_DIR}/main.json")"
[[ "${critical_mg_count}" -eq 1 ]] || {
  printf 'ERROR: Expected exactly one gated Critical Infrastructure management group parented under Landing Zones.\n' >&2
  exit 1
}
critical_sub_count="$(jq '
  [.. | objects
    | select(.type? == "Microsoft.Management/managementGroups/subscriptions")
    | select(.condition == "[parameters(\u0027enableCriticalInfrastructure\u0027)]")
    | select(.copy.count? == "[length(parameters(\u0027criticalInfrastructureSubscriptionIds\u0027))]")
  ] | length
' "${TEMP_DIR}/main.json")"
[[ "${critical_sub_count}" -eq 1 ]] || {
  printf 'ERROR: Expected the Critical Infrastructure subscription associations to be gated and count-bound to criticalInfrastructureSubscriptionIds.\n' >&2
  exit 1
}
jq -e '.outputs.criticalInfrastructureEnabled.value == "[parameters(\u0027enableCriticalInfrastructure\u0027)]"' "${TEMP_DIR}/main.json" >/dev/null

printf '10/14 Confirm criticalInfrastructureSubscriptionIds validates duplicates and overlap...\n'
rg -q "fail\\('criticalInfrastructureSubscriptionIds must not contain duplicate subscription IDs" "${PROJECT_DIR}/modules/hierarchy.bicep"
rg -q "fail\\('criticalInfrastructureSubscriptionIds must not overlap with connectivitySubscriptionId or workloadSubscriptionId" "${PROJECT_DIR}/modules/hierarchy.bicep"
critical_validation_var_count="$(jq '
  [.. | objects
    | select(.type? == "Microsoft.Resources/deployments")
    | .properties.template.variables
    | select(has("hasDuplicateCriticalInfrastructureSubscriptionIds") and has("criticalInfrastructureSubscriptionIdsOverlapRequiredSubscriptions"))
    | select(.criticalInfrastructureManagementGroupIdValidated? | contains("fail("))
  ] | length
' "${TEMP_DIR}/main.json")"
[[ "${critical_validation_var_count}" -eq 1 ]] || {
  printf 'ERROR: Expected the hierarchy module to compute duplicate/overlap validation and fail() the deployment when invalid.\n' >&2
  exit 1
}

printf '11/14 Confirm teardown scripts move critical subscriptions and delete the Critical Infrastructure management group before Landing Zones...\n'
critical_sub_move_line="$(rg -n 'management-group subscription add --name "\$\{tenant_root\}" --subscription "\$\{critical_subscription\}"' "${PROJECT_DIR}/scripts/teardown.sh" | head -1 | cut -d: -f1)"
critical_mg_delete_line="$(rg -n 'management-group delete --name "\$\{prefix\}-criticalinfra"' "${PROJECT_DIR}/scripts/teardown.sh" | head -1 | cut -d: -f1)"
landingzones_delete_line="$(rg -n 'management-group delete --name "\$\{prefix\}-landingzones"' "${PROJECT_DIR}/scripts/teardown.sh" | head -1 | cut -d: -f1)"
[[ -n "${critical_sub_move_line}" && -n "${critical_mg_delete_line}" && -n "${landingzones_delete_line}" ]] || {
  printf 'ERROR: teardown.sh is missing the critical infrastructure subscription move or management group deletion.\n' >&2
  exit 1
}
[[ "${critical_sub_move_line}" -lt "${critical_mg_delete_line}" && "${critical_mg_delete_line}" -lt "${landingzones_delete_line}" ]] || {
  printf 'ERROR: teardown.sh must move critical infrastructure subscriptions, then delete the Critical Infrastructure management group before Landing Zones.\n' >&2
  exit 1
}
critical_sub_move_line_ps1="$(rg -n 'az account management-group subscription add --name \$tenantRoot --subscription \$criticalSubscription' "${PROJECT_DIR}/scripts/teardown.ps1" | head -1 | cut -d: -f1)"
critical_mg_delete_line_ps1="$(rg -n '"\$prefix-criticalinfra"' "${PROJECT_DIR}/scripts/teardown.ps1" | head -1 | cut -d: -f1)"
landingzones_delete_line_ps1="$(rg -n '"\$prefix-landingzones"' "${PROJECT_DIR}/scripts/teardown.ps1" | head -1 | cut -d: -f1)"
[[ -n "${critical_sub_move_line_ps1}" && -n "${critical_mg_delete_line_ps1}" && -n "${landingzones_delete_line_ps1}" ]] || {
  printf 'ERROR: teardown.ps1 is missing the critical infrastructure subscription move or management group deletion.\n' >&2
  exit 1
}
[[ "${critical_sub_move_line_ps1}" -lt "${critical_mg_delete_line_ps1}" && "${critical_mg_delete_line_ps1}" -lt "${landingzones_delete_line_ps1}" ]] || {
  printf 'ERROR: teardown.ps1 must move critical infrastructure subscriptions, then delete the Critical Infrastructure management group before Landing Zones.\n' >&2
  exit 1
}

printf '12/14 Parse cross-platform scripts and check macOS Bash 3.2 compatibility...\n'
for shell_script in "${PROJECT_DIR}"/scripts/*.sh "${PROJECT_DIR}"/tests/*.sh; do
  bash -n "${shell_script}"
done
if rg -n 'declare -A|\$\{[^}]+,,\}|\$\{[^}]+\^\^\}' "${PROJECT_DIR}/scripts" -g '*.sh'; then
  printf 'ERROR: A script uses a Bash 4+ feature unavailable in stock macOS Bash 3.2.\n' >&2
  exit 1
fi

if command -v pwsh >/dev/null 2>&1; then
  pwsh -NoLogo -NoProfile -Command '
    $failed = $false
    Get-ChildItem "'"${PROJECT_DIR}"'/scripts", "'"${PROJECT_DIR}"'/tests" -Filter "*.ps1" |
      ForEach-Object {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
          $_.FullName,
          [ref]$tokens,
          [ref]$errors
        )
        if ($errors.Count -gt 0) {
          Write-Error "PowerShell parse error in $($_.FullName): $($errors[0].Message)"
          $failed = $true
        }
      }
    if ($failed) { exit 1 }
  '
fi

printf '13/14 Validate Entra Conditional Access and PIM demo artifacts...\n'
"${PROJECT_DIR}/scripts/validate-identity-artifacts.sh"

printf '14/14 Confirm identity validators reject invalid Conditional Access and PIM inputs...\n'
IDENTITY_SRC_DIR="${PROJECT_DIR}/identity"
IDENTITY_NEG_DIR="${TEMP_DIR}/identity-negative"
IDENTITY_POP_DIR="${TEMP_DIR}/identity-populated"

expect_identity_validation_failure() {
  local description="$1"
  shift
  if "${PROJECT_DIR}/scripts/validate-identity-artifacts.sh" "$@" >/dev/null 2>&1; then
    printf 'ERROR: validate-identity-artifacts.sh unexpectedly succeeded for case: %s\n' "${description}" >&2
    exit 1
  fi
}

# A fully populated (fake, non-tenant) positive-control copy: every
# REPLACE_WITH_* placeholder replaced with a syntactically valid GUID. Used
# both to confirm --mode populated accepts a genuinely valid input, and as
# the base for populated-mode negative cases below.
rm -rf "${IDENTITY_POP_DIR}" && cp -r "${IDENTITY_SRC_DIR}" "${IDENTITY_POP_DIR}"
for populated_file in "${IDENTITY_POP_DIR}/conditional-access"/*.template.json; do
  jq --arg g "11111111-1111-1111-1111-111111111111" \
    '.emergencyAccessExclusion.placeholder = $g | .conditions.users.excludeGroups = [$g]' \
    "${populated_file}" > "${TEMP_DIR}/tmp.json" && mv "${TEMP_DIR}/tmp.json" "${populated_file}"
done
for populated_file in "${IDENTITY_POP_DIR}/pim"/*.template.json; do
  jq --arg g "22222222-2222-2222-2222-222222222222" --arg a "33333333-3333-3333-3333-333333333333" \
    '.emergencyAccessExclusion.placeholder = $g | .activation.approvers = [$a]' \
    "${populated_file}" > "${TEMP_DIR}/tmp.json" && mv "${TEMP_DIR}/tmp.json" "${populated_file}"
done
"${PROJECT_DIR}/scripts/validate-identity-artifacts.sh" --mode populated --path "${IDENTITY_POP_DIR}" >/dev/null

# Case: populated mode must reject a PIM approver left as an unresolved
# REPLACE_WITH_* placeholder.
rm -rf "${IDENTITY_NEG_DIR}" && cp -r "${IDENTITY_POP_DIR}" "${IDENTITY_NEG_DIR}"
jq '.activation.approvers = ["REPLACE_WITH_PIM_APPROVER_GROUP_OBJECT_ID"]' \
  "${IDENTITY_NEG_DIR}/pim/pim-activation-global-administrator.template.json" > "${TEMP_DIR}/tmp.json" \
  && mv "${TEMP_DIR}/tmp.json" "${IDENTITY_NEG_DIR}/pim/pim-activation-global-administrator.template.json"
expect_identity_validation_failure "unresolved PIM approver placeholder in populated mode" --mode populated --path "${IDENTITY_NEG_DIR}"

# Case: populated mode must reject a PIM approver that isn't a valid GUID.
rm -rf "${IDENTITY_NEG_DIR}" && cp -r "${IDENTITY_POP_DIR}" "${IDENTITY_NEG_DIR}"
jq '.activation.approvers = ["sales-team"]' \
  "${IDENTITY_NEG_DIR}/pim/pim-activation-global-administrator.template.json" > "${TEMP_DIR}/tmp.json" \
  && mv "${TEMP_DIR}/tmp.json" "${IDENTITY_NEG_DIR}/pim/pim-activation-global-administrator.template.json"
expect_identity_validation_failure "invalid non-GUID PIM approver in populated mode" --mode populated --path "${IDENTITY_NEG_DIR}"

# Case: template mode must reject a PIM approver that is already a populated
# GUID instead of an unpopulated REPLACE_WITH_* placeholder.
rm -rf "${IDENTITY_NEG_DIR}" && cp -r "${IDENTITY_SRC_DIR}" "${IDENTITY_NEG_DIR}"
jq '.activation.approvers = ["44444444-4444-4444-4444-444444444444"]' \
  "${IDENTITY_NEG_DIR}/pim/pim-activation-global-administrator.template.json" > "${TEMP_DIR}/tmp.json" \
  && mv "${TEMP_DIR}/tmp.json" "${IDENTITY_NEG_DIR}/pim/pim-activation-global-administrator.template.json"
expect_identity_validation_failure "populated PIM approver GUID in template mode" --path "${IDENTITY_NEG_DIR}"

# Case: ca-privileged-role-mfa must not accept a broadened includeUsers
# subject alongside includeRoles.
rm -rf "${IDENTITY_NEG_DIR}" && cp -r "${IDENTITY_SRC_DIR}" "${IDENTITY_NEG_DIR}"
jq '.conditions.users.includeUsers = ["All"]' \
  "${IDENTITY_NEG_DIR}/conditional-access/ca-privileged-role-mfa.template.json" > "${TEMP_DIR}/tmp.json" \
  && mv "${TEMP_DIR}/tmp.json" "${IDENTITY_NEG_DIR}/conditional-access/ca-privileged-role-mfa.template.json"
expect_identity_validation_failure "broadened includeUsers on privileged-role-mfa" --path "${IDENTITY_NEG_DIR}"

# Case: ca-azure-mgmt-mfa must not accept a broadened 'All' application scope.
rm -rf "${IDENTITY_NEG_DIR}" && cp -r "${IDENTITY_SRC_DIR}" "${IDENTITY_NEG_DIR}"
jq '.conditions.applications.includeApplications = ["All"]' \
  "${IDENTITY_NEG_DIR}/conditional-access/ca-azure-mgmt-mfa.template.json" > "${TEMP_DIR}/tmp.json" \
  && mv "${TEMP_DIR}/tmp.json" "${IDENTITY_NEG_DIR}/conditional-access/ca-azure-mgmt-mfa.template.json"
expect_identity_validation_failure "broadened application scope on azure-mgmt-mfa" --path "${IDENTITY_NEG_DIR}"

# Case: ca-block-legacy-auth must not drop a required legacy client type.
rm -rf "${IDENTITY_NEG_DIR}" && cp -r "${IDENTITY_SRC_DIR}" "${IDENTITY_NEG_DIR}"
jq '.conditions.clientAppTypes = ["other"]' \
  "${IDENTITY_NEG_DIR}/conditional-access/ca-block-legacy-auth.template.json" > "${TEMP_DIR}/tmp.json" \
  && mv "${TEMP_DIR}/tmp.json" "${IDENTITY_NEG_DIR}/conditional-access/ca-block-legacy-auth.template.json"
expect_identity_validation_failure "missing legacy client type on block-legacy-auth" --path "${IDENTITY_NEG_DIR}"

# Case: ca-privileged-role-mfa must not accept a broadened grant control
# (a plain 'mfa' builtInControls entry alongside authenticationStrength
# would let a non-phishing-resistant MFA satisfy an OR-combined policy).
rm -rf "${IDENTITY_NEG_DIR}" && cp -r "${IDENTITY_SRC_DIR}" "${IDENTITY_NEG_DIR}"
jq '.grantControls.builtInControls = ["mfa"]' \
  "${IDENTITY_NEG_DIR}/conditional-access/ca-privileged-role-mfa.template.json" > "${TEMP_DIR}/tmp.json" \
  && mv "${TEMP_DIR}/tmp.json" "${IDENTITY_NEG_DIR}/conditional-access/ca-privileged-role-mfa.template.json"
expect_identity_validation_failure "broadened grant controls on privileged-role-mfa" --path "${IDENTITY_NEG_DIR}"

# Case: ca-privileged-role-mfa must require the exact set of six privileged
# directory role template IDs; an extra, unrecognized role must fail.
rm -rf "${IDENTITY_NEG_DIR}" && cp -r "${IDENTITY_SRC_DIR}" "${IDENTITY_NEG_DIR}"
jq '.conditions.users.includeRoles += ["fedcba98-7654-3210-fedc-ba9876543210"]' \
  "${IDENTITY_NEG_DIR}/conditional-access/ca-privileged-role-mfa.template.json" > "${TEMP_DIR}/tmp.json" \
  && mv "${TEMP_DIR}/tmp.json" "${IDENTITY_NEG_DIR}/conditional-access/ca-privileged-role-mfa.template.json"
expect_identity_validation_failure "extra unrecognized role added to privileged-role-mfa" --path "${IDENTITY_NEG_DIR}"

# Case: ca-privileged-role-mfa must reject a removed (dropped) required role.
rm -rf "${IDENTITY_NEG_DIR}" && cp -r "${IDENTITY_SRC_DIR}" "${IDENTITY_NEG_DIR}"
jq '.conditions.users.includeRoles = .conditions.users.includeRoles[0:5]' \
  "${IDENTITY_NEG_DIR}/conditional-access/ca-privileged-role-mfa.template.json" > "${TEMP_DIR}/tmp.json" \
  && mv "${TEMP_DIR}/tmp.json" "${IDENTITY_NEG_DIR}/conditional-access/ca-privileged-role-mfa.template.json"
expect_identity_validation_failure "required role removed from privileged-role-mfa" --path "${IDENTITY_NEG_DIR}"

# Case: excludeGroups must equal exactly the declared emergency-access
# placeholder; an arbitrary extra excluded group must fail.
rm -rf "${IDENTITY_NEG_DIR}" && cp -r "${IDENTITY_SRC_DIR}" "${IDENTITY_NEG_DIR}"
jq '.conditions.users.excludeGroups += ["REPLACE_WITH_EXTRA_GROUP"]' \
  "${IDENTITY_NEG_DIR}/conditional-access/ca-privileged-role-mfa.template.json" > "${TEMP_DIR}/tmp.json" \
  && mv "${TEMP_DIR}/tmp.json" "${IDENTITY_NEG_DIR}/conditional-access/ca-privileged-role-mfa.template.json"
expect_identity_validation_failure "arbitrary extra excludeGroups entry" --path "${IDENTITY_NEG_DIR}"

# Case: template mode must reject a PIM emergencyAccessExclusion.placeholder
# that is already a populated GUID instead of an unpopulated REPLACE_WITH_*
# placeholder (the PIM schema structurally allows either form; template
# mode must still narrow it to the placeholder form).
rm -rf "${IDENTITY_NEG_DIR}" && cp -r "${IDENTITY_SRC_DIR}" "${IDENTITY_NEG_DIR}"
jq '.emergencyAccessExclusion.placeholder = "44444444-4444-4444-4444-444444444444"' \
  "${IDENTITY_NEG_DIR}/pim/pim-activation-global-administrator.template.json" > "${TEMP_DIR}/tmp.json" \
  && mv "${TEMP_DIR}/tmp.json" "${IDENTITY_NEG_DIR}/pim/pim-activation-global-administrator.template.json"
expect_identity_validation_failure "populated PIM emergency-access GUID in template mode" --path "${IDENTITY_NEG_DIR}"

# Case: populated mode must reject a PIM emergencyAccessExclusion.placeholder
# left as an unresolved REPLACE_WITH_* placeholder.
rm -rf "${IDENTITY_NEG_DIR}" && cp -r "${IDENTITY_POP_DIR}" "${IDENTITY_NEG_DIR}"
jq '.emergencyAccessExclusion.placeholder = "REPLACE_WITH_EMERGENCY_ACCESS_ACCOUNT_OBJECT_ID"' \
  "${IDENTITY_NEG_DIR}/pim/pim-activation-global-administrator.template.json" > "${TEMP_DIR}/tmp.json" \
  && mv "${TEMP_DIR}/tmp.json" "${IDENTITY_NEG_DIR}/pim/pim-activation-global-administrator.template.json"
expect_identity_validation_failure "unresolved PIM emergency-access placeholder in populated mode" --mode populated --path "${IDENTITY_NEG_DIR}"

# Case: PIM activation.authenticationContext must be a Graph
# authenticationContextClassReference id ('c1'..'c25'), not a free-text
# display name.
rm -rf "${IDENTITY_NEG_DIR}" && cp -r "${IDENTITY_SRC_DIR}" "${IDENTITY_NEG_DIR}"
jq '.activation.authenticationContext = "Phishing-resistant MFA"' \
  "${IDENTITY_NEG_DIR}/pim/pim-activation-global-administrator.template.json" > "${TEMP_DIR}/tmp.json" \
  && mv "${TEMP_DIR}/tmp.json" "${IDENTITY_NEG_DIR}/pim/pim-activation-global-administrator.template.json"
expect_identity_validation_failure "invalid PIM authenticationContext display name" --path "${IDENTITY_NEG_DIR}"

# Case: every PIM activation.authenticationContext must have a matching,
# declared Conditional Access policy enforcing that authentication context;
# removing the enforcing policy (while the PIM template still references it)
# must fail even though every individual template stays schema-valid.
rm -rf "${IDENTITY_NEG_DIR}" && cp -r "${IDENTITY_SRC_DIR}" "${IDENTITY_NEG_DIR}"
rm -f "${IDENTITY_NEG_DIR}/conditional-access/ca-pim-activation-mfa.template.json"
expect_identity_validation_failure "PIM authenticationContext with no matching Conditional Access policy" --path "${IDENTITY_NEG_DIR}"

# Case: ca-pim-activation-mfa must declare the exact expected authentication
# context set; broadening it (even with a duplicate, already-known entry)
# must fail the exact-match check.
rm -rf "${IDENTITY_NEG_DIR}" && cp -r "${IDENTITY_SRC_DIR}" "${IDENTITY_NEG_DIR}"
jq '.conditions.applications.includeAuthenticationContextClassReferences = ["c1", "c1"]' \
  "${IDENTITY_NEG_DIR}/conditional-access/ca-pim-activation-mfa.template.json" > "${TEMP_DIR}/tmp.json" \
  && mv "${TEMP_DIR}/tmp.json" "${IDENTITY_NEG_DIR}/conditional-access/ca-pim-activation-mfa.template.json"
expect_identity_validation_failure "broadened authentication context set on ca-pim-activation-mfa" --path "${IDENTITY_NEG_DIR}"

# Case: ca-pim-activation-mfa must target only
# includeAuthenticationContextClassReferences; conditions.applications is a
# mutually exclusive Graph target shape, so re-adding includeApplications
# alongside it must fail.
rm -rf "${IDENTITY_NEG_DIR}" && cp -r "${IDENTITY_SRC_DIR}" "${IDENTITY_NEG_DIR}"
jq '.conditions.applications.includeApplications = ["All"]' \
  "${IDENTITY_NEG_DIR}/conditional-access/ca-pim-activation-mfa.template.json" > "${TEMP_DIR}/tmp.json" \
  && mv "${TEMP_DIR}/tmp.json" "${IDENTITY_NEG_DIR}/conditional-access/ca-pim-activation-mfa.template.json"
expect_identity_validation_failure "includeApplications re-added alongside includeAuthenticationContextClassReferences on ca-pim-activation-mfa" --path "${IDENTITY_NEG_DIR}"

# Case: semantic string/enum comparisons must be case-sensitive, matching
# Microsoft Graph's case-sensitive literals; an uppercased 'ALL' must not be
# silently accepted as 'All'.
rm -rf "${IDENTITY_NEG_DIR}" && cp -r "${IDENTITY_SRC_DIR}" "${IDENTITY_NEG_DIR}"
jq '.conditions.users.includeUsers = ["ALL"]' \
  "${IDENTITY_NEG_DIR}/conditional-access/ca-azure-mgmt-mfa.template.json" > "${TEMP_DIR}/tmp.json" \
  && mv "${TEMP_DIR}/tmp.json" "${IDENTITY_NEG_DIR}/conditional-access/ca-azure-mgmt-mfa.template.json"
expect_identity_validation_failure "case-mutated 'ALL' includeUsers value" --path "${IDENTITY_NEG_DIR}"

# Case: an uppercased 'MFA' builtInControls entry must not be silently
# accepted as the lowercase Graph literal 'mfa'.
rm -rf "${IDENTITY_NEG_DIR}" && cp -r "${IDENTITY_SRC_DIR}" "${IDENTITY_NEG_DIR}"
jq '.grantControls.builtInControls = ["MFA"]' \
  "${IDENTITY_NEG_DIR}/conditional-access/ca-azure-mgmt-mfa.template.json" > "${TEMP_DIR}/tmp.json" \
  && mv "${TEMP_DIR}/tmp.json" "${IDENTITY_NEG_DIR}/conditional-access/ca-azure-mgmt-mfa.template.json"
expect_identity_validation_failure "case-mutated 'MFA' builtInControls value" --path "${IDENTITY_NEG_DIR}"

# Case: an uppercased 'C1' PIM activation.authenticationContext must not be
# silently accepted as the lowercase Graph claim value 'c1'.
rm -rf "${IDENTITY_NEG_DIR}" && cp -r "${IDENTITY_SRC_DIR}" "${IDENTITY_NEG_DIR}"
jq '.activation.authenticationContext = "C1"' \
  "${IDENTITY_NEG_DIR}/pim/pim-activation-global-administrator.template.json" > "${TEMP_DIR}/tmp.json" \
  && mv "${TEMP_DIR}/tmp.json" "${IDENTITY_NEG_DIR}/pim/pim-activation-global-administrator.template.json"
expect_identity_validation_failure "case-mutated 'C1' PIM authenticationContext value" --path "${IDENTITY_NEG_DIR}"

# Case: PIM activation.maximumActivationDurationHours must be a true integer
# from 1 through 8; a fractional value must fail even though it falls within
# the numeric range.
rm -rf "${IDENTITY_NEG_DIR}" && cp -r "${IDENTITY_SRC_DIR}" "${IDENTITY_NEG_DIR}"
jq '.activation.maximumActivationDurationHours = 2.5' \
  "${IDENTITY_NEG_DIR}/pim/pim-activation-global-administrator.template.json" > "${TEMP_DIR}/tmp.json" \
  && mv "${TEMP_DIR}/tmp.json" "${IDENTITY_NEG_DIR}/pim/pim-activation-global-administrator.template.json"
expect_identity_validation_failure "fractional PIM maximumActivationDurationHours value" --path "${IDENTITY_NEG_DIR}"

rm -rf "${IDENTITY_NEG_DIR}" "${IDENTITY_POP_DIR}"

printf '\nAll local validation and safety tests passed.\n'
