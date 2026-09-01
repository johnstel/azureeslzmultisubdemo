#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPILED_TEMPLATE=''

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
[[ -f "${COMPILED_TEMPLATE}" ]] || fail "Compiled template not found: ${COMPILED_TEMPLATE}"
jq empty "${COMPILED_TEMPLATE}" || fail "Compiled template is not valid JSON: ${COMPILED_TEMPLATE}"

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

jq -e '
  [.. | objects | select(.type? == "Microsoft.Authorization/roleAssignments")]
  | length == 5 and all(.properties.principalType == "Group")
' "${COMPILED_TEMPLATE}" >/dev/null \
  || fail 'Every ordinary role assignment must target a group, and exactly five lower-privilege assignments are expected.'

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
[[ "${eligible_request_count}" -eq 2 ]] \
  || fail "Expected exactly two subscription Owner eligibility schedule request artifacts, found ${eligible_request_count}."

jq -e '
  [.. | objects | select(.type? == "Microsoft.Authorization/roleEligibilityScheduleRequests")]
  | all(
      .apiVersion == "2020-10-01"
      and .condition == "[parameters('\''deployEligibleOwnerRoleAssignment'\'')]"
      and .properties.requestType == "AdminAssign"
      and .properties.roleDefinitionId == "[subscriptionResourceId('\''Microsoft.Authorization/roleDefinitions'\'', variables('\''ownerRoleDefinitionId'\''))]"
      and .properties.principalId == "[variables('\''validatedPrivilegedAccessGroupObjectId'\'')]"
      and .properties.justification == "[parameters('\''eligibleOwnerAssignmentJustification'\'')]"
      and .properties.scheduleInfo.startDateTime == "[parameters('\''eligibleOwnerAssignmentStartDateTime'\'')]"
      and .properties.scheduleInfo.expiration.type == "AfterDuration"
      and .properties.scheduleInfo.expiration.duration == "[parameters('\''eligibleOwnerAssignmentDuration'\'')]"
    )
' "${COMPILED_TEMPLATE}" >/dev/null \
  || fail 'Eligible Owner request artifacts must use the stable API, AdminAssign, group input, justification, and a finite parameterized schedule.'

jq -e '
  .parameters.deployRoleAssignments.defaultValue == false
  and .parameters.deployEligibleOwnerRoleAssignments.defaultValue == false
  and .parameters.subscriptionPrivilegedAccessGroupObjectId.defaultValue == ""
  and .parameters.eligibleOwnerAssignmentStartDateTime.defaultValue == ""
  and .parameters.eligibleOwnerAssignmentDuration.defaultValue == "P90D"
  and .parameters.eligibleOwnerAssignmentJustification.defaultValue == ""
' "${COMPILED_TEMPLATE}" >/dev/null \
  || fail 'Compiled RBAC and eligible Owner parameters must retain safe defaults.'

eligible_module_default_count="$(jq '
  [..
    | objects
    | .parameters?
    | select(type == "object")
    | select(.deployEligibleOwnerRoleAssignment.defaultValue? == false)
    | select(.subscriptionPrivilegedAccessGroupObjectId.defaultValue? == "")
  ] | length
' "${COMPILED_TEMPLATE}")"
[[ "${eligible_module_default_count}" -eq 2 ]] \
  || fail 'Both subscription RBAC modules must default the eligible Owner request off and its group input empty.'

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
  and .parameters.deployEligibleOwnerRoleAssignments.value == false
  and .parameters.subscriptionPrivilegedAccessGroupObjectId.value == "REPLACE_WITH_SUBSCRIPTION_PRIVILEGED_ACCESS_GROUP_OBJECT_GUID"
  and .parameters.eligibleOwnerAssignmentStartDateTime.value == "REPLACE_WITH_ELIGIBLE_OWNER_START_DATE_TIME_UTC"
  and .parameters.eligibleOwnerAssignmentDuration.value == "P90D"
  and .parameters.eligibleOwnerAssignmentJustification.value == "REPLACE_WITH_ELIGIBLE_OWNER_ASSIGNMENT_JUSTIFICATION"
' "${parameter_template}" >/dev/null \
  || fail 'The JSON parameter template must keep eligible Owner disabled and use tenant-independent placeholders.'

rg -q "^param deployEligibleOwnerRoleAssignments = false$" "${PROJECT_DIR}/parameters/main.template.bicepparam" \
  || fail 'The Bicep parameter template must keep eligible Owner disabled.'
rg -q "^param subscriptionPrivilegedAccessGroupObjectId = 'REPLACE_WITH_SUBSCRIPTION_PRIVILEGED_ACCESS_GROUP_OBJECT_GUID'$" \
  "${PROJECT_DIR}/parameters/main.template.bicepparam" \
  || fail 'The Bicep parameter template must use a privileged-access group placeholder.'

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
