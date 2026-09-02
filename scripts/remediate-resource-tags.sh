#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PARAMETER_FILE="${1:-${PROJECT_DIR}/parameters/demo.parameters.json}"
MODE="${2:-preview}"
ASSIGNMENT_NAME='demo-inherit-rg-tags'
BUILT_IN_ID='/providers/Microsoft.Authorization/policyDefinitions/ea3f2387-9b95-492a-a190-fcdc54f7b070'
CONFIRMATION='REMEDIATE-MISSING-RESOURCE-TAGS'

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit "${2:-1}"
}

[[ -f "${PARAMETER_FILE}" ]] || fail "Parameter file not found: ${PARAMETER_FILE}"
[[ "${MODE}" == 'preview' || "${MODE}" == '--execute' ]] || fail 'Mode must be preview or --execute.'
command -v az >/dev/null 2>&1 || fail 'Azure CLI is required for validation.'
command -v jq >/dev/null 2>&1 || fail 'jq is required for validation.'

value() {
  jq -er --arg name "$1" '.parameters[$name].value' "${PARAMETER_FILE}"
}

prefix="$(value namePrefix)"
[[ "${prefix}" =~ ^[a-z0-9][a-z0-9-]{2,23}$ ]] \
  || fail 'namePrefix must be 3-24 lowercase letters, numbers, or hyphens and start with a letter or number.'
[[ "$(value enableTagInheritance)" == 'true' ]] \
  || fail 'enableTagInheritance must be true before remediation can be previewed.'

demo_root_scope="/providers/Microsoft.Management/managementGroups/${prefix}"
landing_zones_name="${prefix}-landingzones"
landing_zones_scope="/providers/Microsoft.Management/managementGroups/${landing_zones_name}"
initiative_name="${prefix}-inherit-rg-tags"
initiative_id="${demo_root_scope}/providers/Microsoft.Authorization/policySetDefinitions/${initiative_name}"
assignment_id="${landing_zones_scope}/providers/Microsoft.Authorization/policyAssignments/${ASSIGNMENT_NAME}"

read_azure() {
  local description="$1"
  shift
  local output
  output="$(az "$@" --output json 2>&1)" || fail "Cannot validate ${description}: ${output}"
  printf '%s' "${output}"
}

validate_live_controls() {
  local active_account landing_zones initiative assignment
  active_account="$(read_azure 'the active Azure account' account show)"
  active_tenant="$(printf '%s' "${active_account}" | jq -er '.tenantId')"

  landing_zones="$(read_azure 'the Landing Zones management group' account management-group show --name "${landing_zones_name}")"
  printf '%s' "${landing_zones}" | jq -e \
    --arg id "${landing_zones_scope}" \
    --arg parent "${demo_root_scope}" \
    '(.id | ascii_downcase) == ($id | ascii_downcase)
      and (.details.parent.id | ascii_downcase) == ($parent | ascii_downcase)' >/dev/null \
    || fail 'The Landing Zones management group ID or parent is not the expected deployment scope.'

  initiative="$(read_azure 'the tag-inheritance initiative' policy set-definition show \
    --name "${initiative_name}" --management-group "${prefix}")"
  printf '%s' "${initiative}" | jq -e \
    --arg id "${initiative_id}" \
    --arg built_in "${BUILT_IN_ID}" '
      [
        { id: "inherit-cost-center", tag: "CostCenter" },
        { id: "inherit-application-name", tag: "ApplicationName" },
        { id: "inherit-owner", tag: "Owner" },
        { id: "inherit-environment", tag: "Environment" },
        { id: "inherit-data-classification", tag: "DataClassification" },
        { id: "inherit-ssp-id", tag: "SSP-ID" }
      ] as $expected |
      (.id | ascii_downcase) == ($id | ascii_downcase) and
      (.policyDefinitions // .properties.policyDefinitions // []) as $references |
      ($references | length) == 6 and
      ([$references[] | { id: .policyDefinitionReferenceId, tag: .parameters.tagName.value }] | sort_by(.id)) ==
        ($expected | sort_by(.id)) and
      all($references[];
        (.policyDefinitionId | ascii_downcase) == ($built_in | ascii_downcase) and
        .definitionVersion == "1.*.*")
    ' >/dev/null || fail 'The initiative is not the exact six-reference missing-only tag control.'

  assignment="$(read_azure 'the tag-inheritance assignment' policy assignment show \
    --name "${ASSIGNMENT_NAME}" --scope "${landing_zones_scope}")"
  printf '%s' "${assignment}" | jq -e \
    --arg id "${assignment_id}" \
    --arg initiative "${initiative_id}" '
      (.id | ascii_downcase) == ($id | ascii_downcase) and
      ((.policyDefinitionId // .properties.policyDefinitionId) | ascii_downcase) ==
        ($initiative | ascii_downcase) and
      (.identity.type == "SystemAssigned") and
      ((.location // "") | length) > 0 and
      ((.location // "") | ascii_downcase) != "global" and
      ((.notScopes // .properties.notScopes // []) | length) == 0
    ' >/dev/null || fail 'The assignment ID, scope, initiative, identity, or location is not the expected safe shape.'
}

validate_live_controls
expected_confirmation="${active_tenant}/${landing_zones_name}/${ASSIGNMENT_NAME}"

printf 'TAG-INHERITANCE REMEDIATION PLAN\n'
printf '  Assignment: %s\n' "${assignment_id}"
printf '  Scope: %s\n' "${landing_zones_scope}"
printf '  References: inherit-cost-center, inherit-application-name, inherit-owner, inherit-environment, inherit-data-classification, inherit-ssp-id\n'

if [[ "${MODE}" != '--execute' ]]; then
  printf 'Preview only; no remediation task was created. Re-run with --execute after approval.\n'
  exit 0
fi

[[ "${ESLZ_TAG_REMEDIATION_CONFIRMATION:-}" == "${CONFIRMATION}" ]] \
  || fail "--execute requires ESLZ_TAG_REMEDIATION_CONFIRMATION=${CONFIRMATION}." 2
printf 'Type the validated tenant, scope, and assignment (%s) to continue: ' "${expected_confirmation}"
IFS= read -r typed_confirmation
[[ "${typed_confirmation}" == "${expected_confirmation}" ]] \
  || fail 'Confirmation did not match; remediation cancelled.' 2

validate_live_controls
[[ "${active_tenant}/${landing_zones_name}/${ASSIGNMENT_NAME}" == "${expected_confirmation}" ]] \
  || fail 'Validated context changed after confirmation; remediation cancelled.'

for reference in \
  inherit-cost-center \
  inherit-application-name \
  inherit-owner \
  inherit-environment \
  inherit-data-classification \
  inherit-ssp-id
do
  az policy remediation create \
    --management-group "${landing_zones_name}" \
    --name "tag-${reference}" \
    --policy-assignment "${assignment_id}" \
    --definition-reference-id "${reference}"
done

printf 'Submitted six tag-inheritance remediation tasks.\n'
