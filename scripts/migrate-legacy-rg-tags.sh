#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PARAMETER_FILE="${1:-${PROJECT_DIR}/parameters/demo.parameters.json}"
MODE="${2:-preview}"

[[ -f "${PARAMETER_FILE}" ]] || {
  printf 'ERROR: Parameter file not found: %s\n' "${PARAMETER_FILE}" >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  printf 'ERROR: jq is required.\n' >&2
  exit 1
}
[[ "${MODE}" == 'preview' || "${MODE}" == '--execute' ]] || {
  printf 'ERROR: Mode must be preview or --execute.\n' >&2
  exit 1
}

prefix="$(jq -er '.parameters.namePrefix.value' "${PARAMETER_FILE}")"
archetype="$(jq -er '.parameters.workloadArchetype.value' "${PARAMETER_FILE}")"
[[ "${prefix}" =~ ^[a-z0-9][a-z0-9-]{2,23}$ ]] || {
  printf 'ERROR: namePrefix must be 3-24 lowercase letters, numbers, or hyphens and start with a letter or number.\n' >&2
  exit 1
}
[[ "${archetype}" == 'corp' || "${archetype}" == 'online' ]] || {
  printf 'ERROR: workloadArchetype must be corp or online.\n' >&2
  exit 1
}

legacy_assignment_name='demo-require-rg-tags'
legacy_assignment_scope="/providers/Microsoft.Management/managementGroups/${prefix}-${archetype}"
legacy_definition_name="${prefix}-require-workload-rg-tags"

printf 'LEGACY RESOURCE-GROUP TAG POLICY MIGRATION PLAN\n'
printf '  1. Remove assignment %s only at %s.\n' "${legacy_assignment_name}" "${legacy_assignment_scope}"
printf '  2. Remove custom policy definition %s only from management group %s.\n' "${legacy_definition_name}" "${prefix}"
printf 'The replacement initiative must be previewed, deployed, and approved before execution.\n'

if [[ "${MODE}" != '--execute' ]]; then
  printf 'Dry run only. Add --execute and the documented confirmation after replacement approval.\n'
  exit 0
fi

command -v az >/dev/null 2>&1 || {
  printf 'ERROR: Azure CLI is required for execution.\n' >&2
  exit 1
}
if [[ "${ESLZ_TAG_MIGRATION_CONFIRMATION:-}" != 'REMOVE-LEGACY-RG-TAG-POLICY' ]]; then
  printf 'ERROR: Set ESLZ_TAG_MIGRATION_CONFIRMATION=REMOVE-LEGACY-RG-TAG-POLICY only after replacement approval.\n' >&2
  exit 2
fi

expected_confirmation="${prefix}-${archetype}"
printf 'Type the legacy workload management group ID (%s) to continue: ' "${expected_confirmation}"
read -r typed_confirmation
[[ "${typed_confirmation}" == "${expected_confirmation}" ]] || {
  printf 'Confirmation did not match; migration cancelled.\n' >&2
  exit 2
}

az policy assignment delete --name "${legacy_assignment_name}" --scope "${legacy_assignment_scope}"
az policy definition delete --name "${legacy_definition_name}" --management-group "${prefix}"

printf 'Legacy resource-group tag policy artifacts removed.\n'
