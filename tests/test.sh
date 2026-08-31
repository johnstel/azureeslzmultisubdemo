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

printf '4/14 Confirm there are exactly two subscription associations...\n'
association_count="$(jq '[.. | objects | select(.type? == "Microsoft.Management/managementGroups/subscriptions")] | length' "${TEMP_DIR}/main.json")"
[[ "${association_count}" -eq 2 ]] || {
  printf 'ERROR: Expected 2 subscription association resources, found %s.\n' "${association_count}" >&2
  exit 1
}

printf '5/14 Confirm no paid always-on resource types are declared outside the opt-in central monitoring module...\n'
if rg -n \
  "Microsoft\\.(Compute/virtualMachines|OperationalInsights/workspaces|Network/(azureFirewalls|bastionHosts|natGateways|publicIPAddresses|virtualNetworkGateways)|Storage/storageAccounts)" \
  "${PROJECT_DIR}/main.bicep" "${PROJECT_DIR}/modules" \
  -g '*.bicep' | rg -v 'policy-library\.bicep|central-monitoring(-workspace|-sentinel)?\.bicep'; then
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

printf '9/14 Confirm central monitoring defaults create no metered resources...\n'
jq -e '
  .parameters.deployCentralLogAnalytics.value == false and
  .parameters.deploySentinel.value == false and
  .parameters.existingLogAnalyticsWorkspaceResourceId.value == ""
' "${PROJECT_DIR}/parameters/demo.parameters.template.json" >/dev/null
rg -q "^param deployCentralLogAnalytics bool = false$" "${PROJECT_DIR}/modules/central-monitoring.bicep"
rg -q "^param deploySentinel bool = false$" "${PROJECT_DIR}/modules/central-monitoring.bicep"
rg -q "^param existingLogAnalyticsWorkspaceResourceId string = ''$" "${PROJECT_DIR}/modules/central-monitoring.bicep"

printf "10/14 Confirm central monitoring guards against conflicting new/existing workspace inputs and Sentinel-without-workspace...\n"
rg -q 'conflictingMonitoringInputs = newWorkspaceRequested && existingWorkspaceSupplied' "${PROJECT_DIR}/modules/central-monitoring.bicep"
rg -q 'sentinelRequiresEffectiveWorkspace = deploySentinel && !newWorkspaceRequested && !existingWorkspaceSupplied' "${PROJECT_DIR}/modules/central-monitoring.bicep"
rg -q 'createNewWorkspace = newWorkspaceRequested && !hasMonitoringConfigurationError' "${PROJECT_DIR}/modules/central-monitoring.bicep"
rg -q 'useExistingWorkspace = existingWorkspaceSupplied && !hasMonitoringConfigurationError' "${PROJECT_DIR}/modules/central-monitoring.bicep"

printf '11/14 Confirm the central monitoring module exposes an effective workspace ID output...\n'
rg -q '^output effectiveLogAnalyticsWorkspaceResourceId string' "${PROJECT_DIR}/modules/central-monitoring.bicep"
rg -q 'centralMonitoringEffectiveWorkspaceId string = centralMonitoring\.outputs\.effectiveLogAnalyticsWorkspaceResourceId' "${PROJECT_DIR}/main.bicep"

printf '12/14 Confirm invalid central monitoring configurations fail deployment explicitly...\n'
rg -q "resource conflictingMonitoringInputsGuard 'Microsoft.CentralMonitoringGuard/configurationError@" "${PROJECT_DIR}/modules/central-monitoring.bicep"
rg -q 'if \(conflictingMonitoringInputs\)' "${PROJECT_DIR}/modules/central-monitoring.bicep"
rg -q "resource sentinelRequiresWorkspaceGuard 'Microsoft.CentralMonitoringGuard/configurationError@" "${PROJECT_DIR}/modules/central-monitoring.bicep"
rg -q 'if \(sentinelRequiresEffectiveWorkspace\)' "${PROJECT_DIR}/modules/central-monitoring.bicep"

printf '13/14 Confirm teardown scripts only remove a demo-created monitoring resource group and never touch a supplied existing workspace...\n'
rg -q 'deployCentralLogAnalytics' "${PROJECT_DIR}/scripts/teardown.sh"
rg -q "central_log_analytics_enabled.*==.*'true'" "${PROJECT_DIR}/scripts/teardown.sh"
rg -q 'rg-\$\{prefix\}-monitoring' "${PROJECT_DIR}/scripts/teardown.sh"
rg -q 'deployCentralLogAnalytics' "${PROJECT_DIR}/scripts/teardown.ps1"
rg -q 'centralLogAnalyticsEnabled' "${PROJECT_DIR}/scripts/teardown.ps1"
rg -q 'rg-\$prefix-monitoring' "${PROJECT_DIR}/scripts/teardown.ps1"
if rg -n 'existingLogAnalyticsWorkspaceResourceId' "${PROJECT_DIR}/scripts/teardown.sh" "${PROJECT_DIR}/scripts/teardown.ps1"; then
  printf 'ERROR: Teardown scripts must never reference a supplied existing workspace for deletion.\n' >&2
  exit 1
fi

printf '14/14 Parse cross-platform scripts and check macOS Bash 3.2 compatibility...\n'
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
