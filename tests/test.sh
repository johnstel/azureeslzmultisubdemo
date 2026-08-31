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

printf '1/11 Validate repository versioning and branch guidance...\n'
version_value="$(tr -d '\r\n' < "${PROJECT_DIR}/VERSION")"
[[ "${version_value}" == '2.0.0-dev' ]] || {
  printf 'ERROR: VERSION must be exactly 2.0.0-dev.\n' >&2
  exit 1
}
rg -q '\*\*Version status:\*\* `main` is the \*\*v2 development line\*\* \(`2\.0\.0-dev`\)\.' "${PROJECT_DIR}/README.md"
rg -q 'https://github\.com/johnstel/azureeslzmultisubdemo/releases/tag/v1\.0\.0' "${PROJECT_DIR}/README.md"
rg -q 'https://github\.com/johnstel/azureeslzmultisubdemo/tree/release/v1' "${PROJECT_DIR}/README.md"
rg -q 'https://github\.com/johnstel/azureeslzmultisubdemo/issues\?q=milestone%3A%22v2\.0\.0%22' "${PROJECT_DIR}/README.md"

printf '2/11 Build the complete tenant template...\n'
az bicep build --file "${PROJECT_DIR}/main.bicep" --outfile "${TEMP_DIR}/main.json"

printf '3/11 Validate the ARM parameter template...\n'
jq -e '
  .parameters.deployRoleAssignments.value == false and
  .parameters.deployEvidenceResources.value == false and
  .parameters.denyPolicyEnforcementMode.value == "DoNotEnforce"
' "${PROJECT_DIR}/parameters/demo.parameters.template.json" >/dev/null
az bicep build-params \
  --file "${PROJECT_DIR}/parameters/main.template.bicepparam" \
  --outfile "${TEMP_DIR}/main.parameters.json"

printf '4/11 Confirm there are exactly two subscription associations...\n'
association_count="$(jq '[.. | objects | select(.type? == "Microsoft.Management/managementGroups/subscriptions")] | length' "${TEMP_DIR}/main.json")"
[[ "${association_count}" -eq 2 ]] || {
  printf 'ERROR: Expected 2 subscription association resources, found %s.\n' "${association_count}" >&2
  exit 1
}

printf '5/11 Confirm no paid always-on resource types are declared...\n'
if rg -n \
  "Microsoft\\.(Compute/virtualMachines|OperationalInsights/workspaces|Network/(azureFirewalls|bastionHosts|natGateways|publicIPAddresses|virtualNetworkGateways)|Storage/storageAccounts)" \
  "${PROJECT_DIR}/main.bicep" "${PROJECT_DIR}/modules" \
  -g '*.bicep' | rg -v 'policy-library\.bicep'; then
  printf 'ERROR: A prohibited evidence resource type is declared.\n' >&2
  exit 1
fi

printf '6/11 Confirm tenant-root scope is only used as the parent hierarchy input...\n'
if rg -n 'scope:\\s*managementGroup\\(tenantRootManagementGroupId\\)' "${PROJECT_DIR}" -g '*.bicep'; then
  printf 'ERROR: A module or resource assigns governance directly at the tenant root.\n' >&2
  exit 1
fi

printf '7/11 Confirm five distinct Entra group parameters and guarded scripts...\n'
group_param_count="$(rg -c '^param (governanceAdminsGroupObjectId|subscriptionOwnersGroupObjectId|networkOperatorsGroupObjectId|workloadContributorsGroupObjectId|readOnlyAuditorsGroupObjectId) string$' "${PROJECT_DIR}/main.bicep")"
[[ "${group_param_count}" -eq 5 ]] || {
  printf 'ERROR: Expected five Entra security-group parameters.\n' >&2
  exit 1
}
rg -q 'DEPLOY-ESLZ-DEMO' "${PROJECT_DIR}/scripts/deploy.sh"
rg -q 'DELETE-ESLZ-DEMO' "${PROJECT_DIR}/scripts/teardown.sh"
rg -q 'DEPLOY-ESLZ-DEMO' "${PROJECT_DIR}/scripts/deploy.ps1"
rg -q 'DELETE-ESLZ-DEMO' "${PROJECT_DIR}/scripts/teardown.ps1"

printf '8/11 Confirm region policy safely permits global resources...\n'
rg -q "field: 'location'" "${PROJECT_DIR}/modules/policy-library.bicep"
rg -q "notEquals: 'global'" "${PROJECT_DIR}/modules/policy-library.bicep"
rg -q "notEquals: 'Microsoft.AzureActiveDirectory/b2cDirectories'" "${PROJECT_DIR}/modules/policy-library.bicep"

printf '9/11 Parse cross-platform scripts and check macOS Bash 3.2 compatibility...\n'
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

printf '10/11 Validate Entra Conditional Access and PIM demo artifacts...\n'
"${PROJECT_DIR}/scripts/validate-identity-artifacts.sh"

printf '11/11 Confirm identity validators reject invalid Conditional Access and PIM inputs...\n'
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

rm -rf "${IDENTITY_NEG_DIR}" "${IDENTITY_POP_DIR}"

printf '\nAll local validation and safety tests passed.\n'
