#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPILED_TEMPLATE=''
COMPILED_ELIGIBILITY_TEMPLATE=''

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command '$1' is not installed."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --compiled-template)
      [[ $# -ge 2 ]] || fail '--compiled-template requires a file path.'
      COMPILED_TEMPLATE="$2"
      shift 2
      ;;
    --compiled-eligibility-template)
      [[ $# -ge 2 ]] || fail '--compiled-eligibility-template requires a file path.'
      COMPILED_ELIGIBILITY_TEMPLATE="$2"
      shift 2
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

require_command az
require_command jq
require_command rg

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/eslz-rbac-validation.XXXXXX")"
trap 'rm -rf "${temp_dir}"' EXIT

if [[ -z "${COMPILED_TEMPLATE}" ]]; then
  COMPILED_TEMPLATE="${temp_dir}/main.json"
  az bicep build --file "${PROJECT_DIR}/main.bicep" --outfile "${COMPILED_TEMPLATE}" >/dev/null
fi
if [[ -z "${COMPILED_ELIGIBILITY_TEMPLATE}" ]]; then
  COMPILED_ELIGIBILITY_TEMPLATE="${temp_dir}/owner-eligibility-request.json"
  az bicep build \
    --file "${PROJECT_DIR}/identity/azure-rbac/owner-eligibility-request.bicep" \
    --outfile "${COMPILED_ELIGIBILITY_TEMPLATE}" >/dev/null
fi
[[ -f "${COMPILED_TEMPLATE}" ]] || fail "Compiled template not found: ${COMPILED_TEMPLATE}"
[[ -f "${COMPILED_ELIGIBILITY_TEMPLATE}" ]] \
  || fail "Compiled eligibility template not found: ${COMPILED_ELIGIBILITY_TEMPLATE}"
jq empty "${COMPILED_TEMPLATE}" || fail "Compiled template is not valid JSON: ${COMPILED_TEMPLATE}"
jq empty "${COMPILED_ELIGIBILITY_TEMPLATE}" \
  || fail "Compiled eligibility template is not valid JSON: ${COMPILED_ELIGIBILITY_TEMPLATE}"

owner_role_definition_id='8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
permanent_owner_count="$(jq --arg owner "${owner_role_definition_id}" '
  [..
    | objects
    | select(.type? == "Microsoft.Authorization/roleAssignments")
    | select(
        (.properties.roleDefinitionId? // "" | ascii_downcase) as $role
        | ($role | contains($owner)) or ($role | contains("ownerroledefinitionid"))
      )
  ] | length
' "${COMPILED_TEMPLATE}")"
[[ "${permanent_owner_count}" -eq 0 ]] \
  || fail "Compiled default contains ${permanent_owner_count} permanent Owner role assignment(s)."

owner_reference_count="$(jq --arg owner "${owner_role_definition_id}" '
  # modules/remediating-policy-assignment.bicep stores the Owner and User
  # Access Administrator IDs only as deny-list constants that make the
  # deployment fail when a caller asks for either role. Those guard constants
  # are ignored here (and only when the guard that rejects them is present in
  # the same template); every other Owner reference remains an error.
  def strip_remediation_guard_constants:
    walk(
      if type == "object"
        and (.variables? | type) == "object"
        and (.variables | has("ownerRoleDefinitionId"))
        and (.variables | has("userAccessAdministratorRoleDefinitionId"))
        and ((.variables.invalidRoleDefinitionIds? // "") | contains("ownerRoleDefinitionId"))
        and ((.variables.validatedRoleDefinitionIds? // "") | contains("fail("))
      then .variables |= del(.ownerRoleDefinitionId, .userAccessAdministratorRoleDefinitionId)
      else .
      end
    );
  [strip_remediation_guard_constants | .. | strings | select(ascii_downcase | contains($owner))] | length
' "${COMPILED_TEMPLATE}")"
[[ "${owner_reference_count}" -eq 0 ]] \
  || fail "Compiled main contains ${owner_reference_count} Owner role definition reference(s)."

jq -e '
  [.. | objects | select(.type? == "Microsoft.Authorization/roleAssignments")] as $assignments
  | ($assignments | map(select(.properties.principalType == "Group"))) as $groupAssignments
  | ($assignments | map(select(.properties.principalId == "[parameters(\u0027principalId\u0027)]"))) as $remediationAssignments
  | ($groupAssignments | length) == 5
    and ($assignments | length) == (($groupAssignments | length) + ($remediationAssignments | length))
    and all($remediationAssignments[];
      .properties.principalType == "ServicePrincipal"
      and (.properties.roleDefinitionId | contains("parameters(\u0027roleDefinitionIds\u0027)")))
' "${COMPILED_TEMPLATE}" >/dev/null \
  || fail 'Ordinary role assignments must target groups (exactly five lower-privilege assignments), and any remediation assignment must bind a policy-assignment service principal to verified role definition IDs.'

active_owner_schedule_count="$(jq --arg owner "${owner_role_definition_id}" '
  [..
    | objects
    | select(.type? == "Microsoft.Authorization/roleAssignmentScheduleRequests")
    | select(
        (.properties.roleDefinitionId? // "" | ascii_downcase) as $role
        | ($role | contains($owner)) or ($role | contains("ownerroledefinitionid"))
      )
  ] | length
' "${COMPILED_TEMPLATE}")"
[[ "${active_owner_schedule_count}" -eq 0 ]] \
  || fail "Compiled default contains ${active_owner_schedule_count} active Owner schedule request(s); Owner must be eligible only."

eligible_request_count="$(jq '
  [.. | objects | select(.type? == "Microsoft.Authorization/roleEligibilityScheduleRequests")] | length
' "${COMPILED_TEMPLATE}")"
[[ "${eligible_request_count}" -eq 0 ]] \
  || fail "Repeatable main template contains ${eligible_request_count} one-time eligibility schedule request artifact(s)."

jq -e '
  .parameters.deployRoleAssignments.defaultValue == false
  and (.parameters | has("deployEligibleOwnerRoleAssignments") | not)
  and (.parameters | has("subscriptionPrivilegedAccessGroupObjectId") | not)
  and (.parameters | has("eligibleOwnerAssignmentStartDateTime") | not)
  and (.parameters | has("eligibleOwnerAssignmentDuration") | not)
  and (.parameters | has("eligibleOwnerAssignmentJustification") | not)
' "${COMPILED_TEMPLATE}" >/dev/null \
  || fail 'Repeatable main template must keep ordinary RBAC disabled and contain no PIM request parameters.'

jq -e --arg owner "${owner_role_definition_id}" '
  .parameters.submitEligibilityRequest.defaultValue == false
  and (.parameters.requestId | has("defaultValue") | not)
  and .parameters.requestId.minLength == 36
  and .parameters.requestId.maxLength == 36
  and (.parameters.requestType | has("defaultValue") | not)
  and .parameters.requestType.allowedValues == ["AdminAssign", "AdminUpdate", "AdminRemove"]
  and .parameters.targetRoleEligibilityScheduleId.defaultValue == ""
  and .parameters.eligibleOwnerAssignmentStartDateTime.defaultValue == ""
  and .parameters.eligibleOwnerAssignmentDuration.defaultValue == "P90D"
  and .parameters.eligibleOwnerAssignmentDuration.allowedValues == ["P30D", "P90D", "P180D", "P365D"]
  and .parameters.operatorWorkflowVerificationToken.type == "securestring"
  and (.parameters.operatorWorkflowVerificationToken | has("defaultValue") | not)
  and .variables.ownerRoleDefinitionId == $owner
  and .variables.baseRequestProperties.principalId == "[variables('\''validatedPrincipalId'\'')]"
  and .variables.baseRequestProperties.roleDefinitionId == "[subscriptionResourceId('\''Microsoft.Authorization/roleDefinitions'\'', variables('\''ownerRoleDefinitionId'\''))]"
  and .variables.baseRequestProperties.requestType == "[parameters('\''requestType'\'')]"
  and .variables.baseRequestProperties.justification == "[parameters('\''eligibleOwnerAssignmentJustification'\'')]"
  and (.variables.scheduleProperties | contains("AdminRemove"))
  and (.variables.scheduleProperties | contains("AfterDuration"))
  and (.variables.scheduleProperties | contains("eligibleOwnerAssignmentDuration"))
  and (.variables.targetScheduleProperties | contains("AdminAssign"))
  and (.variables.targetScheduleProperties | contains("targetRoleEligibilityScheduleId"))
  and (.resources | length) == 1
  and ([.resources[] | select(.type == "Microsoft.Authorization/roleEligibilityScheduleRequests")] | length) == 1
  and ([.resources[]
    | select(.type == "Microsoft.Authorization/roleEligibilityScheduleRequests")
    | select(
        .apiVersion == "2020-10-01"
        and .name == "[parameters('\''requestId'\'')]"
        and .condition == "[parameters('\''submitEligibilityRequest'\'')]"
        and .properties == "[union(variables('\''baseRequestProperties'\''), variables('\''scheduleProperties'\''), variables('\''targetScheduleProperties'\''))]"
      )] | length) == 1
' "${COMPILED_ELIGIBILITY_TEMPLATE}" >/dev/null \
  || fail 'One-shot Owner eligibility artifact must require a caller request ID, explicit opt-in and lifecycle action, group input, and a finite schedule.'

jq -e '
  (.variables.requestIdInputIsValid | contains("requestIdResidualCharacters"))
  and (.variables.principalInputIsValid | contains("principalResidualCharacters"))
  and (.variables.targetScheduleGuidIsCanonical | contains("targetScheduleResidualCharacters"))
  and (.variables.startTimeInputIsRfc3339Utc | contains("startTimeBaseResidualCharacters"))
  and (.variables.startTimeInputIsRfc3339Utc | contains("startTimeSuffixResidualCharacters"))
  and .variables.targetScheduleInputIsValid == "[if(equals(parameters('\''requestType'\''), '\''AdminAssign'\''), empty(parameters('\''targetRoleEligibilityScheduleId'\'')), variables('\''targetScheduleGuidIsCanonical'\''))]"
  and .variables.scheduleInputIsValid == "[if(equals(parameters('\''requestType'\''), '\''AdminRemove'\''), empty(parameters('\''eligibleOwnerAssignmentStartDateTime'\'')), variables('\''startTimeInputIsRfc3339Utc'\''))]"
  and .variables.workflowMarkerIsValid == "[equals(parameters('\''operatorWorkflowVerificationToken'\''), variables('\''expectedOperatorWorkflowVerificationToken'\''))]"
  and .variables.executionInputsAreValid == "[or(not(parameters('\''submitEligibilityRequest'\'')), and(and(and(and(and(variables('\''requestIdInputIsValid'\''), variables('\''principalInputIsValid'\'')), variables('\''targetScheduleInputIsValid'\'')), variables('\''scheduleInputIsValid'\'')), not(empty(trim(parameters('\''eligibleOwnerAssignmentJustification'\''))))), variables('\''workflowMarkerIsValid'\'')))]"
' "${COMPILED_ELIGIBILITY_TEMPLATE}" >/dev/null \
  || fail 'One-shot Owner eligibility compiled input guards were weakened or replaced.'

one_shot_forbidden_count="$(jq '
  [..
    | objects
    | select(
        .type? == "Microsoft.Authorization/roleAssignments"
        or .type? == "Microsoft.Authorization/roleAssignmentScheduleRequests"
        or .type? == "Microsoft.Authorization/roleManagementPolicies"
        or .type? == "Microsoft.Authorization/roleManagementPolicyAssignments"
      )
  ] | length
' "${COMPILED_ELIGIBILITY_TEMPLATE}")"
[[ "${one_shot_forbidden_count}" -eq 0 ]] \
  || fail 'One-shot Owner eligibility artifact must not contain permanent/active Owner or PIM activation-policy resources.'

if rg -q 'owner-eligibility-request|roleEligibilityScheduleRequests' \
  "${PROJECT_DIR}/main.bicep" \
  "${PROJECT_DIR}/modules" \
  "${PROJECT_DIR}/scripts/preflight.sh" \
  "${PROJECT_DIR}/scripts/preflight.ps1" \
  "${PROJECT_DIR}/scripts/what-if.sh" \
  "${PROJECT_DIR}/scripts/what-if.ps1" \
  "${PROJECT_DIR}/scripts/deploy.sh" \
  "${PROJECT_DIR}/scripts/deploy.ps1" \
  "${PROJECT_DIR}/scripts/teardown.sh" \
  "${PROJECT_DIR}/scripts/teardown.ps1"; then
  fail 'Normal main modules and lifecycle scripts must not invoke the one-shot Owner eligibility artifact.'
fi

role_management_policy_count="$(jq '
  [..
    | objects
    | select(
        .type? == "Microsoft.Authorization/roleManagementPolicies"
        or .type? == "Microsoft.Authorization/roleManagementPolicyAssignments"
      )
  ] | length
' "${COMPILED_TEMPLATE}")"
[[ "${role_management_policy_count}" -eq 0 ]] \
  || fail 'PIM activation policy resources are out of scope and must remain static/report-only.'

parameter_template="${PROJECT_DIR}/parameters/demo.parameters.template.json"
jq -e '
  .parameters.deployRoleAssignments.value == false
  and (.parameters | has("deployEligibleOwnerRoleAssignments") | not)
  and (.parameters | has("subscriptionPrivilegedAccessGroupObjectId") | not)
' "${parameter_template}" >/dev/null \
  || fail 'The normal JSON parameter template must not expose the one-shot Owner eligibility workflow.'

if rg -q 'deployEligibleOwnerRoleAssignments|subscriptionPrivilegedAccessGroupObjectId|eligibleOwnerAssignment' \
  "${PROJECT_DIR}/parameters/main.template.bicepparam"; then
  fail 'The normal Bicep parameter template must not expose the one-shot Owner eligibility workflow.'
fi

eligibility_parameter_template="${PROJECT_DIR}/identity/azure-rbac/owner-eligibility-request.parameters.template.json"
[[ -f "${eligibility_parameter_template}" ]] \
  || fail "Missing one-shot Owner eligibility parameter template: ${eligibility_parameter_template}"
jq -e '
  .parameters.submitEligibilityRequest.value == false
  and .parameters.requestId.value == "REPLACE_WITH_NEW_UNIQUE_REQUEST_GUID"
  and .parameters.requestType.value == "AdminAssign"
  and .parameters.subscriptionPrivilegedAccessGroupObjectId.value == "REPLACE_WITH_SUBSCRIPTION_PRIVILEGED_ACCESS_GROUP_OBJECT_GUID"
  and .parameters.targetRoleEligibilityScheduleId.value == ""
  and .parameters.eligibleOwnerAssignmentStartDateTime.value == "REPLACE_WITH_ELIGIBLE_OWNER_START_DATE_TIME_UTC"
  and .parameters.eligibleOwnerAssignmentDuration.value == "P90D"
  and .parameters.eligibleOwnerAssignmentJustification.value == "REPLACE_WITH_ELIGIBLE_OWNER_REQUEST_JUSTIFICATION"
  and .parameters.operatorWorkflowVerificationToken.value == "UNSUPPORTED_OUTSIDE_SCRIPTS_OWNER_ELIGIBILITY_REQUEST"
' "${eligibility_parameter_template}" >/dev/null \
  || fail 'One-shot Owner eligibility parameter template must stay disabled and retain explicit tenant-independent placeholders.'

pim_guidance="${PROJECT_DIR}/docs/AZURE-RBAC-PIM.md"
for required_guidance in \
  'existing eligibility' \
  'AdminAssign' \
  'AdminUpdate' \
  'AdminRemove' \
  'fresh request GUID' \
  'never reuse' \
  'immutable compiled template snapshot' \
  'ancestor management-group scope' \
  'immediately before submission'; do
  rg -qi "${required_guidance}" "${pim_guidance}" \
    || fail "PIM runbook is missing one-shot lifecycle guidance: ${required_guidance}"
done

owner_operator_bash="${PROJECT_DIR}/scripts/owner-eligibility-request.sh"
owner_operator_powershell="${PROJECT_DIR}/scripts/owner-eligibility-request.ps1"
[[ -f "${owner_operator_bash}" && -f "${owner_operator_powershell}" ]] \
  || fail 'Both Bash and PowerShell Owner eligibility operator workflows are required.'

for required_pattern in \
  'az ad group show' \
  'securityEnabled == true' \
  'roleEligibilitySchedules' \
  'roleEligibilityScheduleRequests' \
  'atScope()' \
  'deployment sub what-if' \
  'deployment sub create' \
  'az bicep build' \
  'template_snapshot' \
  'verify_live_state' \
  'management/managementgroups' \
  '.nextLink | type == "string"' \
  'ESLZ_OWNER_ELIGIBILITY_CONFIRMATION' \
  'UNSUPPORTED_OUTSIDE_SCRIPTS_OWNER_ELIGIBILITY_REQUEST'; do
  rg -q -F "${required_pattern}" "${owner_operator_bash}" \
    || fail "Bash Owner eligibility workflow is missing required fail-closed control: ${required_pattern}"
done

for required_pattern in \
  "'ad', 'group', 'show'" \
  'securityEnabledProperty.Value -ne $true' \
  'roleEligibilitySchedules' \
  'roleEligibilityScheduleRequests' \
  'atScope()' \
  'deployment sub what-if' \
  'deployment sub create' \
  'bicep build' \
  'TemplateSnapshot' \
  'Test-LiveEligibilityState' \
  'management/managementgroups' \
  'nextLinkProperty.Value -isnot [string]' \
  'ESLZ_OWNER_ELIGIBILITY_CONFIRMATION' \
  'UNSUPPORTED_OUTSIDE_SCRIPTS_OWNER_ELIGIBILITY_REQUEST'; do
  rg -q -F "${required_pattern}" "${owner_operator_powershell}" \
    || fail "PowerShell Owner eligibility workflow is missing required fail-closed control: ${required_pattern}"
done

bash_group_check_line="$(rg -n -F 'securityEnabled == true' "${owner_operator_bash}" | head -n 1 | cut -d: -f1)"
bash_inventory_line="$(rg -n -F 'schedules_url=' "${owner_operator_bash}" | head -n 1 | cut -d: -f1)"
bash_what_if_line="$(rg -n -F 'az deployment sub what-if' "${owner_operator_bash}" | head -n 1 | cut -d: -f1)"
[[ "${bash_group_check_line}" -lt "${bash_inventory_line}" && "${bash_group_check_line}" -lt "${bash_what_if_line}" ]] \
  || fail 'Bash Owner eligibility workflow must verify the security-enabled group before state inventory or what-if.'

powershell_group_check_line="$(rg -n -F 'securityEnabledProperty.Value -ne $true' "${owner_operator_powershell}" | head -n 1 | cut -d: -f1)"
powershell_inventory_line="$(rg -n -F '$schedulesUrl =' "${owner_operator_powershell}" | head -n 1 | cut -d: -f1)"
powershell_what_if_line="$(rg -n -F '& az deployment sub what-if' "${owner_operator_powershell}" | head -n 1 | cut -d: -f1)"
[[ "${powershell_group_check_line}" -lt "${powershell_inventory_line}" && "${powershell_group_check_line}" -lt "${powershell_what_if_line}" ]] \
  || fail 'PowerShell Owner eligibility workflow must verify the security-enabled group before state inventory or what-if.'

bash_compile_line="$(rg -n -F 'az bicep build' "${owner_operator_bash}" | head -n 1 | cut -d: -f1)"
bash_first_verify_line="$(rg -n '^verify_live_state$' "${owner_operator_bash}" | head -n 1 | cut -d: -f1)"
bash_second_verify_line="$(rg -n '^verify_live_state$' "${owner_operator_bash}" | tail -n 1 | cut -d: -f1)"
bash_confirmation_line="$(rg -n -F 'IFS= read -r typed_request_id' "${owner_operator_bash}" | head -n 1 | cut -d: -f1)"
bash_create_line="$(rg -n -F 'az deployment sub create' "${owner_operator_bash}" | head -n 1 | cut -d: -f1)"
[[ "$(rg -c -F -- '--template-file "${template_snapshot}"' "${owner_operator_bash}")" -eq 2 ]] \
  || fail 'Bash Owner eligibility workflow must use the same compiled template snapshot for what-if and create.'
[[ "$(rg -c '^verify_live_state$' "${owner_operator_bash}")" -eq 2 ]] \
  || fail 'Bash Owner eligibility workflow must perform live verification before what-if and again before create.'
[[ "${bash_compile_line}" -lt "${bash_first_verify_line}" \
  && "${bash_first_verify_line}" -lt "${bash_what_if_line}" \
  && "${bash_confirmation_line}" -lt "${bash_second_verify_line}" \
  && "${bash_second_verify_line}" -lt "${bash_create_line}" ]] \
  || fail 'Bash Owner eligibility workflow must compile once, preview, confirm, revalidate live state, then create.'

powershell_compile_line="$(rg -n -F '& az bicep build' "${owner_operator_powershell}" | head -n 1 | cut -d: -f1)"
powershell_first_verify_line="$(rg -n '^Test-LiveEligibilityState$' "${owner_operator_powershell}" | head -n 1 | cut -d: -f1)"
powershell_second_verify_line="$(rg -n '^Test-LiveEligibilityState$' "${owner_operator_powershell}" | tail -n 1 | cut -d: -f1)"
powershell_confirmation_line="$(rg -n -F '$typedRequestId = Read-Host' "${owner_operator_powershell}" | head -n 1 | cut -d: -f1)"
powershell_create_line="$(rg -n -F '& az deployment sub create' "${owner_operator_powershell}" | head -n 1 | cut -d: -f1)"
[[ "$(rg -c -F -- '--template-file $script:TemplateSnapshot' "${owner_operator_powershell}")" -eq 2 ]] \
  || fail 'PowerShell Owner eligibility workflow must use the same compiled template snapshot for what-if and create.'
[[ "$(rg -c '^Test-LiveEligibilityState$' "${owner_operator_powershell}")" -eq 2 ]] \
  || fail 'PowerShell Owner eligibility workflow must perform live verification before what-if and again before create.'
[[ "${powershell_compile_line}" -lt "${powershell_first_verify_line}" \
  && "${powershell_first_verify_line}" -lt "${powershell_what_if_line}" \
  && "${powershell_confirmation_line}" -lt "${powershell_second_verify_line}" \
  && "${powershell_second_verify_line}" -lt "${powershell_create_line}" ]] \
  || fail 'PowerShell Owner eligibility workflow must compile once, preview, confirm, revalidate live state, then create.'

requirements_file="${PROJECT_DIR}/identity/azure-rbac/owner-activation-requirements.template.json"
[[ -f "${requirements_file}" ]] || fail "Missing static Owner activation requirements: ${requirements_file}"
jq empty "${requirements_file}" || fail 'Owner activation requirements are not valid JSON.'
jq -e '
  .artifactType == "azureRbacPimActivationRequirements"
  and .state == "reportOnly"
  and .roleName == "Owner"
  and .scopeType == "subscription"
  and .principalType == "Group"
  and .assignmentType == "eligible"
  and .eligibility.requireTimeBoundSchedule == true
  and .eligibility.maximumEligibilityDuration == "P365D"
  and .activation.requireApproval == true
  and (.activation.approvers | length) >= 1
  and all(.activation.approvers[]; test("^REPLACE_WITH_.+$"))
  and .activation.requireMultiFactorAuthentication == true
  and .activation.requireJustification == true
  and (.activation.maximumActivationDurationHours | type) == "number"
  and .activation.maximumActivationDurationHours >= 1
  and .activation.maximumActivationDurationHours <= 8
  and .notifications.notifyAdminsOnActivation == true
  and .notifications.notifyApproversOnActivationRequest == true
  and .notifications.notifyAssigneeOnActivation == true
  and .emergencyAccess.handledOutsideRepository == true
  and .emergencyAccess.permanentOwnerAssignmentCreatedByRepository == false
' "${requirements_file}" >/dev/null \
  || fail 'Static Owner activation requirements must enforce group eligibility, approval, MFA, justification, bounded duration, notifications, and external emergency access.'

if rg -q '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' "${requirements_file}"; then
  fail 'Static Owner activation requirements must not contain tenant-specific object IDs.'
fi

printf 'PIM-ready subscription RBAC artifacts validated offline.\n'
