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

printf '1/10 Validate repository versioning and branch guidance...\n'
version_value="$(tr -d '\r\n' < "${PROJECT_DIR}/VERSION")"
[[ "${version_value}" == '2.0.0-dev' ]] || {
  printf 'ERROR: VERSION must be exactly 2.0.0-dev.\n' >&2
  exit 1
}
rg -q '\*\*Version status:\*\* `main` is the \*\*v2 development line\*\* \(`2\.0\.0-dev`\)\.' "${PROJECT_DIR}/README.md"
rg -q 'https://github\.com/johnstel/azureeslzmultisubdemo/releases/tag/v1\.0\.0' "${PROJECT_DIR}/README.md"
rg -q 'https://github\.com/johnstel/azureeslzmultisubdemo/tree/release/v1' "${PROJECT_DIR}/README.md"
rg -q 'https://github\.com/johnstel/azureeslzmultisubdemo/issues\?q=milestone%3A%22v2\.0\.0%22' "${PROJECT_DIR}/README.md"

printf '2/10 Build the complete tenant template...\n'
az bicep build --file "${PROJECT_DIR}/main.bicep" --outfile "${TEMP_DIR}/main.json"

printf '3/10 Validate the ARM parameter template...\n'
jq -e '
  .parameters.deployRoleAssignments.value == false and
  .parameters.deployEvidenceResources.value == false and
  .parameters.denyPolicyEnforcementMode.value == "DoNotEnforce"
' "${PROJECT_DIR}/parameters/demo.parameters.template.json" >/dev/null
az bicep build-params \
  --file "${PROJECT_DIR}/parameters/main.template.bicepparam" \
  --outfile "${TEMP_DIR}/main.parameters.json"

printf '4/10 Confirm there are exactly two unconditional subscription associations...\n'
association_count="$(jq '[.. | objects | select(.type? == "Microsoft.Management/managementGroups/subscriptions") | select(has("condition") | not)] | length' "${TEMP_DIR}/main.json")"
[[ "${association_count}" -eq 2 ]] || {
  printf 'ERROR: Expected 2 unconditional subscription association resources, found %s.\n' "${association_count}" >&2
  exit 1
}

printf '5/10 Confirm no paid always-on resource types are declared...\n'
if rg -n \
  "Microsoft\\.(Compute/virtualMachines|OperationalInsights/workspaces|Network/(azureFirewalls|bastionHosts|natGateways|publicIPAddresses|virtualNetworkGateways)|Storage/storageAccounts)" \
  "${PROJECT_DIR}/main.bicep" "${PROJECT_DIR}/modules" \
  -g '*.bicep' | rg -v 'policy-library\.bicep'; then
  printf 'ERROR: A prohibited evidence resource type is declared.\n' >&2
  exit 1
fi

printf '6/10 Confirm tenant-root scope is only used as the parent hierarchy input...\n'
if rg -n 'scope:\\s*managementGroup\\(tenantRootManagementGroupId\\)' "${PROJECT_DIR}" -g '*.bicep'; then
  printf 'ERROR: A module or resource assigns governance directly at the tenant root.\n' >&2
  exit 1
fi

printf '7/10 Confirm five distinct Entra group parameters and guarded scripts...\n'
group_param_count="$(rg -c '^param (governanceAdminsGroupObjectId|subscriptionOwnersGroupObjectId|networkOperatorsGroupObjectId|workloadContributorsGroupObjectId|readOnlyAuditorsGroupObjectId) string$' "${PROJECT_DIR}/main.bicep")"
[[ "${group_param_count}" -eq 5 ]] || {
  printf 'ERROR: Expected five Entra security-group parameters.\n' >&2
  exit 1
}
rg -q 'DEPLOY-ESLZ-DEMO' "${PROJECT_DIR}/scripts/deploy.sh"
rg -q 'DELETE-ESLZ-DEMO' "${PROJECT_DIR}/scripts/teardown.sh"
rg -q 'DEPLOY-ESLZ-DEMO' "${PROJECT_DIR}/scripts/deploy.ps1"
rg -q 'DELETE-ESLZ-DEMO' "${PROJECT_DIR}/scripts/teardown.ps1"

printf '8/10 Confirm region policy safely permits global resources...\n'
rg -q "field: 'location'" "${PROJECT_DIR}/modules/policy-library.bicep"
rg -q "notEquals: 'global'" "${PROJECT_DIR}/modules/policy-library.bicep"
rg -q "notEquals: 'Microsoft.AzureActiveDirectory/b2cDirectories'" "${PROJECT_DIR}/modules/policy-library.bicep"

printf '9/10 Confirm the Critical Infrastructure branch is opt-in and correctly wired...\n'
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

printf '10/10 Parse cross-platform scripts and check macOS Bash 3.2 compatibility...\n'
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

printf '\nAll local validation and safety tests passed.\n'
