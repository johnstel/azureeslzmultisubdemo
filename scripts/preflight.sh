#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PARAMETER_FILE="${1:-${PROJECT_DIR}/parameters/demo.parameters.json}"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command '$1' is not installed."
}

parameter_value() {
  jq -er --arg name "$1" '.parameters[$name].value' "${PARAMETER_FILE}"
}

is_guid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

require_command az
require_command jq
[[ -f "${PARAMETER_FILE}" ]] || fail "Parameter file not found: ${PARAMETER_FILE}"

jq -e '.parameters | type == "object"' "${PARAMETER_FILE}" >/dev/null \
  || fail 'Parameter file is not an ARM deployment-parameters JSON document.'

if jq -e '.. | strings | select(contains("REPLACE_WITH_"))' "${PARAMETER_FILE}" >/dev/null; then
  fail 'Parameter file still contains REPLACE_WITH_* placeholders.'
fi

tenant_root="$(parameter_value tenantRootManagementGroupId)"
name_prefix="$(parameter_value namePrefix)"
connectivity_subscription="$(parameter_value connectivitySubscriptionId)"
workload_subscription="$(parameter_value workloadSubscriptionId)"
deployment_location="$(parameter_value deploymentLocation)"

[[ "${name_prefix}" =~ ^[a-z0-9][a-z0-9-]{1,22}[a-z0-9]$ ]] \
  || fail 'namePrefix must be 3-24 lowercase letters, numbers, or hyphens, with no leading/trailing hyphen.'

is_guid "${connectivity_subscription}" || fail 'connectivitySubscriptionId is not a GUID.'
is_guid "${workload_subscription}" || fail 'workloadSubscriptionId is not a GUID.'
normalized_connectivity_subscription="$(printf '%s' "${connectivity_subscription}" | tr '[:upper:]' '[:lower:]')"
normalized_workload_subscription="$(printf '%s' "${workload_subscription}" | tr '[:upper:]' '[:lower:]')"
[[ "${normalized_connectivity_subscription}" != "${normalized_workload_subscription}" ]] \
  || fail 'The connectivity and workload subscription IDs must be different.'

group_parameters=(
  governanceAdminsGroupObjectId
  networkOperatorsGroupObjectId
  workloadContributorsGroupObjectId
  readOnlyAuditorsGroupObjectId
)

seen_group_ids=()
seen_group_parameters=()
for group_parameter in "${group_parameters[@]}"; do
  group_id="$(parameter_value "${group_parameter}")"
  is_guid "${group_id}" || fail "${group_parameter} is not a GUID."
  normalized_group_id="$(printf '%s' "${group_id}" | tr '[:upper:]' '[:lower:]')"
  for index in "${!seen_group_ids[@]}"; do
    [[ "${normalized_group_id}" != "${seen_group_ids[${index}]}" ]] \
      || fail "${group_parameter} duplicates ${seen_group_parameters[${index}]}; use five distinct least-privilege groups."
  done
  seen_group_ids+=("${normalized_group_id}")
  seen_group_parameters+=("${group_parameter}")
done

printf 'Building Bicep locally...\n'
az bicep build --file "${PROJECT_DIR}/main.bicep" --stdout >/dev/null

printf 'Checking Azure sign-in and supplied scopes (read-only)...\n'
account_json="$(az account show --output json 2>/dev/null)" \
  || fail 'Azure CLI is not signed in. Run az login --tenant <tenant-guid>.'
signed_in_tenant="$(jq -r '.tenantId' <<<"${account_json}")"

check_subscription() {
  local subscription_id="$1"
  local label="$2"
  local subscription_json
  subscription_json="$(az account show --subscription "${subscription_id}" --output json 2>/dev/null)" \
    || fail "Cannot read the ${label} subscription ${subscription_id}."
  local state
  state="$(jq -r '.state' <<<"${subscription_json}")"
  local tenant_id
  tenant_id="$(jq -r '.tenantId' <<<"${subscription_json}")"
  [[ "${state}" == 'Enabled' ]] || fail "${label} subscription state is '${state}', not Enabled."
  normalized_subscription_tenant="$(printf '%s' "${tenant_id}" | tr '[:upper:]' '[:lower:]')"
  normalized_signed_in_tenant="$(printf '%s' "${signed_in_tenant}" | tr '[:upper:]' '[:lower:]')"
  [[ "${normalized_subscription_tenant}" == "${normalized_signed_in_tenant}" ]] \
    || fail "${label} subscription belongs to tenant ${tenant_id}, but the active tenant is ${signed_in_tenant}."
}

check_subscription "${connectivity_subscription}" 'connectivity'
check_subscription "${workload_subscription}" 'workload'

az account management-group show --name "${tenant_root}" --output none 2>/dev/null \
  || fail "Cannot read tenant-root management group '${tenant_root}'. Check the ID and tenant permissions."

printf '\nPreflight passed.\n'
printf '  Active tenant: %s\n' "${signed_in_tenant}"
printf '  Tenant root MG: %s\n' "${tenant_root}"
printf '  Connectivity subscription: %s\n' "${connectivity_subscription}"
printf '  Workload subscription: %s\n' "${workload_subscription}"
printf '  Tenant deployment location: %s\n' "${deployment_location}"
printf '  Entra group IDs: GUID format and uniqueness verified where supplied (directory group type is not queried).\n'
