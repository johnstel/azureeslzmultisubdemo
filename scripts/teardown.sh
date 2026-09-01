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
command -v az >/dev/null 2>&1 || {
  printf 'ERROR: Azure CLI is required.\n' >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  printf 'ERROR: jq is required.\n' >&2
  exit 1
}

value() {
  jq -er --arg name "$1" '.parameters[$name].value' "${PARAMETER_FILE}"
}

tenant_root="$(value tenantRootManagementGroupId)"
prefix="$(value namePrefix)"
archetype="$(value workloadArchetype)"
connectivity_subscription="$(value connectivitySubscriptionId)"
workload_subscription="$(value workloadSubscriptionId)"
governance_group="$(value governanceAdminsGroupObjectId)"
network_group="$(value networkOperatorsGroupObjectId)"
workload_group="$(value workloadContributorsGroupObjectId)"
auditors_group="$(value readOnlyAuditorsGroupObjectId)"
# PIM eligibility removal requires a separately reviewed AdminRemove request and
# is intentionally never inferred or automated by this teardown script.
eligible_owner_enabled="$(jq -r '.parameters.deployEligibleOwnerRoleAssignments.value // false' "${PARAMETER_FILE}")"
# Optional: defaults to false when absent so older parameter files remain safe to tear down.
central_log_analytics_enabled="$(jq -r '.parameters.deployCentralLogAnalytics.value // false' "${PARAMETER_FILE}")"
# Optional: resource ID of a customer-supplied existing Log Analytics workspace. Its
# subscription and resource group are read-only protected inputs and must never be deleted
# by this script, regardless of any naming collision with a generated resource group name.
existing_workspace_resource_id="$(jq -r '.parameters.existingLogAnalyticsWorkspaceResourceId.value // empty' "${PARAMETER_FILE}")"
existing_workspace_subscription=''
existing_workspace_resource_group=''
if [[ -n "${existing_workspace_resource_id}" ]]; then
  # Resource ID shape: /subscriptions/<sub>/resourceGroups/<rg>/providers/<ns>/<type>/<name>
  existing_workspace_subscription="$(printf '%s\n' "${existing_workspace_resource_id}" | cut -d'/' -f3)"
  existing_workspace_resource_group="$(printf '%s\n' "${existing_workspace_resource_id}" | cut -d'/' -f5)"
fi
critical_enabled="$(jq -r '.parameters.enableCriticalInfrastructure.value // false' "${PARAMETER_FILE}")"
critical_subscriptions=()
while IFS= read -r critical_subscription_id; do
  [[ -n "${critical_subscription_id}" ]] && critical_subscriptions+=("${critical_subscription_id}")
done < <(jq -r '.parameters.criticalInfrastructureSubscriptionIds.value // [] | .[]' "${PARAMETER_FILE}")

demo_root_scope="/providers/Microsoft.Management/managementGroups/${prefix}"
platform_scope="/providers/Microsoft.Management/managementGroups/${prefix}-platform"
workload_scope="/providers/Microsoft.Management/managementGroups/${prefix}-${archetype}"
connectivity_scope="/subscriptions/${connectivity_subscription}"
subscription_workload_scope="/subscriptions/${workload_subscription}"
monitoring_resource_group="rg-${prefix}-monitoring"
# The monitoring resource group is only repository-owned (and thus safe to delete) when a
# new workspace was requested without also supplying an existing workspace resource ID. This
# mirrors the conflict guard in modules/central-monitoring.bicep: a conflicting configuration
# (deployCentralLogAnalytics=true AND a non-empty existingLogAnalyticsWorkspaceResourceId)
# never creates a monitoring resource group there, so teardown must not delete one either.
monitoring_group_is_repo_owned='false'
if [[ "${central_log_analytics_enabled}" == 'true' && -z "${existing_workspace_resource_id}" ]]; then
  monitoring_group_is_repo_owned='true'
fi

# Returns success (0) when the given subscription/resource-group pair matches the supplied
# existing workspace's subscription/resource group, meaning it must never be deleted here.
is_protected_existing_workspace_group() {
  local subscription="$1"
  local group="$2"
  [[ -n "${existing_workspace_resource_group}" ]] || return 1
  local subscription_lower group_lower existing_sub_lower existing_group_lower
  subscription_lower="$(printf '%s' "${subscription}" | tr '[:upper:]' '[:lower:]')"
  group_lower="$(printf '%s' "${group}" | tr '[:upper:]' '[:lower:]')"
  existing_sub_lower="$(printf '%s' "${existing_workspace_subscription}" | tr '[:upper:]' '[:lower:]')"
  existing_group_lower="$(printf '%s' "${existing_workspace_resource_group}" | tr '[:upper:]' '[:lower:]')"
  [[ "${subscription_lower}" == "${existing_sub_lower}" && "${group_lower}" == "${existing_group_lower}" ]]
}

# Deletes the named resource group only when it is not the protected existing-workspace
# resource group. Safe to call even when the group does not exist.
delete_resource_group_if_not_protected() {
  local subscription="$1"
  local group="$2"
  if is_protected_existing_workspace_group "${subscription}" "${group}"; then
    printf 'SKIP: %s matches the supplied existingLogAnalyticsWorkspaceResourceId resource group; it is never deleted by this script.\n' "${group}" >&2
    return 0
  fi
  if az group exists --subscription "${subscription}" --name "${group}" --output tsv | grep -qi true; then
    az group delete --subscription "${subscription}" --name "${group}" --yes --no-wait
  fi
}

# Waits for deletion of the named resource group unless it is the protected
# existing-workspace resource group, in which case there is nothing to wait for.
wait_for_resource_group_deletion_if_not_protected() {
  local subscription="$1"
  local group="$2"
  if is_protected_existing_workspace_group "${subscription}" "${group}"; then
    return 0
  fi
  az group wait --subscription "${subscription}" --name "${group}" --deleted --interval 10 --timeout 900 2>/dev/null || true
}

print_plan() {
  local step_number=1
  printf 'TEARDOWN PLAN (reverse dependency order)\n'
  printf '  %d. Delete resource groups rg-%s-connectivity and rg-%s-%s-demo if present.\n' "${step_number}" "${prefix}" "${prefix}" "${archetype}"
  step_number=$((step_number + 1))
  if [[ "${monitoring_group_is_repo_owned}" == 'true' ]]; then
    printf '  %da. Delete the demo-created monitoring resource group %s (deployCentralLogAnalytics=true and no existing workspace supplied).\n' "$((step_number - 1))" "${monitoring_resource_group}"
  fi
  if [[ -n "${existing_workspace_resource_group}" ]]; then
    printf '\nNOTE: existingLogAnalyticsWorkspaceResourceId is set; resource group %s in subscription %s is protected and will never be deleted by this script, even if its name collides with a group above.\n' \
      "${existing_workspace_resource_group}" "${existing_workspace_subscription}"
  fi
  printf '  %d. Delete only the five permanent lower-privilege demo role assignments for the four operator/auditor groups at their documented scopes.\n' "${step_number}"
  step_number=$((step_number + 1))
  printf '  %d. Delete demo policy assignments and the five custom policy definitions.\n' "${step_number}"
  step_number=$((step_number + 1))
  printf '  %d. Move subscriptions %s and %s back to %s.\n' "${step_number}" "${connectivity_subscription}" "${workload_subscription}" "${tenant_root}"
  step_number=$((step_number + 1))
  if [[ "${critical_enabled}" == 'true' && ${#critical_subscriptions[@]} -gt 0 ]]; then
    local critical_subscriptions_joined="${critical_subscriptions[0]}"
    local critical_subscription_index
    for ((critical_subscription_index = 1; critical_subscription_index < ${#critical_subscriptions[@]}; critical_subscription_index++)); do
      critical_subscriptions_joined="${critical_subscriptions_joined}, ${critical_subscriptions[critical_subscription_index]}"
    done
    printf '  %d. Move critical infrastructure subscriptions (%s) back to %s.\n' "${step_number}" "${critical_subscriptions_joined}" "${tenant_root}"
    step_number=$((step_number + 1))
  fi
  if [[ "${critical_enabled}" == 'true' ]]; then
    printf '  %d. Delete management groups %s-connectivity, %s-platform, %s-%s, %s-criticalinfra, %s-landingzones, then %s.\n' \
      "${step_number}" "${prefix}" "${prefix}" "${prefix}" "${archetype}" "${prefix}" "${prefix}" "${prefix}"
  else
    printf '  %d. Delete management groups %s-connectivity, %s-platform, %s-%s, %s-landingzones, then %s.\n' \
      "${step_number}" "${prefix}" "${prefix}" "${prefix}" "${archetype}" "${prefix}" "${prefix}"
  fi
  if [[ "${eligible_owner_enabled}" == 'true' ]]; then
    printf '\nNOTE: The two eligible Owner schedules are not removed automatically. Submit separately reviewed PIM AdminRemove requests for the group at both subscriptions and verify removal in PIM.\n'
  fi
  printf '\nSubscriptions, Entra groups, and any customer-supplied existing Log Analytics workspace are never deleted.\n'
}

delete_role_mapping() {
  local assignee="$1"
  local role="$2"
  local scope="$3"
  az role assignment delete --assignee "${assignee}" --role "${role}" --scope "${scope}" 2>/dev/null || true
}

delete_policy_assignment() {
  local assignment_name="$1"
  local scope="$2"
  az policy assignment delete --name "${assignment_name}" --scope "${scope}" 2>/dev/null || true
}

print_plan

if [[ "${MODE}" != '--execute' ]]; then
  printf '\nDry run only. Add --execute and the documented environment confirmation to perform teardown.\n'
  exit 0
fi

if jq -e '.. | strings | select(contains("REPLACE_WITH_"))' "${PARAMETER_FILE}" >/dev/null; then
  printf 'ERROR: Execution is blocked because the parameter file still contains REPLACE_WITH_* placeholders.\n' >&2
  exit 2
fi

if [[ "${ESLZ_TEARDOWN_CONFIRMATION:-}" != 'DELETE-ESLZ-DEMO' ]]; then
  printf 'ERROR: Set ESLZ_TEARDOWN_CONFIRMATION=DELETE-ESLZ-DEMO to unlock teardown.\n' >&2
  exit 2
fi

printf '\nType the demo root ID (%s) to permanently remove this demo: ' "${prefix}"
read -r typed_confirmation
[[ "${typed_confirmation}" == "${prefix}" ]] || {
  printf 'Confirmation did not match; teardown cancelled.\n' >&2
  exit 2
}

delete_resource_group_if_not_protected "${connectivity_subscription}" "rg-${prefix}-connectivity"
delete_resource_group_if_not_protected "${workload_subscription}" "rg-${prefix}-${archetype}-demo"
# Only delete the monitoring resource group when this repository created it (no conflicting
# existing workspace was supplied). A supplied existing workspace/resource group is never
# owned by this demo and must never be deleted here, even by name collision.
if [[ "${monitoring_group_is_repo_owned}" == 'true' ]]; then
  delete_resource_group_if_not_protected "${connectivity_subscription}" "${monitoring_resource_group}"
fi
wait_for_resource_group_deletion_if_not_protected "${connectivity_subscription}" "rg-${prefix}-connectivity"
wait_for_resource_group_deletion_if_not_protected "${workload_subscription}" "rg-${prefix}-${archetype}-demo"
if [[ "${monitoring_group_is_repo_owned}" == 'true' ]]; then
  wait_for_resource_group_deletion_if_not_protected "${connectivity_subscription}" "${monitoring_resource_group}"
fi

delete_role_mapping "${governance_group}" 'Management Group Contributor' "${demo_root_scope}"
delete_role_mapping "${governance_group}" 'Resource Policy Contributor' "${demo_root_scope}"
delete_role_mapping "${auditors_group}" 'Reader' "${demo_root_scope}"
delete_role_mapping "${network_group}" 'Network Contributor' "${connectivity_scope}"
delete_role_mapping "${workload_group}" 'Contributor' "${subscription_workload_scope}"

delete_policy_assignment 'demo-require-workload-rg-tags' "${workload_scope}"
delete_policy_assignment 'demo-audit-platform-tags' "${platform_scope}"
delete_policy_assignment 'demo-block-expensive' "${demo_root_scope}"
delete_policy_assignment 'demo-audit-public-ip' "${demo_root_scope}"
delete_policy_assignment 'demo-allowed-us-locations' "${demo_root_scope}"

for policy_name in \
  "${prefix}-require-workload-rg-tags" \
  "${prefix}-audit-platform-tags" \
  "${prefix}-block-expensive" \
  "${prefix}-audit-public-ip" \
  "${prefix}-allowed-us-locations"; do
  az policy definition delete --name "${policy_name}" --management-group "${prefix}" 2>/dev/null || true
done

az account management-group subscription add --name "${tenant_root}" --subscription "${connectivity_subscription}"
az account management-group subscription add --name "${tenant_root}" --subscription "${workload_subscription}"

if [[ "${critical_enabled}" == 'true' ]]; then
  for critical_subscription in "${critical_subscriptions[@]}"; do
    az account management-group subscription add --name "${tenant_root}" --subscription "${critical_subscription}"
  done
fi

az account management-group delete --name "${prefix}-connectivity"
az account management-group delete --name "${prefix}-platform"
az account management-group delete --name "${prefix}-${archetype}"
if [[ "${critical_enabled}" == 'true' ]]; then
  az account management-group delete --name "${prefix}-criticalinfra"
fi
az account management-group delete --name "${prefix}-landingzones"
az account management-group delete --name "${prefix}"

printf '\nTeardown commands completed. Verify the hierarchy, both subscriptions, and any separately managed PIM eligibility schedules in the Azure portal.\n'
