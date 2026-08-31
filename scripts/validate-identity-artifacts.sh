#!/usr/bin/env bash
# Static, offline validation of the Entra Conditional Access and PIM demo
# artifacts. This script never contacts Microsoft Graph or any tenant; it
# only inspects JSON files on local disk.
#
# Usage:
#   validate-identity-artifacts.sh [--mode template|populated] [--path DIR]
#
#   --mode template (default): validates the committed templates under
#     identity/. Every emergencyAccessExclusion.placeholder (and every
#     approvers/excludeGroups entry that must equal it) must still be an
#     unpopulated REPLACE_WITH_* value, and no tenant-specific GUID may
#     appear anywhere (only the public, well-known Microsoft constants in
#     identity/schema/known-entra-ids.json are allowed).
#   --mode populated: validates a local, gitignored copy of these artifacts
#     after an operator has replaced every REPLACE_WITH_* placeholder with a
#     real object ID, in preparation for a future, separately gated apply
#     workflow. In this mode every placeholder must be a syntactically valid
#     GUID (not left as REPLACE_WITH_*, not empty), and the tenant-GUID
#     allowlist check is skipped because populated input is expected to
#     contain real tenant identifiers. --path must point away from the
#     tracked identity/ folder in this mode so populated, tenant-specific
#     values are never committed.
#   --path DIR (default: <repo>/identity): directory containing
#     conditional-access/ and pim/ subdirectories to validate.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

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

# bash 3.2 (stock macOS) has no `mapfile`/`readarray` builtin, so read
# newline-delimited command output into an array with a plain while-read
# loop instead. Usage: read_lines_into array_name < <(command)
read_lines_into() {
  local __array_name="$1"
  eval "${__array_name}=()"
  local __line
  while IFS= read -r __line; do
    eval "${__array_name}+=(\"\${__line}\")"
  done
}

mode='template'
identity_dir="${PROJECT_DIR}/identity"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      mode="${2:-}"
      shift 2
      ;;
    --path)
      identity_dir="${2:-}"
      shift 2
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

case "${mode}" in
  template|populated) ;;
  *) fail "--mode must be 'template' or 'populated', found '${mode}'." ;;
esac

if [[ "${mode}" == "populated" ]]; then
  case "${identity_dir}" in
    "${PROJECT_DIR}/identity"|"${PROJECT_DIR}/identity"/*)
      fail "--mode populated must validate a path outside the tracked identity/ folder so real object IDs are never committed. Copy identity/ to a local, gitignored location first."
      ;;
  esac
fi

known_ids_file="${PROJECT_DIR}/identity/schema/known-entra-ids.json"
[[ -f "${known_ids_file}" ]] || fail "Missing reference file: ${known_ids_file}"

guid_pattern='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
is_guid() { [[ "$1" =~ $guid_pattern ]]; }

phishing_resistant_id="$(jq -r '.authenticationStrengthPolicyIds["Phishing-resistant MFA"]' "${known_ids_file}")"
azure_mgmt_app_id="$(jq -r '.wellKnownServicePrincipalAppIds["Microsoft Azure Management"]' "${known_ids_file}")"
read_lines_into known_role_ids < <(jq -r '.directoryRoleTemplateIds[]' "${known_ids_file}")
read_lines_into known_auth_strength_ids < <(jq -r '.authenticationStrengthPolicyIds[]' "${known_ids_file}")

is_known_role_id() {
  local candidate="$1" known
  for known in "${known_role_ids[@]}"; do
    [[ "${candidate}" == "${known}" ]] && return 0
  done
  return 1
}

ca_dir="${identity_dir}/conditional-access"
pim_dir="${identity_dir}/pim"

[[ -d "${ca_dir}" ]] || fail "Missing directory: ${ca_dir}"
[[ -d "${pim_dir}" ]] || fail "Missing directory: ${pim_dir}"

# Validates emergencyAccessExclusion.required and .placeholder against the
# active mode. Sets the shared $placeholder variable for optional follow-up
# containment checks (see check_placeholder_excluded_from).
check_emergency_placeholder() {
  local template="$1" name="$2"

  exclusion_required="$(jq -r '.emergencyAccessExclusion.required' "${template}")"
  [[ "${exclusion_required}" == "true" ]] || \
    fail "${name} must declare emergencyAccessExclusion.required=true."

  placeholder="$(jq -r '.emergencyAccessExclusion.placeholder' "${template}")"
  if [[ "${mode}" == "template" ]]; then
    [[ "${placeholder}" =~ ^REPLACE_WITH_.+$ ]] || \
      fail "${name} emergencyAccessExclusion.placeholder must be an unpopulated REPLACE_WITH_* input in template mode, found '${placeholder}'."
  else
    [[ "${placeholder}" =~ ^REPLACE_WITH_.+$ ]] && \
      fail "${name} emergencyAccessExclusion.placeholder still contains an unpopulated REPLACE_WITH_* value; replace it with a real object ID before populated-mode validation."
    is_guid "${placeholder}" || \
      fail "${name} emergencyAccessExclusion.placeholder must be a valid object ID (GUID) in populated mode, found '${placeholder}'."
  fi
}

# Confirms the emergencyAccessExclusion.placeholder (set by
# check_emergency_placeholder above) is actually excluded via the given
# array field, e.g. conditions.users.excludeGroups for Conditional Access.
check_placeholder_excluded_from() {
  local template="$1" name="$2" array_field="$3"

  array_count="$(jq "[.${array_field}[]] | length" "${template}")"
  [[ "${array_count}" -ge 1 ]] || \
    fail "${name} ${array_field} must not be empty; the emergency-access placeholder must be excluded."

  contains_placeholder="$(jq --arg p "${placeholder}" "[.${array_field}[] | select(. == \$p)] | length" "${template}")"
  [[ "${contains_placeholder}" -ge 1 ]] || \
    fail "${name} ${array_field} must include the declared emergencyAccessExclusion.placeholder."
}


ca_count=0
for template in "${ca_dir}"/*.template.json; do
  [[ -e "${template}" ]] || fail "No Conditional Access templates found in ${ca_dir}"
  ca_count=$((ca_count + 1))
  name="$(basename "${template}")"

  jq empty "${template}" || fail "${name} is not valid JSON."

  state="$(jq -r '.state' "${template}")"
  [[ "${state}" == "enabledForReportingButNotEnforced" ]] || \
    fail "${name} must default to state=enabledForReportingButNotEnforced (report-only), found '${state}'."

  check_emergency_placeholder "${template}" "${name}"
  check_placeholder_excluded_from "${template}" "${name}" 'conditions.users.excludeGroups'

  # Subject (conditions.users): must use Graph-compatible values. Either
  # includeUsers (only 'All', 'None', 'GuestsOrExternalUsers', or a GUID) or
  # includeRoles (only GUID directory role template IDs from the known-IDs
  # allowlist) must be present; free-text role display names such as
  # "Global Administrator" or the non-Graph value "All users" are rejected.
  include_users_present="$(jq '.conditions.users | has("includeUsers")' "${template}")"
  include_roles_present="$(jq '.conditions.users | has("includeRoles")' "${template}")"
  [[ "${include_users_present}" == "true" || "${include_roles_present}" == "true" ]] || \
    fail "${name} conditions.users must declare includeUsers or includeRoles."

  if [[ "${include_users_present}" == "true" ]]; then
    read_lines_into include_users < <(jq -r '.conditions.users.includeUsers[]' "${template}")
    [[ "${#include_users[@]}" -ge 1 ]] || fail "${name} conditions.users.includeUsers must not be empty."
    for value in "${include_users[@]}"; do
      case "${value}" in
        All|None|GuestsOrExternalUsers) ;;
        *)
          is_guid "${value}" || fail "${name} conditions.users.includeUsers entry '${value}' must be 'All', 'None', 'GuestsOrExternalUsers', or a user object ID (GUID)."
          ;;
      esac
    done
  fi

  if [[ "${include_roles_present}" == "true" ]]; then
    read_lines_into include_roles < <(jq -r '.conditions.users.includeRoles[]' "${template}")
    [[ "${#include_roles[@]}" -ge 1 ]] || fail "${name} conditions.users.includeRoles must not be empty."
    for value in "${include_roles[@]}"; do
      is_guid "${value}" || \
        fail "${name} conditions.users.includeRoles entry '${value}' must be a directory role template ID (GUID), not a display name or 'All users'."
      is_known_role_id "${value}" || \
        fail "${name} conditions.users.includeRoles entry '${value}' is not a known directory role template ID from identity/schema/known-entra-ids.json."
    done
  fi

  # Application scope must be present and non-empty.
  application_count="$(jq '.conditions.applications.includeApplications | length' "${template}")"
  [[ "${application_count}" -ge 1 ]] || fail "${name} conditions.applications.includeApplications must not be empty."

  # Client app types must be present and non-empty.
  client_app_type_count="$(jq '.conditions.clientAppTypes | length' "${template}")"
  [[ "${client_app_type_count}" -ge 1 ]] || fail "${name} conditions.clientAppTypes must not be empty."

  # Grant controls: authenticationStrength must be modeled as its own Graph
  # relationship object (id + displayName), never as a builtInControls
  # string entry.
  if rg -q '"authenticationStrength"' <(jq '.grantControls.builtInControls // []' "${template}"); then
    fail "${name} grantControls.builtInControls must not contain 'authenticationStrength'; use the grantControls.authenticationStrength relationship object instead."
  fi
  built_in_controls_present="$(jq '.grantControls | has("builtInControls")' "${template}")"
  authentication_strength_present="$(jq '.grantControls | has("authenticationStrength")' "${template}")"
  [[ "${built_in_controls_present}" == "true" || "${authentication_strength_present}" == "true" ]] || \
    fail "${name} grantControls must declare builtInControls or authenticationStrength."
  if [[ "${authentication_strength_present}" == "true" ]]; then
    auth_strength_id="$(jq -r '.grantControls.authenticationStrength.id' "${template}")"
    is_known_id=false
    for known in "${known_auth_strength_ids[@]}"; do
      [[ "${auth_strength_id}" == "${known}" ]] && is_known_id=true
    done
    [[ "${is_known_id}" == true ]] || \
      fail "${name} grantControls.authenticationStrength.id '${auth_strength_id}' is not a known built-in authenticationStrengthPolicy id from identity/schema/known-entra-ids.json."
  fi

  # Policy-specific semantic checks, keyed by the known template filenames.
  case "${name}" in
    ca-privileged-role-mfa.template.json)
      [[ "${include_roles_present}" == "true" ]] || \
        fail "${name} must scope the subject with conditions.users.includeRoles (privileged directory roles)."
      apps_all="$(jq '[.conditions.applications.includeApplications[] | select(. == "All")] | length' "${template}")"
      [[ "${apps_all}" -ge 1 ]] || fail "${name} conditions.applications.includeApplications must include 'All'."
      client_all="$(jq '[.conditions.clientAppTypes[] | select(. == "all")] | length' "${template}")"
      [[ "${client_all}" -ge 1 ]] || fail "${name} conditions.clientAppTypes must include 'all'."
      [[ "${authentication_strength_present}" == "true" ]] || \
        fail "${name} grantControls.authenticationStrength must be set."
      [[ "${auth_strength_id}" == "${phishing_resistant_id}" ]] || \
        fail "${name} grantControls.authenticationStrength.id must reference the built-in Phishing-resistant MFA policy (${phishing_resistant_id})."
      ;;
    ca-azure-mgmt-mfa.template.json)
      [[ "${include_users_present}" == "true" ]] || \
        fail "${name} must scope the subject to all users with conditions.users.includeUsers."
      users_all="$(jq '.conditions.users.includeUsers == ["All"]' "${template}")"
      [[ "${users_all}" == "true" ]] || fail "${name} conditions.users.includeUsers must equal [\"All\"]."
      app_scoped="$(jq --arg id "${azure_mgmt_app_id}" '[.conditions.applications.includeApplications[] | select(. == $id)] | length' "${template}")"
      [[ "${app_scoped}" -ge 1 ]] || \
        fail "${name} conditions.applications.includeApplications must include the Microsoft Azure Management application id (${azure_mgmt_app_id})."
      mfa_control="$(jq '[.grantControls.builtInControls[]? | select(. == "mfa")] | length' "${template}")"
      [[ "${mfa_control}" -ge 1 ]] || fail "${name} grantControls.builtInControls must include 'mfa'."
      ;;
    ca-block-legacy-auth.template.json)
      [[ "${include_users_present}" == "true" ]] || \
        fail "${name} must scope the subject to all users with conditions.users.includeUsers."
      users_all="$(jq '.conditions.users.includeUsers == ["All"]' "${template}")"
      [[ "${users_all}" == "true" ]] || fail "${name} conditions.users.includeUsers must equal [\"All\"]."
      non_legacy_client_types="$(jq '[.conditions.clientAppTypes[] | select(. != "exchangeActiveSync" and . != "other")] | length' "${template}")"
      [[ "${non_legacy_client_types}" -eq 0 ]] || \
        fail "${name} conditions.clientAppTypes must only contain legacy client types (exchangeActiveSync, other)."
      block_control="$(jq '[.grantControls.builtInControls[]? | select(. == "block")] | length' "${template}")"
      [[ "${block_control}" -ge 1 ]] || fail "${name} grantControls.builtInControls must include 'block'."
      ;;
  esac

  notes="$(jq -r '.notes' "${template}")"
  [[ -n "${notes}" ]] || fail "${name} must document rollout/licensing notes."
done
printf 'Conditional Access templates validated (mode=%s): %s\n' "${mode}" "${ca_count}"

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

  check_emergency_placeholder "${template}" "${name}"

  notes="$(jq -r '.notes' "${template}")"
  [[ -n "${notes}" ]] || fail "${name} must document rollout/licensing notes."
done
printf 'PIM activation templates validated (mode=%s): %s\n' "${mode}" "${pim_count}"

if [[ "${mode}" == "template" ]]; then
  # Confirm no tenant-specific identifiers (GUIDs) leak into any identity
  # artifact, other than the well-known, publicly documented Microsoft
  # constants in identity/schema/known-entra-ids.json.
  read_lines_into allowed_guids < <(jq -r '[.directoryRoleTemplateIds[], .authenticationStrengthPolicyIds[], .wellKnownServicePrincipalAppIds[]] | .[]' "${known_ids_file}")
  guid_pattern_global='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
  allow_filter_args=()
  for allowed in "${allowed_guids[@]}"; do
    allow_filter_args+=(-e ":${allowed}\$")
  done
  if rg -no -e "${guid_pattern_global}" "${identity_dir}" -g '*.json' | \
    rg -v "${allow_filter_args[@]}"; then
    fail "A tenant-specific GUID was found in ${identity_dir}. Replace it with a REPLACE_WITH_* placeholder, or add it to identity/schema/known-entra-ids.json only if it is a public Microsoft constant."
  fi
fi

printf 'Identity artifact validation passed (mode=%s): %s Conditional Access template(s), %s PIM template(s).\n' \
  "${mode}" "${ca_count}" "${pim_count}"
