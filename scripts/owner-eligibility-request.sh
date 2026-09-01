#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BICEP_FILE="${PROJECT_DIR}/identity/azure-rbac/owner-eligibility-request.bicep"
OWNER_ROLE_DEFINITION_ID='8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
API_VERSION='2020-10-01'
EXECUTION_CONFIRMATION='SUBMIT-OWNER-ELIGIBILITY'

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  ./scripts/owner-eligibility-request.sh \
    --subscription-id <guid> \
    --parameter-file <local-parameters.json> \
    [--location <azure-region>] \
    [--execute]

The default mode performs read-only preflight checks and an Azure what-if. It
does not submit an eligibility request. --execute additionally requires:

  ESLZ_OWNER_ELIGIBILITY_CONFIRMATION=SUBMIT-OWNER-ELIGIBILITY

and a typed request-ID confirmation after the what-if.
EOF
}

is_canonical_guid() {
  [[ "$1" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]
}

is_rfc3339_utc() {
  local value="$1"
  local year
  local month
  local day
  local hour
  local minute
  local second
  local maximum_day

  [[ "${value}" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})([.][0-9]+)?Z$ ]] || return 1
  year=$((10#${BASH_REMATCH[1]}))
  month=$((10#${BASH_REMATCH[2]}))
  day=$((10#${BASH_REMATCH[3]}))
  hour=$((10#${BASH_REMATCH[4]}))
  minute=$((10#${BASH_REMATCH[5]}))
  second=$((10#${BASH_REMATCH[6]}))
  [[ "${year}" -ge 1 && "${month}" -ge 1 && "${month}" -le 12 && "${hour}" -le 23 && "${minute}" -le 59 && "${second}" -le 59 ]] || return 1

  case "${month}" in
    4|6|9|11) maximum_day=30 ;;
    2)
      maximum_day=28
      if (( year % 400 == 0 || (year % 4 == 0 && year % 100 != 0) )); then
        maximum_day=29
      fi
      ;;
    *) maximum_day=31 ;;
  esac
  [[ "${day}" -ge 1 && "${day}" -le "${maximum_day}" ]]
}

read_string_parameter() {
  local name="$1"
  jq -er --arg name "${name}" '
    .parameters[$name].value
    | select(type == "string")
  ' "${parameter_file}" 2>/dev/null || fail "Parameter '${name}' must have a string value."
}

collect_arm_pages() {
  local next_url="$1"
  local page_count=0
  local page
  local values
  local collected='[]'

  while [[ -n "${next_url}" ]]; do
    case "${next_url}" in
      https://management.azure.com/*) ;;
      *) return 1 ;;
    esac

    page_count=$((page_count + 1))
    [[ "${page_count}" -le 100 ]] || return 1
    page="$(az rest --method get --url "${next_url}" --subscription "${subscription_id}" --output json 2>/dev/null)" || return 1
    printf '%s' "${page}" | jq -e '.value | type == "array"' >/dev/null 2>&1 || return 1
    values="$(printf '%s' "${page}" | jq -c '.value')" || return 1
    collected="$(jq -cn --argjson current "${collected}" --argjson next "${values}" '$current + $next')" || return 1
    next_url="$(printf '%s' "${page}" | jq -er '.nextLink // ""' 2>/dev/null)" || return 1
  done

  printf '%s\n' "${collected}"
}

subscription_id=''
parameter_file=''
location='eastus'
execute=false

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --subscription-id)
      [[ "$#" -ge 2 ]] || fail '--subscription-id requires a value.'
      subscription_id="$2"
      shift 2
      ;;
    --parameter-file)
      [[ "$#" -ge 2 ]] || fail '--parameter-file requires a value.'
      parameter_file="$2"
      shift 2
      ;;
    --location)
      [[ "$#" -ge 2 ]] || fail '--location requires a value.'
      location="$2"
      shift 2
      ;;
    --execute)
      execute=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

[[ -n "${subscription_id}" ]] || fail '--subscription-id is required.'
is_canonical_guid "${subscription_id}" || fail 'Subscription ID must be a canonical GUID.'
[[ -n "${parameter_file}" && -f "${parameter_file}" ]] || fail '--parameter-file must identify an existing local JSON file.'
[[ -n "${location}" && "${location}" =~ ^[a-z0-9-]+$ ]] || fail 'Location must contain only lowercase letters, numbers, and hyphens.'
command -v az >/dev/null 2>&1 || fail 'Azure CLI is required.'
command -v jq >/dev/null 2>&1 || fail 'jq is required.'

operator_temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/eslz-owner-eligibility.XXXXXX")" ||
  fail 'Unable to create a private parameter snapshot.'
trap 'rm -rf "${operator_temp_dir}"' EXIT
parameter_snapshot="${operator_temp_dir}/parameters.json"
cp "${parameter_file}" "${parameter_snapshot}" || fail 'Unable to create a private parameter snapshot.'
chmod 600 "${parameter_snapshot}"
parameter_file="${parameter_snapshot}"

jq -e '.parameters | type == "object"' "${parameter_file}" >/dev/null 2>&1 || fail 'Parameter file is not a valid ARM deployment parameter document.'

submit_eligibility_request="$(jq -er '.parameters.submitEligibilityRequest.value | select(type == "boolean")' "${parameter_file}" 2>/dev/null)" ||
  fail "Parameter 'submitEligibilityRequest' must have a boolean value."
[[ "${submit_eligibility_request}" == 'true' ]] ||
  fail "Set 'submitEligibilityRequest' to true only in the reviewed local one-shot file before using this workflow."

request_id="$(read_string_parameter 'requestId')"
request_type="$(read_string_parameter 'requestType')"
group_id="$(read_string_parameter 'subscriptionPrivilegedAccessGroupObjectId')"
target_schedule_id="$(read_string_parameter 'targetRoleEligibilityScheduleId')"
start_time="$(read_string_parameter 'eligibleOwnerAssignmentStartDateTime')"
duration="$(read_string_parameter 'eligibleOwnerAssignmentDuration')"
justification="$(read_string_parameter 'eligibleOwnerAssignmentJustification')"
file_workflow_token="$(read_string_parameter 'operatorWorkflowVerificationToken')"

is_canonical_guid "${request_id}" || fail 'requestId must be a canonical GUID.'
is_canonical_guid "${group_id}" || fail 'subscriptionPrivilegedAccessGroupObjectId must be a canonical GUID.'
[[ "${justification}" =~ [^[:space:]] ]] || fail 'eligibleOwnerAssignmentJustification must not be blank.'
case "${duration}" in
  P30D|P90D|P180D|P365D) ;;
  *) fail 'eligibleOwnerAssignmentDuration must be one of P30D, P90D, P180D, or P365D.' ;;
esac
[[ "${file_workflow_token}" == 'UNSUPPORTED_OUTSIDE_SCRIPTS_OWNER_ELIGIBILITY_REQUEST' ]] ||
  fail 'Do not place workflow verification evidence in the parameter file; use this operator workflow.'

case "${request_type}" in
  AdminAssign)
    [[ -z "${target_schedule_id}" ]] || fail 'AdminAssign requires an empty targetRoleEligibilityScheduleId.'
    is_rfc3339_utc "${start_time}" || fail 'AdminAssign requires an RFC3339 UTC eligibleOwnerAssignmentStartDateTime ending in Z.'
    ;;
  AdminUpdate)
    is_canonical_guid "${target_schedule_id}" || fail 'AdminUpdate requires a canonical targetRoleEligibilityScheduleId GUID.'
    is_rfc3339_utc "${start_time}" || fail 'AdminUpdate requires an RFC3339 UTC eligibleOwnerAssignmentStartDateTime ending in Z.'
    ;;
  AdminRemove)
    is_canonical_guid "${target_schedule_id}" || fail 'AdminRemove requires a canonical targetRoleEligibilityScheduleId GUID.'
    [[ -z "${start_time}" ]] || fail 'AdminRemove requires an empty eligibleOwnerAssignmentStartDateTime.'
    ;;
  *)
    fail 'requestType must be AdminAssign, AdminUpdate, or AdminRemove.'
    ;;
esac

if [[ "${execute}" == 'true' && "${ESLZ_OWNER_ELIGIBILITY_CONFIRMATION:-}" != "${EXECUTION_CONFIRMATION}" ]]; then
  fail "--execute requires ESLZ_OWNER_ELIGIBILITY_CONFIRMATION=${EXECUTION_CONFIRMATION}."
fi

workflow_request_id="${request_id}"
workflow_group_id="${group_id}"
subscription_id="$(printf '%s' "${subscription_id}" | tr '[:upper:]' '[:lower:]')"
request_id="$(printf '%s' "${request_id}" | tr '[:upper:]' '[:lower:]')"
group_id="$(printf '%s' "${group_id}" | tr '[:upper:]' '[:lower:]')"
target_schedule_id="$(printf '%s' "${target_schedule_id}" | tr '[:upper:]' '[:lower:]')"
scope="/subscriptions/${subscription_id}"
owner_role_definition_resource_id="${scope}/providers/microsoft.authorization/roledefinitions/${OWNER_ROLE_DEFINITION_ID}"
workflow_token="verified:${workflow_request_id}:${workflow_group_id}:${request_type}:${subscription_id}"

subscription_json="$(az account show --subscription "${subscription_id}" --output json 2>/dev/null)" ||
  fail 'Unable to read the target subscription context.'
printf '%s' "${subscription_json}" | jq -e --arg id "${subscription_id}" '
  ((.id // "") | ascii_downcase) == $id
  and ((.state // "") | ascii_downcase) == "enabled"
  and ((.tenantId // "") | type == "string")
  and ((.tenantId // "") | length > 0)
' >/dev/null 2>&1 || fail 'Target subscription context is missing, disabled, or ambiguous.'
target_tenant_id="$(printf '%s' "${subscription_json}" | jq -er '.tenantId | ascii_downcase')" ||
  fail 'Target subscription context does not contain a tenant ID.'

active_context_json="$(az account show --output json 2>/dev/null)" ||
  fail 'Unable to read the active Azure CLI context.'
printf '%s' "${active_context_json}" | jq -e --arg tenant_id "${target_tenant_id}" '
  ((.tenantId // "") | ascii_downcase) == $tenant_id
  and ((.state // "") | ascii_downcase) == "enabled"
' >/dev/null 2>&1 ||
  fail 'The active Azure CLI context must use the target subscription tenant before the Entra group lookup.'

group_json="$(az ad group show --group "${group_id}" --output json 2>/dev/null)" ||
  fail 'Unable to verify the privileged principal through Microsoft Entra.'
printf '%s' "${group_json}" | jq -e --arg id "${group_id}" '
  ((.id // "") | ascii_downcase) == $id
  and .securityEnabled == true
' >/dev/null 2>&1 ||
  fail 'The supplied privileged principal is not the exact existing security-enabled Microsoft Entra group.'

principal_filter="principalId%20eq%20${group_id}"
schedules_url="https://management.azure.com${scope}/providers/Microsoft.Authorization/roleEligibilitySchedules?api-version=${API_VERSION}&%24filter=${principal_filter}"
requests_url="https://management.azure.com${scope}/providers/Microsoft.Authorization/roleEligibilityScheduleRequests?api-version=${API_VERSION}&%24filter=atScope()"
schedules="$(collect_arm_pages "${schedules_url}")" ||
  fail 'Unable to enumerate existing Owner eligibility schedules; refusing to preview or submit.'
requests="$(collect_arm_pages "${requests_url}")" ||
  fail 'Unable to enumerate existing or pending eligibility requests; refusing to preview or submit.'
printf '%s' "${schedules}" | jq -e 'all(.[];
  (type == "object")
  and ((.id // null) | type == "string")
  and ((.name // null) | type == "string")
  and ((.properties.scope // null) | type == "string")
  and ((.properties.principalId // null) | type == "string")
  and ((.properties.roleDefinitionId // null) | type == "string")
)' >/dev/null 2>&1 ||
  fail 'Existing eligibility schedule inventory returned an unexpected shape.'
printf '%s' "${requests}" | jq -e 'all(.[];
  (type == "object")
  and ((.id // null) | type == "string")
  and ((.name // null) | type == "string")
  and ((.properties.scope // null) | type == "string")
  and ((.properties.principalId // null) | type == "string")
  and ((.properties.roleDefinitionId // null) | type == "string")
  and ((.properties.status // null) | type == "string")
)' >/dev/null 2>&1 ||
  fail 'Eligibility request inventory returned an unexpected shape.'

matching_schedules="$(printf '%s' "${schedules}" | jq -c \
  --arg principal "${group_id}" \
  --arg role "${owner_role_definition_resource_id}" \
  --arg scope "${scope}" '
  [.[] | select(
    ((.properties.principalId // "") | ascii_downcase) == $principal
    and ((.properties.roleDefinitionId // "") | ascii_downcase) == $role
    and (
      ((.properties.scope // "") | ascii_downcase) == $scope
      or (((.id // "") | ascii_downcase) | startswith($scope + "/providers/microsoft.authorization/roleeligibilityschedules/"))
    )
  )]
')" || fail 'Unable to evaluate existing eligibility schedules.'

matching_requests="$(printf '%s' "${requests}" | jq -c \
  --arg principal "${group_id}" \
  --arg role "${owner_role_definition_resource_id}" \
  --arg scope "${scope}" '
  [.[] | select(
    ((.properties.principalId // "") | ascii_downcase) == $principal
    and ((.properties.roleDefinitionId // "") | ascii_downcase) == $role
    and (
      ((.properties.scope // "") | ascii_downcase) == $scope
      or (((.id // "") | ascii_downcase) | startswith($scope + "/providers/microsoft.authorization/roleeligibilityschedulerequests/"))
    )
  )]
')" || fail 'Unable to evaluate existing eligibility requests.'

request_id_reuse_count="$(printf '%s' "${requests}" | jq \
  --arg request_id "${request_id}" '
  [.[] | select(
    ((.name // "") | ascii_downcase) == $request_id
    or (((.id // "") | ascii_downcase) | endswith("/" + $request_id))
  )] | length
')"
[[ "${request_id_reuse_count}" -eq 0 ]] || fail 'requestId already exists at this subscription scope and must never be reused.'

unresolved_request_count="$(printf '%s' "${matching_requests}" | jq '
  def terminal_statuses:
    ["denied", "admindenied", "canceled", "failed", "failedasresourceislocked", "revoked", "timedout", "invalid", "provisioned", "schedulecreated"];
  [.[] | select(
    ((.properties.status // "") | ascii_downcase) as $status
    | (terminal_statuses | index($status)) == null
  )] | length
')"
[[ "${unresolved_request_count}" -eq 0 ]] ||
  fail 'A matching eligibility request is pending or has an unknown non-terminal status.'

schedule_count="$(printf '%s' "${matching_schedules}" | jq 'length')"
if [[ "${request_type}" == 'AdminAssign' ]]; then
  [[ "${schedule_count}" -eq 0 ]] || fail 'AdminAssign is blocked because matching Owner eligibility already exists.'
else
  target_schedule_count="$(printf '%s' "${matching_schedules}" | jq \
    --arg target "${target_schedule_id}" '
    [.[] | select(
      ((.name // "") | ascii_downcase) == $target
      or (((.id // "") | ascii_downcase) | endswith("/" + $target))
    )] | length
  ')"
  [[ "${schedule_count}" -eq 1 && "${target_schedule_count}" -eq 1 ]] ||
    fail "${request_type} requires exactly one matching existing Owner eligibility schedule with the supplied target schedule ID."
fi

printf 'Preflight passed for %s at %s.\n' "${request_type}" "${scope}"
printf 'Verified principal: security-enabled group %s\n' "${group_id}"
printf 'Running subscription what-if; no eligibility request is submitted by this step.\n'
az deployment sub what-if \
  --name "owner-eligibility-${request_id}" \
  --location "${location}" \
  --subscription "${subscription_id}" \
  --template-file "${BICEP_FILE}" \
  --parameters "@${parameter_file}" \
  "operatorWorkflowVerificationToken=${workflow_token}"

if [[ "${execute}" != 'true' ]]; then
  printf 'Preview complete. No eligibility request was submitted.\n'
  exit 0
fi

printf 'Type the one-time request ID %s to submit the unchanged preview: ' "${request_id}"
IFS= read -r typed_request_id
[[ "${typed_request_id}" == "${request_id}" ]] || fail 'Typed request ID did not match; no eligibility request was submitted.'

if ! az deployment sub create \
  --name "owner-eligibility-${request_id}" \
  --location "${location}" \
  --subscription "${subscription_id}" \
  --template-file "${BICEP_FILE}" \
  --parameters "@${parameter_file}" \
  "operatorWorkflowVerificationToken=${workflow_token}"; then
  fail 'Owner eligibility submission failed or returned an ambiguous result. Do not retry with the same request ID; repeat the preflight with a fresh request ID.'
fi

printf 'One-time Owner eligibility request submitted. Do not retry or reuse request ID %s.\n' "${request_id}"
