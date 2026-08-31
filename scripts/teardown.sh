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
owners_group="$(value subscriptionOwnersGroupObjectId)"
network_group="$(value networkOperatorsGroupObjectId)"
workload_group="$(value workloadContributorsGroupObjectId)"
auditors_group="$(value readOnlyAuditorsGroupObjectId)"
# Optional: defaults to false when absent so older parameter files remain safe to tear down.
central_log_analytics_enabled="$(jq -r '.parameters.deployCentralLogAnalytics.value // false' "${PARAMETER_FILE}")"

demo_root_scope="/providers/Microsoft.Management/managementGroups/${prefix}"
platform_scope="/providers/Microsoft.Management/managementGroups/${prefix}-platform"
workload_scope="/providers/Microsoft.Management/managementGroups/${prefix}-${archetype}"
connectivity_scope="/subscriptions/${connectivity_subscription}"
subscription_workload_scope="/subscriptions/${workload_subscription}"
monitoring_resource_group="rg-${prefix}-monitoring"

print_plan() {
  printf 'TEARDOWN PLAN (reverse dependency order)\n'
  printf '  1. Delete resource groups rg-%s-connectivity and rg-%s-%s-demo if present.\n' "${prefix}" "${prefix}" "${archetype}"
  if [[ "${central_log_analytics_enabled}" == 'true' ]]; then
    printf '  1a. Delete the demo-created monitoring resource group %s (deployCentralLogAnalytics=true).\n' "${monitoring_resource_group}"
  fi
  printf '  2. Delete only the seven demo role assignments for the five groups at their documented scopes.\n'
  printf '  3. Delete demo policy assignments and the five custom policy definitions.\n'
  printf '  4. Move subscriptions %s and %s back to %s.\n' "${connectivity_subscription}" "${workload_subscription}" "${tenant_root}"
  printf '  5. Delete management groups %s-connectivity, %s-platform, %s-%s, %s-landingzones, then %s.\n' \
    "${prefix}" "${prefix}" "${prefix}" "${archetype}" "${prefix}" "${prefix}"
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

if az group exists --subscription "${connectivity_subscription}" --name "rg-${prefix}-connectivity" --output tsv | grep -qi true; then
  az group delete --subscription "${connectivity_subscription}" --name "rg-${prefix}-connectivity" --yes --no-wait
fi
if az group exists --subscription "${workload_subscription}" --name "rg-${prefix}-${archetype}-demo" --output tsv | grep -qi true; then
  az group delete --subscription "${workload_subscription}" --name "rg-${prefix}-${archetype}-demo" --yes --no-wait
fi
# Only delete the monitoring resource group when this repository created it
# (deployCentralLogAnalytics=true). A supplied existing workspace/resource group is never
# owned by this demo and must never be deleted here.
if [[ "${central_log_analytics_enabled}" == 'true' ]]; then
  if az group exists --subscription "${connectivity_subscription}" --name "${monitoring_resource_group}" --output tsv | grep -qi true; then
    az group delete --subscription "${connectivity_subscription}" --name "${monitoring_resource_group}" --yes --no-wait
  fi
fi
az group wait --subscription "${connectivity_subscription}" --name "rg-${prefix}-connectivity" --deleted --interval 10 --timeout 900 2>/dev/null || true
az group wait --subscription "${workload_subscription}" --name "rg-${prefix}-${archetype}-demo" --deleted --interval 10 --timeout 900 2>/dev/null || true
if [[ "${central_log_analytics_enabled}" == 'true' ]]; then
  az group wait --subscription "${connectivity_subscription}" --name "${monitoring_resource_group}" --deleted --interval 10 --timeout 900 2>/dev/null || true
fi

delete_role_mapping "${governance_group}" 'Management Group Contributor' "${demo_root_scope}"
delete_role_mapping "${governance_group}" 'Resource Policy Contributor' "${demo_root_scope}"
delete_role_mapping "${auditors_group}" 'Reader' "${demo_root_scope}"
delete_role_mapping "${owners_group}" 'Owner' "${connectivity_scope}"
delete_role_mapping "${network_group}" 'Network Contributor' "${connectivity_scope}"
delete_role_mapping "${owners_group}" 'Owner' "${subscription_workload_scope}"
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

az account management-group delete --name "${prefix}-connectivity"
az account management-group delete --name "${prefix}-platform"
az account management-group delete --name "${prefix}-${archetype}"
az account management-group delete --name "${prefix}-landingzones"
az account management-group delete --name "${prefix}"

printf '\nTeardown commands completed. Verify the hierarchy and both subscriptions in the Azure portal.\n'
