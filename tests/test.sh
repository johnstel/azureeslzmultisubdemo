#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARTIFACTS_PARENT="${PROJECT_DIR}/.test-artifacts"
TEMP_DIR="${ARTIFACTS_PARENT}/test-sh-$$"
mkdir -p "${TEMP_DIR}"
trap 'rm -rf "${TEMP_DIR}"; rmdir "${ARTIFACTS_PARENT}" 2>/dev/null || true' EXIT

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

printf '1/23 Validate repository versioning and branch guidance...\n'
version_value="$(tr -d '\r\n' < "${PROJECT_DIR}/VERSION")"
[[ "${version_value}" == '2.0.0-dev' ]] || {
  printf 'ERROR: VERSION must be exactly 2.0.0-dev.\n' >&2
  exit 1
}
rg -q '\*\*Version status:\*\* `main` is the \*\*v2 development line\*\* \(`2\.0\.0-dev`\)\.' "${PROJECT_DIR}/README.md"
rg -q 'https://github\.com/johnstel/azureeslzmultisubdemo/releases/tag/v1\.0\.0' "${PROJECT_DIR}/README.md"
rg -q 'https://github\.com/johnstel/azureeslzmultisubdemo/tree/release/v1' "${PROJECT_DIR}/README.md"
rg -q 'https://github\.com/johnstel/azureeslzmultisubdemo/issues\?q=milestone%3A%22v2\.0\.0%22' "${PROJECT_DIR}/README.md"

printf '2/23 Build the complete tenant template and validate policy assignment shapes...\n'
az_build_stderr="$(az bicep build --file "${PROJECT_DIR}/main.bicep" --outfile "${TEMP_DIR}/main.json" 2>&1 1>/dev/null)"
if printf '%s' "${az_build_stderr}" | rg -q 'BCP318'; then
  printf 'ERROR: main.bicep build must not emit a BCP318 nullable-module-output warning.\n' >&2
  printf '%s\n' "${az_build_stderr}" >&2
  exit 1
fi
COMPILED_MAIN_TEMPLATE="${TEMP_DIR}/main.json" "${SCRIPT_DIR}/validate-policy-assignment.sh"
printf '    Confirm the exact six-tag initiative and compliant evidence resource groups...\n'
jq -e '
  def deployment($name):
    first(.. | objects | select(.type? == "Microsoft.Resources/deployments" and .name? == $name));
  ["CostCenter", "ApplicationName", "Owner", "Environment", "DataClassification", "SSP-ID"] as $requiredTags |
  deployment("resource-group-tags-initiative") as $initiative |
  deployment("assign-resource-group-tags") as $assignment |
  deployment("connectivity-evidence") as $connectivityEvidence |
  deployment("workload-evidence") as $workloadEvidence |
  ($initiative.properties.parameters.policyDefinitionReferences.value |
    map({key: .policyDefinitionReferenceId, value: .parameters.tagName.value}) | from_entries) as $tagsByReference |
  ($initiative.properties.parameters.policyDefinitionReferences.value | map(.parameters.tagName.value) | sort) ==
    ($requiredTags | sort) and
  ($initiative.properties.parameters.policyDefinitionReferences.value | length) == 6 and
  ([$initiative.properties.parameters.policyDefinitionReferences.value[].policyDefinitionId] | unique) ==
    ["[variables(\u0027requireResourceGroupTagPolicyDefinitionId\u0027)]"] and
  all($initiative.properties.parameters.policyDefinitionReferences.value[]; .definitionVersion == "1.*.*") and
  ($initiative.scope | contains("demoRootManagementGroupId")) and
  ($assignment.scope | contains("landingZonesManagementGroupId")) and
  ($assignment.properties.parameters.enforcementMode.value == "[parameters(\u0027denyPolicyEnforcementMode\u0027)]") and
  ($assignment.properties.parameters.nonComplianceMessages.value | length) == 6 and
  ($assignment.properties.parameters.nonComplianceMessages.value | map(.policyDefinitionReferenceId) | sort) ==
    ($initiative.properties.parameters.policyDefinitionReferences.value | map(.policyDefinitionReferenceId) | sort) and
  all($assignment.properties.parameters.nonComplianceMessages.value[];
    $tagsByReference[.policyDefinitionReferenceId] as $tag |
    $tag != null and .message == "Resource groups must include the \($tag) tag.") and
  (all($requiredTags[]; $connectivityEvidence.properties.template.variables.commonTags[.] != null)) and
  (first($workloadEvidence.properties.template.resources[] |
    select(.type == "Microsoft.Resources/resourceGroups")).tags | keys | sort) == ($requiredTags | sort)
' "${TEMP_DIR}/main.json" >/dev/null || {
  printf 'ERROR: Required resource-group tag initiative or evidence tags are invalid.\n' >&2
  exit 1
}
"${SCRIPT_DIR}/validate-remediating-policy-assignment.sh"

printf '3/23 Validate the ARM parameter template...\n'
jq -e '
  .parameters.deployRoleAssignments.value == false and
  .parameters.deployEvidenceResources.value == false and
  .parameters.denyPolicyEnforcementMode.value == "DoNotEnforce"
' "${PROJECT_DIR}/parameters/demo.parameters.template.json" >/dev/null
az bicep build-params \
  --file "${PROJECT_DIR}/parameters/main.template.bicepparam" \
  --outfile "${TEMP_DIR}/main.parameters.json"

printf '4/23 Confirm there are exactly two unconditional subscription associations...\n'
association_count="$(jq '[.. | objects | select(.type? == "Microsoft.Management/managementGroups/subscriptions") | select(has("condition") | not)] | length' "${TEMP_DIR}/main.json")"
[[ "${association_count}" -eq 2 ]] || {
  printf 'ERROR: Expected 2 unconditional subscription association resources, found %s.\n' "${association_count}" >&2
  exit 1
}

printf '5/23 Confirm no paid always-on resource types are declared outside the opt-in central monitoring module...\n'
if rg -n \
  "Microsoft\\.(Compute/virtualMachines|OperationalInsights/workspaces|Network/(azureFirewalls|bastionHosts|natGateways|publicIPAddresses|virtualNetworkGateways)|Storage/storageAccounts)" \
  "${PROJECT_DIR}/main.bicep" "${PROJECT_DIR}/modules" \
  -g '*.bicep' | rg -v 'policy-library\.bicep|central-monitoring(-workspace|-sentinel)?\.bicep'; then
  printf 'ERROR: A prohibited evidence resource type is declared.\n' >&2
  exit 1
fi

printf '6/23 Confirm tenant-root scope is only used as the parent hierarchy input...\n'
if rg -n 'scope:\\s*managementGroup\\(tenantRootManagementGroupId\\)' "${PROJECT_DIR}" -g '*.bicep'; then
  printf 'ERROR: A module or resource assigns governance directly at the tenant root.\n' >&2
  exit 1
fi

printf '7/23 Confirm five distinct Entra group parameters and guarded scripts...\n'
group_param_count="$(rg -c '^param (governanceAdminsGroupObjectId|subscriptionOwnersGroupObjectId|networkOperatorsGroupObjectId|workloadContributorsGroupObjectId|readOnlyAuditorsGroupObjectId) string$' "${PROJECT_DIR}/main.bicep")"
[[ "${group_param_count}" -eq 5 ]] || {
  printf 'ERROR: Expected five Entra security-group parameters.\n' >&2
  exit 1
}
rg -q 'DEPLOY-ESLZ-DEMO' "${PROJECT_DIR}/scripts/deploy.sh"
rg -q 'DELETE-ESLZ-DEMO' "${PROJECT_DIR}/scripts/teardown.sh"
rg -q 'DEPLOY-ESLZ-DEMO' "${PROJECT_DIR}/scripts/deploy.ps1"
rg -q 'DELETE-ESLZ-DEMO' "${PROJECT_DIR}/scripts/teardown.ps1"

printf '8/23 Confirm region policy safely permits global resources...\n'
rg -q "field: 'location'" "${PROJECT_DIR}/modules/policy-library.bicep"
rg -q "notEquals: 'global'" "${PROJECT_DIR}/modules/policy-library.bicep"
rg -q "notEquals: 'Microsoft.AzureActiveDirectory/b2cDirectories'" "${PROJECT_DIR}/modules/policy-library.bicep"

printf '9/23 Confirm the Critical Infrastructure branch is opt-in and correctly wired...\n'
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

printf '10/23 Confirm criticalInfrastructureSubscriptionIds validates duplicates and overlap...\n'
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

printf '11/23 Confirm teardown scripts move critical subscriptions and delete the Critical Infrastructure management group before Landing Zones...\n'
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
landingzones_delete_line_ps1="$(rg -n '\$managementGroups \+= "\$prefix-landingzones"' "${PROJECT_DIR}/scripts/teardown.ps1" | head -1 | cut -d: -f1)"
[[ -n "${critical_sub_move_line_ps1}" && -n "${critical_mg_delete_line_ps1}" && -n "${landingzones_delete_line_ps1}" ]] || {
  printf 'ERROR: teardown.ps1 is missing the critical infrastructure subscription move or management group deletion.\n' >&2
  exit 1
}
[[ "${critical_sub_move_line_ps1}" -lt "${critical_mg_delete_line_ps1}" && "${critical_mg_delete_line_ps1}" -lt "${landingzones_delete_line_ps1}" ]] || {
  printf 'ERROR: teardown.ps1 must move critical infrastructure subscriptions, then delete the Critical Infrastructure management group before Landing Zones.\n' >&2
  exit 1
}

printf '12/23 Confirm central monitoring defaults create no metered resources...\n'
jq -e '
  .parameters.deployCentralLogAnalytics.value == false and
  .parameters.deploySentinel.value == false and
  .parameters.existingLogAnalyticsWorkspaceResourceId.value == ""
' "${PROJECT_DIR}/parameters/demo.parameters.template.json" >/dev/null
rg -q "^param deployCentralLogAnalytics bool = false$" "${PROJECT_DIR}/modules/central-monitoring.bicep"
rg -q "^param deploySentinel bool = false$" "${PROJECT_DIR}/modules/central-monitoring.bicep"
rg -q "^param existingLogAnalyticsWorkspaceResourceId string = ''$" "${PROJECT_DIR}/modules/central-monitoring.bicep"

printf "13/23 Confirm central monitoring guards against conflicting new/existing workspace inputs and Sentinel-without-workspace...\n"
rg -q 'conflictingMonitoringInputs = newWorkspaceRequested && existingWorkspaceSupplied' "${PROJECT_DIR}/modules/central-monitoring.bicep"
rg -q 'sentinelRequiresEffectiveWorkspace = deploySentinel && !newWorkspaceRequested && !existingWorkspaceSupplied' "${PROJECT_DIR}/modules/central-monitoring.bicep"
rg -q 'createNewWorkspace = newWorkspaceRequested && !hasMonitoringConfigurationError' "${PROJECT_DIR}/modules/central-monitoring.bicep"
rg -q 'useExistingWorkspace = existingWorkspaceSupplied && !hasMonitoringConfigurationError' "${PROJECT_DIR}/modules/central-monitoring.bicep"

printf '14/23 Confirm the central monitoring module exposes an effective workspace ID output...\n'
rg -q '^output effectiveLogAnalyticsWorkspaceResourceId string' "${PROJECT_DIR}/modules/central-monitoring.bicep"
rg -q 'centralMonitoringEffectiveWorkspaceId string = centralMonitoring\.outputs\.effectiveLogAnalyticsWorkspaceResourceId' "${PROJECT_DIR}/main.bicep"

printf '15/23 Confirm invalid central monitoring configurations fail deployment explicitly...\n'
rg -q "resource conflictingMonitoringInputsGuard 'Microsoft.CentralMonitoringGuard/configurationError@" "${PROJECT_DIR}/modules/central-monitoring.bicep"
rg -q 'if \(conflictingMonitoringInputs\)' "${PROJECT_DIR}/modules/central-monitoring.bicep"
rg -q "resource sentinelRequiresWorkspaceGuard 'Microsoft.CentralMonitoringGuard/configurationError@" "${PROJECT_DIR}/modules/central-monitoring.bicep"
rg -q 'if \(sentinelRequiresEffectiveWorkspace\)' "${PROJECT_DIR}/modules/central-monitoring.bicep"

printf '16/23 Confirm teardown scripts protect a supplied existing workspace resource group and only remove a demo-created monitoring resource group...\n'
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

printf '17/23 Confirm a whitespace-only existing workspace resource ID never triggers deletion of the monitoring resource group...\n'
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

printf '18/23 Parse cross-platform scripts and check macOS Bash 3.2 compatibility...\n'
"${SCRIPT_DIR}/validate-tag-policy-migration.sh"
for shell_script in "${PROJECT_DIR}"/scripts/*.sh "${PROJECT_DIR}"/tests/*.sh; do
  bash -n "${shell_script}"
done
# Bash 4+ constructs banned for macOS Bash 3.2 compatibility. Every banned
# literal below is deliberately split across a quote boundary (for example
# 'declare -'"A" and \bmap''file\b) so that this very definition line does
# not itself contain any banned substring contiguously -- each quote/paste
# boundary breaks up the literal text on disk even though bash concatenates
# the pieces back into the correct pattern value at runtime. This lets the
# scan below cover test.sh itself (unlike a `-g '!test.sh'` exclusion, which
# would leave test.sh permanently unprotected against a future regression)
# without the pattern definition line matching its own scan.
banned_bash4_pattern='declare -'"A"'|\$\{[^}]+,,\}|\$\{[^}]+\^\^\}|\bmap''file\b|\bread''array\b'
# A real stock Bash 3.2 interpreter is not available in every environment
# (this sandbox only ships Bash 5.x), so `bash -n` above only proves each
# script is Bash-5-syntax-valid; it does NOT execute the script under Bash
# 3.2, so it cannot itself catch a missing Bash 4+ array-reading builtin
# (syntactically valid in Bash 5, but absent as a command and only failing at
# runtime on Bash < 4.0). When a real Bash 3.2 (or any Bash < 4.0) is present
# on PATH, exercise the validator scripts under it directly as a
# defense-in-depth check beyond the static banned-construct scan below.
bash3_candidate=""
for bash_bin in /usr/local/bin/bash /opt/homebrew/bin/bash /bin/bash; do
  if [[ -x "${bash_bin}" ]] && "${bash_bin}" -c '[[ "${BASH_VERSINFO[0]}" -lt 4 ]]' 2>/dev/null; then
    bash3_candidate="${bash_bin}"
    break
  fi
done
if [[ -n "${bash3_candidate}" ]]; then
  printf '  Found a Bash < 4.0 interpreter (%s); executing Bash validators under it...\n' "${bash3_candidate}"
  for bash3_validator in validate-control-catalog.sh validate-initiative-composition.sh; do
    if ! "${bash3_candidate}" "${PROJECT_DIR}/tests/${bash3_validator}" >/dev/null; then
      printf 'ERROR: tests/%s failed when executed directly under %s.\n' "${bash3_validator}" "${bash3_candidate}" >&2
      exit 1
    fi
  done
else
  printf '  (No Bash < 4.0 interpreter found on PATH; relying on the static banned-construct scan below plus `bash -n` syntax checks.)\n'
fi
if rg -n "${banned_bash4_pattern}" "${PROJECT_DIR}/scripts" "${PROJECT_DIR}/tests" -g '*.sh'; then
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

printf '19/23 Validate reusable initiative composition...\n'
"${SCRIPT_DIR}/validate-initiative-composition.sh"

printf '20/23 Validate the v2 control catalog (schema-equivalent checks + matrix consistency)...\n'
"${SCRIPT_DIR}/validate-control-catalog.sh"

printf '21/23 Backend parity and structural-matrix regression tests (bash/python, bash/jq, pwsh/python, pwsh/native)...\n'
"${SCRIPT_DIR}/uri-grammar-forced-fallback-tests.sh"

printf '22/23 Validate Entra Conditional Access and PIM demo artifacts...\n'
"${PROJECT_DIR}/scripts/validate-identity-artifacts.sh"

printf '23/23 Confirm identity validators reject invalid Conditional Access and PIM inputs...\n'
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

# Like expect_identity_validation_failure, but also asserts the failure
# reason: some negative fixtures would still fail even without the fix under
# test (e.g. a nested-symlink containment bypass reusing tracked, still-
# unpopulated templates would separately trip the REPLACE_WITH_* placeholder
# check), which would let a regression pass this check for the wrong reason.
# Requiring the specific containment-guard message confirms the guard itself
# is what rejected the input.
expect_identity_validation_failure_with_message() {
  local description="$1"
  local expected_message="$2"
  shift 2
  local output
  if output="$("${PROJECT_DIR}/scripts/validate-identity-artifacts.sh" "$@" 2>&1)"; then
    printf 'ERROR: validate-identity-artifacts.sh unexpectedly succeeded for case: %s\n' "${description}" >&2
    exit 1
  fi
  if ! printf '%s' "${output}" | grep -qF "${expected_message}"; then
    printf 'ERROR: validate-identity-artifacts.sh failed for case: %s, but not for the expected reason.\nExpected message to contain: %s\nActual output: %s\n' \
      "${description}" "${expected_message}" "${output}" >&2
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

# Case: the full JSON Schema (not just hand-picked field checks) must be
# enforced. additionalProperties: false means an unknown/unexpected field on
# a Conditional Access template must fail even though every field the
# manual checks inspect is otherwise valid.
rm -rf "${IDENTITY_NEG_DIR}" && cp -r "${IDENTITY_SRC_DIR}" "${IDENTITY_NEG_DIR}"
jq '. + {unknownField: "not part of the schema"}' \
  "${IDENTITY_NEG_DIR}/conditional-access/ca-azure-mgmt-mfa.template.json" > "${TEMP_DIR}/tmp.json" \
  && mv "${TEMP_DIR}/tmp.json" "${IDENTITY_NEG_DIR}/conditional-access/ca-azure-mgmt-mfa.template.json"
expect_identity_validation_failure "unknown property rejected by Conditional Access JSON Schema (additionalProperties: false)" --path "${IDENTITY_NEG_DIR}"

# Case: same additionalProperties: false enforcement for the PIM schema, at
# a nested level (activation), not just at the document root.
rm -rf "${IDENTITY_NEG_DIR}" && cp -r "${IDENTITY_SRC_DIR}" "${IDENTITY_NEG_DIR}"
jq '.activation += {unknownField: "not part of the schema"}' \
  "${IDENTITY_NEG_DIR}/pim/pim-activation-global-administrator.template.json" > "${TEMP_DIR}/tmp.json" \
  && mv "${TEMP_DIR}/tmp.json" "${IDENTITY_NEG_DIR}/pim/pim-activation-global-administrator.template.json"
expect_identity_validation_failure "unknown nested property rejected by PIM JSON Schema (additionalProperties: false)" --path "${IDENTITY_NEG_DIR}"

# Case: the JSON Schema's "type": "integer" must reject a non-integer value
# for maximumActivationDurationHours even independent of the dedicated
# range/type check above (schema-level enforcement, not just the manual
# field check).
rm -rf "${IDENTITY_NEG_DIR}" && cp -r "${IDENTITY_SRC_DIR}" "${IDENTITY_NEG_DIR}"
jq '.activation.maximumActivationDurationHours = "4"' \
  "${IDENTITY_NEG_DIR}/pim/pim-activation-global-administrator.template.json" > "${TEMP_DIR}/tmp.json" \
  && mv "${TEMP_DIR}/tmp.json" "${IDENTITY_NEG_DIR}/pim/pim-activation-global-administrator.template.json"
expect_identity_validation_failure "string-typed PIM maximumActivationDurationHours rejected by JSON Schema" --path "${IDENTITY_NEG_DIR}"

# Case: the populated-mode tracked-folder containment check must canonicalize
# both the requested --path and the tracked identity/ folder before
# comparing, so unnormalized bypass forms cannot slip a real, tenant-specific
# populated copy into the tracked identity/ folder undetected.
expect_identity_validation_failure "populated mode bypass via unnormalized relative './identity' path" --mode populated --path "${PROJECT_DIR}/./identity"
expect_identity_validation_failure "populated mode bypass via unnormalized absolute path with a nested '..' segment" --mode populated --path "${PROJECT_DIR}/identity/conditional-access/../../identity"
(
  cd "${PROJECT_DIR}" && expect_identity_validation_failure "populated mode bypass via unnormalized relative 'scripts/../identity' path" --mode populated --path "scripts/../identity"
)
(
  cd "${PROJECT_DIR}" && expect_identity_validation_failure "populated mode bypass via unnormalized relative './identity' path from repo root" --mode populated --path "./identity"
)

# Case: a symbolic link that targets the tracked identity/ folder must also
# be rejected by the populated-mode guard. Canonicalizing '.'/'..' segments
# alone is not sufficient here; the alias itself must be dereferenced to its
# final filesystem target (via `cd`+`pwd -P`) before the containment check.
IDENTITY_SYMLINK_DIR="${TEMP_DIR}/identity-symlink-alias"
rm -rf "${IDENTITY_SYMLINK_DIR}" && ln -s "${PROJECT_DIR}/identity" "${IDENTITY_SYMLINK_DIR}"
expect_identity_validation_failure "populated mode bypass via a symbolic link aliasing the tracked identity/ folder" --mode populated --path "${IDENTITY_SYMLINK_DIR}"
rm -f "${IDENTITY_SYMLINK_DIR}"

# Case: an otherwise-legitimate external --path root whose conditional-access/
# or pim/ subdirectory is itself a symbolic link back into the tracked
# identity/ folder must be rejected. Only checking the containment of the
# requested root is not sufficient: the root can resolve outside identity/
# while a nested directory constructed beneath it aliases the tracked,
# unpopulated tree. Each subdirectory is tested in isolation (the other
# subdirectory is a genuine, non-symlinked copy) so that one containment
# check rejecting first cannot mask another one silently never being
# exercised. Schema/reference files are always read from the tracked
# repository's canonical identity/schema/ tree, independent of --path, so
# there is no schema containment check to bypass -- see the schema-ignored
# regression below instead.
make_isolated_bypass_dir() {
  local target_dir="$1"
  rm -rf "${target_dir}"
  cp -r "${IDENTITY_POP_DIR}" "${target_dir}"
}

IDENTITY_BYPASS_CA_DIR="${TEMP_DIR}/identity-bypass-ca-dir"
make_isolated_bypass_dir "${IDENTITY_BYPASS_CA_DIR}"
rm -rf "${IDENTITY_BYPASS_CA_DIR}/conditional-access"
ln -s "${PROJECT_DIR}/identity/conditional-access" "${IDENTITY_BYPASS_CA_DIR}/conditional-access"
expect_identity_validation_failure_with_message "populated mode bypass via a symbolic link aliasing the tracked conditional-access/ subdirectory (pim/ genuine)" "the conditional-access/ directory" --mode populated --path "${IDENTITY_BYPASS_CA_DIR}"
rm -rf "${IDENTITY_BYPASS_CA_DIR}"

IDENTITY_BYPASS_PIM_DIR="${TEMP_DIR}/identity-bypass-pim-dir"
make_isolated_bypass_dir "${IDENTITY_BYPASS_PIM_DIR}"
rm -rf "${IDENTITY_BYPASS_PIM_DIR}/pim"
ln -s "${PROJECT_DIR}/identity/pim" "${IDENTITY_BYPASS_PIM_DIR}/pim"
expect_identity_validation_failure_with_message "populated mode bypass via a symbolic link aliasing the tracked pim/ subdirectory (conditional-access/ genuine)" "the pim/ directory" --mode populated --path "${IDENTITY_BYPASS_PIM_DIR}"
rm -rf "${IDENTITY_BYPASS_PIM_DIR}"

# Case: an otherwise-legitimate external --path root with genuine, external
# conditional-access/ and pim/ directories, but whose individual files are
# themselves symbolic links back into the tracked identity/ folder, must
# also be rejected. Directory-level containment checks alone do not catch a
# symlinked leaf file. Each artifact type's files are tested in isolation
# (the other directory's files are genuine, non-symlinked copies), so that
# Conditional Access's containment check rejecting first cannot mask the
# PIM per-file check silently never being exercised.
IDENTITY_BYPASS_CA_FILE_DIR="${TEMP_DIR}/identity-bypass-ca-file"
make_isolated_bypass_dir "${IDENTITY_BYPASS_CA_FILE_DIR}"
for f in "${IDENTITY_BYPASS_CA_FILE_DIR}/conditional-access"/*.template.json; do
  name="$(basename "${f}")"
  rm -f "${f}"
  ln -s "${PROJECT_DIR}/identity/conditional-access/${name}" "${f}"
done
expect_identity_validation_failure_with_message "populated mode bypass via symbolic-link Conditional Access template files (PIM files genuine)" "outside the tracked identity/ folder" --mode populated --path "${IDENTITY_BYPASS_CA_FILE_DIR}"
rm -rf "${IDENTITY_BYPASS_CA_FILE_DIR}"

IDENTITY_BYPASS_PIM_FILE_DIR="${TEMP_DIR}/identity-bypass-pim-file"
make_isolated_bypass_dir "${IDENTITY_BYPASS_PIM_FILE_DIR}"
for f in "${IDENTITY_BYPASS_PIM_FILE_DIR}/pim"/*.template.json; do
  name="$(basename "${f}")"
  rm -f "${f}"
  ln -s "${PROJECT_DIR}/identity/pim/${name}" "${f}"
done
expect_identity_validation_failure_with_message "populated mode bypass via symbolic-link PIM template files (Conditional Access files genuine)" "outside the tracked identity/ folder" --mode populated --path "${IDENTITY_BYPASS_PIM_FILE_DIR}"
rm -rf "${IDENTITY_BYPASS_PIM_FILE_DIR}"

# Case: schema/reference files are always read from the tracked repository's
# canonical identity/schema/ tree, never from a caller-supplied --path. A
# malicious or malformed schema/ directory under an external populated root
# must therefore be silently ignored rather than read -- validation must
# still succeed using the tracked schemas.
IDENTITY_SCHEMA_IGNORED_DIR="${TEMP_DIR}/identity-schema-ignored"
make_isolated_bypass_dir "${IDENTITY_SCHEMA_IGNORED_DIR}"
rm -rf "${IDENTITY_SCHEMA_IGNORED_DIR}/schema"
mkdir -p "${IDENTITY_SCHEMA_IGNORED_DIR}/schema"
echo '{"not":"a real schema"}' > "${IDENTITY_SCHEMA_IGNORED_DIR}/schema/known-entra-ids.json"
"${PROJECT_DIR}/scripts/validate-identity-artifacts.sh" --mode populated --path "${IDENTITY_SCHEMA_IGNORED_DIR}" >/dev/null
rm -rf "${IDENTITY_SCHEMA_IGNORED_DIR}"

# Case: the tracked identity/schema/ tree used above is always resolved
# relative to the *validator script file's own location* (never the
# caller-supplied --path). That location must therefore be derived from the
# script file's fully resolved final target, not its unresolved invocation
# path -- otherwise invoking the validator through a symbolic link (e.g. a
# wrapper/shim placed elsewhere) would silently make an external, permissive
# identity/schema/ directory placed beside that symlink into the "trusted"
# schema root, defeating the whole point of always using tracked schemas.
# Both a direct symlink to the script file and a chained symlink (a symlink
# to a symlink to the script file) must be fully dereferenced.
IDENTITY_SCRIPT_SYMLINK_ROOT="${TEMP_DIR}/identity-script-symlink-root"
rm -rf "${IDENTITY_SCRIPT_SYMLINK_ROOT}"
mkdir -p "${IDENTITY_SCRIPT_SYMLINK_ROOT}/identity/schema"
echo '{"not":"a real schema"}' > "${IDENTITY_SCRIPT_SYMLINK_ROOT}/identity/schema/known-entra-ids.json"
echo '{"not":"a real schema"}' > "${IDENTITY_SCRIPT_SYMLINK_ROOT}/identity/schema/conditional-access-policy.schema.json"
echo '{"not":"a real schema"}' > "${IDENTITY_SCRIPT_SYMLINK_ROOT}/identity/schema/pim-activation-policy.schema.json"
ln -s "${PROJECT_DIR}/scripts/validate-identity-artifacts.sh" "${IDENTITY_SCRIPT_SYMLINK_ROOT}/validator-direct.sh"
ln -s "${IDENTITY_SCRIPT_SYMLINK_ROOT}/validator-direct.sh" "${IDENTITY_SCRIPT_SYMLINK_ROOT}/validator-chained.sh"

# Positive control: a genuinely valid populated artifact tree must still
# validate successfully when invoked through the symlinked script file(s),
# proving the canonical (not the permissive external) schema was used.
"${IDENTITY_SCRIPT_SYMLINK_ROOT}/validator-direct.sh" --mode populated --path "${IDENTITY_POP_DIR}" >/dev/null
"${IDENTITY_SCRIPT_SYMLINK_ROOT}/validator-chained.sh" --mode populated --path "${IDENTITY_POP_DIR}" >/dev/null

# Negative control: an artifact that is genuinely invalid under the
# canonical tracked schema must still be rejected -- and for the genuine
# schema-driven reason -- when invoked through the same script-file
# symlinks, proving the permissive external schema was not what was loaded.
IDENTITY_SCRIPT_SYMLINK_NEG_DIR="${TEMP_DIR}/identity-script-symlink-neg"
rm -rf "${IDENTITY_SCRIPT_SYMLINK_NEG_DIR}" && cp -r "${IDENTITY_POP_DIR}" "${IDENTITY_SCRIPT_SYMLINK_NEG_DIR}"
jq '.activation.approvers = ["sales-team"]' \
  "${IDENTITY_SCRIPT_SYMLINK_NEG_DIR}/pim/pim-activation-global-administrator.template.json" > "${TEMP_DIR}/tmp.json" \
  && mv "${TEMP_DIR}/tmp.json" "${IDENTITY_SCRIPT_SYMLINK_NEG_DIR}/pim/pim-activation-global-administrator.template.json"
for script_symlink in "${IDENTITY_SCRIPT_SYMLINK_ROOT}/validator-direct.sh" "${IDENTITY_SCRIPT_SYMLINK_ROOT}/validator-chained.sh"; do
  if output="$("${script_symlink}" --mode populated --path "${IDENTITY_SCRIPT_SYMLINK_NEG_DIR}" 2>&1)"; then
    printf 'ERROR: validate-identity-artifacts.sh unexpectedly succeeded for case: invalid PIM approver rejected through a script-file symlink (%s)\n' "${script_symlink}" >&2
    exit 1
  fi
  if ! printf '%s' "${output}" | grep -qF "sales-team"; then
    printf 'ERROR: validate-identity-artifacts.sh failed for case: invalid PIM approver rejected through a script-file symlink (%s), but not for the expected reason.\nActual output: %s\n' \
      "${script_symlink}" "${output}" >&2
    exit 1
  fi
done
rm -rf "${IDENTITY_SCRIPT_SYMLINK_ROOT}" "${IDENTITY_SCRIPT_SYMLINK_NEG_DIR}"

# Case: on a genuinely case-insensitive filesystem (default macOS APFS,
# exFAT/vfat, some NTFS/SMB mounts), a casing variant of the tracked
# identity/ folder (e.g. IDENTITY) transparently resolves to the exact same
# directory with no symlink involved at all. `filesystem_is_case_insensitive`
# must detect this by probing the real filesystem rather than assuming
# case-(in)sensitivity from uname/OS, and the containment check must fold
# case before comparing when it does. Tested here against a loopback-mounted
# vfat (genuinely case-insensitive) filesystem containing its own copy of the
# script and identity/ folder, so PROJECT_DIR itself resolves inside the
# case-insensitive filesystem (mirroring a case-insensitive-volume checkout).
# Skipped (not failed) if a case-insensitive filesystem cannot be created
# in this environment (no mkfs.vfat, no root/passwordless sudo, no loop
# device support), since this exercises real filesystem behavior rather
# than mocked assumptions.
CASE_INSENSITIVE_IMG="${TEMP_DIR}/case-insensitive-fs.img"
CASE_INSENSITIVE_MNT="${TEMP_DIR}/case-insensitive-mnt"
if command -v mkfs.vfat >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  mkdir -p "${CASE_INSENSITIVE_MNT}"
  dd if=/dev/zero of="${CASE_INSENSITIVE_IMG}" bs=1M count=16 >/dev/null 2>&1
  mkfs.vfat "${CASE_INSENSITIVE_IMG}" >/dev/null 2>&1
  if sudo -n mount -o loop,uid="$(id -u)",gid="$(id -g)" "${CASE_INSENSITIVE_IMG}" "${CASE_INSENSITIVE_MNT}" 2>/dev/null; then
    CASE_INSENSITIVE_REPO="${CASE_INSENSITIVE_MNT}/repo"
    mkdir -p "${CASE_INSENSITIVE_REPO}/scripts"
    cp "${PROJECT_DIR}/scripts/validate-identity-artifacts.sh" "${CASE_INSENSITIVE_REPO}/scripts/"
    cp -r "${IDENTITY_SRC_DIR}" "${CASE_INSENSITIVE_REPO}/identity"
    if bash "${CASE_INSENSITIVE_REPO}/scripts/validate-identity-artifacts.sh" \
      --mode populated --path "${CASE_INSENSITIVE_REPO}/IDENTITY" >/dev/null 2>&1; then
      printf 'ERROR: validate-identity-artifacts.sh unexpectedly succeeded for case: %s\n' \
        "populated mode bypass via a casing variant of the tracked identity/ folder on a genuinely case-insensitive filesystem" >&2
      sudo -n umount "${CASE_INSENSITIVE_MNT}" 2>/dev/null || true
      exit 1
    fi
    sudo -n umount "${CASE_INSENSITIVE_MNT}" 2>/dev/null || true
  else
    printf '  (skipping case-insensitive filesystem test: unable to mount a loopback vfat filesystem in this environment)\n'
  fi
else
  printf '  (skipping case-insensitive filesystem test: mkfs.vfat or passwordless sudo not available in this environment)\n'
fi
rm -f "${CASE_INSENSITIVE_IMG}"

rm -rf "${IDENTITY_NEG_DIR}" "${IDENTITY_POP_DIR}"

printf '\nAll local validation and safety tests passed.\n'
