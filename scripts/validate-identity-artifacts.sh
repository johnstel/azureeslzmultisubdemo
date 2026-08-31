#!/usr/bin/env bash
# Static, offline validation of the Entra Conditional Access and PIM demo
# artifacts under identity/. This script never contacts Microsoft Graph or
# any tenant; it only inspects the JSON files that ship in this repository.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
IDENTITY_DIR="${PROJECT_DIR}/identity"

command -v jq >/dev/null 2>&1 || {
  printf 'ERROR: jq is required for identity artifact validation.\n' >&2
  exit 1
}
command -v rg >/dev/null 2>&1 || {
  printf 'ERROR: ripgrep is required for identity artifact validation.\n' >&2
  exit 1
}

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

ca_dir="${IDENTITY_DIR}/conditional-access"
pim_dir="${IDENTITY_DIR}/pim"

[[ -d "${ca_dir}" ]] || fail "Missing directory: ${ca_dir}"
[[ -d "${pim_dir}" ]] || fail "Missing directory: ${pim_dir}"

ca_count=0
for template in "${ca_dir}"/*.template.json; do
  [[ -e "${template}" ]] || fail "No Conditional Access templates found in ${ca_dir}"
  ca_count=$((ca_count + 1))
  name="$(basename "${template}")"

  jq empty "${template}" || fail "${name} is not valid JSON."

  state="$(jq -r '.state' "${template}")"
  [[ "${state}" == "enabledForReportingButNotEnforced" ]] || \
    fail "${name} must default to state=enabledForReportingButNotEnforced (report-only), found '${state}'."

  exclusion_required="$(jq -r '.emergencyAccessExclusion.required' "${template}")"
  [[ "${exclusion_required}" == "true" ]] || \
    fail "${name} must declare emergencyAccessExclusion.required=true."

  placeholder="$(jq -r '.emergencyAccessExclusion.placeholder' "${template}")"
  [[ "${placeholder}" =~ ^REPLACE_WITH_.+$ ]] || \
    fail "${name} emergencyAccessExclusion.placeholder must be a REPLACE_WITH_* input, found '${placeholder}'."

  exclude_count="$(jq '.conditions.users.excludeGroups | length' "${template}")"
  [[ "${exclude_count}" -ge 1 ]] || \
    fail "${name} conditions.users.excludeGroups must not be empty; the emergency-access group must be excluded."

  contains_placeholder="$(jq --arg p "${placeholder}" '[.conditions.users.excludeGroups[] | select(. == $p)] | length' "${template}")"
  [[ "${contains_placeholder}" -ge 1 ]] || \
    fail "${name} conditions.users.excludeGroups must include the declared emergencyAccessExclusion.placeholder."

  notes="$(jq -r '.notes' "${template}")"
  [[ -n "${notes}" ]] || fail "${name} must document rollout/licensing notes."
done
printf 'Conditional Access templates validated: %s\n' "${ca_count}"

pim_count=0
for template in "${pim_dir}"/*.template.json; do
  [[ -e "${template}" ]] || fail "No PIM templates found in ${pim_dir}"
  pim_count=$((pim_count + 1))
  name="$(basename "${template}")"

  jq empty "${template}" || fail "${name} is not valid JSON."

  assignment_type="$(jq -r '.assignmentType' "${template}")"
  [[ "${assignment_type}" == "eligible" ]] || \
    fail "${name} assignmentType must be 'eligible' (never permanent), found '${assignment_type}'."

  for bool_field in .activation.requireApproval .activation.requireMultiFactorAuthentication \
    .activation.requireJustification .notifications.notifyAdminsOnActivation \
    .notifications.notifyApproversOnActivationRequest .notifications.notifyAssigneeOnActivation; do
    value="$(jq -r "${bool_field}" "${template}")"
    [[ "${value}" == "true" ]] || fail "${name} ${bool_field} must be true."
  done

  approver_count="$(jq '.activation.approvers | length' "${template}")"
  [[ "${approver_count}" -ge 1 ]] || fail "${name} activation.approvers must not be empty."

  duration="$(jq -r '.activation.maximumActivationDurationHours' "${template}")"
  [[ "${duration}" =~ ^[0-9]+$ ]] && [[ "${duration}" -ge 1 ]] && [[ "${duration}" -le 8 ]] || \
    fail "${name} activation.maximumActivationDurationHours must be an integer between 1 and 8, found '${duration}'."

  auth_context="$(jq -r '.activation.authenticationContext' "${template}")"
  [[ -n "${auth_context}" ]] || fail "${name} activation.authenticationContext must be set."

  exclusion_required="$(jq -r '.emergencyAccessExclusion.required' "${template}")"
  [[ "${exclusion_required}" == "true" ]] || \
    fail "${name} must declare emergencyAccessExclusion.required=true."

  placeholder="$(jq -r '.emergencyAccessExclusion.placeholder' "${template}")"
  [[ "${placeholder}" =~ ^REPLACE_WITH_.+$ ]] || \
    fail "${name} emergencyAccessExclusion.placeholder must be a REPLACE_WITH_* input, found '${placeholder}'."

  notes="$(jq -r '.notes' "${template}")"
  [[ -n "${notes}" ]] || fail "${name} must document rollout/licensing notes."
done
printf 'PIM activation templates validated: %s\n' "${pim_count}"

# Confirm no tenant-specific identifiers (GUIDs) leak into any identity
# artifact, other than the well-known, publicly documented first-party
# "Microsoft Azure Management" application ID.
guid_pattern='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
if rg -no -e "${guid_pattern}" "${IDENTITY_DIR}" -g '*.json' | \
  rg -v '797f4846-ba00-4fd7-ba43-dac1f8f63013'; then
  fail "A tenant-specific GUID was found in identity/. Replace it with a REPLACE_WITH_* placeholder."
fi

printf 'Identity artifact validation passed: %s Conditional Access template(s), %s PIM template(s).\n' \
  "${ca_count}" "${pim_count}"
