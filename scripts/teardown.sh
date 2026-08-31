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

print_plan() {
  local step_number=1
  printf 'TEARDOWN PLAN (reverse dependency order)\n'
  printf '  %d. Delete resource groups rg-%s-connectivity and rg-%s-%s-demo if present.\n' "${step_number}" "${prefix}" "${prefix}" "${archetype}"
  step_number=$((step_number + 1))
  printf '  %d. Delete only the seven demo role assignments for the five groups at their documented scopes.\n' "${step_number}"
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
  printf '\nSubscriptions and Entra groups are never deleted.\n'
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
az group wait --subscription "${connectivity_subscription}" --name "rg-${prefix}-connectivity" --deleted --interval 10 --timeout 900 2>/dev/null || true
az group wait --subscription "${workload_subscription}" --name "rg-${prefix}-${archetype}-demo" --deleted --interval 10 --timeout 900 2>/dev/null || true

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

printf '\nTeardown commands completed. Verify the hierarchy and both subscriptions in the Azure portal.\n'
