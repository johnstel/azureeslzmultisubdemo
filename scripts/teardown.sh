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
# Optional: defaults to false when absent so older parameter files remain safe to tear down.
central_log_analytics_enabled="$(jq -r '.parameters.deployCentralLogAnalytics.value // false' "${PARAMETER_FILE}")"
recovery_services_vault_enabled="$(jq -r '.parameters.deployRecoveryServicesVault.value // false' "${PARAMETER_FILE}")"
role_assignments_enabled="$(jq -r '.parameters.deployRoleAssignments.value // false' "${PARAMETER_FILE}")"
evidence_resources_enabled="$(jq -r '.parameters.deployEvidenceResources.value // false' "${PARAMETER_FILE}")"
firewall_route_guardrails_enabled="$(jq -r '.parameters.enableFirewallRouteGuardrails.value // false' "${PARAMETER_FILE}")"
nerc_cip_overlay_enabled="$(jq -r '.parameters.enableNercCipTechnicalOverlay.value // false' "${PARAMETER_FILE}")"
vm_backup_remediation_enabled="$(jq -r '.parameters.enableVmBackupRemediation.value // false' "${PARAMETER_FILE}")"
vault_diagnostics_enabled="$(jq -r '.parameters.enableVaultDiagnostics.value // false' "${PARAMETER_FILE}")"
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
landing_zones_scope="/providers/Microsoft.Management/managementGroups/${prefix}-landingzones"
workload_scope="/providers/Microsoft.Management/managementGroups/${prefix}-${archetype}"
connectivity_scope="/subscriptions/${connectivity_subscription}"
subscription_workload_scope="/subscriptions/${workload_subscription}"
workspace_scope=''
if [[ "${central_log_analytics_enabled}" == 'true' ]]; then
  workspace_scope="/subscriptions/${connectivity_subscription}/resourceGroups/rg-${prefix}-monitoring/providers/Microsoft.OperationalInsights/workspaces/log-${prefix}-central"
elif [[ "${existing_workspace_resource_id}" =~ ^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.OperationalInsights/workspaces/[^/]+$ ]]; then
  workspace_scope="${existing_workspace_resource_id}"
fi
monitoring_resource_group="rg-${prefix}-monitoring"
backup_resource_group="rg-${prefix}-backup"
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
    return 1
  fi
  local group_exists
  if ! group_exists="$(az group exists --subscription "${subscription}" --name "${group}" --output tsv)"; then
    printf 'ERROR: Cannot determine whether resource group %s exists.\n' "${group}" >&2
    exit 1
  fi
  if printf '%s\n' "${group_exists}" | grep -qi true; then
    local owner
    owner="$(az group show --subscription "${subscription}" --name "${group}" --query 'tags.ESLZLifecycleOwner' --output tsv)" \
      || { printf 'ERROR: Cannot read ownership marker for %s; it is protected.\n' "${group}" >&2; return 1; }
    if [[ -z "${owner}" ]]; then
      printf 'SKIP: %s is external/protected because ESLZLifecycleOwner is absent.\n' "${group}" >&2
      return 1
    fi
    if [[ "${owner}" != "${prefix}" ]]; then
      printf 'SKIP: %s is external/protected because ESLZLifecycleOwner does not match this demo root.\n' "${group}" >&2
      return 1
    fi
    az group delete --subscription "${subscription}" --name "${group}" --yes --no-wait \
      || { printf 'ERROR: Failed to start deletion of resource group %s.\n' "${group}" >&2; exit 1; }
    return 0
  fi
  return 1
}

# Waits only after this script successfully started resource-group deletion.
wait_for_resource_group_deletion() {
  local subscription="$1"
  local group="$2"
  if ! az group wait --subscription "${subscription}" --name "${group}" --deleted --interval 10 --timeout 900; then
    local group_exists
    if ! group_exists="$(az group exists --subscription "${subscription}" --name "${group}" --output tsv)"; then
      printf 'ERROR: Cannot determine whether resource group %s was deleted.\n' "${group}" >&2
      exit 1
    fi
    if printf '%s\n' "${group_exists}" | grep -qi true; then
      printf 'ERROR: Failed waiting for resource group %s deletion.\n' "${group}" >&2
      exit 1
    fi
  fi
}

print_plan() {
  local step_number=1
  printf 'TEARDOWN PLAN (reverse dependency order)\n'
  printf '  %d. deployment-owned policy exemptions:\n' "${step_number}"
  jq -r '.parameters.policyExemptions.value // [] | .[] |
    if .exemptionScopeType == "managementGroup" then "     deployment-owned exemption \(.exemptionName) at /providers/Microsoft.Management/managementGroups/\(.managementGroupName)"
    elif .exemptionScopeType == "subscription" then "     deployment-owned exemption \(.exemptionName) at /subscriptions/\(.subscriptionId)"
    elif .exemptionScopeType == "resourceGroup" then "     deployment-owned exemption \(.exemptionName) at /subscriptions/\(.subscriptionId)/resourceGroups/\(.resourceGroupName)"
    else "     disabled/not-owned invalid exemption \(.exemptionName // "")" end' "${PARAMETER_FILE}"
  step_number=$((step_number + 1))
  printf '  %d. deployment-owned assignments and remediating identity role mappings:\n' "${step_number}"
  [[ "${role_assignments_enabled}" == true ]] && printf '     deployment-owned ordinary RBAC mappings at %s, %s, and %s\n' "${demo_root_scope}" "${connectivity_scope}" "${subscription_workload_scope}" || printf '     disabled/not-owned ordinary RBAC mappings\n'
  printf '     deployment-owned demo-allowed-us-locs, demo-audit-public-ip, demo-block-expensive, demo-activity-logs, demo-resource-diags at %s\n' "${demo_root_scope}"
  printf '     deployment-owned demo-deploy-restrictions at %s\n' "${demo_root_scope}"
  printf '     deployment-owned demo-audit-platform-tags at %s\n' "${platform_scope}"
  printf '     deployment-owned demo-data-protection, demo-require-rg-tags, demo-audit-vuln-assess, demo-audit-ama-windows, demo-audit-ama-linux, demo-backup-posture at %s\n' "${landing_zones_scope}"
  printf '     deployment-owned demo-network-ingress, demo-private-access at %s\n' "${workload_scope}"
  [[ "$(jq -r '.parameters.enableDefenderCspm.value // false' "${PARAMETER_FILE}")" == true ]] && defender_cspm_effect='DeployIfNotExists' || defender_cspm_effect='Disabled'
  [[ "$(jq -r '.parameters.enableDefenderForServers.value // false' "${PARAMETER_FILE}")" == true ]] && defender_servers_effect='DeployIfNotExists' || defender_servers_effect='Disabled'
  [[ "$(jq -r '.parameters.enableDefenderForStorage.value // false' "${PARAMETER_FILE}")" == true ]] && defender_storage_effect='DeployIfNotExists' || defender_storage_effect='Disabled'
  printf '     deployment-owned demo-defender-cspm at %s (effect: %s)\n' "${demo_root_scope}" "${defender_cspm_effect}"
  printf '     deployment-owned demo-defender-servers at %s (effect: %s); demo-defender-storage at %s (effect: %s)\n' "${landing_zones_scope}" "${defender_servers_effect}" "${landing_zones_scope}" "${defender_storage_effect}"
  [[ "$(jq -r '.parameters.enableMicrosoftCloudSecurityBenchmark.value // false' "${PARAMETER_FILE}")" == true ]] && printf '     deployment-owned demo-mcsb-baseline at %s\n' "${demo_root_scope}" || printf '     disabled/not-owned demo-mcsb-baseline\n'
  [[ "$(jq -r '.parameters.enableCisAzureFoundationsBenchmark.value // false' "${PARAMETER_FILE}")" == true ]] && printf '     deployment-owned demo-cis-foundations at %s\n' "${demo_root_scope}" || printf '     disabled/not-owned demo-cis-foundations\n'
  [[ "$(jq -r '.parameters.enableNistSp80053Rev5.value // false' "${PARAMETER_FILE}")" == true ]] && printf '     deployment-owned demo-nist-800-53-r5 at %s\n' "${demo_root_scope}" || printf '     disabled/not-owned demo-nist-800-53-r5\n'
  [[ "$(jq -r '.parameters.enableTagInheritance.value // false' "${PARAMETER_FILE}")" == true ]] && printf '     deployment-owned demo-inherit-rg-tags at %s\n' "${landing_zones_scope}" || printf '     disabled/not-owned demo-inherit-rg-tags\n'
  [[ "${vault_diagnostics_enabled}" == true ]] && printf '     deployment-owned demo-vault-diagnostics at %s\n' "${landing_zones_scope}" || printf '     disabled/not-owned demo-vault-diagnostics\n'
  if [[ "${critical_enabled}" == true ]]; then
    printf '     deployment-owned demo-critical-private at /providers/Microsoft.Management/managementGroups/%s-criticalinfra\n' "${prefix}"
    [[ "${nerc_cip_overlay_enabled}" == true ]] && printf '     deployment-owned demo-nerc-cip-technical at /providers/Microsoft.Management/managementGroups/%s-criticalinfra\n' "${prefix}" || printf '     disabled/not-owned demo-nerc-cip-technical\n'
    [[ "${firewall_route_guardrails_enabled}" == true ]] && printf '     deployment-owned demo-critical-fw-routes at /providers/Microsoft.Management/managementGroups/%s-criticalinfra\n' "${prefix}"
  else
    printf '     disabled/not-owned Critical Infrastructure assignments\n'
  fi
  [[ "${firewall_route_guardrails_enabled}" == true ]] && printf '     deployment-owned demo-firewall-routes at %s\n' "${workload_scope}" || printf '     disabled/not-owned demo-firewall-routes\n'
  if [[ "${vm_backup_remediation_enabled}" == true ]]; then
    jq -r '.parameters.approvedBackupVaults.value // [] | to_entries[] | "     deployment-owned demo-vm-backup-\(.key) at '"${landing_zones_scope}"'"' "${PARAMETER_FILE}"
  else
    printf '     disabled/not-owned dynamic demo-vm-backup assignments\n'
  fi
  [[ -n "${workspace_scope}" ]] && printf '     deployment-owned remediating identity roles at %s; workspace is external/protected when supplied.\n' "${workspace_scope}"
  step_number=$((step_number + 1))
  printf '  %d. deployment-owned optional resource groups:\n' "${step_number}"
  if [[ "${evidence_resources_enabled}" == 'true' ]]; then
    printf '     deployment-owned rg-%s-connectivity and rg-%s-%s-demo\n' "${prefix}" "${prefix}" "${archetype}"
  fi
  if [[ "${monitoring_group_is_repo_owned}" == 'true' ]]; then
    printf '  %da. Delete the demo-created monitoring resource group %s (deployCentralLogAnalytics=true and no existing workspace supplied).\n' "$((step_number - 1))" "${monitoring_resource_group}"
  fi
  if [[ "${recovery_services_vault_enabled}" == 'true' ]]; then
    local backup_step_suffix='a'
    if [[ "${monitoring_group_is_repo_owned}" == 'true' ]]; then
      backup_step_suffix='b'
    fi
    printf '  %d%s. Delete the demo-created backup resource group %s.\n' "$((step_number - 1))" "${backup_step_suffix}" "${backup_resource_group}"
  fi
  if [[ -n "${existing_workspace_resource_group}" ]]; then
    printf '\nNOTE: existingLogAnalyticsWorkspaceResourceId is set; resource group %s in subscription %s is protected and will never be deleted by this script, even if its name collides with a group above.\n' \
      "${existing_workspace_resource_group}" "${existing_workspace_subscription}"
  fi
  jq -r '
    .parameters |
    [
      .existingLogAnalyticsWorkspaceResourceId.value?,
      .approvedFirewallResourceId.value?,
      (.approvedCustomerManagedKeyVaultUris.value? // [] | .[]),
      (.approvedBackupVaults.value? // [] | .[] | .vaultResourceId, .backupPolicyResourceId),
      (.approvedRouteTableResourceIds.value? // [] | .[]),
      (.policyExemptions.value? // [] | .[] | .policyAssignmentId)
    ] | .[]? | select(type == "string" and length > 0) |
    "     external/protected \(. )"
  ' "${PARAMETER_FILE}"
  printf '  %d. deployment-owned custom initiatives and policy definitions are deleted after assignments.\n' "${step_number}"
  printf '     deployment-owned initiatives %s-required-rg-tags, %s-inherit-rg-tags, %s-network-ingress, %s-private-access, %s-data-protection, %s-deploy-restrictions, %s-backup-posture, %s-nerc-cip-technical-overlay at %s\n' "${prefix}" "${prefix}" "${prefix}" "${prefix}" "${prefix}" "${prefix}" "${prefix}" "${prefix}" "${demo_root_scope}"
  printf '     deployment-owned definitions %s-allowed-us-locations, %s-allowed-resource-types-all, %s-require-workload-rg-tags, %s-audit-public-ip, %s-public-mgmt-ingress, %s-require-subnet-nsg, %s-audit-paas-public-network, %s-audit-approved-firewall-routes, %s-block-expensive, %s-audit-storage-cmk-approved-key, %s-audit-platform-tags at %s\n' "${prefix}" "${prefix}" "${prefix}" "${prefix}" "${prefix}" "${prefix}" "${prefix}" "${prefix}" "${prefix}" "${prefix}" "${prefix}" "${demo_root_scope}"
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
  printf '\nNOTE: Owner eligibility is managed only through the separate one-shot PIM artifact. This teardown never discovers or removes it; submit a new, separately reviewed AdminRemove request for each existing schedule and verify removal in PIM.\n'
  printf '\nOnly objects named by this deployment and optional resource groups enabled in this parameter file are deployment-owned. Supplied workspace, firewall, key, vault, policy, and other external IDs are never deleted. Subscriptions and Entra groups are never deleted.\n'
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
  local destination_scope="${3:-}"
  local principal_id role_assignment_id role_scope
  principal_id="$(az policy assignment show --name "${assignment_name}" --scope "${scope}" --query identity.principalId --output tsv 2>/dev/null || true)"
  if [[ -n "${principal_id}" && "${principal_id}" != 'null' ]]; then
    for role_scope in "${scope}" "${destination_scope}"; do
      [[ -n "${role_scope}" ]] || continue
      while IFS= read -r role_assignment_id; do
        [[ -n "${role_assignment_id}" ]] && az role assignment delete --ids "${role_assignment_id}" 2>/dev/null || true
      done < <(az role assignment list --assignee "${principal_id}" --scope "${role_scope}" --query '[].id' --output tsv 2>/dev/null || true)
    done
  fi
  az policy assignment delete --name "${assignment_name}" --scope "${scope}" 2>/dev/null || true
}

delete_policy_exemptions() {
  while IFS= read -r exemption; do
    local exemption_name scope_type management_group subscription resource_group exemption_scope
    exemption_name="$(printf '%s' "${exemption}" | jq -r '.exemptionName // empty')"
    scope_type="$(printf '%s' "${exemption}" | jq -r '.exemptionScopeType // empty')"
    management_group="$(printf '%s' "${exemption}" | jq -r '.managementGroupName // empty')"
    subscription="$(printf '%s' "${exemption}" | jq -r '.subscriptionId // empty')"
    resource_group="$(printf '%s' "${exemption}" | jq -r '.resourceGroupName // empty')"
    case "${scope_type}" in
      managementGroup) exemption_scope="/providers/Microsoft.Management/managementGroups/${management_group}" ;;
      subscription) exemption_scope="/subscriptions/${subscription}" ;;
      resourceGroup) exemption_scope="/subscriptions/${subscription}/resourceGroups/${resource_group}" ;;
      *) continue ;;
    esac
    [[ -n "${exemption_name}" && "${exemption_scope}" != */managementGroups/ && "${exemption_scope}" != */subscriptions/ && "${exemption_scope}" != */resourceGroups/ ]] || continue
    az policy exemption delete --name "${exemption_name}" --scope "${exemption_scope}" 2>/dev/null || true
  done < <(jq -c '.parameters.policyExemptions.value // [] | .[]' "${PARAMETER_FILE}")
}

delete_demo_policy_assignments() {
  local assignment
  local owned_assignments=(
    "demo-allowed-us-locs|${demo_root_scope}" "demo-audit-public-ip|${demo_root_scope}"
    "demo-block-expensive|${demo_root_scope}" "demo-defender-cspm|${demo_root_scope}"
    "demo-activity-logs|${demo_root_scope}" "demo-deploy-restrictions|${demo_root_scope}"
    "demo-resource-diags|${demo_root_scope}" "demo-audit-platform-tags|${platform_scope}"
    "demo-data-protection|${landing_zones_scope}" "demo-require-rg-tags|${landing_zones_scope}"
    "demo-defender-servers|${landing_zones_scope}" "demo-defender-storage|${landing_zones_scope}"
    "demo-audit-vuln-assess|${landing_zones_scope}" "demo-audit-ama-windows|${landing_zones_scope}"
    "demo-audit-ama-linux|${landing_zones_scope}"
    "demo-backup-posture|${landing_zones_scope}"
    "demo-network-ingress|${workload_scope}" "demo-private-access|${workload_scope}"
  )
  for assignment in "${owned_assignments[@]}"; do
    delete_policy_assignment "${assignment%%|*}" "${assignment#*|}" "${workspace_scope}"
  done
  [[ "$(jq -r '.parameters.enableMicrosoftCloudSecurityBenchmark.value // false' "${PARAMETER_FILE}")" == true ]] && delete_policy_assignment 'demo-mcsb-baseline' "${demo_root_scope}" "${workspace_scope}"
  [[ "$(jq -r '.parameters.enableCisAzureFoundationsBenchmark.value // false' "${PARAMETER_FILE}")" == true ]] && delete_policy_assignment 'demo-cis-foundations' "${demo_root_scope}" "${workspace_scope}"
  [[ "$(jq -r '.parameters.enableNistSp80053Rev5.value // false' "${PARAMETER_FILE}")" == true ]] && delete_policy_assignment 'demo-nist-800-53-r5' "${demo_root_scope}" "${workspace_scope}"
  [[ "$(jq -r '.parameters.enableTagInheritance.value // false' "${PARAMETER_FILE}")" == true ]] && delete_policy_assignment 'demo-inherit-rg-tags' "${landing_zones_scope}" "${workspace_scope}"
  [[ "${vault_diagnostics_enabled}" == true ]] && delete_policy_assignment 'demo-vault-diagnostics' "${landing_zones_scope}" "${workspace_scope}"
  if [[ "${critical_enabled}" == 'true' ]]; then
    local critical_scope="/providers/Microsoft.Management/managementGroups/${prefix}-criticalinfra"
    delete_policy_assignment 'demo-critical-private' "${critical_scope}" "${workspace_scope}"
    [[ "${nerc_cip_overlay_enabled}" == true ]] && delete_policy_assignment 'demo-nerc-cip-technical' "${critical_scope}" "${workspace_scope}"
  fi
  if [[ "${firewall_route_guardrails_enabled}" == 'true' ]]; then
    delete_policy_assignment 'demo-firewall-routes' "${workload_scope}" "${workspace_scope}"
    if [[ "${critical_enabled}" == 'true' ]]; then
      delete_policy_assignment 'demo-critical-fw-routes' "${critical_scope}" "${workspace_scope}"
    fi
  fi
  local backup_index
  if [[ "${vm_backup_remediation_enabled}" == true ]]; then
    while IFS= read -r backup_index; do
      delete_policy_assignment "demo-vm-backup-${backup_index}" "${landing_zones_scope}" "${workspace_scope}"
    done < <(jq -r '.parameters.approvedBackupVaults.value // [] | keys[]' "${PARAMETER_FILE}")
  fi
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

delete_policy_exemptions
if [[ "${role_assignments_enabled}" == 'true' ]]; then
  delete_role_mapping "${governance_group}" 'Management Group Contributor' "${demo_root_scope}"
  delete_role_mapping "${governance_group}" 'Resource Policy Contributor' "${demo_root_scope}"
  delete_role_mapping "${auditors_group}" 'Reader' "${demo_root_scope}"
  delete_role_mapping "${network_group}" 'Network Contributor' "${connectivity_scope}"
  delete_role_mapping "${workload_group}" 'Contributor' "${subscription_workload_scope}"
fi
delete_demo_policy_assignments

if [[ "${evidence_resources_enabled}" == 'true' ]]; then
  delete_resource_group_if_not_protected "${connectivity_subscription}" "rg-${prefix}-connectivity" && wait_for_resource_group_deletion "${connectivity_subscription}" "rg-${prefix}-connectivity"
  delete_resource_group_if_not_protected "${workload_subscription}" "rg-${prefix}-${archetype}-demo" && wait_for_resource_group_deletion "${workload_subscription}" "rg-${prefix}-${archetype}-demo"
fi
# Only delete the monitoring resource group when this repository created it (no conflicting
# existing workspace was supplied). A supplied existing workspace/resource group is never
# owned by this demo and must never be deleted here, even by name collision.
if [[ "${monitoring_group_is_repo_owned}" == 'true' ]]; then
  delete_resource_group_if_not_protected "${connectivity_subscription}" "${monitoring_resource_group}" && wait_for_resource_group_deletion "${connectivity_subscription}" "${monitoring_resource_group}"
fi
if [[ "${recovery_services_vault_enabled}" == 'true' ]]; then
  delete_resource_group_if_not_protected "${workload_subscription}" "${backup_resource_group}" && wait_for_resource_group_deletion "${workload_subscription}" "${backup_resource_group}"
fi

for initiative_name in \
  "${prefix}-required-rg-tags" \
  "${prefix}-inherit-rg-tags" \
  "${prefix}-network-ingress" \
  "${prefix}-private-access" \
  "${prefix}-data-protection" \
  "${prefix}-deploy-restrictions" \
  "${prefix}-backup-posture" \
  "${prefix}-nerc-cip-technical-overlay"; do
  az policy set-definition delete --name "${initiative_name}" --management-group "${prefix}" 2>/dev/null || true
done
for policy_name in \
  "${prefix}-allowed-us-locations" \
  "${prefix}-allowed-resource-types-all" \
  "${prefix}-require-workload-rg-tags" \
  "${prefix}-audit-platform-tags" \
  "${prefix}-block-expensive" \
  "${prefix}-audit-public-ip" \
  "${prefix}-public-mgmt-ingress" \
  "${prefix}-require-subnet-nsg" \
  "${prefix}-audit-paas-public-network" \
  "${prefix}-audit-approved-firewall-routes" \
  "${prefix}-audit-storage-cmk-approved-key"; do
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
