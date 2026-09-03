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

printf '1/28 Validate repository versioning and branch guidance...\n'
version_value="$(tr -d '\r\n' < "${PROJECT_DIR}/VERSION")"
[[ "${version_value}" == '2.0.0-dev' ]] || {
  printf 'ERROR: VERSION must be exactly 2.0.0-dev.\n' >&2
  exit 1
}
rg -q '\*\*Version status:\*\* `main` is the \*\*v2 development line\*\* \(`2\.0\.0-dev`\)\.' "${PROJECT_DIR}/README.md"
rg -q 'https://github\.com/johnstel/azureeslzmultisubdemo/releases/tag/v1\.0\.0' "${PROJECT_DIR}/README.md"
rg -q 'https://github\.com/johnstel/azureeslzmultisubdemo/tree/release/v1' "${PROJECT_DIR}/README.md"
rg -q 'https://github\.com/johnstel/azureeslzmultisubdemo/issues\?q=milestone%3A%22v2\.0\.0%22' "${PROJECT_DIR}/README.md"

printf '2/28 Build the complete tenant template and validate policy assignment shapes...\n'
az_build_stderr="$(az bicep build --file "${PROJECT_DIR}/main.bicep" --outfile "${TEMP_DIR}/main.json" 2>&1 1>/dev/null)"
if printf '%s' "${az_build_stderr}" | rg -q 'BCP318'; then
  printf 'ERROR: main.bicep build must not emit a BCP318 nullable-module-output warning.\n' >&2
  printf '%s\n' "${az_build_stderr}" >&2
  exit 1
fi
az bicep build \
  --file "${PROJECT_DIR}/identity/azure-rbac/owner-eligibility-request.bicep" \
  --outfile "${TEMP_DIR}/owner-eligibility-request.json" >/dev/null
COMPILED_MAIN_TEMPLATE="${TEMP_DIR}/main.json" "${SCRIPT_DIR}/validate-policy-assignment.sh"
printf '    Confirm the exact six-tag initiative and compliant evidence resource groups...\n'
jq -e '
  def deployment($name):
    first(.. | objects | select(.type? == "Microsoft.Resources/deployments" and .name? == $name));
  ["CostCenter", "ApplicationName", "Owner", "Environment", "DataClassification", "SSP-ID"] as $requiredTags |
  deployment("resource-group-tags-initiative") as $initiative |
  deployment("assign-resource-group-tags") as $assignment |
  deployment("tag-inheritance-initiative") as $inheritanceInitiative |
  deployment("assign-tag-inheritance") as $inheritanceAssignment |
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
  ($inheritanceInitiative.properties.parameters.policyDefinitionReferences.value | length) == 6 and
  ($inheritanceInitiative.properties.parameters.policyDefinitionReferences.value | map(.parameters.tagName.value) | sort) ==
    ($requiredTags | sort) and
  ([$inheritanceInitiative.properties.parameters.policyDefinitionReferences.value[].policyDefinitionId] | unique) ==
    ["[variables(\u0027inheritResourceGroupTagPolicyDefinitionId\u0027)]"] and
  all($inheritanceInitiative.properties.parameters.policyDefinitionReferences.value[];
    .definitionVersion == "1.*.*" and (.policyDefinitionReferenceId | startswith("inherit-"))) and
  ($inheritanceInitiative.scope | contains("demoRootManagementGroupId")) and
  ($inheritanceAssignment.scope | contains("landingZonesManagementGroupId")) and
  $inheritanceAssignment.properties.parameters.location.value == "[parameters(\u0027deploymentLocation\u0027)]" and
  $inheritanceAssignment.properties.parameters.identity.value == {"type": "SystemAssigned"} and
  $inheritanceAssignment.properties.parameters.verifiedRoleDefinitionIds.value ==
    ["[variables(\u0027contributorRoleDefinitionId\u0027)]"] and
  $inheritanceAssignment.properties.parameters.enforcementMode.value ==
    "[parameters(\u0027denyPolicyEnforcementMode\u0027)]" and
  $inheritanceAssignment.condition == "[parameters(\u0027enableTagInheritance\u0027)]" and
  .parameters.enableTagInheritance.defaultValue == false and
  .outputs.tagInheritanceRemediation.value.enabled == "[parameters(\u0027enableTagInheritance\u0027)]" and
  ([.. | objects | select(.type? == "Microsoft.PolicyInsights/remediations")] | length) == 0 and
  .outputs.tagInheritanceRemediation.value.remediationStarted == false and
  (all($requiredTags[]; $connectivityEvidence.properties.template.variables.commonTags[.] != null)) and
  (first($workloadEvidence.properties.template.resources[] |
    select(.type == "Microsoft.Resources/resourceGroups")).tags | keys | sort) == ($requiredTags | sort)
' "${TEMP_DIR}/main.json" >/dev/null || {
  printf 'ERROR: Required resource-group tag controls, remediation safety, or evidence tags are invalid.\n' >&2
  exit 1
}
jq -e '
  [.controls[] | select(.id | test("^REQ-TAG-(0[7-9]|1[0-2])$"))] as $controls |
  ($controls | length) == 6 and
  all($controls[];
    .mechanism.definitionId == "ea3f2387-9b95-492a-a190-fcdc54f7b070" and
    .mechanism.verificationMethod == "raw-json" and
    .supportedEffects == ["Modify"] and
    .roleDefinitionIds == ["b24988ac-6180-42a0-ab88-20f7382dd24c"] and
    .remediationIdentityRequired == true and
    (.notes | contains("only adds a missing tag")) and
    (.notes | contains("never overwrites an existing tag value")))
' "${PROJECT_DIR}/policy/control-catalog.json" >/dev/null || {
  printf 'ERROR: Verified built-in Modify semantics for tag inheritance are invalid.\n' >&2
  exit 1
}
"${SCRIPT_DIR}/validate-remediating-policy-assignment.sh"

printf '3/28 Validate the ARM parameter template...\n'
jq -e '
  .parameters.deployRoleAssignments.value == false and
  .parameters.deployEvidenceResources.value == false and
  .parameters.enableTagInheritance.value == false and
  .parameters.denyPolicyEnforcementMode.value == "DoNotEnforce" and
  .parameters.networkIngressPolicyEffect.value == "Audit" and
  .parameters.privateAccessPublicNetworkPolicyEffect.value == "Audit" and
  .parameters.privateAccessServiceCategories.value == ["Storage", "KeyVault"] and
  .parameters.enableFirewallRouteGuardrails.value == false and
  .parameters.approvedFirewallResourceId.value == "" and
  .parameters.approvedFirewallPrivateIp.value == "" and
  .parameters.approvedRouteTableResourceIds.value == [] and
  .parameters.approvedRouteTablePrefixes.value == [] and
  .parameters.deployLoggingRemediationRoleAssignments.value == false and
  .parameters.customerAllowedLocations.value == ["eastus", "eastus2"] and
  (.parameters.customerAllowedResourceTypes.value | index("Microsoft.PolicyInsights/remediations")) != null and
  (.parameters.customerAllowedVmSkus.value | length) > 0 and
  .parameters.networkIngressPolicyEffect.value == "Audit"
' "${PROJECT_DIR}/parameters/demo.parameters.template.json" >/dev/null
az bicep build-params \
  --file "${PROJECT_DIR}/parameters/main.template.bicepparam" \
  --outfile "${TEMP_DIR}/main.parameters.json"
jq -e '
  .parameters.networkIngressPolicyEffect.value == "Audit" and
  .parameters.privateAccessPublicNetworkPolicyEffect.value == "Audit" and
  .parameters.privateAccessServiceCategories.value == ["Storage", "KeyVault"] and
  .parameters.enableFirewallRouteGuardrails.value == false and
  .parameters.approvedFirewallResourceId.value == "" and
  .parameters.approvedFirewallPrivateIp.value == "" and
  .parameters.approvedRouteTableResourceIds.value == [] and
  .parameters.approvedRouteTablePrefixes.value == [] and
  .parameters.deployLoggingRemediationRoleAssignments.value == false
' "${TEMP_DIR}/main.parameters.json" >/dev/null
jq -e '.parameters.enableTagInheritance.value == false' "${TEMP_DIR}/main.parameters.json" >/dev/null
for tag_inheritance_enabled in false true; do
  tag_params="${TEMP_DIR}/tag-inheritance-${tag_inheritance_enabled}.bicepparam"
  sed -e "s|^using '../main.bicep'\$|using '../../main.bicep'|" \
    -e 's/^param enableTagInheritance = .*$/param enableTagInheritance = '"${tag_inheritance_enabled}"'/' \
    "${PROJECT_DIR}/parameters/main.template.bicepparam" > "${tag_params}"
  az bicep build-params --file "${tag_params}" --outfile "${tag_params}.json" >/dev/null
  jq -e --argjson enabled "${tag_inheritance_enabled}" \
    '.parameters.enableTagInheritance.value == $enabled' "${tag_params}.json" >/dev/null || {
    printf 'ERROR: Tag-inheritance %s parameter shape did not compile as expected.\n' \
      "${tag_inheritance_enabled}" >&2
    exit 1
  }
done

printf '    Confirm tag remediation workflows remain preview-first and explicitly guarded...\n'
bash_remediation="${PROJECT_DIR}/scripts/remediate-resource-tags.sh"
powershell_remediation="${PROJECT_DIR}/scripts/remediate-resource-tags.ps1"
bash -n "${bash_remediation}"
if command -v pwsh >/dev/null 2>&1; then
  pwsh -NoLogo -NoProfile -Command \
    "\$errors = \$null; [void][System.Management.Automation.Language.Parser]::ParseFile('${powershell_remediation}', [ref]\$null, [ref]\$errors); if (\$errors.Count) { exit 1 }"
else
  printf '  (skipping PowerShell tag-remediation syntax parse: pwsh is not available; tests/test.ps1 provides full coverage)\n'
fi
rg -q -F 'ESLZ_TAG_REMEDIATION_CONFIRMATION' "${bash_remediation}"
rg -q -F 'IFS= read -r typed_confirmation' "${bash_remediation}"
rg -q -F 'validate_live_controls' "${bash_remediation}"
rg -q -F 'az policy remediation create' "${bash_remediation}"
rg -q -F 'Start-AzPolicyRemediation' "${powershell_remediation}"
rg -q -F '$typedConfirmation = Read-Host' "${powershell_remediation}"
rg -q -F 'Test-LiveControls' "${powershell_remediation}"
unsupported_remediation_command='New-AzPolicy''Remediation'
if rg -q -F "${unsupported_remediation_command}" "${PROJECT_DIR}"; then
  printf 'ERROR: The unsupported PowerShell remediation command remains in the repository.\n' >&2
  exit 1
fi
bash_preview_line="$(rg -n -F 'if [[ "${MODE}" != '"'"'--execute'"'"' ]]' "${bash_remediation}" | cut -d: -f1)"
bash_environment_line="$(rg -n -F 'ESLZ_TAG_REMEDIATION_CONFIRMATION' "${bash_remediation}" | tail -n 1 | cut -d: -f1)"
bash_typed_line="$(rg -n -F 'IFS= read -r typed_confirmation' "${bash_remediation}" | cut -d: -f1)"
bash_revalidation_line="$(rg -n -F 'validate_live_controls' "${bash_remediation}" | tail -n 1 | cut -d: -f1)"
bash_create_line="$(rg -n -F 'az policy remediation create' "${bash_remediation}" | cut -d: -f1)"
[[ "${bash_preview_line}" -lt "${bash_environment_line}" \
  && "${bash_environment_line}" -lt "${bash_typed_line}" \
  && "${bash_typed_line}" -lt "${bash_revalidation_line}" \
  && "${bash_revalidation_line}" -lt "${bash_create_line}" ]] \
  || { printf 'ERROR: Bash tag remediation must preview, unlock, type-confirm, revalidate, then create.\n' >&2; exit 1; }
powershell_preview_line="$(rg -n -F 'if (-not $Execute)' "${powershell_remediation}" | cut -d: -f1)"
powershell_environment_line="$(rg -n -F 'ESLZ_TAG_REMEDIATION_CONFIRMATION' "${powershell_remediation}" | tail -n 1 | cut -d: -f1)"
powershell_typed_line="$(rg -n -F '$typedConfirmation = Read-Host' "${powershell_remediation}" | cut -d: -f1)"
powershell_revalidation_line="$(rg -n -F 'Test-LiveControls' "${powershell_remediation}" | tail -n 1 | cut -d: -f1)"
powershell_create_line="$(rg -n -F 'Start-AzPolicyRemediation `' "${powershell_remediation}" | cut -d: -f1)"
[[ "${powershell_preview_line}" -lt "${powershell_environment_line}" \
  && "${powershell_environment_line}" -lt "${powershell_typed_line}" \
  && "${powershell_typed_line}" -lt "${powershell_revalidation_line}" \
  && "${powershell_revalidation_line}" -lt "${powershell_create_line}" ]] \
  || { printf 'ERROR: PowerShell tag remediation must preview, unlock, type-confirm, revalidate, then create.\n' >&2; exit 1; }

printf '4/28 Confirm there are exactly two unconditional subscription associations...\n'
association_count="$(jq '[.. | objects | select(.type? == "Microsoft.Management/managementGroups/subscriptions") | select(has("condition") | not)] | length' "${TEMP_DIR}/main.json")"
[[ "${association_count}" -eq 2 ]] || {
  printf 'ERROR: Expected 2 unconditional subscription association resources, found %s.\n' "${association_count}" >&2
  exit 1
}

printf '5/28 Confirm no paid always-on resource types are declared outside the opt-in central monitoring module...\n'
find_prohibited_paid_declarations() {
  jq -r '
    def prohibited:
      test("^Microsoft\\.(Compute/virtualMachines|OperationalInsights/workspaces|Network/(azureFirewalls|bastionHosts|natGateways|publicIPAddresses|virtualNetworkGateways)|Storage/storageAccounts)$"; "i");
    def declarations:
      if type == "object" then
        . as $resource
        | if $resource.type? == "Microsoft.Resources/deployments"
            and ($resource.name? | IN("central-monitoring", "central-monitoring-workspace", "central-monitoring-sentinel", "activity-log-workspace-destination-rbac", "resource-diagnostics-workspace-destination-rbac"))
          then empty
          elif (($resource.type? | type) == "string") and $resource.apiVersion? and ($resource.type | prohibited)
          then $resource.type
          else .[] | declarations
          end
      elif type == "array" then .[] | declarations
      else empty
      end;
    declarations
  ' "$1"
}

if [[ -n "$(find_prohibited_paid_declarations "${TEMP_DIR}/main.json")" ]]; then
  printf 'ERROR: A prohibited evidence resource type is declared.\n' >&2
  exit 1
fi
az bicep build \
  --file "${SCRIPT_DIR}/fixtures/paid-resource-declaration.bicep" \
  --outfile "${TEMP_DIR}/paid-resource-declaration.json"
[[ -n "$(find_prohibited_paid_declarations "${TEMP_DIR}/paid-resource-declaration.json")" ]] || {
  printf 'ERROR: The paid-resource declaration safety check did not reject its negative fixture.\n' >&2
  exit 1
}

printf '6/28 Confirm tenant-root scope is only used as the parent hierarchy input...\n'
if rg -n 'scope:\\s*managementGroup\\(tenantRootManagementGroupId\\)' "${PROJECT_DIR}" -g '*.bicep'; then
  printf 'ERROR: A module or resource assigns governance directly at the tenant root.\n' >&2
  exit 1
fi

printf '7/28 Confirm group-only RBAC, idempotent main, one-shot Owner eligibility, and guarded scripts...\n'
group_param_count="$(rg -c '^param (governanceAdminsGroupObjectId|networkOperatorsGroupObjectId|workloadContributorsGroupObjectId|readOnlyAuditorsGroupObjectId) string$' "${PROJECT_DIR}/main.bicep")"
[[ "${group_param_count}" -eq 4 ]] || {
  printf 'ERROR: Expected four ordinary Entra security-group parameters in main.bicep.\n' >&2
  exit 1
}
"${PROJECT_DIR}/scripts/validate-rbac-artifacts.sh" \
  --compiled-template "${TEMP_DIR}/main.json" \
  --compiled-eligibility-template "${TEMP_DIR}/owner-eligibility-request.json"
rbac_negative_template="${TEMP_DIR}/main-permanent-owner.json"
jq '
  .resources.__testPermanentOwner = {
    "type": "Microsoft.Authorization/roleAssignments",
    "apiVersion": "2022-04-01",
    "name": "00000000-0000-0000-0000-000000000000",
    "properties": {
      "principalId": "[parameters('\''governanceAdminsGroupObjectId'\'')]",
      "roleDefinitionId": "[subscriptionResourceId('\''Microsoft.Authorization/roleDefinitions'\'', '\''8e3af657-a8ff-443c-a75c-2fe8c4bcb635'\'')]"
    }
  }
' "${TEMP_DIR}/main.json" > "${rbac_negative_template}"
if rbac_validation_output="$("${PROJECT_DIR}/scripts/validate-rbac-artifacts.sh" \
  --compiled-template "${rbac_negative_template}" \
  --compiled-eligibility-template "${TEMP_DIR}/owner-eligibility-request.json" 2>&1)"; then
  printf 'ERROR: RBAC validator accepted a compiled permanent Owner assignment.\n' >&2
  exit 1
fi
if ! printf '%s' "${rbac_validation_output}" | grep -qF 'permanent Owner role assignment'; then
  printf 'ERROR: RBAC validator rejected the permanent Owner fixture for the wrong reason: %s\n' "${rbac_validation_output}" >&2
  exit 1
fi
rbac_main_request_fixture="${TEMP_DIR}/main-one-shot-request.json"
jq '
  .resources.__testOneShotRequest = {
    "type": "Microsoft.Authorization/roleEligibilityScheduleRequests",
    "apiVersion": "2020-10-01",
    "name": "[guid(subscription().id, '\''reused-request'\'')]",
    "condition": false,
    "properties": {}
  }
' "${TEMP_DIR}/main.json" > "${rbac_main_request_fixture}"
if rbac_validation_output="$("${PROJECT_DIR}/scripts/validate-rbac-artifacts.sh" \
  --compiled-template "${rbac_main_request_fixture}" \
  --compiled-eligibility-template "${TEMP_DIR}/owner-eligibility-request.json" 2>&1)"; then
  printf 'ERROR: RBAC validator accepted a one-time eligibility request in the repeatable main template.\n' >&2
  exit 1
fi
if ! printf '%s' "${rbac_validation_output}" | grep -qF 'one-time eligibility schedule request'; then
  printf 'ERROR: RBAC validator rejected the main eligibility fixture for the wrong reason: %s\n' "${rbac_validation_output}" >&2
  exit 1
fi
rbac_owner_binding_fixture="${TEMP_DIR}/main-owner-role-binding.json"
jq '
  walk(
    if type == "object"
      and .parameters?.operatorRoleDefinitionId?.value? == "4d97b98b-1d4f-4787-a291-c67834d212e7"
    then .parameters.operatorRoleDefinitionId.value = "8e3af657-a8ff-443c-a75c-2fe8c4bcb635"
    else .
    end
  )
' "${TEMP_DIR}/main.json" > "${rbac_owner_binding_fixture}"
if rbac_validation_output="$("${PROJECT_DIR}/scripts/validate-rbac-artifacts.sh" \
  --compiled-template "${rbac_owner_binding_fixture}" \
  --compiled-eligibility-template "${TEMP_DIR}/owner-eligibility-request.json" 2>&1)"; then
  printf 'ERROR: RBAC validator accepted an Owner role passed through a nested module binding.\n' >&2
  exit 1
fi
if ! printf '%s' "${rbac_validation_output}" | grep -qF 'Owner role definition reference'; then
  printf 'ERROR: RBAC validator rejected the Owner module binding for the wrong reason: %s\n' "${rbac_validation_output}" >&2
  exit 1
fi
rbac_extra_resource_fixture="${TEMP_DIR}/owner-request-with-deployment-script.json"
jq '
  .resources += [{
    "type": "Microsoft.Resources/deploymentScripts",
    "apiVersion": "2023-08-01",
    "name": "prohibited-automation",
    "properties": {}
  }]
' "${TEMP_DIR}/owner-eligibility-request.json" > "${rbac_extra_resource_fixture}"
if rbac_validation_output="$("${PROJECT_DIR}/scripts/validate-rbac-artifacts.sh" \
  --compiled-template "${TEMP_DIR}/main.json" \
  --compiled-eligibility-template "${rbac_extra_resource_fixture}" 2>&1)"; then
  printf 'ERROR: RBAC validator accepted an extra automation resource in the one-shot artifact.\n' >&2
  exit 1
fi
if ! printf '%s' "${rbac_validation_output}" | grep -qF 'One-shot Owner eligibility artifact'; then
  printf 'ERROR: RBAC validator rejected the one-shot extra resource for the wrong reason: %s\n' "${rbac_validation_output}" >&2
  exit 1
fi
for guard_name in targetScheduleInputIsValid scheduleInputIsValid executionInputsAreValid; do
  rbac_guard_fixture="${TEMP_DIR}/owner-request-${guard_name}-true.json"
  jq --arg guard "${guard_name}" '.variables[$guard] = true' \
    "${TEMP_DIR}/owner-eligibility-request.json" > "${rbac_guard_fixture}"
  if rbac_validation_output="$("${PROJECT_DIR}/scripts/validate-rbac-artifacts.sh" \
    --compiled-template "${TEMP_DIR}/main.json" \
    --compiled-eligibility-template "${rbac_guard_fixture}" 2>&1)"; then
    printf 'ERROR: RBAC validator accepted %s replaced with true.\n' "${guard_name}" >&2
    exit 1
  fi
  if ! printf '%s' "${rbac_validation_output}" | grep -qF 'compiled input guards'; then
    printf 'ERROR: RBAC validator rejected the %s mutation for the wrong reason: %s\n' "${guard_name}" "${rbac_validation_output}" >&2
    exit 1
  fi
done

owner_mock_bin="${TEMP_DIR}/owner-mockbin"
owner_az_log="${TEMP_DIR}/owner-az-calls.log"
mkdir -p "${owner_mock_bin}"
cat > "${owner_mock_bin}/az" <<'MOCKOWNERAZ'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${OWNER_AZ_CALL_LOG}"
if [[ "$1" == 'bicep' && "$2" == 'build' ]]; then
  source_file=''
  output_file=''
  shift 2
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --file) source_file="$2"; shift 2 ;;
      --outfile) output_file="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  source_text="$(<"${source_file}")"
  jq -cn --arg source "${source_text}" '{compiledSource:$source}' > "${output_file}"
  exit 0
fi
if [[ "$1" == 'account' && "$2" == 'show' ]]; then
  printf '{"id":"%s","state":"Enabled","tenantId":"44444444-4444-4444-8444-444444444444"}\n' "${MOCK_SUBSCRIPTION_ID}"
  exit 0
fi
if [[ "$1" == 'ad' && "$2" == 'group' && "$3" == 'show' ]]; then
  [[ "$*" == "ad group show --group ${MOCK_GROUP_ID} --output json" ]] || exit 64
  if [[ "${MOCK_SECURITY_AS_STRING:-false}" == 'true' ]]; then
    printf '{"id":"%s","securityEnabled":"true"}\n' "${MOCK_GROUP_ID}"
  else
    printf '{"id":"%s","securityEnabled":%s}\n' "${MOCK_GROUP_ID}" "${MOCK_SECURITY_ENABLED:-true}"
  fi
  exit 0
fi
if [[ "$1" == 'rest' ]]; then
  if [[ "$*" == *'roleEligibilitySchedules?'* ]]; then
    if [[ "${MOCK_FALSE_NEXT_LINK:-false}" == 'true' ]]; then
      printf '{"value":[],"nextLink":false}\n'
    elif [[ "${MOCK_ANCESTOR_SCHEDULE:-false}" == 'true' ]]; then
      printf '{"value":[{"name":"55555555-5555-4555-8555-555555555555","id":"/providers/Microsoft.Management/managementGroups/eslz-parent/providers/Microsoft.Authorization/roleEligibilitySchedules/55555555-5555-4555-8555-555555555555","properties":{"scope":"/providers/Microsoft.Management/managementGroups/eslz-parent","principalId":"%s","roleDefinitionId":"/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635"}}]}\n' \
        "${MOCK_GROUP_ID}"
    elif [[ "${MOCK_EXISTING_SCHEDULE:-false}" == 'true' ]]; then
      printf '{"value":[{"name":"55555555-5555-4555-8555-555555555555","id":"/subscriptions/%s/providers/Microsoft.Authorization/roleEligibilitySchedules/55555555-5555-4555-8555-555555555555","properties":{"scope":"/subscriptions/%s","principalId":"%s","roleDefinitionId":"/subscriptions/%s/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635"}}]}\n' \
        "${MOCK_SUBSCRIPTION_ID}" "${MOCK_SUBSCRIPTION_ID}" "${MOCK_GROUP_ID}" "${MOCK_SUBSCRIPTION_ID}"
    else
      printf '{"value":[]}\n'
    fi
    exit 0
  fi
  if [[ "$*" == *'roleEligibilityScheduleRequests?'* ]]; then
    if [[ "${MOCK_FALSE_REQUEST_NEXT_LINK:-false}" == 'true' ]]; then
      printf '{"value":[],"nextLink":false}\n'
    elif [[ "${MOCK_MALFORMED_REQUESTS:-false}" == 'true' ]]; then
      printf '{"value":false}\n'
    elif [[ "${MOCK_ANCESTOR_PENDING_REQUEST:-false}" == 'true' ]]; then
      printf '{"value":[{"name":"66666666-6666-4666-8666-666666666666","id":"/providers/Microsoft.Management/managementGroups/eslz-parent/providers/Microsoft.Authorization/roleEligibilityScheduleRequests/66666666-6666-4666-8666-666666666666","properties":{"scope":"/providers/Microsoft.Management/managementGroups/eslz-parent","principalId":"%s","roleDefinitionId":"/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635","status":"PendingApproval"}}]}\n' \
        "${MOCK_GROUP_ID}"
    elif [[ "${MOCK_PENDING_REQUEST:-false}" == 'true' || ( "${MOCK_LIVE_STATE_CHANGE_AFTER_PREVIEW:-false}" == 'true' && -f "${OWNER_MOCK_PHASE_FILE:-/dev/null}" ) ]]; then
      printf '{"value":[{"name":"66666666-6666-4666-8666-666666666666","id":"/subscriptions/%s/providers/Microsoft.Authorization/roleEligibilityScheduleRequests/66666666-6666-4666-8666-666666666666","properties":{"scope":"/subscriptions/%s","principalId":"%s","roleDefinitionId":"/subscriptions/%s/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635","status":"PendingApproval"}}]}\n' \
        "${MOCK_SUBSCRIPTION_ID}" "${MOCK_SUBSCRIPTION_ID}" "${MOCK_GROUP_ID}" "${MOCK_SUBSCRIPTION_ID}"
    else
      printf '{"value":[]}\n'
    fi
    exit 0
  fi
fi
if [[ "$1" == 'deployment' && "$2" == 'sub' && "$3" == 'what-if' ]]; then
  template_file=''
  previous=''
  for argument in "$@"; do
    if [[ "${previous}" == '--template-file' ]]; then
      template_file="${argument}"
      break
    fi
    previous="${argument}"
  done
  printf 'WHAT_IF_TEMPLATE=%s|%s\n' "${template_file}" "$(cksum < "${template_file}" | tr -d ' ')" >> "${OWNER_AZ_CALL_LOG}"
  if [[ "${MOCK_MUTATE_SOURCE_AFTER_PREVIEW:-false}" == 'true' ]]; then
    printf '\n// source changed after what-if\n' >> "${MOCK_OPERATOR_BICEP_FILE}"
  fi
  if [[ -n "${OWNER_MOCK_PHASE_FILE:-}" ]]; then
    printf 'post-preview\n' > "${OWNER_MOCK_PHASE_FILE}"
  fi
  printf '{"status":"previewed"}\n'
  exit 0
fi
if [[ "$1" == 'deployment' && "$2" == 'sub' && "$3" == 'create' ]]; then
  template_file=''
  previous=''
  for argument in "$@"; do
    if [[ "${previous}" == '--template-file' ]]; then
      template_file="${argument}"
      break
    fi
    previous="${argument}"
  done
  printf 'CREATE_TEMPLATE=%s|%s\n' "${template_file}" "$(cksum < "${template_file}" | tr -d ' ')" >> "${OWNER_AZ_CALL_LOG}"
  printf '{"status":"submitted"}\n'
  exit 0
fi
exit 1
MOCKOWNERAZ
chmod +x "${owner_mock_bin}/az"

owner_subscription_id='11111111-1111-4111-8111-111111111111'
owner_request_id='22222222-2222-4222-8222-222222222222'
owner_group_id='33333333-3333-4333-8333-333333333333'
owner_parameter_file="${TEMP_DIR}/owner-valid.parameters.json"
owner_update_parameter_file="${TEMP_DIR}/owner-update.parameters.json"
owner_operator_project="${TEMP_DIR}/owner-operator-project"
mkdir -p "${owner_operator_project}/scripts" "${owner_operator_project}/identity/azure-rbac"
cp "${PROJECT_DIR}/scripts/owner-eligibility-request.sh" "${owner_operator_project}/scripts/"
cp "${PROJECT_DIR}/identity/azure-rbac/owner-eligibility-request.bicep" "${owner_operator_project}/identity/azure-rbac/"
owner_operator_path="${owner_operator_project}/scripts/owner-eligibility-request.sh"
owner_operator_bicep="${owner_operator_project}/identity/azure-rbac/owner-eligibility-request.bicep"
jq \
  --arg request_id "${owner_request_id}" \
  --arg group_id "${owner_group_id}" '
  .parameters.submitEligibilityRequest.value = true
  | .parameters.requestId.value = $request_id
  | .parameters.subscriptionPrivilegedAccessGroupObjectId.value = $group_id
  | .parameters.eligibleOwnerAssignmentStartDateTime.value = "2030-01-02T03:04:05Z"
  | .parameters.eligibleOwnerAssignmentJustification.value = "Approved sandbox Owner eligibility demonstration"
' "${PROJECT_DIR}/identity/azure-rbac/owner-eligibility-request.parameters.template.json" > "${owner_parameter_file}"
jq '
  .parameters.requestType.value = "AdminUpdate"
  | .parameters.targetRoleEligibilityScheduleId.value = "55555555-5555-4555-8555-555555555555"
' "${owner_parameter_file}" > "${owner_update_parameter_file}"

for invalid_case in request-id group-id target-schedule start-time calendar-date duration; do
  invalid_owner_parameter_file="${TEMP_DIR}/owner-invalid-${invalid_case}.parameters.json"
  case "${invalid_case}" in
    request-id)
      jq '.parameters.requestId.value = "not-a-canonical-request-guid-value-00"' "${owner_parameter_file}" > "${invalid_owner_parameter_file}"
      ;;
    group-id)
      jq '.parameters.subscriptionPrivilegedAccessGroupObjectId.value = "not-a-group-object-guid"' "${owner_parameter_file}" > "${invalid_owner_parameter_file}"
      ;;
    target-schedule)
      jq '
        .parameters.requestType.value = "AdminUpdate"
        | .parameters.targetRoleEligibilityScheduleId.value = "not-a-schedule-guid"
      ' "${owner_parameter_file}" > "${invalid_owner_parameter_file}"
      ;;
    start-time)
      jq '.parameters.eligibleOwnerAssignmentStartDateTime.value = "2030-01-02 03:04:05+00:00"' "${owner_parameter_file}" > "${invalid_owner_parameter_file}"
      ;;
    calendar-date)
      jq '.parameters.eligibleOwnerAssignmentStartDateTime.value = "2030-02-30T03:04:05Z"' "${owner_parameter_file}" > "${invalid_owner_parameter_file}"
      ;;
    duration)
      jq '.parameters.eligibleOwnerAssignmentDuration.value = "P999D"' "${owner_parameter_file}" > "${invalid_owner_parameter_file}"
      ;;
  esac
  : > "${owner_az_log}"
  if PATH="${owner_mock_bin}:${PATH}" \
    OWNER_AZ_CALL_LOG="${owner_az_log}" \
    MOCK_SUBSCRIPTION_ID="${owner_subscription_id}" \
    MOCK_GROUP_ID="${owner_group_id}" \
    "${owner_operator_path}" \
      --subscription-id "${owner_subscription_id}" \
      --parameter-file "${invalid_owner_parameter_file}" >/dev/null 2>&1; then
    printf 'ERROR: Owner eligibility workflow accepted invalid %s input.\n' "${invalid_case}" >&2
    exit 1
  fi
  [[ ! -s "${owner_az_log}" ]] || {
    printf 'ERROR: Owner eligibility workflow called Azure before rejecting invalid %s input.\n' "${invalid_case}" >&2
    exit 1
  }
done

: > "${owner_az_log}"
if PATH="${owner_mock_bin}:${PATH}" \
  OWNER_AZ_CALL_LOG="${owner_az_log}" \
  MOCK_SUBSCRIPTION_ID="${owner_subscription_id}" \
  MOCK_GROUP_ID="${owner_group_id}" \
  "${owner_operator_path}" \
    --subscription-id "${owner_subscription_id}" \
    --parameter-file "${owner_parameter_file}" \
    --execute >/dev/null 2>&1; then
  printf 'ERROR: Owner eligibility workflow accepted --execute without its environment confirmation.\n' >&2
  exit 1
fi
[[ ! -s "${owner_az_log}" ]] || {
  printf 'ERROR: Owner eligibility workflow called Azure before enforcing its execution confirmation.\n' >&2
  exit 1
}

: > "${owner_az_log}"
PATH="${owner_mock_bin}:${PATH}" \
  OWNER_AZ_CALL_LOG="${owner_az_log}" \
  MOCK_SUBSCRIPTION_ID="${owner_subscription_id}" \
  MOCK_GROUP_ID="${owner_group_id}" \
  "${owner_operator_path}" \
    --subscription-id "${owner_subscription_id}" \
    --parameter-file "${owner_parameter_file}" >/dev/null
rg -q -F 'ad group show' "${owner_az_log}" || {
  printf 'ERROR: Owner eligibility preview did not verify the Entra group.\n' >&2
  exit 1
}
rg -q -F 'roleEligibilitySchedules?' "${owner_az_log}" || {
  printf 'ERROR: Owner eligibility preview did not inspect existing schedules.\n' >&2
  exit 1
}
rg -q -F 'roleEligibilityScheduleRequests?' "${owner_az_log}" || {
  printf 'ERROR: Owner eligibility preview did not inspect existing requests.\n' >&2
  exit 1
}
rg -q -F 'deployment sub what-if' "${owner_az_log}" || {
  printf 'ERROR: Owner eligibility preview did not run what-if.\n' >&2
  exit 1
}
if rg -q -F 'deployment sub create' "${owner_az_log}"; then
  printf 'ERROR: Owner eligibility preview submitted a request without --execute.\n' >&2
  exit 1
fi

for blocked_state in non-security-group string-security-enabled existing-schedule ancestor-schedule pending-request ancestor-pending-request malformed-requests false-next-link false-request-next-link; do
  : > "${owner_az_log}"
  mock_security_enabled='true'
  mock_existing_schedule='false'
  mock_pending_request='false'
  mock_security_as_string='false'
  mock_malformed_requests='false'
  mock_ancestor_schedule='false'
  mock_ancestor_pending_request='false'
  mock_false_next_link='false'
  mock_false_request_next_link='false'
  case "${blocked_state}" in
    non-security-group) mock_security_enabled='false' ;;
    string-security-enabled) mock_security_as_string='true' ;;
    existing-schedule) mock_existing_schedule='true' ;;
    ancestor-schedule) mock_ancestor_schedule='true' ;;
    pending-request) mock_pending_request='true' ;;
    ancestor-pending-request) mock_ancestor_pending_request='true' ;;
    malformed-requests) mock_malformed_requests='true' ;;
    false-next-link) mock_false_next_link='true' ;;
    false-request-next-link) mock_false_request_next_link='true' ;;
  esac
  if PATH="${owner_mock_bin}:${PATH}" \
    OWNER_AZ_CALL_LOG="${owner_az_log}" \
    MOCK_SUBSCRIPTION_ID="${owner_subscription_id}" \
    MOCK_GROUP_ID="${owner_group_id}" \
    MOCK_SECURITY_ENABLED="${mock_security_enabled}" \
    MOCK_SECURITY_AS_STRING="${mock_security_as_string}" \
    MOCK_EXISTING_SCHEDULE="${mock_existing_schedule}" \
    MOCK_PENDING_REQUEST="${mock_pending_request}" \
    MOCK_MALFORMED_REQUESTS="${mock_malformed_requests}" \
    MOCK_ANCESTOR_SCHEDULE="${mock_ancestor_schedule}" \
    MOCK_ANCESTOR_PENDING_REQUEST="${mock_ancestor_pending_request}" \
    MOCK_FALSE_NEXT_LINK="${mock_false_next_link}" \
    MOCK_FALSE_REQUEST_NEXT_LINK="${mock_false_request_next_link}" \
    "${owner_operator_path}" \
      --subscription-id "${owner_subscription_id}" \
      --parameter-file "${owner_parameter_file}" >/dev/null 2>&1; then
    printf 'ERROR: Owner eligibility workflow accepted blocked state: %s.\n' "${blocked_state}" >&2
    exit 1
  fi
  if rg -q -F 'deployment sub what-if' "${owner_az_log}"; then
    printf 'ERROR: Owner eligibility workflow previewed after blocked state: %s.\n' "${blocked_state}" >&2
    exit 1
  fi
done

: > "${owner_az_log}"
if PATH="${owner_mock_bin}:${PATH}" \
  OWNER_AZ_CALL_LOG="${owner_az_log}" \
  MOCK_SUBSCRIPTION_ID="${owner_subscription_id}" \
  MOCK_GROUP_ID="${owner_group_id}" \
  MOCK_ANCESTOR_SCHEDULE='true' \
  "${owner_operator_path}" \
    --subscription-id "${owner_subscription_id}" \
    --parameter-file "${owner_update_parameter_file}" >/dev/null 2>&1; then
  printf 'ERROR: AdminUpdate accepted an inherited schedule as its required exact subscription schedule.\n' >&2
  exit 1
fi
if rg -q -F 'deployment sub what-if' "${owner_az_log}"; then
  printf 'ERROR: AdminUpdate previewed with only an inherited Owner eligibility schedule.\n' >&2
  exit 1
fi

: > "${owner_az_log}"
PATH="${owner_mock_bin}:${PATH}" \
  OWNER_AZ_CALL_LOG="${owner_az_log}" \
  MOCK_SUBSCRIPTION_ID="${owner_subscription_id}" \
  MOCK_GROUP_ID="${owner_group_id}" \
  MOCK_EXISTING_SCHEDULE='true' \
  MOCK_ANCESTOR_PENDING_REQUEST='true' \
  "${owner_operator_path}" \
    --subscription-id "${owner_subscription_id}" \
    --parameter-file "${owner_update_parameter_file}" >/dev/null
rg -q -F 'deployment sub what-if' "${owner_az_log}" || {
  printf 'ERROR: AdminUpdate treated an ancestor request as mutable at the subscription scope.\n' >&2
  exit 1
}

: > "${owner_az_log}"
owner_phase_file="${TEMP_DIR}/owner-operator-phase"
rm -f "${owner_phase_file}"
printf '%s\n' "${owner_request_id}" | \
  PATH="${owner_mock_bin}:${PATH}" \
  OWNER_AZ_CALL_LOG="${owner_az_log}" \
  OWNER_MOCK_PHASE_FILE="${owner_phase_file}" \
  MOCK_OPERATOR_BICEP_FILE="${owner_operator_bicep}" \
  MOCK_MUTATE_SOURCE_AFTER_PREVIEW='true' \
  MOCK_SUBSCRIPTION_ID="${owner_subscription_id}" \
  MOCK_GROUP_ID="${owner_group_id}" \
  ESLZ_OWNER_ELIGIBILITY_CONFIRMATION='SUBMIT-OWNER-ELIGIBILITY' \
  "${owner_operator_path}" \
    --subscription-id "${owner_subscription_id}" \
    --parameter-file "${owner_parameter_file}" \
    --execute >/dev/null
what_if_template="$(rg '^WHAT_IF_TEMPLATE=' "${owner_az_log}" | sed 's/^WHAT_IF_TEMPLATE=//')"
create_template="$(rg '^CREATE_TEMPLATE=' "${owner_az_log}" | sed 's/^CREATE_TEMPLATE=//')"
[[ -n "${what_if_template}" && "${what_if_template}" == "${create_template}" ]] || {
  printf 'ERROR: Owner eligibility create did not reuse the exact immutable template snapshot reviewed by what-if.\n' >&2
  exit 1
}
rg -q -F 'source changed after what-if' "${owner_operator_bicep}" || {
  printf 'ERROR: Owner eligibility template-race fixture did not mutate the source Bicep after preview.\n' >&2
  exit 1
}

cp "${PROJECT_DIR}/identity/azure-rbac/owner-eligibility-request.bicep" "${owner_operator_bicep}"
: > "${owner_az_log}"
rm -f "${owner_phase_file}"
if printf '%s\n' "${owner_request_id}" | \
  PATH="${owner_mock_bin}:${PATH}" \
  OWNER_AZ_CALL_LOG="${owner_az_log}" \
  OWNER_MOCK_PHASE_FILE="${owner_phase_file}" \
  MOCK_OPERATOR_BICEP_FILE="${owner_operator_bicep}" \
  MOCK_LIVE_STATE_CHANGE_AFTER_PREVIEW='true' \
  MOCK_SUBSCRIPTION_ID="${owner_subscription_id}" \
  MOCK_GROUP_ID="${owner_group_id}" \
  ESLZ_OWNER_ELIGIBILITY_CONFIRMATION='SUBMIT-OWNER-ELIGIBILITY' \
  "${owner_operator_path}" \
    --subscription-id "${owner_subscription_id}" \
    --parameter-file "${owner_parameter_file}" \
    --execute >/dev/null 2>&1; then
  printf 'ERROR: Owner eligibility workflow submitted after live eligibility state changed during approval.\n' >&2
  exit 1
fi
rg -q -F 'deployment sub what-if' "${owner_az_log}" || {
  printf 'ERROR: Owner eligibility live-state race fixture did not reach what-if.\n' >&2
  exit 1
}
if rg -q -F 'deployment sub create' "${owner_az_log}"; then
  printf 'ERROR: Owner eligibility workflow called create after live state changed during approval.\n' >&2
  exit 1
fi
owner_group_check_count="$(rg -c -F 'ad group show' "${owner_az_log}" || true)"
[[ "${owner_group_check_count:-0}" -eq 2 ]] || {
  printf 'ERROR: Owner eligibility workflow did not repeat the group verification immediately before create.\n' >&2
  exit 1
}
rg -q 'DEPLOY-ESLZ-DEMO' "${PROJECT_DIR}/scripts/deploy.sh"
rg -q 'DELETE-ESLZ-DEMO' "${PROJECT_DIR}/scripts/teardown.sh"
rg -q 'DEPLOY-ESLZ-DEMO' "${PROJECT_DIR}/scripts/deploy.ps1"
rg -q 'DELETE-ESLZ-DEMO' "${PROJECT_DIR}/scripts/teardown.ps1"

printf '8/28 Confirm region policy and workload network guardrails are safe by default...\n'
rg -q "field: 'location'" "${PROJECT_DIR}/modules/policy-library.bicep"
rg -q "notEquals: 'global'" "${PROJECT_DIR}/modules/policy-library.bicep"
rg -q "notEquals: 'Microsoft.AzureActiveDirectory/b2cDirectories'" "${PROJECT_DIR}/modules/policy-library.bicep"
jq -e '
  .parameters.networkIngressPolicyEffect.defaultValue == "Audit" and
  .parameters.networkIngressPolicyEffect.allowedValues == ["Audit", "Deny", "Disabled"] and
  .resources as $resources |
  ($resources[] | select(.name | startswith("[format(\u0027policy-library-"))) as $library |
  $library.properties.template.resources as $definitions |
  ($definitions | map(select(.properties.displayName == "Demo - block public RDP and SSH NSG rules")) | first) as $ingress |
  ($definitions | map(select(.properties.displayName == "Demo - require NSGs on workload subnets")) | first) as $subnet |
  ($resources | map(select(.name == "network-ingress-initiative")) | first) as $initiative |
  ($resources | map(select(.name == "assign-network-ingress")) | first) as $assignment |
  $ingress.properties.parameters.effect.defaultValue == "Audit" and
  $ingress.properties.parameters.effect.allowedValues == ["Audit", "Deny", "Disabled"] and
  $library.properties.template.variables.managementPorts == ["22", "3389"] and
  ($ingress.properties.policyRule.if | tostring | contains("Microsoft.Network/networkSecurityGroups/securityRules")) and
  ($ingress.properties.policyRule.if | tostring | contains("\"Internet\"")) and
  ($ingress.properties.policyRule.if | tostring | contains("\"0.0.0.0/0\"")) and
  ($ingress.properties.policyRule.if | tostring | contains("sourceAddressPrefixes[*]")) and
  ($ingress.properties.policyRule.if | tostring | contains("destinationPortRanges[*]")) and
  ($ingress.properties.policyRule.if | tostring | contains("networkSecurityGroups/securityRules[*].protocol")) and
  ($ingress.properties.policyRule.if | tostring | contains("\"Microsoft.Network/networkSecurityGroups\"")) and
  ($subnet.properties.policyRule.if | tostring | contains("networkSecurityGroup.id")) and
  ($subnet.properties.policyRule.if | tostring | contains("virtualNetworks/subnets[*].networkSecurityGroup.id")) and
  ($subnet.properties.policyRule.if | tostring | contains("\"Microsoft.Network/virtualNetworks\"")) and
  ($initiative.scope | contains("demoRootManagementGroupId")) and
  ($initiative.properties.parameters.policyDefinitionReferences.value | map(.policyDefinitionReferenceId) | sort) == ["public-management-ingress", "require-subnet-nsg"] and
  ($assignment.scope | contains("workloadManagementGroupId")) and
  ($assignment.scope | contains("platformManagementGroupId") | not) and
  $assignment.properties.parameters.enforcementMode.value == "[parameters(\u0027denyPolicyEnforcementMode\u0027)]" and
  $assignment.properties.parameters.parameters.value.effect.value == "[parameters(\u0027networkIngressPolicyEffect\u0027)]" and
  ($assignment.properties.parameters.nonComplianceMessages.value | length) == 2 and
  ($assignment.properties.parameters.nonComplianceMessages.value | map(.policyDefinitionReferenceId) | sort) == ["public-management-ingress", "require-subnet-nsg"] and
  ($assignment.properties.parameters.nonComplianceMessages.value | all(.message | length > 0))
' "${TEMP_DIR}/main.json" >/dev/null
private_access_and_route_guardrail_count="$(jq '
  .resources as $resources |
  ($resources | map(select(.name == "private-access-initiative")) | first) as $initiative |
  ($resources | map(select(.name == "assign-private-access-workload")) | first) as $workload |
  ($resources | map(select(.name == "assign-private-access-critical")) | first) as $critical |
  ($resources | map(select(.name == "assign-firewall-routes-workload")) | first) as $routes |
  ($initiative.properties.parameters.policyDefinitionReferences.value | map(.policyDefinitionReferenceId) | sort) == ["key-vault-private-link", "paas-public-network-access", "storage-private-link"] and
  ($initiative.properties.parameters.policyDefinitionReferences.value | map(select(.policyDefinitionReferenceId == "storage-private-link")) | first).definitionVersion == "2.*.*" and
  ($initiative.properties.parameters.policyDefinitionReferences.value | map(select(.policyDefinitionReferenceId == "key-vault-private-link")) | first).definitionVersion == "1.*.*" and
  $initiative.properties.parameters.initiativeParameters.value.publicNetworkAccessEffect.defaultValue == "Audit" and
  ($workload.scope | contains("workloadManagementGroupId")) and
  ($workload.scope | contains("platformManagementGroupId") | not) and
  $critical.condition == "[parameters(\u0027enableCriticalInfrastructure\u0027)]" and
  ($critical.scope | contains("criticalInfrastructureManagementGroupId")) and
  $routes.condition == "[parameters(\u0027enableFirewallRouteGuardrails\u0027)]" and
  ($routes.scope | contains("workloadManagementGroupId")) and
  $routes.properties.parameters.parameters.value.approvedFirewallResourceId.value == "[parameters(\u0027approvedFirewallResourceId\u0027)]" and
  (.variables.validatedFirewallRouteInputs | contains("fail(")) and
  (.variables.validatedFirewallRouteInputs | contains("approvedFirewallResourceId")) and
  (.variables.validatedFirewallRouteInputs | contains("approvedRouteTableResourceIds")) and
  (.variables.validatedFirewallRouteInputs | contains("approvedRouteTablePrefixes"))
' "${TEMP_DIR}/main.json")"
[[ "${private_access_and_route_guardrail_count}" == "true" ]] || {
  printf 'ERROR: Private-access and approved-firewall-route guardrails must remain audit-first, input-gated, and workload/critical scoped.\n' >&2
  exit 1
}
rg -q 'privateAccessServiceCategories must contain non-empty, uniquely cased Storage and/or KeyVault values' "${PROJECT_DIR}/main.bicep"
rg -q 'approvedFirewallResourceId must be an Azure Firewall resource ID' "${PROJECT_DIR}/main.bicep"
python3 - "${PROJECT_DIR}/tests/fixtures/firewall-route-input-validation-cases.json" <<'PYEOF'
import json
import ipaddress
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    cases = json.load(stream)

for case in cases["ipv4Cases"]:
    try:
        valid = isinstance(ipaddress.ip_address(case["value"]), ipaddress.IPv4Address)
    except ValueError:
        valid = False
    if valid != case["valid"]:
        raise SystemExit(f"ERROR: IPv4 validation case failed: {case['value']}")

for case in cases["serviceCategoryCases"]:
    values = case["value"]
    valid = bool(values) and all(value in {"Storage", "KeyVault"} for value in values) and len(values) == len(set(values))
    if valid != case["valid"]:
        raise SystemExit(f"ERROR: Private-access category validation case failed: {values}")
PYEOF
root_public_ip_assignment_count="$(jq '
  [.resources[]
    | select(.name == "assign-audit-public-ip")
    | select(.scope | contains("demoRootManagementGroupId"))
  ] | length
' "${TEMP_DIR}/main.json")"
[[ "${root_public_ip_assignment_count}" -eq 1 ]] || {
  printf 'ERROR: Expected the existing public-IP audit to remain a single dedicated-root assignment.\n' >&2
  exit 1
}
python3 - "${TEMP_DIR}/main.json" "${PROJECT_DIR}/tests/fixtures/network-ingress-semantic-cases.json" <<'PYEOF'
import ipaddress
import json
import sys

compiled_path, fixture_path = sys.argv[1:3]
with open(compiled_path, encoding="utf-8") as stream:
    compiled = json.load(stream)
with open(fixture_path, encoding="utf-8") as stream:
    fixture = json.load(stream)

library = next(
    resource
    for resource in compiled["resources"].values()
    if resource["name"].startswith("[format('policy-library-")
)
template = library["properties"]["template"]
definition = next(
    resource
    for resource in template["resources"]
    if resource["properties"]["displayName"] == "Demo - block public RDP and SSH NSG rules"
)
if template["variables"]["nonPublicIpv4Ranges"] != fixture["nonPublicIpv4Ranges"]:
    raise SystemExit("ERROR: Compiled non-public IPv4 ranges differ from the behavioral fixture.")

policy_text = json.dumps(definition["properties"]["policyRule"]["if"])
for required_expression in (
    "ipRangeContains(",
    "ipRangeContains('0.0.0.0/0'",
    "int(first(split(",
    "int(last(split(",
    "securityRules/sourceAddressPrefixes[*]",
    "securityRules[*].sourceAddressPrefixes[*]",
    "securityRules/destinationPortRanges[*]",
    "securityRules[*].destinationPortRanges[*]",
):
    if required_expression not in policy_text:
        raise SystemExit(f"ERROR: Compiled ingress policy is missing semantic expression: {required_expression}")
for expression, expected_count in (
    ("ipRangeContains('0.0.0.0/0'", 4),
    ("ipRangeContains(current('nonPublicIpv4Range')", 4),
    ("int(first(split(", 4),
    ("int(last(split(", 4),
):
    if policy_text.count(expression) != expected_count:
        raise SystemExit(
            f"ERROR: Compiled ingress policy has {policy_text.count(expression)} occurrences "
            f"of {expression}; expected {expected_count}."
        )

non_public = [ipaddress.ip_network(value) for value in fixture["nonPublicIpv4Ranges"]]
service_tags = set(fixture["supportedServiceTags"])

def is_public_source(value):
    if value in {"*", "Internet", "0.0.0.0/0"}:
        return True
    if value in service_tags or not value or value[0].isalpha():
        return False
    try:
        source = ipaddress.ip_network(value, strict=False)
    except ValueError:
        return False
    return source.version == 4 and not any(source.subnet_of(network) for network in non_public)

def contains_management_port(value):
    if value == "*":
        return True
    try:
        parts = value.split("-")
        if len(parts) == 1:
            start = end = int(parts[0])
        elif len(parts) == 2:
            start, end = map(int, parts)
        else:
            return False
    except ValueError:
        return False
    return 0 <= start <= end <= 65535 and any(start <= port <= end for port in (22, 3389))

forms = {
    "shape": set(),
    "source": set(),
    "destination": set(),
}
for case in fixture["cases"]:
    forms["shape"].add(case["shape"])
    forms["source"].add(case.get("sourceForm", "single"))
    forms["destination"].add(case.get("destinationForm", "single"))
    actual = (
        case["access"] == "Allow"
        and case["direction"] == "Inbound"
        and case["protocol"] in {"Tcp", "*"}
        and any(is_public_source(value) for value in case["sourcePrefixes"])
        and any(contains_management_port(value) for value in case["destinationPorts"])
    )
    if actual != case["expectedNonCompliant"]:
        raise SystemExit(
            f"ERROR: Network ingress semantic case failed: {case['name']} "
            f"(expected {case['expectedNonCompliant']}, got {actual})."
        )

if forms != {
    "shape": {"child", "inline"},
    "source": {"single", "plural"},
    "destination": {"single", "plural"},
}:
    raise SystemExit(f"ERROR: Network ingress fixtures do not cover all resource/property forms: {forms}")
PYEOF

python3 - "${TEMP_DIR}/main.json" "${PROJECT_DIR}/tests/fixtures/firewall-route-semantic-cases.json" <<'PYEOF'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    compiled = json.load(stream)
with open(sys.argv[2], encoding="utf-8") as stream:
    fixture = json.load(stream)

library = next(resource for resource in compiled["resources"].values() if resource["name"].startswith("[format('policy-library-"))
definition = next(
    resource for resource in library["properties"]["template"]["resources"]
    if resource["properties"]["displayName"] == "Demo - audit approved firewall route expectations"
)
policy_text = json.dumps(definition["properties"]["policyRule"]["if"])
for expression in (
    "approvedRouteTablePrefixes",
    "current('approvedRouteTablePrefix')",
    "nextHopType",
    "VirtualAppliance",
    "nextHopIpAddress",
    "approvedFirewallPrivateIp",
):
    if expression not in policy_text:
        raise SystemExit(f"ERROR: Compiled firewall route policy is missing: {expression}")

for case in fixture["cases"]:
    has_approved_route = any(
        route["addressPrefix"] == fixture["approvedRouteTablePrefix"]
        and route["nextHopType"] == "VirtualAppliance"
        and route["nextHopIpAddress"] == fixture["approvedFirewallPrivateIp"]
        for route in case["routes"]
    )
    if (not has_approved_route) != case["expectedNonCompliant"]:
        raise SystemExit(f"ERROR: Firewall route semantic case failed: {case['name']}")
PYEOF

printf '9/28 Confirm the Critical Infrastructure branch is opt-in and correctly wired...\n'
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

printf '10/28 Confirm Defender for Cloud plans are explicit, independent, safe-by-default opt-ins with no auto-granted role and current AMA audit controls exist...\n'
rg -q "^param enableDefenderCspm bool = false$" "${PROJECT_DIR}/main.bicep"
rg -q "^param enableDefenderForServers bool = false$" "${PROJECT_DIR}/main.bicep"
rg -q "^param enableDefenderForStorage bool = false$" "${PROJECT_DIR}/main.bicep"
jq -e '
  .parameters.enableDefenderCspm.defaultValue == false and
  .parameters.enableDefenderForServers.defaultValue == false and
  .parameters.enableDefenderForStorage.defaultValue == false
' "${TEMP_DIR}/main.json" >/dev/null
jq -e '
  .parameters.enableDefenderCspm.value == false and
  .parameters.enableDefenderForServers.value == false and
  .parameters.enableDefenderForStorage.value == false
' "${PROJECT_DIR}/parameters/demo.parameters.template.json" >/dev/null
jq -e '
  .parameters.enableDefenderCspm.value == false and
  .parameters.enableDefenderForServers.value == false and
  .parameters.enableDefenderForStorage.value == false
' "${TEMP_DIR}/main.parameters.json" >/dev/null
rg -q "^param plan .cspm. \| .servers. \| .storage.$" "${PROJECT_DIR}/modules/defender-plan-assignment.bicep"
rg -q "type: enablePlan \\? 'SystemAssigned' : 'None'" "${PROJECT_DIR}/modules/defender-plan-assignment.bicep"
rg -q "value: enablePlan \\? 'DeployIfNotExists' : 'Disabled'" "${PROJECT_DIR}/modules/defender-plan-assignment.bicep"
! rg -q "roleDefinitionId" "${PROJECT_DIR}/modules/defender-plan-assignment.bicep" || {
  printf 'ERROR: modules/defender-plan-assignment.bicep must never reference a roleDefinitionId; it must never auto-grant a role.\n' >&2
  exit 1
}
! rg -q "Microsoft.Authorization/roleAssignments" "${PROJECT_DIR}/modules/defender-plan-assignment.bicep" || {
  printf 'ERROR: modules/defender-plan-assignment.bicep must never create a role assignment.\n' >&2
  exit 1
}
rg -q "^param enableDefenderCiem bool = true$" "${PROJECT_DIR}/main.bicep"
rg -q "^param defenderForServersSubPlan string = 'P2'$" "${PROJECT_DIR}/main.bicep"
rg -q "^param defenderForServersAgentlessVmScanningEnabled bool = true$" "${PROJECT_DIR}/main.bicep"
defender_plan_assignments="$(jq '
  [.. | objects
    | select(.type? == "Microsoft.Resources/deployments")
    | select(.name? == "assign-defender-cspm" or .name? == "assign-defender-servers" or .name? == "assign-defender-storage")
  ]
' "${TEMP_DIR}/main.json")"
[[ "$(printf '%s' "${defender_plan_assignments}" | jq 'length')" -eq 3 ]] || {
  printf 'ERROR: Expected exactly three Defender plan assignment module deployments (cspm/servers/storage).\n' >&2
  exit 1
}
# Each of the three deployments must map to its own distinct plan/scope/opt-in
# wiring; an "any of the three" style assertion could pass even if, for
# example, the CSPM deployment were accidentally wired to the Storage GUID.
cspm_deployment="$(printf '%s' "${defender_plan_assignments}" | jq -c '.[] | select(.name == "assign-defender-cspm")')"
servers_deployment="$(printf '%s' "${defender_plan_assignments}" | jq -c '.[] | select(.name == "assign-defender-servers")')"
storage_deployment="$(printf '%s' "${defender_plan_assignments}" | jq -c '.[] | select(.name == "assign-defender-storage")')"
printf '%s' "${cspm_deployment}" | jq -e '
  .properties.parameters.plan.value == "cspm" and
  .properties.parameters.enablePlan.value == "[parameters(\u0027enableDefenderCspm\u0027)]" and
  .properties.parameters.cspmEntraPermissionsManagementEnabled.value == "[parameters(\u0027enableDefenderCiem\u0027)]" and
  (.scope | contains("demoRootManagementGroupId"))
' >/dev/null || {
  printf 'ERROR: assign-defender-cspm must be scoped to the demo root management group and wired to enableDefenderCspm/enableDefenderCiem.\n' >&2
  exit 1
}
printf '%s' "${servers_deployment}" | jq -e '
  .properties.parameters.plan.value == "servers" and
  .properties.parameters.enablePlan.value == "[parameters(\u0027enableDefenderForServers\u0027)]" and
  .properties.parameters.serversSubPlan.value == "[parameters(\u0027defenderForServersSubPlan\u0027)]" and
  .properties.parameters.serversAgentlessVmScanningEnabled.value == "[parameters(\u0027defenderForServersAgentlessVmScanningEnabled\u0027)]" and
  (.scope | contains("landingZonesManagementGroupId"))
' >/dev/null || {
  printf 'ERROR: assign-defender-servers must be scoped to the Landing Zones management group and wired to enableDefenderForServers/defenderForServersSubPlan/defenderForServersAgentlessVmScanningEnabled.\n' >&2
  exit 1
}
printf '%s' "${storage_deployment}" | jq -e '
  .properties.parameters.plan.value == "storage" and
  .properties.parameters.enablePlan.value == "[parameters(\u0027enableDefenderForStorage\u0027)]" and
  .properties.parameters.storageOnUploadMalwareScanningEnabled.value == "[parameters(\u0027enableDefenderStorageMalwareScanning\u0027)]" and
  .properties.parameters.storageCapGBPerMonthPerStorageAccount.value == "[parameters(\u0027defenderStorageMalwareScanningCapGBPerMonthPerStorageAccount\u0027)]" and
  (.scope | contains("landingZonesManagementGroupId"))
' >/dev/null || {
  printf 'ERROR: assign-defender-storage must be scoped to the Landing Zones management group and wired to enableDefenderForStorage/enableDefenderStorageMalwareScanning/defenderStorageMalwareScanningCapGBPerMonthPerStorageAccount.\n' >&2
  exit 1
}
rg -q "^param enableDefenderStorageMalwareScanning bool = false$" "${PROJECT_DIR}/main.bicep"
rg -q "^param defenderStorageMalwareScanningCapGBPerMonthPerStorageAccount int = 10000$" "${PROJECT_DIR}/main.bicep"
jq -e '
  .parameters.enableDefenderStorageMalwareScanning.defaultValue == false
' "${TEMP_DIR}/main.json" >/dev/null || {
  printf 'ERROR: enableDefenderStorageMalwareScanning must default to false so enabling the base Storage plan never silently enables the metered malware-scanning extension.\n' >&2
  exit 1
}
jq -e '
  .parameters.enableDefenderStorageMalwareScanning.value == false
' "${PROJECT_DIR}/parameters/demo.parameters.template.json" >/dev/null || {
  printf 'ERROR: parameters/demo.parameters.template.json must default enableDefenderStorageMalwareScanning to false.\n' >&2
  exit 1
}
# The module itself must map each verified plan to its own distinct
# definitionId/definitionVersion/parameter-object entry ("switch"), not a
# shared/ambiguous shape.
rg -q "definitionId: .72f8cee7-2937-403d-84a1-a4e3e57f3c21." "${PROJECT_DIR}/modules/defender-plan-assignment.bicep"
rg -q "definitionId: .5eb6d64a-4086-4d7a-92da-ec51aed0332d." "${PROJECT_DIR}/modules/defender-plan-assignment.bicep"
rg -q "definitionId: .cfdc5972-75b3-4418-8ae1-7f5c36839390." "${PROJECT_DIR}/modules/defender-plan-assignment.bicep"
rg -c "definitionVersion: '1\.\*\.\*'" "${PROJECT_DIR}/modules/defender-plan-assignment.bicep" | rg -q '^3$'
printf '%s' "${cspm_deployment}" | jq -e '
  .properties.template.variables.planDefinitions.cspm.definitionId == "72f8cee7-2937-403d-84a1-a4e3e57f3c21" and
  .properties.template.variables.planDefinitions.cspm.definitionVersion == "1.*.*" and
  (.properties.template.variables.planParameters.cspm | has("isSensitiveDataDiscoveryEnabled") and has("isContainerRegistriesVulnerabilityAssessmentsEnabled") and has("isAgentlessDiscoveryForKubernetesEnabled") and has("isAgentlessVmScanningEnabled") and has("isEntraPermissionsManagementEnabled"))
' >/dev/null || {
  printf 'ERROR: The compiled CSPM plan definition/parameter switch is missing an expected field.\n' >&2
  exit 1
}
printf '%s' "${servers_deployment}" | jq -e '
  .properties.template.variables.planDefinitions.servers.definitionId == "5eb6d64a-4086-4d7a-92da-ec51aed0332d" and
  .properties.template.variables.planDefinitions.servers.definitionVersion == "1.*.*" and
  (.properties.template.variables.planParameters.servers | has("subPlan") and has("isAgentlessVmScanningEnabled") and has("isMdeDesignatedSubscriptionEnabled"))
' >/dev/null || {
  printf 'ERROR: The compiled Servers plan definition/parameter switch is missing an expected field.\n' >&2
  exit 1
}
printf '%s' "${storage_deployment}" | jq -e '
  .properties.template.variables.planDefinitions.storage.definitionId == "cfdc5972-75b3-4418-8ae1-7f5c36839390" and
  .properties.template.variables.planDefinitions.storage.definitionVersion == "1.*.*" and
  (.properties.template.variables.planParameters.storage | has("isOnUploadMalwareScanningEnabled") and has("capGBPerMonthPerStorageAccount") and has("isSensitiveDataDiscoveryEnabled"))
' >/dev/null || {
  printf 'ERROR: The compiled Storage plan definition/parameter switch is missing an expected field.\n' >&2
  exit 1
}
# Assert the exact compiled identity/effect/policyDefinitionId/definitionVersion
# wiring on the nested assignment resource itself (not just the shared
# module's source text) for every one of the three plan deployments, so a
# regression in any single plan's compiled shape is caught even if the
# module source text still looks correct.
for defender_deployment_var in cspm_deployment servers_deployment storage_deployment; do
  printf '%s' "${!defender_deployment_var}" | jq -e '
    .properties.template.resources.assignment.identity.type == "[if(parameters(\u0027enablePlan\u0027), \u0027SystemAssigned\u0027, \u0027None\u0027)]" and
    .properties.template.resources.assignment.properties.policyDefinitionId == "[variables(\u0027policyDefinitionId\u0027)]" and
    .properties.template.resources.assignment.properties.definitionVersion == "[variables(\u0027selectedPlan\u0027).definitionVersion]" and
    .properties.template.resources.assignment.properties.parameters == "[union(createObject(\u0027effect\u0027, createObject(\u0027value\u0027, if(parameters(\u0027enablePlan\u0027), \u0027DeployIfNotExists\u0027, \u0027Disabled\u0027))), variables(\u0027planParameters\u0027)[parameters(\u0027plan\u0027)])]"
  ' >/dev/null || {
    printf 'ERROR: %s does not compile the expected identity/effect/policyDefinitionId/definitionVersion wiring on its nested assignment resource.\n' "${defender_deployment_var}" >&2
    exit 1
  }
done
printf '%s' "${servers_deployment}" | jq -e '
  .properties.template.variables.validatedServersAgentlessVmScanningEnabled == "[if(and(and(equals(parameters(\u0027plan\u0027), \u0027servers\u0027), equals(parameters(\u0027serversSubPlan\u0027), \u0027P1\u0027)), parameters(\u0027serversAgentlessVmScanningEnabled\u0027)), fail(\u0027serversAgentlessVmScanningEnabled must be false when serversSubPlan is P1; agentless VM scanning is only supported on the Servers P2 sub-plan.\u0027), parameters(\u0027serversAgentlessVmScanningEnabled\u0027))]" and
  .properties.template.variables.planParameters.servers.isAgentlessVmScanningEnabled.value == "[if(variables(\u0027validatedServersAgentlessVmScanningEnabled\u0027), \u0027true\u0027, \u0027false\u0027)]"
' >/dev/null || {
  printf 'ERROR: assign-defender-servers must compile the exact P1/agentless-scanning fail() rejection expression, and isAgentlessVmScanningEnabled must be wired through the validated variable rather than the raw parameter.\n' >&2
  exit 1
}
# The built-in's own parameter metadata documents capGBPerMonthPerStorageAccount
# as "an integer, 10GB or higher" or "-1 for unlimited scanning"; values from
# 0 through 9 (or anything below -1) must be rejected explicitly rather than
# forwarded unchanged.
printf '%s' "${storage_deployment}" | jq -e '
  .properties.template.variables.validatedStorageCapGBPerMonthPerStorageAccount == "[if(or(equals(parameters(\u0027storageCapGBPerMonthPerStorageAccount\u0027), -1), greaterOrEquals(parameters(\u0027storageCapGBPerMonthPerStorageAccount\u0027), 10)), parameters(\u0027storageCapGBPerMonthPerStorageAccount\u0027), fail(\u0027storageCapGBPerMonthPerStorageAccount must be -1 (unlimited) or at least 10 GB per storage account per month.\u0027))]" and
  .properties.template.variables.planParameters.storage.capGBPerMonthPerStorageAccount.value == "[variables(\u0027validatedStorageCapGBPerMonthPerStorageAccount\u0027)]"
' >/dev/null || {
  printf 'ERROR: assign-defender-storage must compile the exact -1-or->=10 fail() rejection expression for storageCapGBPerMonthPerStorageAccount, and capGBPerMonthPerStorageAccount must be wired through the validated variable rather than the raw parameter.\n' >&2
  exit 1
}
! rg -q "475aae12-b88a-4572-8b36-9b712b2b3a17" "${PROJECT_DIR}/main.bicep" "${PROJECT_DIR}/modules/defender-plan-assignment.bicep" || {
  printf 'ERROR: The deprecated Log Analytics (MMA) auto-provisioning policy definition must never be referenced.\n' >&2
  exit 1
}
rg -q "c02729e5-e5e7-4458-97fa-2b5ad0661f28" "${PROJECT_DIR}/main.bicep"
rg -q "1afdc4b6-581a-45fb-b630-f1e6051e3e7a" "${PROJECT_DIR}/main.bicep"
ama_audit_assignments="$(jq '
  [.. | objects
    | select(.type? == "Microsoft.Resources/deployments")
    | select(.name? == "assign-defender-ama-audit-windows" or .name? == "assign-defender-ama-audit-linux")
  ]
' "${TEMP_DIR}/main.json")"
[[ "$(printf '%s' "${ama_audit_assignments}" | jq 'length')" -eq 2 ]] || {
  printf 'ERROR: Expected exactly two Azure Monitor Agent audit policy assignment module deployments (Windows/Linux).\n' >&2
  exit 1
}
printf '%s' "${ama_audit_assignments}" | jq -e '
  (.[] | select(.name == "assign-defender-ama-audit-windows") | .properties.parameters.policyDefinitionId.value) == "[variables(\u0027windowsAmaAuditPolicyDefinitionId\u0027)]" and
  (.[] | select(.name == "assign-defender-ama-audit-linux") | .properties.parameters.policyDefinitionId.value) == "[variables(\u0027linuxAmaAuditPolicyDefinitionId\u0027)]"
' >/dev/null || {
  printf 'ERROR: The Windows/Linux AMA audit assignments must each be wired to their own dedicated policyDefinitionId variable.\n' >&2
  exit 1
}
jq -e '
  .variables.windowsAmaAuditPolicyDefinitionId == "[tenantResourceId(\u0027Microsoft.Authorization/policyDefinitions\u0027, \u0027c02729e5-e5e7-4458-97fa-2b5ad0661f28\u0027)]" and
  .variables.linuxAmaAuditPolicyDefinitionId == "[tenantResourceId(\u0027Microsoft.Authorization/policyDefinitions\u0027, \u00271afdc4b6-581a-45fb-b630-f1e6051e3e7a\u0027)]"
' "${TEMP_DIR}/main.json" >/dev/null || {
  printf 'ERROR: The Windows/Linux AMA audit policy definition IDs must each resolve to their own verified built-in GUID.\n' >&2
  exit 1
}
printf '%s' "${ama_audit_assignments}" | jq -e 'all(.[]; .properties.parameters.definitionVersion.value == "3.*.*")' >/dev/null
printf '%s' "${ama_audit_assignments}" | jq -e 'all(.[]; .properties.template.resources.assignment.identity == null)' >/dev/null
printf '%s' "${ama_audit_assignments}" | jq -e 'all(.[]; .scope | contains("landingZonesManagementGroupId"))' >/dev/null || {
  printf 'ERROR: Both AMA audit assignments must be scoped to the Landing Zones management group.\n' >&2
  exit 1
}
printf '%s' "${ama_audit_assignments}" | jq -e 'all(.[]; .properties.parameters.parameters.value.effect.value == "AuditIfNotExists")' >/dev/null || {
  printf 'ERROR: Both AMA audit assignments must explicitly pass effect: AuditIfNotExists rather than silently inheriting the built-in'"'"'s own default.\n' >&2
  exit 1
}
# The free vulnerability-assessment audit assignment must independently pin
# its own verified GUID/version/scope and must never attach an identity
# (it has no paid-plan dependency and performs no remediation).
vuln_assessment_deployment="$(jq -c '
  [.. | objects | select(.type? == "Microsoft.Resources/deployments") | select(.name? == "assign-vuln-assessment-audit")][0]
' "${TEMP_DIR}/main.json")"
[[ "${vuln_assessment_deployment}" != "null" ]] || {
  printf 'ERROR: Expected an assign-vuln-assessment-audit module deployment.\n' >&2
  exit 1
}
printf '%s' "${vuln_assessment_deployment}" | jq -e '
  .properties.parameters.policyDefinitionId.value == "[variables(\u0027vulnerabilityAssessmentAuditPolicyDefinitionId\u0027)]" and
  .properties.parameters.definitionVersion.value == "3.*.*" and
  .properties.parameters.parameters.value.effect.value == "AuditIfNotExists" and
  .properties.template.resources.assignment.identity == null and
  (.scope | contains("landingZonesManagementGroupId"))
' >/dev/null || {
  printf 'ERROR: assign-vuln-assessment-audit must be scoped to the Landing Zones management group, wired to its own vulnerabilityAssessmentAuditPolicyDefinitionId variable, pinned to definitionVersion 3.*.*, explicitly set effect: AuditIfNotExists, and must never attach an identity.\n' >&2
  exit 1
}
jq -e '
  .variables.vulnerabilityAssessmentAuditPolicyDefinitionId == "[tenantResourceId(\u0027Microsoft.Authorization/policyDefinitions\u0027, \u0027501541f7-f7e7-4cd6-868c-4190fdad3ac9\u0027)]"
' "${TEMP_DIR}/main.json" >/dev/null || {
  printf 'ERROR: vulnerabilityAssessmentAuditPolicyDefinitionId must resolve to its own verified built-in GUID.\n' >&2
  exit 1
}

rg -q '"REQ-DEF-09"' "${PROJECT_DIR}/policy/control-catalog.json"
rg -q "Foundational CSPM" "${PROJECT_DIR}/README.md"

printf '11/28 Confirm criticalInfrastructureSubscriptionIds validates duplicates and overlap...\n'
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

printf '12/28 Confirm teardown scripts move critical subscriptions and delete the Critical Infrastructure management group before Landing Zones...\n'
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

printf '13/28 Confirm central monitoring defaults create no metered resources...\n'
jq -e '
  .parameters.deployCentralLogAnalytics.value == false and
  .parameters.deploySentinel.value == false and
  .parameters.existingLogAnalyticsWorkspaceResourceId.value == ""
' "${PROJECT_DIR}/parameters/demo.parameters.template.json" >/dev/null
rg -q "^param deployCentralLogAnalytics bool = false$" "${PROJECT_DIR}/modules/central-monitoring.bicep"
rg -q "^param deploySentinel bool = false$" "${PROJECT_DIR}/modules/central-monitoring.bicep"
rg -q "^param existingLogAnalyticsWorkspaceResourceId string = ''$" "${PROJECT_DIR}/modules/central-monitoring.bicep"

printf "14/28 Confirm central monitoring guards against conflicting new/existing workspace inputs and Sentinel-without-workspace...\n"
rg -q 'conflictingMonitoringInputs = newWorkspaceRequested && existingWorkspaceSupplied' "${PROJECT_DIR}/modules/central-monitoring.bicep"
rg -q 'sentinelRequiresEffectiveWorkspace = deploySentinel && !newWorkspaceRequested && !existingWorkspaceSupplied' "${PROJECT_DIR}/modules/central-monitoring.bicep"
rg -q 'createNewWorkspace = newWorkspaceRequested && !hasMonitoringConfigurationError' "${PROJECT_DIR}/modules/central-monitoring.bicep"
rg -q 'useExistingWorkspace = existingWorkspaceSupplied && !hasMonitoringConfigurationError' "${PROJECT_DIR}/modules/central-monitoring.bicep"

printf '15/28 Confirm the central monitoring module exposes an effective workspace ID output...\n'
rg -q '^output effectiveLogAnalyticsWorkspaceResourceId string' "${PROJECT_DIR}/modules/central-monitoring.bicep"
rg -q 'centralMonitoringEffectiveWorkspaceId string = centralMonitoring\.outputs\.effectiveLogAnalyticsWorkspaceResourceId' "${PROJECT_DIR}/main.bicep"

printf '16/28 Confirm invalid central monitoring configurations fail deployment explicitly...\n'
rg -q "resource conflictingMonitoringInputsGuard 'Microsoft.CentralMonitoringGuard/configurationError@" "${PROJECT_DIR}/modules/central-monitoring.bicep"
rg -q 'if \(conflictingMonitoringInputs\)' "${PROJECT_DIR}/modules/central-monitoring.bicep"
rg -q "resource sentinelRequiresWorkspaceGuard 'Microsoft.CentralMonitoringGuard/configurationError@" "${PROJECT_DIR}/modules/central-monitoring.bicep"
rg -q 'if \(sentinelRequiresEffectiveWorkspace\)' "${PROJECT_DIR}/modules/central-monitoring.bicep"

printf '17/28 Confirm teardown scripts protect a supplied existing workspace resource group and only remove a demo-created monitoring resource group...\n'
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

printf '18/28 Confirm a whitespace-only existing workspace resource ID never triggers deletion of the monitoring resource group...\n'
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

printf '19/28 Parse cross-platform scripts and check macOS Bash 3.2 compatibility...\n'
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
  if ! "${bash3_candidate}" "${PROJECT_DIR}/scripts/validate-rbac-artifacts.sh" >/dev/null; then
    printf 'ERROR: scripts/validate-rbac-artifacts.sh failed when executed directly under %s.\n' "${bash3_candidate}" >&2
    exit 1
  fi
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

printf '20/28 Validate reusable initiative composition...\n'
"${SCRIPT_DIR}/validate-initiative-composition.sh"

printf '21/28 Validate the v2 control catalog (schema-equivalent checks + matrix consistency)...\n'
"${SCRIPT_DIR}/validate-control-catalog.sh"

printf '22/28 Backend parity and structural-matrix regression tests (bash/python, bash/jq, pwsh/python, pwsh/native)...\n'
"${SCRIPT_DIR}/uri-grammar-forced-fallback-tests.sh"

printf '23/28 Validate Entra Conditional Access and PIM demo artifacts...\n'
"${PROJECT_DIR}/scripts/validate-identity-artifacts.sh"

printf '24/28 Confirm identity validators reject invalid Conditional Access and PIM inputs...\n'
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

printf '25/28 Confirm security benchmark assignments trace to the control catalog and stay optional...\n'
control_catalog="${PROJECT_DIR}/policy/control-catalog.json"
jq -e --slurpfile catalog "${control_catalog}" '
  def deployment($name):
    first(.. | objects | select(.type? == "Microsoft.Resources/deployments" and .name? == $name));
  def control($id):
    first($catalog[0].controls[] | select(.id == $id));
  def definition_id($id):
    "[tenantResourceId(\u0027Microsoft.Authorization/policySetDefinitions\u0027, \u0027\(control($id).mechanism.definitionId)\u0027)]";
  def pinned_version($id):
    "\(control($id).mechanism.majorVersion).*.*";
  def assigned_at_demo_root($deployment):
    $deployment.scope == "[format(\u0027Microsoft.Management/managementGroups/{0}\u0027, variables(\u0027demoRootManagementGroupId\u0027))]";
  deployment("assign-mcsb-baseline") as $mcsb |
  deployment("assign-cis-foundations") as $cis |
  deployment("assign-nist-sp-800-53-r5") as $nist |
  .parameters.enableMicrosoftCloudSecurityBenchmark.defaultValue == true and
  .parameters.enableCisAzureFoundationsBenchmark.defaultValue == false and
  .parameters.enableNistSp80053Rev5.defaultValue == false and
  $mcsb.condition == "[parameters(\u0027enableMicrosoftCloudSecurityBenchmark\u0027)]" and
  $cis.condition == "[parameters(\u0027enableCisAzureFoundationsBenchmark\u0027)]" and
  $nist.condition == "[parameters(\u0027enableNistSp80053Rev5\u0027)]" and
  assigned_at_demo_root($mcsb) and assigned_at_demo_root($cis) and assigned_at_demo_root($nist) and
  .variables.microsoftCloudSecurityBenchmarkPolicySetDefinitionId == definition_id("REQ-BASE-01") and
  .variables.cisAzureFoundationsPolicySetDefinitionId == definition_id("REQ-BASE-02") and
  .variables.nistSp80053Rev5PolicySetDefinitionId == definition_id("REQ-BASE-03") and
  $mcsb.properties.parameters.policyDefinitionId.value ==
    "[variables(\u0027microsoftCloudSecurityBenchmarkPolicySetDefinitionId\u0027)]" and
  $cis.properties.parameters.policyDefinitionId.value ==
    "[variables(\u0027cisAzureFoundationsPolicySetDefinitionId\u0027)]" and
  $nist.properties.parameters.policyDefinitionId.value ==
    "[variables(\u0027nistSp80053Rev5PolicySetDefinitionId\u0027)]" and
  $mcsb.properties.parameters.definitionVersion.value == pinned_version("REQ-BASE-01") and
  $cis.properties.parameters.definitionVersion.value == pinned_version("REQ-BASE-02") and
  $nist.properties.parameters.definitionVersion.value == pinned_version("REQ-BASE-03") and
  all(($mcsb, $cis, $nist);
    .properties.parameters.enforcementMode.value == "[parameters(\u0027denyPolicyEnforcementMode\u0027)]") and
  all(($mcsb, $cis);
    all(.properties.template.resources[] | select(.type == "Microsoft.Authorization/policyAssignments");
      has("identity") | not)) and
  $nist.properties.parameters.identity.value == {type: "SystemAssigned"} and
  $nist.properties.parameters.verifiedRoleDefinitionIds.value ==
    ["[variables(\u0027contributorRoleDefinitionId\u0027)]"] and
  .variables.contributorRoleDefinitionId == (control("REQ-BASE-03").roleDefinitionIds | first) and
  .outputs.securityBenchmarkAssignments.value == {
    microsoftCloudSecurityBenchmark: "[parameters(\u0027enableMicrosoftCloudSecurityBenchmark\u0027)]",
    cisAzureFoundationsBenchmark: "[parameters(\u0027enableCisAzureFoundationsBenchmark\u0027)]",
    nistSp80053Rev5: "[parameters(\u0027enableNistSp80053Rev5\u0027)]"
  }
' "${TEMP_DIR}/main.json" >/dev/null || {
  printf 'ERROR: Security benchmark assignments do not match the verified control catalog or safe defaults.\n' >&2
  exit 1
}
printf '    Confirm preview or superseded benchmark initiatives are never selected...\n'
for preview_definition_id in \
  'e3ec7e09-768c-4b64-882c-fcada3772047' \
  '60205a79-6280-4e20-a147-e2011e09dc78' \
  'c3f5c4d9-9a1d-4a99-85c0-7f93e384d5c5'; do
  if rg -q --glob '*.bicep' --glob '*.bicepparam' "${preview_definition_id}" "${PROJECT_DIR}"; then
    printf 'ERROR: Preview or superseded benchmark initiative %s must never be assigned.\n' \
      "${preview_definition_id}" >&2
    exit 1
  fi
done
if rg -qi 'azure security baseline' --glob '*.bicep' --glob '*.bicepparam' "${PROJECT_DIR}"; then
  printf 'ERROR: Do not create a duplicate "Azure Security Baseline" initiative; per-service baselines are guidance only.\n' >&2
  exit 1
fi
printf '    Confirm every enabled/disabled benchmark combination compiles with the expected assignments...\n'
for benchmark_case in 'true,false,false' 'false,false,false' 'true,true,true' 'false,true,false' 'false,false,true'; do
  mcsb_enabled="${benchmark_case%%,*}"
  cis_enabled="${benchmark_case#*,}"
  cis_enabled="${cis_enabled%%,*}"
  nist_enabled="${benchmark_case##*,}"
  benchmark_params="${TEMP_DIR}/benchmark-${mcsb_enabled}-${cis_enabled}-${nist_enabled}.bicepparam"
  sed -e "s|^using '../main.bicep'\$|using '../../main.bicep'|" \
    -e 's/^param enableMicrosoftCloudSecurityBenchmark = .*$/param enableMicrosoftCloudSecurityBenchmark = '"${mcsb_enabled}"'/' \
    -e 's/^param enableCisAzureFoundationsBenchmark = .*$/param enableCisAzureFoundationsBenchmark = '"${cis_enabled}"'/' \
    -e 's/^param enableNistSp80053Rev5 = .*$/param enableNistSp80053Rev5 = '"${nist_enabled}"'/' \
    "${PROJECT_DIR}/parameters/main.template.bicepparam" > "${benchmark_params}"
  az bicep build-params --file "${benchmark_params}" --outfile "${benchmark_params}.json" >/dev/null
  jq -e \
    --argjson mcsb "${mcsb_enabled}" \
    --argjson cis "${cis_enabled}" \
    --argjson nist "${nist_enabled}" '
    .parameters.enableMicrosoftCloudSecurityBenchmark.value == $mcsb and
    .parameters.enableCisAzureFoundationsBenchmark.value == $cis and
    .parameters.enableNistSp80053Rev5.value == $nist
  ' "${benchmark_params}.json" >/dev/null || {
    printf 'ERROR: Benchmark combination %s did not compile to the expected parameter values.\n' \
      "${benchmark_case}" >&2
    exit 1
  }
done
jq -e '
  .parameters.enableMicrosoftCloudSecurityBenchmark.value == true and
  .parameters.enableCisAzureFoundationsBenchmark.value == false and
  .parameters.enableNistSp80053Rev5.value == false
' "${PROJECT_DIR}/parameters/demo.parameters.template.json" >/dev/null || {
  printf 'ERROR: The ARM parameter template must enable only the stable MCSB baseline by default.\n' >&2
  exit 1
}

printf '26/28 Confirm logging assignments use the verified workspace/identity/effect model at the demo root...\n'
rg -q -F "func hasCanonicalArmIdSegments" "${PROJECT_DIR}/main.bicep"
rg -q "func hasDisallowedResourceGroupAsciiChars" "${PROJECT_DIR}/main.bicep"
rg -q "func isResourceGroupName\\(value string\\) bool => .*length\\(value\\) <= 90.*!hasDisallowedResourceGroupAsciiChars\\(value\\)" "${PROJECT_DIR}/main.bicep"
rg -q "func isLogAnalyticsWorkspaceName\\(value string\\) bool => .*length\\(value\\) >= 4.*length\\(value\\) <= 63.*!startsWith\\(value, '-'\\).*empty\\(stripAlphaNumeric\\(replace\\(value, '-', ''\\)\\)\\)" "${PROJECT_DIR}/main.bicep"
rg -q "func isWorkspaceResourceId\\(value string\\) bool => .*hasCanonicalArmIdSegments\\(value\\).*isResourceGroupName\\(split\\(value, '/'\\)\\[4\\]\\).*isLogAnalyticsWorkspaceName\\(split\\(value, '/'\\)\\[8\\]\\)" "${PROJECT_DIR}/main.bicep"
jq -e --slurpfile catalog "${control_catalog}" '
  def deployment($name):
    first(.. | objects | select(.type? == "Microsoft.Resources/deployments" and .name? == $name));
  def control($id):
    first($catalog[0].controls[] | select(.id == $id));
  def definition_id($id):
    if control($id).mechanism.kind == "policySetDefinition"
    then "[tenantResourceId(\u0027Microsoft.Authorization/policySetDefinitions\u0027, \u0027\(control($id).mechanism.definitionId)\u0027)]"
    else "[tenantResourceId(\u0027Microsoft.Authorization/policyDefinitions\u0027, \u0027\(control($id).mechanism.definitionId)\u0027)]"
    end;
  def assigned_at_demo_root($deployment):
    $deployment.scope | contains("demoRootManagementGroupId");
  deployment("assign-activity-logs") as $activity |
  deployment("assign-activity-logs-remediating") as $activity_remediating |
  deployment("assign-resource-diagnostics") as $diagnostics |
  deployment("assign-resource-diagnostics-remediating") as $diagnostics_remediating |
  deployment("activity-log-workspace-destination-rbac") as $activity_workspace_rbac |
  deployment("resource-diagnostics-workspace-destination-rbac") as $diagnostics_workspace_rbac |
  .parameters.activityLogExportPolicyEffect.defaultValue == "Disabled" and
  .parameters.activityLogExportLogsEnabled.defaultValue == "True" and
  .parameters.resourceDiagnosticsPolicyEffect.defaultValue == "AuditIfNotExists" and
  .parameters.resourceDiagnosticsCategoryGroup.defaultValue == "audit" and
  .parameters.deployLoggingRemediationRoleAssignments.defaultValue == false and
  .variables.activityLogExportPolicyDefinitionId == definition_id("REQ-LOG-01") and
  .variables.resourceDiagnosticsAllLogsPolicySetDefinitionId == definition_id("REQ-LOG-02") and
  .variables.resourceDiagnosticsAuditPolicySetDefinitionId ==
    "[tenantResourceId(\u0027Microsoft.Authorization/policySetDefinitions\u0027, \u0027f5b29bc4-feca-4cc6-a58a-772dd5e290a5\u0027)]" and
  .variables.resourceDiagnosticsPolicySetDefinitionId ==
    "[if(equals(parameters(\u0027resourceDiagnosticsCategoryGroup\u0027), \u0027allLogs\u0027), variables(\u0027resourceDiagnosticsAllLogsPolicySetDefinitionId\u0027), variables(\u0027resourceDiagnosticsAuditPolicySetDefinitionId\u0027))]" and
  .variables.loggingWorkspaceSubscriptionId ==
    "[if(parameters(\u0027deployCentralLogAnalytics\u0027), parameters(\u0027connectivitySubscriptionId\u0027), variables(\u0027existingWorkspaceResourceIdParts\u0027)[2])]" and
  .variables.loggingWorkspaceResourceGroupName ==
    "[if(parameters(\u0027deployCentralLogAnalytics\u0027), format(\u0027rg-{0}-monitoring\u0027, parameters(\u0027namePrefix\u0027)), variables(\u0027existingWorkspaceResourceIdParts\u0027)[4])]" and
  .variables.loggingWorkspaceName ==
    "[if(parameters(\u0027deployCentralLogAnalytics\u0027), format(\u0027log-{0}-central\u0027, parameters(\u0027namePrefix\u0027)), variables(\u0027existingWorkspaceResourceIdParts\u0027)[8])]" and
  .variables.monitoringContributorRoleDefinitionId == (control("REQ-LOG-01").roleDefinitionIds | first) and
  .variables.logAnalyticsContributorRoleDefinitionId == (control("REQ-LOG-02").roleDefinitionIds | first) and
  .variables.loggingAssignmentsRequireWorkspace ==
    "[or(or(equals(parameters(\u0027activityLogExportPolicyEffect\u0027), \u0027DeployIfNotExists\u0027), equals(parameters(\u0027resourceDiagnosticsPolicyEffect\u0027), \u0027DeployIfNotExists\u0027)), equals(parameters(\u0027resourceDiagnosticsPolicyEffect\u0027), \u0027AuditIfNotExists\u0027))]" and
  .variables.activityLogRemediationDeployRequested == "[equals(parameters(\u0027activityLogExportPolicyEffect\u0027), \u0027DeployIfNotExists\u0027)]" and
  .variables.resourceDiagnosticsRemediationDeployRequested == "[equals(parameters(\u0027resourceDiagnosticsPolicyEffect\u0027), \u0027DeployIfNotExists\u0027)]" and
  .variables.deployActivityLogRemediationRoleAssignments ==
    "[and(and(parameters(\u0027deployRoleAssignments\u0027), parameters(\u0027deployLoggingRemediationRoleAssignments\u0027)), variables(\u0027activityLogRemediationDeployRequested\u0027))]" and
  .variables.deployResourceDiagnosticsRemediationRoleAssignments ==
    "[and(and(parameters(\u0027deployRoleAssignments\u0027), parameters(\u0027deployLoggingRemediationRoleAssignments\u0027)), variables(\u0027resourceDiagnosticsRemediationDeployRequested\u0027))]" and
  assigned_at_demo_root($activity) and assigned_at_demo_root($activity_remediating) and
  assigned_at_demo_root($diagnostics) and assigned_at_demo_root($diagnostics_remediating) and
  all(($activity, $activity_remediating, $diagnostics, $diagnostics_remediating);
    .properties.parameters.enforcementMode.value == "[parameters(\u0027denyPolicyEnforcementMode\u0027)]") and
  ($activity.properties.parameters | has("location") | not) and
  ($activity.properties.parameters | has("identity") | not) and
  ($activity.properties.parameters | has("verifiedRoleDefinitionIds") | not) and
  ($activity.properties.parameters | has("deployRemediationRoleAssignments") | not) and
  ($diagnostics.properties.parameters | has("location") | not) and
  ($diagnostics.properties.parameters | has("identity") | not) and
  ($diagnostics.properties.parameters | has("verifiedRoleDefinitionIds") | not) and
  ($diagnostics.properties.parameters | has("deployRemediationRoleAssignments") | not) and
  all(($activity_remediating, $diagnostics_remediating);
    .properties.parameters.location.value == "[parameters(\u0027deploymentLocation\u0027)]" and
    .properties.parameters.identity.value == {type: "SystemAssigned"}) and
  $activity.properties.parameters.policyDefinitionId.value ==
    "[variables(\u0027activityLogExportPolicyDefinitionId\u0027)]" and
  $activity_remediating.properties.parameters.policyDefinitionId.value ==
    "[variables(\u0027activityLogExportPolicyDefinitionId\u0027)]" and
  $activity.properties.parameters.definitionVersion.value == "1.*.*" and
  $activity_remediating.properties.parameters.definitionVersion.value == "1.*.*" and
  $activity.properties.parameters.parameters.value.effect.value ==
    "[parameters(\u0027activityLogExportPolicyEffect\u0027)]" and
  $activity_remediating.properties.parameters.parameters.value.effect.value ==
    "[parameters(\u0027activityLogExportPolicyEffect\u0027)]" and
  $activity.properties.parameters.parameters.value.logsEnabled.value ==
    "[parameters(\u0027activityLogExportLogsEnabled\u0027)]" and
  $activity_remediating.properties.parameters.parameters.value.logsEnabled.value ==
    "[parameters(\u0027activityLogExportLogsEnabled\u0027)]" and
  ($activity.properties.parameters.parameters.value.logAnalytics.value |
    contains("reference(\u0027centralMonitoring\u0027).outputs.effectiveLogAnalyticsWorkspaceResourceId.value")) and
  ($activity_remediating.properties.parameters.parameters.value.logAnalytics.value |
    contains("reference(\u0027centralMonitoring\u0027).outputs.effectiveLogAnalyticsWorkspaceResourceId.value")) and
  ($activity.properties.parameters.parameters.value.logAnalytics.value |
    contains("fail(\u0027Activity Log and supported-resource diagnostics assignments require a valid effective Log Analytics workspace resource ID in the exact form /subscriptions/<guid>/resourceGroups/<name>/providers/Microsoft.OperationalInsights/workspaces/<name>")) and
  ($activity_remediating.properties.parameters.parameters.value.logAnalytics.value |
    contains("fail(\u0027Activity Log and supported-resource diagnostics assignments require a valid effective Log Analytics workspace resource ID in the exact form /subscriptions/<guid>/resourceGroups/<name>/providers/Microsoft.OperationalInsights/workspaces/<name>")) and
  ($activity.properties.parameters.parameters.value.logAnalytics.value |
    contains("__bicep.isWorkspaceResourceId")) and
  ($activity_remediating.properties.parameters.parameters.value.logAnalytics.value |
    contains("__bicep.isWorkspaceResourceId")) and
  $activity_remediating.properties.parameters.verifiedRoleDefinitionIds.value ==
    ["[variables(\u0027monitoringContributorRoleDefinitionId\u0027)]", "[variables(\u0027logAnalyticsContributorRoleDefinitionId\u0027)]"] and
  $activity_remediating.properties.parameters.deployRemediationRoleAssignments.value ==
    "[variables(\u0027deployActivityLogRemediationRoleAssignments\u0027)]" and
  $activity.properties.parameters.nonComplianceMessages.value == [
    {
      "message": "Activity Log export requires a valid effective Log Analytics workspace resource ID and the configured subscription diagnostic settings must stream to that workspace."
    }
  ] and
  $activity_remediating.properties.parameters.nonComplianceMessages.value == [
    {
      "message": "Activity Log export requires a valid effective Log Analytics workspace resource ID and the configured subscription diagnostic settings must stream to that workspace."
    }
  ] and
  $diagnostics.properties.parameters.policyDefinitionId.value ==
    "[variables(\u0027resourceDiagnosticsPolicySetDefinitionId\u0027)]" and
  $diagnostics_remediating.properties.parameters.policyDefinitionId.value ==
    "[variables(\u0027resourceDiagnosticsPolicySetDefinitionId\u0027)]" and
  $diagnostics.properties.parameters.definitionVersion.value == "1.*.*" and
  $diagnostics_remediating.properties.parameters.definitionVersion.value == "1.*.*" and
  $diagnostics.properties.parameters.parameters.value.effect.value ==
    "[parameters(\u0027resourceDiagnosticsPolicyEffect\u0027)]" and
  $diagnostics_remediating.properties.parameters.parameters.value.effect.value ==
    "[parameters(\u0027resourceDiagnosticsPolicyEffect\u0027)]" and
  ($diagnostics.properties.parameters.parameters.value.logAnalytics.value |
    contains("reference(\u0027centralMonitoring\u0027).outputs.effectiveLogAnalyticsWorkspaceResourceId.value")) and
  ($diagnostics.properties.parameters.parameters.value.logAnalytics.value |
    contains("fail(\u0027Activity Log and supported-resource diagnostics assignments require a valid effective Log Analytics workspace resource ID in the exact form /subscriptions/<guid>/resourceGroups/<name>/providers/Microsoft.OperationalInsights/workspaces/<name>")) and
  ($diagnostics.properties.parameters.parameters.value.logAnalytics.value |
    contains("__bicep.isWorkspaceResourceId")) and
  ($diagnostics_remediating.properties.parameters.parameters.value.logAnalytics.value |
    contains("reference(\u0027centralMonitoring\u0027).outputs.effectiveLogAnalyticsWorkspaceResourceId.value")) and
  ($diagnostics_remediating.properties.parameters.parameters.value.logAnalytics.value |
    contains("fail(\u0027Activity Log and supported-resource diagnostics assignments require a valid effective Log Analytics workspace resource ID in the exact form /subscriptions/<guid>/resourceGroups/<name>/providers/Microsoft.OperationalInsights/workspaces/<name>")) and
  ($diagnostics_remediating.properties.parameters.parameters.value.logAnalytics.value |
    contains("__bicep.isWorkspaceResourceId")) and
  $diagnostics_remediating.properties.parameters.verifiedRoleDefinitionIds.value ==
    ["[variables(\u0027logAnalyticsContributorRoleDefinitionId\u0027)]"] and
  $diagnostics_remediating.properties.parameters.deployRemediationRoleAssignments.value ==
    "[variables(\u0027deployResourceDiagnosticsRemediationRoleAssignments\u0027)]" and
  $diagnostics.properties.parameters.nonComplianceMessages.value == [
    {
      "message": "Supported-resource diagnostics export requires a valid effective Log Analytics workspace resource ID and compliant diagnostic settings for supported resource types."
    }
  ] and
  $diagnostics_remediating.properties.parameters.nonComplianceMessages.value == [
    {
      "message": "Supported-resource diagnostics export requires a valid effective Log Analytics workspace resource ID and compliant diagnostic settings for supported resource types."
    }
  ] and
  $activity.condition == "[not(variables(\u0027activityLogRemediationDeployRequested\u0027))]" and
  $activity_remediating.condition == "[variables(\u0027activityLogRemediationDeployRequested\u0027)]" and
  $diagnostics.condition == "[not(variables(\u0027resourceDiagnosticsRemediationDeployRequested\u0027))]" and
  $diagnostics_remediating.condition == "[variables(\u0027resourceDiagnosticsRemediationDeployRequested\u0027)]" and
  $activity_workspace_rbac.condition ==
    "[variables(\u0027deployActivityLogRemediationRoleAssignments\u0027)]" and
  $diagnostics_workspace_rbac.condition ==
    "[variables(\u0027deployResourceDiagnosticsRemediationRoleAssignments\u0027)]" and
  $activity_workspace_rbac.subscriptionId == "[variables(\u0027loggingWorkspaceSubscriptionId\u0027)]" and
  $activity_workspace_rbac.resourceGroup == "[variables(\u0027loggingWorkspaceResourceGroupName\u0027)]" and
  $diagnostics_workspace_rbac.subscriptionId == "[variables(\u0027loggingWorkspaceSubscriptionId\u0027)]" and
  $diagnostics_workspace_rbac.resourceGroup == "[variables(\u0027loggingWorkspaceResourceGroupName\u0027)]" and
  $activity_workspace_rbac.properties.parameters.workspaceName.value == "[variables(\u0027loggingWorkspaceName\u0027)]" and
  $diagnostics_workspace_rbac.properties.parameters.workspaceName.value == "[variables(\u0027loggingWorkspaceName\u0027)]" and
  $activity_workspace_rbac.properties.parameters.roleDefinitionIds.value ==
    ["[variables(\u0027logAnalyticsContributorRoleDefinitionId\u0027)]"] and
  $activity_workspace_rbac.properties.template.resources.remediationRoleAssignments.scope ==
    "[resourceId(\u0027Microsoft.OperationalInsights/workspaces\u0027, parameters(\u0027workspaceName\u0027))]" and
  $activity_workspace_rbac.properties.template.resources.remediationRoleAssignments.properties.roleDefinitionId ==
    "[tenantResourceId(\u0027Microsoft.Authorization/roleDefinitions\u0027, parameters(\u0027roleDefinitionIds\u0027)[copyIndex()])]" and
  .outputs.loggingAssignments.value.activityLogExport.policyAssignmentId ==
    "[if(variables(\u0027activityLogRemediationDeployRequested\u0027), reference(\u0027activityLogExportRemediatingAssignment\u0027).outputs.policyAssignmentId.value, reference(\u0027activityLogExportAssignment\u0027).outputs.policyAssignmentId.value)]" and
  .outputs.loggingAssignments.value.activityLogExport.identityPrincipalId ==
    "[if(variables(\u0027activityLogRemediationDeployRequested\u0027), reference(\u0027activityLogExportRemediatingAssignment\u0027).outputs.identityPrincipalId.value, \u0027\u0027)]" and
  .outputs.loggingAssignments.value.activityLogExport.roleAssignmentIds ==
    "[if(variables(\u0027activityLogRemediationDeployRequested\u0027), reference(\u0027activityLogExportRemediatingAssignment\u0027).outputs.roleAssignmentIds.value, createArray())]" and
  .outputs.loggingAssignments.value.activityLogExport.remediationRoleAssignmentIds ==
    "[if(variables(\u0027activityLogRemediationDeployRequested\u0027), reference(\u0027activityLogExportRemediatingAssignment\u0027).outputs.roleAssignmentIds.value, createArray())]" and
  .outputs.loggingAssignments.value.activityLogExport.effect ==
    "[parameters(\u0027activityLogExportPolicyEffect\u0027)]" and
  .outputs.loggingAssignments.value.resourceDiagnostics.policyAssignmentId ==
    "[if(variables(\u0027resourceDiagnosticsRemediationDeployRequested\u0027), reference(\u0027resourceDiagnosticsRemediatingAssignment\u0027).outputs.policyAssignmentId.value, reference(\u0027resourceDiagnosticsAssignment\u0027).outputs.policyAssignmentId.value)]" and
  .outputs.loggingAssignments.value.resourceDiagnostics.identityPrincipalId ==
    "[if(variables(\u0027resourceDiagnosticsRemediationDeployRequested\u0027), reference(\u0027resourceDiagnosticsRemediatingAssignment\u0027).outputs.identityPrincipalId.value, \u0027\u0027)]" and
  .outputs.loggingAssignments.value.resourceDiagnostics.roleAssignmentIds ==
    "[if(variables(\u0027resourceDiagnosticsRemediationDeployRequested\u0027), reference(\u0027resourceDiagnosticsRemediatingAssignment\u0027).outputs.roleAssignmentIds.value, createArray())]" and
  .outputs.loggingAssignments.value.resourceDiagnostics.remediationRoleAssignmentIds ==
    "[if(variables(\u0027resourceDiagnosticsRemediationDeployRequested\u0027), reference(\u0027resourceDiagnosticsRemediatingAssignment\u0027).outputs.roleAssignmentIds.value, createArray())]" and
  .outputs.loggingAssignments.value.resourceDiagnostics.effect ==
    "[parameters(\u0027resourceDiagnosticsPolicyEffect\u0027)]" and
  .outputs.loggingAssignments.value.resourceDiagnostics.categoryGroup ==
    "[parameters(\u0027resourceDiagnosticsCategoryGroup\u0027)]" and
  .outputs.loggingAssignments.value.activityLogExport.workspaceDestinationRoleAssignmentIds ==
    "[if(variables(\u0027deployActivityLogRemediationRoleAssignments\u0027), reference(\u0027activityLogWorkspaceDestinationRbac\u0027).outputs.roleAssignmentIds.value, createArray())]" and
  .outputs.loggingAssignments.value.resourceDiagnostics.workspaceDestinationRoleAssignmentIds ==
    "[if(variables(\u0027deployResourceDiagnosticsRemediationRoleAssignments\u0027), reference(\u0027resourceDiagnosticsWorkspaceDestinationRbac\u0027).outputs.roleAssignmentIds.value, createArray())]"
' "${TEMP_DIR}/main.json" >/dev/null || {
  printf 'ERROR: Logging assignments do not match the required workspace wiring, identity/roles, effects, or demo-root inheritance.\n' >&2
  exit 1
}
jq -e '
  .parameters.activityLogExportPolicyEffect.value == "Disabled" and
  .parameters.activityLogExportLogsEnabled.value == "True" and
  .parameters.resourceDiagnosticsPolicyEffect.value == "AuditIfNotExists" and
  .parameters.resourceDiagnosticsCategoryGroup.value == "audit" and
  .parameters.deployLoggingRemediationRoleAssignments.value == false
' "${PROJECT_DIR}/parameters/demo.parameters.template.json" >/dev/null || {
  printf 'ERROR: Logging policy defaults in parameters/demo.parameters.template.json are not safe audit-first values.\n' >&2
  exit 1
}
printf '    Confirm mirrored logging compile-matrix coverage across enabled/disabled effects, workspace paths, and category-group modes...\n'
python3 - "${PROJECT_DIR}" "${TEMP_DIR}" <<'PYEOF'
import json
import pathlib
import re
import subprocess
import sys

project_dir = pathlib.Path(sys.argv[1])
temp_dir = pathlib.Path(sys.argv[2])
template_path = project_dir / "parameters/main.template.bicepparam"
template_text = template_path.read_text(encoding="utf-8")

valid_workspace = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-monitor/providers/Microsoft.OperationalInsights/workspaces/log-demo-central"
wrong_type_workspace = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-monitor/providers/Microsoft.Storage/storageAccounts/not-a-workspace"
malformed_workspace = "/subscriptions/not-a-guid/resourceGroups/rg-monitor/providers/Microsoft.OperationalInsights/workspaces/"
malformed_prefix_workspace = "junk/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-monitor/providers/Microsoft.OperationalInsights/workspaces/log-demo-central"
forbidden_segment_workspace = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/./providers/Microsoft.OperationalInsights/workspaces/.."
illegal_rg_name_workspace = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg#bad/providers/Microsoft.OperationalInsights/workspaces/log-demo-central"
illegal_workspace_name_workspace = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-monitor/providers/Microsoft.OperationalInsights/workspaces/-bad-"
unicode_rg_name_workspace = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-ßeta/providers/Microsoft.OperationalInsights/workspaces/log-demo-central"

cases = [
    {
        "name": "disabled-empty-default",
        "deployCentralLogAnalytics": "false",
        "existingLogAnalyticsWorkspaceResourceId": "",
        "activityLogExportPolicyEffect": "Disabled",
        "resourceDiagnosticsPolicyEffect": "Disabled",
        "resourceDiagnosticsCategoryGroup": "audit",
        "deployRoleAssignments": "false",
        "deployLoggingRemediationRoleAssignments": "false",
    },
    {
        "name": "activity-deploy-existing-valid",
        "deployCentralLogAnalytics": "false",
        "existingLogAnalyticsWorkspaceResourceId": valid_workspace,
        "activityLogExportPolicyEffect": "DeployIfNotExists",
        "resourceDiagnosticsPolicyEffect": "Disabled",
        "resourceDiagnosticsCategoryGroup": "audit",
        "deployRoleAssignments": "true",
        "deployLoggingRemediationRoleAssignments": "true",
    },
    {
        "name": "diagnostics-deploy-existing-alllogs",
        "deployCentralLogAnalytics": "false",
        "existingLogAnalyticsWorkspaceResourceId": valid_workspace,
        "activityLogExportPolicyEffect": "Disabled",
        "resourceDiagnosticsPolicyEffect": "DeployIfNotExists",
        "resourceDiagnosticsCategoryGroup": "allLogs",
        "deployRoleAssignments": "true",
        "deployLoggingRemediationRoleAssignments": "true",
    },
    {
        "name": "diagnostics-auditif-existing",
        "deployCentralLogAnalytics": "false",
        "existingLogAnalyticsWorkspaceResourceId": valid_workspace,
        "activityLogExportPolicyEffect": "Disabled",
        "resourceDiagnosticsPolicyEffect": "AuditIfNotExists",
        "resourceDiagnosticsCategoryGroup": "audit",
        "deployRoleAssignments": "true",
        "deployLoggingRemediationRoleAssignments": "true",
    },
    {
        "name": "new-workspace-both-deploy",
        "deployCentralLogAnalytics": "true",
        "existingLogAnalyticsWorkspaceResourceId": "",
        "activityLogExportPolicyEffect": "DeployIfNotExists",
        "resourceDiagnosticsPolicyEffect": "DeployIfNotExists",
        "resourceDiagnosticsCategoryGroup": "allLogs",
        "deployRoleAssignments": "true",
        "deployLoggingRemediationRoleAssignments": "true",
    },
    {
        "name": "enabled-empty-existing-id",
        "deployCentralLogAnalytics": "false",
        "existingLogAnalyticsWorkspaceResourceId": "",
        "activityLogExportPolicyEffect": "DeployIfNotExists",
        "resourceDiagnosticsPolicyEffect": "AuditIfNotExists",
        "resourceDiagnosticsCategoryGroup": "audit",
        "deployRoleAssignments": "true",
        "deployLoggingRemediationRoleAssignments": "true",
    },
    {
        "name": "enabled-malformed-existing-id",
        "deployCentralLogAnalytics": "false",
        "existingLogAnalyticsWorkspaceResourceId": malformed_workspace,
        "activityLogExportPolicyEffect": "DeployIfNotExists",
        "resourceDiagnosticsPolicyEffect": "DeployIfNotExists",
        "resourceDiagnosticsCategoryGroup": "audit",
        "deployRoleAssignments": "true",
        "deployLoggingRemediationRoleAssignments": "true",
    },
    {
        "name": "enabled-wrong-type-existing-id",
        "deployCentralLogAnalytics": "false",
        "existingLogAnalyticsWorkspaceResourceId": wrong_type_workspace,
        "activityLogExportPolicyEffect": "Disabled",
        "resourceDiagnosticsPolicyEffect": "AuditIfNotExists",
        "resourceDiagnosticsCategoryGroup": "allLogs",
        "deployRoleAssignments": "true",
        "deployLoggingRemediationRoleAssignments": "true",
    },
    {
        "name": "enabled-malformed-prefix-existing-id",
        "deployCentralLogAnalytics": "false",
        "existingLogAnalyticsWorkspaceResourceId": malformed_prefix_workspace,
        "activityLogExportPolicyEffect": "DeployIfNotExists",
        "resourceDiagnosticsPolicyEffect": "Disabled",
        "resourceDiagnosticsCategoryGroup": "audit",
        "deployRoleAssignments": "true",
        "deployLoggingRemediationRoleAssignments": "true",
    },
    {
        "name": "enabled-forbidden-segment-existing-id",
        "deployCentralLogAnalytics": "false",
        "existingLogAnalyticsWorkspaceResourceId": forbidden_segment_workspace,
        "activityLogExportPolicyEffect": "Disabled",
        "resourceDiagnosticsPolicyEffect": "AuditIfNotExists",
        "resourceDiagnosticsCategoryGroup": "allLogs",
        "deployRoleAssignments": "true",
        "deployLoggingRemediationRoleAssignments": "true",
    },
    {
        "name": "enabled-illegal-rg-name-existing-id",
        "deployCentralLogAnalytics": "false",
        "existingLogAnalyticsWorkspaceResourceId": illegal_rg_name_workspace,
        "activityLogExportPolicyEffect": "DeployIfNotExists",
        "resourceDiagnosticsPolicyEffect": "Disabled",
        "resourceDiagnosticsCategoryGroup": "audit",
        "deployRoleAssignments": "true",
        "deployLoggingRemediationRoleAssignments": "true",
    },
    {
        "name": "enabled-illegal-workspace-name-existing-id",
        "deployCentralLogAnalytics": "false",
        "existingLogAnalyticsWorkspaceResourceId": illegal_workspace_name_workspace,
        "activityLogExportPolicyEffect": "Disabled",
        "resourceDiagnosticsPolicyEffect": "AuditIfNotExists",
        "resourceDiagnosticsCategoryGroup": "allLogs",
        "deployRoleAssignments": "true",
        "deployLoggingRemediationRoleAssignments": "true",
    },
    {
        "name": "enabled-unicode-rg-name-existing-id",
        "deployCentralLogAnalytics": "false",
        "existingLogAnalyticsWorkspaceResourceId": unicode_rg_name_workspace,
        "activityLogExportPolicyEffect": "Disabled",
        "resourceDiagnosticsPolicyEffect": "AuditIfNotExists",
        "resourceDiagnosticsCategoryGroup": "audit",
        "deployRoleAssignments": "true",
        "deployLoggingRemediationRoleAssignments": "true",
    },
]

def replace_param(text: str, name: str, value_literal: str) -> str:
    pattern = rf"(?m)^param {re.escape(name)} = .*$"
    return re.sub(pattern, f"param {name} = {value_literal}", text)

def is_resource_group_name(value: str) -> bool:
    if value != value.strip() or len(value) < 1 or len(value) > 90 or value.endswith('.'):
        return False
    return all(ch.isalpha() or ch.isdecimal() or ch in "_.-()" for ch in value)

def is_workspace_name(value: str) -> bool:
    if value != value.strip() or len(value) < 4 or len(value) > 63:
        return False
    if value.startswith("-") or value.endswith("-"):
        return False
    return all(ch.isalnum() or ch == '-' for ch in value)

def is_workspace_resource_id(value: str) -> bool:
    if value != value.strip() or not value.startswith('/') or value.endswith('/'):
        return False
    parts = value.split('/')
    if len(parts) != 9 or parts[0] != '':
        return False
    if any(part == '' or part != part.strip() for part in parts[1:]):
        return False
    if parts[1].lower() != "subscriptions" or not re.fullmatch(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", parts[2]):
        return False
    if parts[3].lower() != "resourcegroups" or not is_resource_group_name(parts[4]):
        return False
    if parts[5].lower() != "providers" or parts[6].lower() != "microsoft.operationalinsights" or parts[7].lower() != "workspaces":
        return False
    return is_workspace_name(parts[8])

covered_workspace_modes = set()
covered_category_modes = set()
covered_effect_states = set()

for case in cases:
    case_text = template_text.replace("using '../main.bicep'", "using '../../main.bicep'")
    for key, value in case.items():
        if key == "name":
            continue
        literal = f"'{value}'" if key in {
            "existingLogAnalyticsWorkspaceResourceId",
            "activityLogExportPolicyEffect",
            "resourceDiagnosticsPolicyEffect",
            "resourceDiagnosticsCategoryGroup",
        } else value
        case_text = replace_param(case_text, key, literal)
    case_path = temp_dir / f"logging-{case['name']}.bicepparam"
    case_path.write_text(case_text, encoding="utf-8")
    out_path = temp_dir / f"logging-{case['name']}.json"
    subprocess.run(
        ["az", "bicep", "build-params", "--file", str(case_path), "--outfile", str(out_path)],
        check=True,
        capture_output=True,
        text=True,
    )
    compiled = json.loads(out_path.read_text(encoding="utf-8"))
    for key, value in case.items():
        if key == "name":
            continue
        compiled_value = compiled["parameters"][key]["value"]
        expected_value = value
        if key in {"deployCentralLogAnalytics", "deployRoleAssignments", "deployLoggingRemediationRoleAssignments"}:
            expected_value = (value == "true")
        if compiled_value != expected_value:
            raise SystemExit(f"ERROR: Logging matrix case {case['name']} did not compile expected parameter value for {key}.")
    existing_id = case["existingLogAnalyticsWorkspaceResourceId"]
    if case["deployCentralLogAnalytics"] == "false" and existing_id != "":
        is_valid = is_workspace_resource_id(existing_id)
        expected_valid = existing_id in {valid_workspace, unicode_rg_name_workspace}
        if is_valid != expected_valid:
            raise SystemExit(f"ERROR: Logging matrix offline workspace-ID rejection mismatch for {case['name']}.")
    if case["deployCentralLogAnalytics"] == "true":
        covered_workspace_modes.add("new")
    elif existing_id == "":
        covered_workspace_modes.add("empty")
    elif existing_id == valid_workspace:
        covered_workspace_modes.add("existing-valid")
    elif existing_id == malformed_workspace:
        covered_workspace_modes.add("existing-malformed")
    elif existing_id == wrong_type_workspace:
        covered_workspace_modes.add("existing-wrong-type")
    elif existing_id == malformed_prefix_workspace:
        covered_workspace_modes.add("existing-malformed-prefix")
    elif existing_id == forbidden_segment_workspace:
        covered_workspace_modes.add("existing-forbidden-segment")
    elif existing_id == illegal_rg_name_workspace:
        covered_workspace_modes.add("existing-illegal-rg-name")
    elif existing_id == illegal_workspace_name_workspace:
        covered_workspace_modes.add("existing-illegal-workspace-name")
    elif existing_id == unicode_rg_name_workspace:
        covered_workspace_modes.add("existing-unicode-rg-name")
    covered_category_modes.add(case["resourceDiagnosticsCategoryGroup"])
    covered_effect_states.add((case["activityLogExportPolicyEffect"], case["resourceDiagnosticsPolicyEffect"]))

required_workspace_modes = {
    "new",
    "empty",
    "existing-valid",
    "existing-malformed",
    "existing-wrong-type",
    "existing-malformed-prefix",
    "existing-forbidden-segment",
    "existing-illegal-rg-name",
    "existing-illegal-workspace-name",
    "existing-unicode-rg-name",
}
if covered_workspace_modes != required_workspace_modes:
    raise SystemExit(f"ERROR: Logging matrix coverage mismatch for workspace-path modes: {covered_workspace_modes}")
if covered_category_modes != {"audit", "allLogs"}:
    raise SystemExit(f"ERROR: Logging matrix must cover both diagnostics category-group modes: {covered_category_modes}")
if ("Disabled", "Disabled") not in covered_effect_states or ("DeployIfNotExists", "DeployIfNotExists") not in covered_effect_states:
    raise SystemExit("ERROR: Logging matrix must include both disabled and enabled remediation effect combinations.")
PYEOF
printf '27/28 Confirm storage, Key Vault, and customer-managed key controls are verified and audit-first...\n'
jq -e '
  .parameters.dataProtectionPolicyEffect.defaultValue == "Audit" and
  .parameters.dataProtectionPolicyEffect.allowedValues == ["Audit", "Deny", "Disabled"] and
  .parameters.storageMinimumTlsVersion.defaultValue == "TLS1_2" and
  .parameters.storageMinimumTlsVersion.allowedValues == ["TLS1_0", "TLS1_1", "TLS1_2"] and
  .parameters.approvedCustomerManagedKeyVaultUris.defaultValue == [] and
  .parameters.approvedCustomerManagedKeyNames.defaultValue == [] and
  .variables.dataProtectionAuditOnlyEffect == "[if(equals(parameters(\u0027dataProtectionPolicyEffect\u0027), \u0027Disabled\u0027), \u0027Disabled\u0027, \u0027Audit\u0027)]" and
  .variables.dataProtectionAuditIfNotExistsEffect == "[if(equals(parameters(\u0027dataProtectionPolicyEffect\u0027), \u0027Disabled\u0027), \u0027Disabled\u0027, \u0027AuditIfNotExists\u0027)]" and
  .variables.dataProtectionPurgeProtectionEffect == "[if(equals(parameters(\u0027dataProtectionPolicyEffect\u0027), \u0027Deny\u0027), \u0027Deny\u0027, \u0027Audit\u0027)]" and
  .resources as $resources |
  ($resources | map(select(.name == "data-protection-initiative")) | first) as $initiative |
  ($resources | map(select(.name == "assign-data-protection")) | first) as $assignment |
  ($initiative.scope == "[format(\u0027Microsoft.Management/managementGroups/{0}\u0027, variables(\u0027demoRootManagementGroupId\u0027))]") and
  ($assignment.scope == "[format(\u0027Microsoft.Management/managementGroups/{0}\u0027, variables(\u0027landingZonesManagementGroupId\u0027))]") and
  ($initiative.properties.parameters.policyDefinitionReferences.value | map(.policyDefinitionReferenceId) | sort) == [
    "key-vault-deletion-protection",
    "key-vault-diagnostics-readiness",
    "key-vault-network-access",
    "key-vault-rbac-authorization",
    "key-vault-soft-delete",
    "storage-approved-customer-managed-key",
    "storage-customer-managed-key",
    "storage-minimum-tls",
    "storage-network-access",
    "storage-public-blob-access",
    "storage-secure-transfer",
    "storage-shared-key-access"
  ] and
  ($assignment.properties.parameters.parameters.value.effect.value == "[parameters(\u0027dataProtectionPolicyEffect\u0027)]") and
  ($assignment.properties.parameters.parameters.value.auditOnlyEffect.value == "[variables(\u0027dataProtectionAuditOnlyEffect\u0027)]") and
  ($assignment.properties.parameters.parameters.value.purgeProtectionEffect.value == "[variables(\u0027dataProtectionPurgeProtectionEffect\u0027)]") and
  ($assignment.properties.parameters.parameters.value.auditIfNotExistsEffect.value == "[variables(\u0027dataProtectionAuditIfNotExistsEffect\u0027)]") and
  ($assignment.properties.parameters.parameters.value.minimumTlsVersion.value == "[parameters(\u0027storageMinimumTlsVersion\u0027)]") and
  ($assignment.properties.parameters.parameters.value.approvedKeyVaultUris.value == "[parameters(\u0027approvedCustomerManagedKeyVaultUris\u0027)]") and
  ($assignment.properties.parameters.parameters.value.approvedKeyNames.value == "[parameters(\u0027approvedCustomerManagedKeyNames\u0027)]") and
  ($assignment.properties.parameters.nonComplianceMessages.value | length) == 12 and
  ($assignment.properties.parameters.nonComplianceMessages.value | map(.policyDefinitionReferenceId) | sort) ==
    ($initiative.properties.parameters.policyDefinitionReferences.value | map(.policyDefinitionReferenceId) | sort) and
  ($assignment.properties.parameters.nonComplianceMessages.value | all(.message | length > 0))
' "${TEMP_DIR}/main.json" >/dev/null || {
  printf 'ERROR: The data-protection initiative or assignment is missing an audit-first default, a control reference, or a non-compliance message.\n' >&2
  exit 1
}

# Every built-in referenced by the initiative must be one of the GUIDs recorded
# in the verified control catalog, so a control can never be wired to an
# unverified or invented definition ID.
data_protection_builtin_ids="$(jq -r '
  .resources[]
  | select(.name == "data-protection-initiative")
  | .properties.parameters.policyDefinitionReferences.value[]
  | .policyDefinitionId
  | select(startswith("[tenantResourceId(\u0027Microsoft.Authorization/policyDefinitions\u0027, "))
  | capture("(?<guid>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})").guid
' "${TEMP_DIR}/main.json" | sort -u)"
[[ "$(printf '%s\n' "${data_protection_builtin_ids}" | wc -l | tr -d ' ')" -eq 11 ]] || {
  printf 'ERROR: Expected 11 distinct verified built-in definitions in the data-protection initiative.\n' >&2
  exit 1
}
while IFS= read -r builtin_id; do
  jq -e --arg id "${builtin_id}" '
    [.controls[] | select(.mechanism.builtIn == true and .mechanism.definitionId == $id)] | length > 0
  ' "${PROJECT_DIR}/policy/control-catalog.json" >/dev/null || {
    printf 'ERROR: Data-protection built-in %s is not a verified control-catalog definition ID.\n' "${builtin_id}" >&2
    exit 1
  }
done <<< "${data_protection_builtin_ids}"

# Every built-in member must be pinned to the exact major version verified in
# the control catalog, and the in-repository custom member must stay unpinned
# because definitionVersion applies only to built-in definitions.
data_protection_reference_pins="$(jq -r '
  .resources[]
  | select(.name == "data-protection-initiative")
  | .properties.parameters.policyDefinitionReferences.value[]
  | [
      .policyDefinitionReferenceId,
      (.policyDefinitionId | capture("(?<guid>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})").guid? // "custom"),
      (.definitionVersion // "")
    ]
  | @tsv
' "${TEMP_DIR}/main.json")"
while IFS="$(printf '\t')" read -r reference_id builtin_id pinned_version; do
  if [[ "${builtin_id}" == 'custom' ]]; then
    [[ -z "${pinned_version}" ]] || {
      printf 'ERROR: Custom data-protection reference %s must not declare definitionVersion.\n' "${reference_id}" >&2
      exit 1
    }
    continue
  fi
  expected_major="$(jq -r --arg id "${builtin_id}" '
    [.controls[] | select(.mechanism.builtIn == true and .mechanism.definitionId == $id) | .mechanism.majorVersion] | first // ""
  ' "${PROJECT_DIR}/policy/control-catalog.json")"
  [[ -n "${expected_major}" ]] || {
    printf 'ERROR: Data-protection built-in %s has no verified majorVersion in the control catalog.\n' "${builtin_id}" >&2
    exit 1
  }
  [[ "${pinned_version}" == "${expected_major}.*.*" ]] || {
    printf 'ERROR: Data-protection reference %s must pin definitionVersion %s.*.* but pins "%s".\n' \
      "${reference_id}" "${expected_major}" "${pinned_version}" >&2
    exit 1
  }
done <<< "${data_protection_reference_pins}"

# The exact expected pin per reference is spelled out so an unpinned, removed,
# or silently re-pointed built-in fails even if the catalog changes too.
jq -e '
  (.resources[] | select(.name == "data-protection-initiative")
    | .properties.parameters.policyDefinitionReferences.value
    | map({ (.policyDefinitionReferenceId): (.definitionVersion // null) })
    | add) == {
    "storage-secure-transfer": "2.*.*",
    "storage-minimum-tls": "1.*.*",
    "storage-public-blob-access": "3.*.*",
    "storage-network-access": "1.*.*",
    "storage-shared-key-access": "2.*.*",
    "key-vault-soft-delete": "3.*.*",
    "key-vault-deletion-protection": "2.*.*",
    "key-vault-rbac-authorization": "1.*.*",
    "key-vault-network-access": "3.*.*",
    "key-vault-diagnostics-readiness": "5.*.*",
    "storage-customer-managed-key": "1.*.*",
    "storage-approved-customer-managed-key": null
  }
' "${TEMP_DIR}/main.json" >/dev/null || {
  printf 'ERROR: Data-protection references must pin the exact verified built-in majors and leave the custom member unpinned.\n' >&2
  exit 1
}

# Purge protection is only ever audited or denied, never turned off, and the
# audit-only and readiness controls can never be escalated to Deny.
jq -e '
  (.resources | map(select(.name == "data-protection-initiative")) | first) as $initiative |
  $initiative.properties.parameters.initiativeParameters.value as $initiativeParameters |
  $initiativeParameters.effect.allowedValues == ["Audit", "Deny", "Disabled"] and
  $initiativeParameters.effect.defaultValue == "Audit" and
  $initiativeParameters.auditOnlyEffect.allowedValues == ["Audit", "Disabled"] and
  $initiativeParameters.auditIfNotExistsEffect.allowedValues == ["AuditIfNotExists", "Disabled"] and
  $initiativeParameters.purgeProtectionEffect.allowedValues == ["Audit", "Deny"] and
  $initiativeParameters.purgeProtectionEffect.defaultValue == "Audit" and
  ($initiative.properties.parameters.policyDefinitionReferences.value
    | map(select(.policyDefinitionReferenceId == "key-vault-deletion-protection"))
    | first
    | .parameters.effect.value) == "[[parameters(\u0027purgeProtectionEffect\u0027)]" and
  ($initiative.properties.parameters.policyDefinitionReferences.value
    | map(select(.policyDefinitionReferenceId == "storage-customer-managed-key"))
    | first
    | .parameters.effect.value) == "[[parameters(\u0027auditOnlyEffect\u0027)]"
' "${TEMP_DIR}/main.json" >/dev/null || {
  printf 'ERROR: Data-protection effects must stay audit-first, must never disable Key Vault purge protection, and must bind the operative built-in parameter names.\n' >&2
  exit 1
}

# The in-repository customer-managed key control must stay parameterized and
# must report nothing until the customer supplies an approved key inventory.
jq -e '
  (.resources[] | select(.name | startswith("[format(\u0027policy-library-"))) as $library |
  ($library.properties.template.resources
    | map(select(.properties.displayName == "Demo - audit storage customer-managed keys against approved Key Vaults and keys"))
    | first) as $cmk |
  $cmk.properties.parameters.approvedKeyVaultUris.defaultValue == [] and
  $cmk.properties.parameters.approvedKeyNames.defaultValue == [] and
  $cmk.properties.parameters.effect.defaultValue == "Audit" and
  ($cmk.properties.policyRule.if | tostring | contains("length(parameters(\u0027approvedKeyVaultUris\u0027))")) and
  ($cmk.properties.policyRule.if | tostring | contains("length(parameters(\u0027approvedKeyNames\u0027))")) and
  ($cmk.properties.policyRule.if | tostring | contains("encryption.keyvaultproperties.keyvaulturi")) and
  ($cmk.properties.policyRule.if | tostring | contains("encryption.keyvaultproperties.keyname"))
' "${TEMP_DIR}/main.json" >/dev/null || {
  printf 'ERROR: The storage customer-managed key audit must be parameterized and silent until approved inputs are supplied.\n' >&2
  exit 1
}

# Restricting public access must never be implemented by deploying a Key Vault,
# a key, a private endpoint, or a private DNS zone in this template, and the
# data-protection controls must never request a managed identity (which would
# imply remediation rights or paid/data-plane changes).
prohibited_data_protection_types="$(jq -r '
  [.. | objects
    | select((.type? | type) == "string")
    | select(.apiVersion?)
    | select(.type | test("^Microsoft\\.(KeyVault/vaults(/keys|/secrets)?|Network/(privateEndpoints|privateDnsZones))$"; "i"))
    | .type
  ] | unique | .[]
' "${TEMP_DIR}/main.json")"
[[ -z "${prohibited_data_protection_types}" ]] || {
  printf 'ERROR: The data-protection controls must not declare a Key Vault, key, secret, private endpoint, or private DNS zone.\n' >&2
  exit 1
}
jq -e '
  .resources as $resources |
  [$resources[] | select(.name == "data-protection-initiative" or .name == "assign-data-protection")] as $deployments |
  ($deployments | length) == 2 and
  ($deployments | all(has("identity") | not)) and
  ([$deployments[] | .properties.template.resources[]] | length) == 2 and
  ([$deployments[] | .properties.template.resources[] | .type] | sort) == [
    "Microsoft.Authorization/policyAssignments",
    "Microsoft.Authorization/policySetDefinitions"
  ] and
  ([$deployments[] | .properties.template.resources[]] | all((has("identity") | not) and (has("location") | not))) and
  ([$deployments[] | .properties.template.resources[]]
    | all(.type | test("^Microsoft\\.(ManagedIdentity|KeyVault|Storage|Network|OperationalInsights)/"; "i") | not))
' "${TEMP_DIR}/main.json" >/dev/null || {
  printf 'ERROR: The data-protection initiative and assignment must declare only policy resources with no system-assigned or user-assigned identity.\n' >&2
  exit 1
}
jq -e '
  .parameters.dataProtectionPolicyEffect.value == "Audit" and
  .parameters.storageMinimumTlsVersion.value == "TLS1_2" and
  .parameters.approvedCustomerManagedKeyVaultUris.value == [] and
  .parameters.approvedCustomerManagedKeyNames.value == []
' "${PROJECT_DIR}/parameters/demo.parameters.template.json" >/dev/null || {
  printf 'ERROR: The JSON parameter template must keep audit-first data-protection defaults with no approved key inputs.\n' >&2
  exit 1
}
jq -e '.parameters.dataProtectionPolicyEffect.value == "Audit"' "${TEMP_DIR}/main.parameters.json" >/dev/null

printf '28/28 Confirm the privileged access review is read-only, criteria-driven, and offline-testable...\n'
access_review_script="${PROJECT_DIR}/scripts/review-privileged-access.sh"
access_review_ps_script="${PROJECT_DIR}/scripts/review-privileged-access.ps1"
access_review_criteria="${PROJECT_DIR}/policy/access-review-criteria.json"
access_review_assignments="${PROJECT_DIR}/tests/fixtures/privileged-access-assignments.json"
access_review_expected="${PROJECT_DIR}/tests/fixtures/privileged-access-expected-report.json"
access_review_observations="${PROJECT_DIR}/tests/fixtures/privileged-access-observations.json"
access_review_observations_expected="${PROJECT_DIR}/tests/fixtures/privileged-access-expected-observations-report.json"
access_review_tenant='44444444-4444-4444-8444-444444444444'
access_review_subscription='22222222-2222-4222-8222-222222222222'
access_review_second_subscription='66666666-6666-4666-8666-666666666666'
for access_review_file in "${access_review_script}" "${access_review_ps_script}" "${access_review_criteria}" \
  "${access_review_assignments}" "${access_review_expected}" "${access_review_observations}" \
  "${access_review_observations_expected}"; do
  [[ -f "${access_review_file}" ]] || {
    printf 'ERROR: Missing privileged access review artifact: %s\n' "${access_review_file}" >&2
    exit 1
  }
done
if rg -n 'az (role assignment (create|delete|update)|ad (app|sp|group) (create|delete|update)|deployment|rest --method)' \
  "${access_review_script}" "${access_review_ps_script}"; then
  printf 'ERROR: The privileged access review scripts must stay read-only.\n' >&2
  exit 1
fi
access_review_out="${TEMP_DIR}/access-review"
"${access_review_script}" \
  --tenant-id "${access_review_tenant}" \
  --subscription-id "${access_review_subscription}" \
  --management-group demo-root \
  --assignments-file "${access_review_assignments}" \
  --output-dir "${access_review_out}" >/dev/null
access_review_report="$(ls "${access_review_out}"/privileged-access-review-*.json)"
[[ -f "${access_review_report}" ]] || {
  printf 'ERROR: The privileged access review produced no JSON report.\n' >&2
  exit 1
}
[[ -f "${access_review_report%.json}.md" ]] || {
  printf 'ERROR: The privileged access review produced no Markdown report.\n' >&2
  exit 1
}
jq -S 'del(.generatedOn)' "${access_review_report}" > "${TEMP_DIR}/access-review-actual.json"
jq -S '.' "${access_review_expected}" > "${TEMP_DIR}/access-review-expected.json"
diff -u "${TEMP_DIR}/access-review-expected.json" "${TEMP_DIR}/access-review-actual.json" || {
  printf 'ERROR: The privileged access review classification changed unexpectedly.\n' >&2
  exit 1
}
jq -e '
  (.generatedOn | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
  and .mode == "offline-file"
  and (.findings | length) > 0
  and all(.findings[]; .reviewAction == "manual-review-required")
  and ([.findings[] | select(.principalType == "ServicePrincipal" and .roleDefinitionName == "Owner")]
    | all(.severity == "high" and (.reasons | index("direct-non-human-principal-assignment") != null)))
  and (.. | strings | test("password|secret|clientSecret"; "i") | not)
' "${access_review_report}" >/dev/null || {
  printf 'ERROR: The privileged access review report shape or safety expectations are invalid.\n' >&2
  exit 1
}
# The generated reports contain directory identifiers and must never be tracked.
git -C "${PROJECT_DIR}" check-ignore -q "${PROJECT_DIR}/.access-reviews/privileged-access-review-example.json" || {
  printf 'ERROR: Locally generated access-review reports must be ignored by source control.\n' >&2
  exit 1
}

# Every direct service-principal or managed-identity grant must appear in the
# inventory, including narrow, lower-privilege ones that are only ranked low.
jq -e '
  ([.findings[] | select(.principalType == "ServicePrincipal" or .principalType == "MSI")] | length)
    == .summary.nonHumanAssignmentCount
  and (
    [.findings[]
      | select(.principalId == "88888888-8888-4888-8888-888888888888"
        and .roleDefinitionName == "Storage Blob Data Reader")]
    | length == 1
      and (.[0].severity == "low")
      and (.[0].scopeType == "resource")
      and ((.[0].reasons | index("direct-non-human-principal-assignment")) != null)
  )
' "${access_review_report}" >/dev/null || {
  printf 'ERROR: Direct service-principal and managed-identity grants must always be surfaced.\n' >&2
  exit 1
}

# Subscription queries use --include-inherited, so the same management-group
# assignment is observed repeatedly; it must collapse to one finding while the
# observing subscriptions stay attributed.
access_review_observations_out="${TEMP_DIR}/access-review-observations"
"${access_review_script}" \
  --tenant-id "${access_review_tenant}" \
  --subscription-id "${access_review_subscription}" \
  --subscription-id "${access_review_second_subscription}" \
  --management-group demo-root \
  --assignments-file "${access_review_observations}" \
  --output-dir "${access_review_observations_out}" >/dev/null
access_review_observations_report="$(ls "${access_review_observations_out}"/privileged-access-review-*.json)"
jq -S 'del(.generatedOn)' "${access_review_observations_report}" \
  > "${TEMP_DIR}/access-review-observations-actual.json"
jq -S '.' "${access_review_observations_expected}" \
  > "${TEMP_DIR}/access-review-observations-expected.json"
diff -u "${TEMP_DIR}/access-review-observations-expected.json" \
  "${TEMP_DIR}/access-review-observations-actual.json" || {
  printf 'ERROR: The deduplicated inheritance classification changed unexpectedly.\n' >&2
  exit 1
}
jq -e --arg first "${access_review_subscription}" --arg second "${access_review_second_subscription}" '
  .summary.assignmentsCollected == 10
  and .summary.assignmentsEvaluated == 5
  and .summary.duplicateObservationsCollapsed == 5
  and ([.findings[] | select(.scopeType == "managementGroup")] | length) == 2
  and all(.findings[] | select(.scopeType == "managementGroup");
    .observedInSubscriptions == [$first, $second])
  and (
    [.findings[] | select(.principalId == "77777777-7777-4777-8777-777777777777")]
    | length == 1 and (.[0].observedInSubscriptions == [$first, $second])
  )
  and ((.summary.subscriptionOwnerCounts | map(.subscriptionId)) == [$first, $second])
  and (.summary.subscriptionOwnerCounts[0]
    | .ownerPrincipalCount == 3 and .directOwnerPrincipalCount == 1
      and .inheritedOwnerPrincipalCount == 2)
  and (.summary.subscriptionOwnerCounts[1]
    | .ownerPrincipalCount == 2 and .directOwnerPrincipalCount == 0
      and .inheritedOwnerPrincipalCount == 2)
' "${access_review_observations_report}" >/dev/null || {
  printf 'ERROR: Inherited assignments were not deduplicated and attributed to the requested subscriptions.\n' >&2
  exit 1
}
# An Owner scoped to a resource group does not confer Owner over the
# subscription, so it stays a finding but never inflates the Owner totals.
jq -e --arg first "${access_review_subscription}" '
  ([.findings[]
    | select(.roleDefinitionName == "Owner" and .scopeType == "resourceGroup")] as $childOwners
  | ($childOwners | length) == 1
    and ($childOwners[0].observedInSubscriptions == [$first])
    and (
      # The child-scoped Owner principal is observed in the subscription, yet
      # the Owner total stays at the three subscription-wide Owner principals.
      [.findings[]
        | select(.roleDefinitionName == "Owner"
          and ((.observedInSubscriptions | index($first)) != null))
        | .principalId]
      | unique | length == 4))
  and all(.summary.subscriptionOwnerCounts[];
    .ownerPrincipalCount == (.directOwnerPrincipalCount + .inheritedOwnerPrincipalCount))
' "${access_review_observations_report}" >/dev/null || {
  printf 'ERROR: A child-scoped Owner grant must remain a finding without counting as a subscription Owner.\n' >&2
  exit 1
}

access_review_strict_criteria="${TEMP_DIR}/access-review-strict-criteria.json"
jq '.maxOwnersPerSubscription = 1' "${access_review_criteria}" > "${access_review_strict_criteria}"
access_review_strict_out="${TEMP_DIR}/access-review-strict"
"${access_review_script}" \
  --tenant-id "${access_review_tenant}" \
  --subscription-id "${access_review_subscription}" \
  --criteria-file "${access_review_strict_criteria}" \
  --assignments-file "${access_review_assignments}" \
  --output-dir "${access_review_strict_out}" >/dev/null
jq -e --arg subscription "${access_review_subscription}" '
  .summary.subscriptionsExceedingOwnerThreshold == [$subscription]
  and (.summary.subscriptionOwnerCounts[0] | .ownerPrincipalCount == 2 and .exceedsThreshold)
  and .criteria.maxOwnersPerSubscription == 1
' "$(ls "${access_review_strict_out}"/privileged-access-review-*.json)" >/dev/null || {
  printf 'ERROR: The configurable Owner-count threshold was not honoured.\n' >&2
  exit 1
}

expect_access_review_failure() {
  local description="$1"
  shift
  local output
  if output="$("${access_review_script}" "$@" 2>&1)"; then
    printf 'ERROR: The privileged access review accepted %s.\n' "${description}" >&2
    exit 1
  fi
  printf '%s' "${output}" | grep -q 'ERROR:' || {
    printf 'ERROR: The privileged access review rejected %s without an explicit error.\n' "${description}" >&2
    exit 1
  }
}

access_review_negative_out="${TEMP_DIR}/access-review-negative"
expect_access_review_failure 'a missing tenant context' \
  --subscription-id "${access_review_subscription}" \
  --assignments-file "${access_review_assignments}" \
  --output-dir "${access_review_negative_out}"
expect_access_review_failure 'a missing subscription context' \
  --tenant-id "${access_review_tenant}" \
  --assignments-file "${access_review_assignments}" \
  --output-dir "${access_review_negative_out}"
expect_access_review_failure 'a non-canonical subscription GUID' \
  --tenant-id "${access_review_tenant}" \
  --subscription-id 'not-a-guid' \
  --assignments-file "${access_review_assignments}" \
  --output-dir "${access_review_negative_out}"
expect_access_review_failure 'a duplicate subscription' \
  --tenant-id "${access_review_tenant}" \
  --subscription-id "${access_review_subscription}" \
  --subscription-id "${access_review_subscription}" \
  --assignments-file "${access_review_assignments}" \
  --output-dir "${access_review_negative_out}"
access_review_bad_assignments="${TEMP_DIR}/access-review-bad-assignments.json"
jq '.[0] |= del(.principalType)' "${access_review_assignments}" > "${access_review_bad_assignments}"
expect_access_review_failure 'an assignment without a principal type' \
  --tenant-id "${access_review_tenant}" \
  --subscription-id "${access_review_subscription}" \
  --assignments-file "${access_review_bad_assignments}" \
  --output-dir "${access_review_negative_out}"
access_review_bad_observations="${TEMP_DIR}/access-review-bad-observations.json"
jq '.observations[0].source.kind = "resourceGroup"' "${access_review_observations}" \
  > "${access_review_bad_observations}"
expect_access_review_failure 'an observation with an unsupported source kind' \
  --tenant-id "${access_review_tenant}" \
  --subscription-id "${access_review_subscription}" \
  --assignments-file "${access_review_bad_observations}" \
  --output-dir "${access_review_negative_out}"
access_review_bad_criteria="${TEMP_DIR}/access-review-bad-criteria.json"
jq '.highPrivilegeRoleNames = []' "${access_review_criteria}" > "${access_review_bad_criteria}"
expect_access_review_failure 'an empty high-privilege role list' \
  --tenant-id "${access_review_tenant}" \
  --subscription-id "${access_review_subscription}" \
  --criteria-file "${access_review_bad_criteria}" \
  --assignments-file "${access_review_assignments}" \
  --output-dir "${access_review_negative_out}"

access_review_mock_bin="${TEMP_DIR}/access-review-mockbin"
mkdir -p "${access_review_mock_bin}"
cat > "${access_review_mock_bin}/az" <<'MOCKACCESSREVIEWAZ'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${ACCESS_REVIEW_AZ_CALL_LOG}"
if [[ "$1" == 'account' && "$2" == 'show' ]]; then
  printf '%s\n' "${MOCK_SIGNED_IN_TENANT}"
  exit 0
fi
if [[ "$1" == 'role' && "$2" == 'assignment' && "$3" == 'list' ]]; then
  cat "${MOCK_ASSIGNMENTS_FILE}"
  exit 0
fi
exit 1
MOCKACCESSREVIEWAZ
chmod +x "${access_review_mock_bin}/az"
access_review_az_log="${TEMP_DIR}/access-review-az-calls.log"
: > "${access_review_az_log}"
access_review_live_out="${TEMP_DIR}/access-review-live"
if ! PATH="${access_review_mock_bin}:${PATH}" \
  ACCESS_REVIEW_AZ_CALL_LOG="${access_review_az_log}" \
  MOCK_SIGNED_IN_TENANT="${access_review_tenant}" \
  MOCK_ASSIGNMENTS_FILE="${access_review_assignments}" \
  "${access_review_script}" \
    --tenant-id "${access_review_tenant}" \
    --subscription-id "${access_review_subscription}" \
    --output-dir "${access_review_live_out}" >/dev/null; then
  printf 'ERROR: The privileged access review failed against a read-only Azure CLI mock.\n' >&2
  exit 1
fi
jq -e '.mode == "live-read-only" and .summary.assignmentsEvaluated == 8' \
  "$(ls "${access_review_live_out}"/privileged-access-review-*.json)" >/dev/null || {
  printf 'ERROR: The live read-only mode did not evaluate the collected assignments.\n' >&2
  exit 1
}
[[ ! -e "${access_review_live_out}/.collected-assignments.json" ]] || {
  printf 'ERROR: The privileged access review must not leave collected assignments behind.\n' >&2
  exit 1
}
if ! grep -q '^account show --query tenantId --output tsv$' "${access_review_az_log}"; then
  printf 'ERROR: The privileged access review must verify the signed-in tenant before reading assignments.\n' >&2
  exit 1
fi
access_review_unexpected_calls="$(grep -Ev '^(account show|role assignment list) ' "${access_review_az_log}" || true)"
if [[ -n "${access_review_unexpected_calls//[[:space:]]/}" ]]; then
  printf 'ERROR: The privileged access review invoked an Azure CLI command that is not read-only.\n' >&2
  printf '%s\n' "${access_review_unexpected_calls}" >&2
  exit 1
fi
: > "${access_review_az_log}"
if PATH="${access_review_mock_bin}:${PATH}" \
  ACCESS_REVIEW_AZ_CALL_LOG="${access_review_az_log}" \
  MOCK_SIGNED_IN_TENANT='55555555-5555-4555-8555-555555555555' \
  MOCK_ASSIGNMENTS_FILE="${access_review_assignments}" \
  "${access_review_script}" \
    --tenant-id "${access_review_tenant}" \
    --subscription-id "${access_review_subscription}" \
    --output-dir "${TEMP_DIR}/access-review-wrong-tenant" >/dev/null 2>&1; then
  printf 'ERROR: The privileged access review accepted a signed-in tenant that does not match --tenant-id.\n' >&2
  exit 1
fi
if grep -q 'role assignment list' "${access_review_az_log}"; then
  printf 'ERROR: The privileged access review read assignments from a mismatched tenant.\n' >&2
  exit 1
fi

if command -v pwsh >/dev/null 2>&1; then
  printf '    Confirm the PowerShell review produces an identical report...\n'
  access_review_ps_out="${TEMP_DIR}/access-review-pwsh"
  pwsh -NoLogo -NoProfile -File "${access_review_ps_script}" \
    -TenantId "${access_review_tenant}" \
    -SubscriptionId "${access_review_subscription}" \
    -ManagementGroupId demo-root \
    -AssignmentsFile "${access_review_assignments}" \
    -OutputDirectory "${access_review_ps_out}" >/dev/null
  jq -S 'del(.generatedOn)' "$(ls "${access_review_ps_out}"/privileged-access-review-*.json)" \
    > "${TEMP_DIR}/access-review-pwsh-actual.json"
  diff -u "${TEMP_DIR}/access-review-expected.json" "${TEMP_DIR}/access-review-pwsh-actual.json" || {
    printf 'ERROR: The PowerShell privileged access review report differs from the Bash report.\n' >&2
    exit 1
  }
  access_review_ps_observations_out="${TEMP_DIR}/access-review-pwsh-observations"
  pwsh -NoLogo -NoProfile -File "${access_review_ps_script}" \
    -TenantId "${access_review_tenant}" \
    -SubscriptionId "${access_review_subscription}","${access_review_second_subscription}" \
    -ManagementGroupId demo-root \
    -AssignmentsFile "${access_review_observations}" \
    -OutputDirectory "${access_review_ps_observations_out}" >/dev/null
  jq -S 'del(.generatedOn)' \
    "$(ls "${access_review_ps_observations_out}"/privileged-access-review-*.json)" \
    > "${TEMP_DIR}/access-review-pwsh-observations-actual.json"
  diff -u "${TEMP_DIR}/access-review-observations-expected.json" \
    "${TEMP_DIR}/access-review-pwsh-observations-actual.json" || {
    printf 'ERROR: The PowerShell deduplicated inheritance report differs from the Bash report.\n' >&2
    exit 1
  }
else
  printf '    (No pwsh interpreter found on PATH; tests/test.ps1 covers the PowerShell review.)\n'
fi

rg -q 'reviewCadenceDays' "${PROJECT_DIR}/docs/ACCESS-REVIEWS.md"
rg -q 'Defender CSPM CIEM' "${PROJECT_DIR}/docs/ACCESS-REVIEWS.md"
rg -q 'Evidence retention' "${PROJECT_DIR}/docs/ACCESS-REVIEWS.md"
rg -q 'Subscription Owner-count review' "${PROJECT_DIR}/docs/ACCESS-REVIEWS.md"
rg -q 'Remediation decision workflow' "${PROJECT_DIR}/docs/ACCESS-REVIEWS.md"

printf '\nAll local validation and safety tests passed.\n'
