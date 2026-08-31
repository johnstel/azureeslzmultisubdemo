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

printf '1/18 Validate repository versioning and branch guidance...\n'
version_value="$(tr -d '\r\n' < "${PROJECT_DIR}/VERSION")"
[[ "${version_value}" == '2.0.0-dev' ]] || {
  printf 'ERROR: VERSION must be exactly 2.0.0-dev.\n' >&2
  exit 1
}
rg -q '\*\*Version status:\*\* `main` is the \*\*v2 development line\*\* \(`2\.0\.0-dev`\)\.' "${PROJECT_DIR}/README.md"
rg -q 'https://github\.com/johnstel/azureeslzmultisubdemo/releases/tag/v1\.0\.0' "${PROJECT_DIR}/README.md"
rg -q 'https://github\.com/johnstel/azureeslzmultisubdemo/tree/release/v1' "${PROJECT_DIR}/README.md"
rg -q 'https://github\.com/johnstel/azureeslzmultisubdemo/issues\?q=milestone%3A%22v2\.0\.0%22' "${PROJECT_DIR}/README.md"

printf '2/18 Build the complete tenant template...\n'
az_build_stderr="$(az bicep build --file "${PROJECT_DIR}/main.bicep" --outfile "${TEMP_DIR}/main.json" 2>&1 1>/dev/null)"
if printf '%s' "${az_build_stderr}" | rg -q 'BCP318'; then
  printf 'ERROR: main.bicep build must not emit a BCP318 nullable-module-output warning.\n' >&2
  printf '%s\n' "${az_build_stderr}" >&2
  exit 1
fi

printf '3/18 Validate the ARM parameter template...\n'
jq -e '
  .parameters.deployRoleAssignments.value == false and
  .parameters.deployEvidenceResources.value == false and
  .parameters.denyPolicyEnforcementMode.value == "DoNotEnforce"
' "${PROJECT_DIR}/parameters/demo.parameters.template.json" >/dev/null
az bicep build-params \
  --file "${PROJECT_DIR}/parameters/main.template.bicepparam" \
  --outfile "${TEMP_DIR}/main.parameters.json"

printf '4/18 Confirm there are exactly two unconditional subscription associations...\n'
association_count="$(jq '[.. | objects | select(.type? == "Microsoft.Management/managementGroups/subscriptions") | select(has("condition") | not)] | length' "${TEMP_DIR}/main.json")"
[[ "${association_count}" -eq 2 ]] || {
  printf 'ERROR: Expected 2 unconditional subscription association resources, found %s.\n' "${association_count}" >&2
  exit 1
}

printf '5/18 Confirm no paid always-on resource types are declared outside the opt-in central monitoring module...\n'
if rg -n \
  "Microsoft\\.(Compute/virtualMachines|OperationalInsights/workspaces|Network/(azureFirewalls|bastionHosts|natGateways|publicIPAddresses|virtualNetworkGateways)|Storage/storageAccounts)" \
  "${PROJECT_DIR}/main.bicep" "${PROJECT_DIR}/modules" \
  -g '*.bicep' | rg -v 'policy-library\.bicep|central-monitoring(-workspace|-sentinel)?\.bicep'; then
  printf 'ERROR: A prohibited evidence resource type is declared.\n' >&2
  exit 1
fi

printf '6/18 Confirm tenant-root scope is only used as the parent hierarchy input...\n'
if rg -n 'scope:\\s*managementGroup\\(tenantRootManagementGroupId\\)' "${PROJECT_DIR}" -g '*.bicep'; then
  printf 'ERROR: A module or resource assigns governance directly at the tenant root.\n' >&2
  exit 1
fi

printf '7/18 Confirm five distinct Entra group parameters and guarded scripts...\n'
group_param_count="$(rg -c '^param (governanceAdminsGroupObjectId|subscriptionOwnersGroupObjectId|networkOperatorsGroupObjectId|workloadContributorsGroupObjectId|readOnlyAuditorsGroupObjectId) string$' "${PROJECT_DIR}/main.bicep")"
[[ "${group_param_count}" -eq 5 ]] || {
  printf 'ERROR: Expected five Entra security-group parameters.\n' >&2
  exit 1
}
rg -q 'DEPLOY-ESLZ-DEMO' "${PROJECT_DIR}/scripts/deploy.sh"
rg -q 'DELETE-ESLZ-DEMO' "${PROJECT_DIR}/scripts/teardown.sh"
rg -q 'DEPLOY-ESLZ-DEMO' "${PROJECT_DIR}/scripts/deploy.ps1"
rg -q 'DELETE-ESLZ-DEMO' "${PROJECT_DIR}/scripts/teardown.ps1"

printf '8/18 Confirm region policy safely permits global resources...\n'
rg -q "field: 'location'" "${PROJECT_DIR}/modules/policy-library.bicep"
rg -q "notEquals: 'global'" "${PROJECT_DIR}/modules/policy-library.bicep"
rg -q "notEquals: 'Microsoft.AzureActiveDirectory/b2cDirectories'" "${PROJECT_DIR}/modules/policy-library.bicep"

printf '9/18 Confirm the Critical Infrastructure branch is opt-in and correctly wired...\n'
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

printf '10/18 Confirm criticalInfrastructureSubscriptionIds validates duplicates and overlap...\n'
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

printf '11/18 Confirm teardown scripts move critical subscriptions and delete the Critical Infrastructure management group before Landing Zones...\n'
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

printf '12/18 Confirm central monitoring defaults create no metered resources...\n'
jq -e '
  .parameters.deployCentralLogAnalytics.value == false and
  .parameters.deploySentinel.value == false and
  .parameters.existingLogAnalyticsWorkspaceResourceId.value == ""
' "${PROJECT_DIR}/parameters/demo.parameters.template.json" >/dev/null
rg -q "^param deployCentralLogAnalytics bool = false$" "${PROJECT_DIR}/modules/central-monitoring.bicep"
rg -q "^param deploySentinel bool = false$" "${PROJECT_DIR}/modules/central-monitoring.bicep"
rg -q "^param existingLogAnalyticsWorkspaceResourceId string = ''$" "${PROJECT_DIR}/modules/central-monitoring.bicep"

printf "13/18 Confirm central monitoring guards against conflicting new/existing workspace inputs and Sentinel-without-workspace...\n"
rg -q 'conflictingMonitoringInputs = newWorkspaceRequested && existingWorkspaceSupplied' "${PROJECT_DIR}/modules/central-monitoring.bicep"
rg -q 'sentinelRequiresEffectiveWorkspace = deploySentinel && !newWorkspaceRequested && !existingWorkspaceSupplied' "${PROJECT_DIR}/modules/central-monitoring.bicep"
rg -q 'createNewWorkspace = newWorkspaceRequested && !hasMonitoringConfigurationError' "${PROJECT_DIR}/modules/central-monitoring.bicep"
rg -q 'useExistingWorkspace = existingWorkspaceSupplied && !hasMonitoringConfigurationError' "${PROJECT_DIR}/modules/central-monitoring.bicep"

printf '14/18 Confirm the central monitoring module exposes an effective workspace ID output...\n'
rg -q '^output effectiveLogAnalyticsWorkspaceResourceId string' "${PROJECT_DIR}/modules/central-monitoring.bicep"
rg -q 'centralMonitoringEffectiveWorkspaceId string = centralMonitoring\.outputs\.effectiveLogAnalyticsWorkspaceResourceId' "${PROJECT_DIR}/main.bicep"

printf '15/18 Confirm invalid central monitoring configurations fail deployment explicitly...\n'
rg -q "resource conflictingMonitoringInputsGuard 'Microsoft.CentralMonitoringGuard/configurationError@" "${PROJECT_DIR}/modules/central-monitoring.bicep"
rg -q 'if \(conflictingMonitoringInputs\)' "${PROJECT_DIR}/modules/central-monitoring.bicep"
rg -q "resource sentinelRequiresWorkspaceGuard 'Microsoft.CentralMonitoringGuard/configurationError@" "${PROJECT_DIR}/modules/central-monitoring.bicep"
rg -q 'if \(sentinelRequiresEffectiveWorkspace\)' "${PROJECT_DIR}/modules/central-monitoring.bicep"

printf '16/18 Confirm teardown scripts protect a supplied existing workspace resource group and only remove a demo-created monitoring resource group...\n'
rg -q 'deployCentralLogAnalytics' "${PROJECT_DIR}/scripts/teardown.sh"
rg -q "central_log_analytics_enabled.*==.*'true'" "${PROJECT_DIR}/scripts/teardown.sh"
rg -q 'rg-\$\{prefix\}-monitoring' "${PROJECT_DIR}/scripts/teardown.sh"
rg -q 'existingLogAnalyticsWorkspaceResourceId' "${PROJECT_DIR}/scripts/teardown.sh"
rg -q 'is_protected_existing_workspace_group' "${PROJECT_DIR}/scripts/teardown.sh"
rg -q 'monitoring_group_is_repo_owned' "${PROJECT_DIR}/scripts/teardown.sh"
rg -q "central_log_analytics_enabled.*==.*'true'.*&&.*-z.*existing_workspace_resource_id" "${PROJECT_DIR}/scripts/teardown.sh"
rg -q 'delete_resource_group_if_not_protected "\$\{connectivity_subscription\}" "rg-\$\{prefix\}-connectivity"' "${PROJECT_DIR}/scripts/teardown.sh"

rg -q 'deployCentralLogAnalytics' "${PROJECT_DIR}/scripts/teardown.ps1"
rg -q 'centralLogAnalyticsEnabled' "${PROJECT_DIR}/scripts/teardown.ps1"
rg -q 'rg-\$prefix-monitoring' "${PROJECT_DIR}/scripts/teardown.ps1"
rg -q 'existingLogAnalyticsWorkspaceResourceId' "${PROJECT_DIR}/scripts/teardown.ps1"
rg -q 'Test-ProtectedExistingWorkspaceGroup' "${PROJECT_DIR}/scripts/teardown.ps1"
rg -q '\$existingWorkspaceSupplied = \$existingWorkspaceResourceId\.Length -gt 0' "${PROJECT_DIR}/scripts/teardown.ps1"
rg -q '\$monitoringGroupIsRepoOwned = \$centralLogAnalyticsEnabled -and -not \$existingWorkspaceSupplied' "${PROJECT_DIR}/scripts/teardown.ps1"
if rg -q 'IsNullOrWhiteSpace\(\$existingWorkspaceResourceId\)' "${PROJECT_DIR}/scripts/teardown.ps1"; then
  printf 'ERROR: teardown.ps1 must not use IsNullOrWhiteSpace on the raw existing workspace resource ID; it must match Bicep/Bash length-based presence semantics so a whitespace-only value is treated as supplied.\n' >&2
  exit 1
fi
rg -q 'Remove-ResourceGroupIfNotProtected -Subscription \$connectivitySubscription -Group \$connectivityResourceGroup' "${PROJECT_DIR}/scripts/teardown.ps1"

printf '17/18 Confirm a whitespace-only existing workspace resource ID never triggers deletion of the monitoring resource group...\n'
mock_bin_dir="${TEMP_DIR}/mockbin"
mkdir -p "${mock_bin_dir}"
az_call_log="${TEMP_DIR}/az_calls.log"
cat > "${mock_bin_dir}/az" <<'MOCKAZ'
#!/usr/bin/env bash
echo "$*" >> "${AZ_CALL_LOG}"
if [[ "$1" == 'group' && "$2" == 'exists' ]]; then
  echo 'true'
  exit 0
fi
exit 0
MOCKAZ
chmod +x "${mock_bin_dir}/az"

whitespace_param_file="${TEMP_DIR}/whitespace.parameters.json"
jq '
  .parameters.tenantRootManagementGroupId.value = "mg-root" |
  .parameters.connectivitySubscriptionId.value = "11111111-1111-1111-1111-111111111111" |
  .parameters.workloadSubscriptionId.value = "22222222-2222-2222-2222-222222222222" |
  .parameters.governanceAdminsGroupObjectId.value = "33333333-3333-3333-3333-333333333333" |
  .parameters.subscriptionOwnersGroupObjectId.value = "44444444-4444-4444-4444-444444444444" |
  .parameters.networkOperatorsGroupObjectId.value = "55555555-5555-5555-5555-555555555555" |
  .parameters.workloadContributorsGroupObjectId.value = "66666666-6666-6666-6666-666666666666" |
  .parameters.readOnlyAuditorsGroupObjectId.value = "77777777-7777-7777-7777-777777777777" |
  .parameters.deployCentralLogAnalytics.value = true |
  .parameters.existingLogAnalyticsWorkspaceResourceId.value = "   "
' "${PROJECT_DIR}/parameters/demo.parameters.template.json" > "${whitespace_param_file}"

: > "${az_call_log}"
echo 'eslz-demo' | PATH="${mock_bin_dir}:${PATH}" AZ_CALL_LOG="${az_call_log}" ESLZ_TEARDOWN_CONFIRMATION='DELETE-ESLZ-DEMO' \
  bash "${PROJECT_DIR}/scripts/teardown.sh" "${whitespace_param_file}" --execute >/dev/null
if rg -qi 'rg-eslz-demo-monitoring' "${az_call_log}"; then
  printf 'ERROR: teardown.sh must never touch rg-eslz-demo-monitoring when existingLogAnalyticsWorkspaceResourceId is a whitespace-only value (Bicep treats it as supplied).\n' >&2
  cat "${az_call_log}" >&2
  exit 1
fi

if command -v pwsh >/dev/null 2>&1; then
  : > "${az_call_log}"
  echo 'eslz-demo' | PATH="${mock_bin_dir}:${PATH}" AZ_CALL_LOG="${az_call_log}" ESLZ_TEARDOWN_CONFIRMATION='DELETE-ESLZ-DEMO' \
    pwsh -NoLogo -NoProfile -File "${PROJECT_DIR}/scripts/teardown.ps1" "${whitespace_param_file}" -Execute >/dev/null
  if rg -qi 'rg-eslz-demo-monitoring' "${az_call_log}"; then
    printf 'ERROR: teardown.ps1 must never touch rg-eslz-demo-monitoring when existingLogAnalyticsWorkspaceResourceId is a whitespace-only value (Bicep treats it as supplied).\n' >&2
    cat "${az_call_log}" >&2
    exit 1
  fi
fi

printf '18/18 Parse cross-platform scripts and check macOS Bash 3.2 compatibility...\n'
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
