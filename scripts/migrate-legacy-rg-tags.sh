#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PARAMETER_FILE="${1:-${PROJECT_DIR}/parameters/demo.parameters.json}"
MODE="${2:-preview}"

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit "${2:-1}"
}

[[ -f "${PARAMETER_FILE}" ]] || fail "Parameter file not found: ${PARAMETER_FILE}"
command -v jq >/dev/null 2>&1 || fail 'jq is required.'
[[ "${MODE}" == 'preview' || "${MODE}" == '--execute' ]] || fail 'Mode must be preview or --execute.'

value() {
  jq -er --arg name "$1" '.parameters[$name].value' "${PARAMETER_FILE}"
}

tenant_root="$(value tenantRootManagementGroupId)"
prefix="$(value namePrefix)"
archetype="$(value workloadArchetype)"
connectivity_subscription="$(value connectivitySubscriptionId)"
workload_subscription="$(value workloadSubscriptionId)"
[[ "${prefix}" =~ ^[a-z0-9][a-z0-9-]{2,23}$ ]] \
  || fail 'namePrefix must be 3-24 lowercase letters, numbers, or hyphens and start with a letter or number.'
[[ "${archetype}" == 'corp' || "${archetype}" == 'online' ]] \
  || fail 'workloadArchetype must be corp or online.'

legacy_assignment_name='demo-require-rg-tags'
legacy_definition_name="${prefix}-require-workload-rg-tags"
replacement_initiative_name="${prefix}-required-rg-tags"
demo_root_scope="/providers/Microsoft.Management/managementGroups/${prefix}"
tenant_root_scope="/providers/Microsoft.Management/managementGroups/${tenant_root}"
landing_zones_scope="/providers/Microsoft.Management/managementGroups/${prefix}-landingzones"
workload_scope="/providers/Microsoft.Management/managementGroups/${prefix}-${archetype}"
legacy_definition_id="${demo_root_scope}/providers/Microsoft.Authorization/policyDefinitions/${legacy_definition_name}"
legacy_assignment_id="${workload_scope}/providers/Microsoft.Authorization/policyAssignments/${legacy_assignment_name}"
replacement_initiative_id="${demo_root_scope}/providers/Microsoft.Authorization/policySetDefinitions/${replacement_initiative_name}"
replacement_assignment_id="${landing_zones_scope}/providers/Microsoft.Authorization/policyAssignments/${legacy_assignment_name}"

printf 'LEGACY RESOURCE-GROUP TAG POLICY MIGRATION PLAN\n'
printf '  1. Validate the active tenant/subscription, exact demo ancestry, legacy relationship, and replacement controls.\n'
printf '  2. Remove assignment %s only at %s when it exists.\n' "${legacy_assignment_name}" "${workload_scope}"
printf '  3. Remove custom policy definition %s only from management group %s when it exists.\n' "${legacy_definition_name}" "${prefix}"
printf 'The replacement initiative must be previewed, deployed, and approved before execution.\n'

if [[ "${MODE}" != '--execute' ]]; then
  printf 'Dry run only. Add --execute to perform read-only validation before the documented approval prompts.\n'
  exit 0
fi

command -v az >/dev/null 2>&1 || fail 'Azure CLI is required for execution.'

read_required() {
  local description="$1"
  shift
  local output
  output="$(az "$@" --output json 2>&1)" || fail "Cannot validate ${description}: ${output}"
  printf '%s' "${output}"
}

READ_EXISTS='false'
READ_JSON=''
read_optional() {
  local description="$1"
  local not_found_pattern="$2"
  shift 2
  local output
  if output="$(az "$@" --output json 2>&1)"; then
    READ_EXISTS='true'
    READ_JSON="${output}"
  elif printf '%s' "${output}" | grep -Eq "${not_found_pattern}"; then
    READ_EXISTS='false'
    READ_JSON=''
    printf 'Already absent: %s.\n' "${description}"
  else
    fail "Cannot validate ${description}: ${output}"
  fi
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

active_account="$(read_required 'the active Azure account' account show)"
active_tenant="$(printf '%s' "${active_account}" | jq -er '.tenantId')"
active_subscription="$(printf '%s' "${active_account}" | jq -er '.id')"
[[ "$(printf '%s' "${active_account}" | jq -er '.state')" == 'Enabled' ]] \
  || fail 'The active Azure subscription is not enabled.'
[[ "$(lower "${active_subscription}")" == "$(lower "${connectivity_subscription}")" || "$(lower "${active_subscription}")" == "$(lower "${workload_subscription}")" ]] \
  || fail 'The active Azure subscription is not one of the two subscriptions in the parameter file.'

connectivity_account="$(read_required 'the connectivity subscription' account show --subscription "${connectivity_subscription}")"
workload_account="$(read_required 'the workload subscription' account show --subscription "${workload_subscription}")"
connectivity_tenant="$(printf '%s' "${connectivity_account}" | jq -er '.tenantId')"
workload_tenant="$(printf '%s' "${workload_account}" | jq -er '.tenantId')"
[[ "$(lower "${active_tenant}")" == "$(lower "${connectivity_tenant}")" && "$(lower "${active_tenant}")" == "$(lower "${workload_tenant}")" ]] \
  || fail 'The active account and both supplied subscriptions must belong to the same tenant.'
[[ "$(printf '%s' "${connectivity_account}" | jq -er '.id | ascii_downcase')" == "$(lower "${connectivity_subscription}")" \
  && "$(printf '%s' "${connectivity_account}" | jq -er '.state')" == 'Enabled' ]] \
  || fail 'The connectivity subscription response does not match an enabled supplied subscription.'
[[ "$(printf '%s' "${workload_account}" | jq -er '.id | ascii_downcase')" == "$(lower "${workload_subscription}")" \
  && "$(printf '%s' "${workload_account}" | jq -er '.state')" == 'Enabled' ]] \
  || fail 'The workload subscription response does not match an enabled supplied subscription.'

tenant_root_group="$(read_required 'the tenant root management group' account management-group show --name "${tenant_root}")"
demo_root="$(read_required 'the demo root management group' account management-group show --name "${prefix}")"
landing_zones="$(read_required 'the Landing Zones management group' account management-group show --name "${prefix}-landingzones")"
workload_group="$(read_required 'the workload management group' account management-group show --name "${prefix}-${archetype}")"
[[ "$(printf '%s' "${tenant_root_group}" | jq -er '.id | ascii_downcase')" == "$(lower "${tenant_root_scope}")" ]] \
  || fail 'The tenant root management-group ID does not match tenantRootManagementGroupId.'
[[ "$(printf '%s' "${demo_root}" | jq -er '.id | ascii_downcase')" == "$(lower "${demo_root_scope}")" ]] \
  || fail 'The demo root management-group ID does not match namePrefix.'
[[ "$(printf '%s' "${landing_zones}" | jq -er '.id | ascii_downcase')" == "$(lower "${landing_zones_scope}")" ]] \
  || fail 'The Landing Zones management-group ID does not match namePrefix.'
[[ "$(printf '%s' "${workload_group}" | jq -er '.id | ascii_downcase')" == "$(lower "${workload_scope}")" ]] \
  || fail 'The workload management-group ID does not match namePrefix and workloadArchetype.'
[[ "$(printf '%s' "${demo_root}" | jq -er '.details.parent.id | ascii_downcase')" == "$(lower "${tenant_root_scope}")" ]] \
  || fail 'The demo root is not an exact child of tenantRootManagementGroupId.'
[[ "$(printf '%s' "${landing_zones}" | jq -er '.details.parent.id | ascii_downcase')" == "$(lower "${demo_root_scope}")" ]] \
  || fail 'The Landing Zones management group is not an exact child of the demo root.'
[[ "$(printf '%s' "${workload_group}" | jq -er '.details.parent.id | ascii_downcase')" == "$(lower "${landing_zones_scope}")" ]] \
  || fail 'The workload management group is not an exact child of Landing Zones.'

replacement_initiative="$(read_required 'the replacement tagging initiative' policy set-definition show \
  --name "${replacement_initiative_name}" --management-group "${prefix}")"
[[ "$(printf '%s' "${replacement_initiative}" | jq -er '.id | ascii_downcase')" == "$(lower "${replacement_initiative_id}")" ]] \
  || fail 'The replacement tagging initiative has an unexpected resource ID.'
replacement_assignment="$(read_required 'the replacement Landing Zones assignment' policy assignment show \
  --name "${legacy_assignment_name}" --scope "${landing_zones_scope}")"
[[ "$(printf '%s' "${replacement_assignment}" | jq -er '.id | ascii_downcase')" == "$(lower "${replacement_assignment_id}")" ]] \
  || fail 'The replacement Landing Zones assignment has an unexpected resource ID.'
[[ "$(printf '%s' "${replacement_assignment}" | jq -er '(.policyDefinitionId // .properties.policyDefinitionId) | ascii_downcase')" == "$(lower "${replacement_initiative_id}")" ]] \
  || fail 'The replacement Landing Zones assignment does not reference the replacement tagging initiative.'

read_optional 'legacy workload assignment' 'PolicyAssignmentNotFound|ResourceNotFound' \
  policy assignment show --name "${legacy_assignment_name}" --scope "${workload_scope}"
legacy_assignment_exists="${READ_EXISTS}"
legacy_assignment="${READ_JSON}"
if [[ "${legacy_assignment_exists}" == 'true' ]]; then
  [[ "$(printf '%s' "${legacy_assignment}" | jq -er '.id | ascii_downcase')" == "$(lower "${legacy_assignment_id}")" ]] \
    || fail 'The legacy workload assignment has an unexpected resource ID.'
  [[ "$(printf '%s' "${legacy_assignment}" | jq -er '(.policyDefinitionId // .properties.policyDefinitionId) | ascii_downcase')" == "$(lower "${legacy_definition_id}")" ]] \
    || fail 'The legacy workload assignment does not reference the exact obsolete custom definition.'
fi

read_optional 'obsolete custom tag definition' 'PolicyDefinitionNotFound|ResourceNotFound' \
  policy definition show --name "${legacy_definition_name}" --management-group "${prefix}"
legacy_definition_exists="${READ_EXISTS}"
legacy_definition="${READ_JSON}"
if [[ "${legacy_definition_exists}" == 'true' ]]; then
  [[ "$(printf '%s' "${legacy_definition}" | jq -er '.id | ascii_downcase')" == "$(lower "${legacy_definition_id}")" ]] \
    || fail 'The obsolete custom definition has an unexpected resource ID.'
fi

printf 'Validated active tenant %s and subscription %s; replacement controls are present.\n' \
  "${active_tenant}" "${active_subscription}"
if [[ "${legacy_assignment_exists}" == 'false' && "${legacy_definition_exists}" == 'false' ]]; then
  printf 'Migration already complete; no delete operation is required.\n'
  exit 0
fi

[[ "${ESLZ_TAG_MIGRATION_CONFIRMATION:-}" == 'REMOVE-LEGACY-RG-TAG-POLICY' ]] \
  || fail 'Set ESLZ_TAG_MIGRATION_CONFIRMATION=REMOVE-LEGACY-RG-TAG-POLICY only after reviewing the validated context above.' 2
expected_confirmation="${active_tenant}/${prefix}-${archetype}"
printf 'Type the validated tenant and legacy workload management group (%s) to continue: ' "${expected_confirmation}"
read -r typed_confirmation
[[ "${typed_confirmation}" == "${expected_confirmation}" ]] || fail 'Confirmation did not match; migration cancelled.' 2

if [[ "${legacy_assignment_exists}" == 'true' ]]; then
  az policy assignment delete --name "${legacy_assignment_name}" --scope "${workload_scope}"
fi
if [[ "${legacy_definition_exists}" == 'true' ]]; then
  az policy definition delete --name "${legacy_definition_name}" --management-group "${prefix}"
fi

printf 'Legacy resource-group tag policy migration completed.\n'
