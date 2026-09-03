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

optional_parameter_value() {
  jq -r --arg name "$1" '.parameters[$name].value // empty' "${PARAMETER_FILE}"
}

parameter_is_true() {
  [[ "$(optional_parameter_value "$1")" == 'true' ]]
}

is_guid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

is_resource_id() {
  local value="$1"
  local provider="$2"
  local type="$3"
  local escaped_provider="${provider//./\\.}"
  local escaped_type="${type//./\\.}"
  [[ "${value}" =~ ^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/[:space:]]+/providers/${escaped_provider}/${escaped_type}/[^/[:space:]]+$ ]]
}

validate_resource_id_parameter() {
  local name="$1"
  local value
  value="$(optional_parameter_value "${name}")"
  [[ -z "${value}" ]] || is_resource_id "${value}" "$2" "$3" \
    || fail "${name} must be a canonical $2/$3 resource ID when supplied."
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
[[ "$(printf '%s' "${deployment_location}" | tr '[:upper:]' '[:lower:]')" != 'global' ]] \
  || fail 'deploymentLocation must not be global because policy identities require an Azure region.'

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

validate_resource_id_parameter existingLogAnalyticsWorkspaceResourceId Microsoft.OperationalInsights workspaces
validate_resource_id_parameter approvedFirewallResourceId Microsoft.Network azureFirewalls
while IFS= read -r route_table_id; do
  [[ -z "${route_table_id}" ]] || is_resource_id "${route_table_id}" Microsoft.Network routeTables \
    || fail 'approvedRouteTableResourceIds contains an invalid Microsoft.Network/routeTables resource ID.'
done < <(jq -r '.parameters.approvedRouteTableResourceIds.value[]? // empty' "${PARAMETER_FILE}")
while IFS= read -r key_vault_uri; do
  [[ "${key_vault_uri}" =~ ^https://[a-zA-Z0-9-]+\.vault\.azure\.net/$ ]] \
    || fail 'approvedCustomerManagedKeyVaultUris contains an invalid Key Vault URI.'
done < <(jq -r '.parameters.approvedCustomerManagedKeyVaultUris.value[]? // empty' "${PARAMETER_FILE}")
while IFS= read -r key_name; do
  [[ "${key_name}" =~ ^[A-Za-z0-9-]{1,127}$ ]] \
    || fail 'approvedCustomerManagedKeyNames contains an invalid key name.'
done < <(jq -r '.parameters.approvedCustomerManagedKeyNames.value[]? // empty' "${PARAMETER_FILE}")

if parameter_is_true enableFirewallRouteGuardrails; then
  [[ -n "$(optional_parameter_value approvedFirewallResourceId)" ]] || fail 'enableFirewallRouteGuardrails requires approvedFirewallResourceId.'
  [[ -n "$(optional_parameter_value approvedFirewallPrivateIp)" ]] || fail 'enableFirewallRouteGuardrails requires approvedFirewallPrivateIp.'
  jq -e '.parameters.approvedRouteTableResourceIds.value | type == "array" and length > 0' "${PARAMETER_FILE}" >/dev/null \
    || fail 'enableFirewallRouteGuardrails requires approvedRouteTableResourceIds.'
  jq -e '.parameters.approvedRouteTablePrefixes.value | type == "array" and length > 0' "${PARAMETER_FILE}" >/dev/null \
    || fail 'enableFirewallRouteGuardrails requires approvedRouteTablePrefixes.'
fi

if parameter_is_true deployCentralLogAnalytics && [[ -n "$(optional_parameter_value existingLogAnalyticsWorkspaceResourceId)" ]]; then
  fail 'deployCentralLogAnalytics and existingLogAnalyticsWorkspaceResourceId cannot both be supplied.'
fi
if parameter_is_true deploySentinel && ! parameter_is_true deployCentralLogAnalytics && [[ -z "$(optional_parameter_value existingLogAnalyticsWorkspaceResourceId)" ]]; then
  fail 'deploySentinel requires deployCentralLogAnalytics or existingLogAnalyticsWorkspaceResourceId.'
fi

critical_subscription_ids=()
while IFS= read -r critical_subscription_id; do
  is_guid "${critical_subscription_id}" || fail 'criticalInfrastructureSubscriptionIds contains a non-GUID subscription ID.'
  normalized_critical_subscription_id="$(printf '%s' "${critical_subscription_id}" | tr '[:upper:]' '[:lower:]')"
  for seen_critical_subscription_id in "${critical_subscription_ids[@]}"; do
    [[ "${normalized_critical_subscription_id}" != "${seen_critical_subscription_id}" ]] \
      || fail 'criticalInfrastructureSubscriptionIds must not contain duplicate subscription IDs.'
  done
  critical_subscription_ids+=("${normalized_critical_subscription_id}")
done < <(jq -r '.parameters.criticalInfrastructureSubscriptionIds.value[]? // empty' "${PARAMETER_FILE}")
if parameter_is_true enableCriticalInfrastructure && [[ "${#critical_subscription_ids[@]}" -eq 0 ]]; then
  fail 'enableCriticalInfrastructure requires one or more criticalInfrastructureSubscriptionIds.'
fi

approved_backup_vault_count="$(jq -r '.parameters.approvedBackupVaults.value | length // 0' "${PARAMETER_FILE}")"
while IFS=$'\t' read -r vault_id backup_policy_id; do
  [[ -z "${vault_id}" ]] && continue
  is_resource_id "${vault_id}" Microsoft.RecoveryServices vaults \
    || fail 'approvedBackupVaults contains an invalid Recovery Services vault resource ID.'
  normalized_vault_id="$(printf '%s' "${vault_id}" | tr '[:upper:]' '[:lower:]')"
  normalized_backup_policy_id="$(printf '%s' "${backup_policy_id}" | tr '[:upper:]' '[:lower:]')"
  [[ "${normalized_backup_policy_id}" == "${normalized_vault_id}/backuppolicies/"* ]] \
    || fail 'approvedBackupVaults backupPolicyResourceId must be inside its vault.'
done < <(jq -r '.parameters.approvedBackupVaults.value[]? | [.vaultResourceId, .backupPolicyResourceId] | @tsv' "${PARAMETER_FILE}")
if parameter_is_true enableVmBackupRemediation; then
  [[ "${approved_backup_vault_count}" -gt 0 ]] || fail 'enableVmBackupRemediation requires approvedBackupVaults.'
  [[ -n "$(optional_parameter_value vmBackupInclusionTagName)" ]] || fail 'enableVmBackupRemediation requires vmBackupInclusionTagName.'
  [[ -n "$(optional_parameter_value backupRetentionStandardId)" ]] || fail 'enableVmBackupRemediation requires backupRetentionStandardId.'
  parameter_is_true deployRoleAssignments || fail 'enableVmBackupRemediation requires deployRoleAssignments for remediation permissions.'
fi
if parameter_is_true deployRecoveryServicesVault; then
  [[ "${approved_backup_vault_count}" -eq 0 ]] || fail 'deployRecoveryServicesVault cannot be combined with approvedBackupVaults.'
  [[ -n "$(optional_parameter_value backupRetentionStandardId)" ]] || fail 'deployRecoveryServicesVault requires backupRetentionStandardId.'
fi
if parameter_is_true enableVaultDiagnostics; then
  parameter_is_true deployCentralLogAnalytics || [[ -n "$(optional_parameter_value existingLogAnalyticsWorkspaceResourceId)" ]] \
    || fail 'enableVaultDiagnostics requires deployCentralLogAnalytics or existingLogAnalyticsWorkspaceResourceId.'
fi
if parameter_is_true grantVaultDiagnosticsWorkspaceAccess; then
  parameter_is_true enableVaultDiagnostics || fail 'grantVaultDiagnosticsWorkspaceAccess requires enableVaultDiagnostics.'
  [[ "$(optional_parameter_value vaultDiagnosticsEffect)" == 'DeployIfNotExists' ]] \
    || fail 'grantVaultDiagnosticsWorkspaceAccess requires vaultDiagnosticsEffect=DeployIfNotExists.'
  parameter_is_true deployRoleAssignments || fail 'grantVaultDiagnosticsWorkspaceAccess requires deployRoleAssignments.'
fi
if [[ "$(optional_parameter_value resourceDiagnosticsPolicyEffect)" == 'DeployIfNotExists' ]]; then
  parameter_is_true deployLoggingRemediationRoleAssignments \
    || fail 'resourceDiagnosticsPolicyEffect=DeployIfNotExists requires deployLoggingRemediationRoleAssignments.'
  parameter_is_true deployRoleAssignments \
    || fail 'resourceDiagnosticsPolicyEffect=DeployIfNotExists requires deployRoleAssignments.'
fi

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
for critical_subscription_id in "${critical_subscription_ids[@]}"; do
  check_subscription "${critical_subscription_id}" 'critical infrastructure'
done

az account management-group show --name "${tenant_root}" --output none 2>/dev/null \
  || fail "Cannot read tenant-root management group '${tenant_root}'. Check the ID and tenant permissions."

check_provider() {
  local subscription_id="$1"
  local namespace="$2"
  local registration_state
  registration_state="$(az provider show --subscription "${subscription_id}" --namespace "${namespace}" --query registrationState --output tsv 2>/dev/null)" \
    || fail "Cannot read provider ${namespace} in subscription ${subscription_id}."
  [[ "${registration_state}" == 'Registered' ]] \
    || fail "Provider ${namespace} is not registered in subscription ${subscription_id}; register it before deployment."
}

for subscription_id in "${connectivity_subscription}" "${workload_subscription}" "${critical_subscription_ids[@]}"; do
  check_provider "${subscription_id}" Microsoft.Authorization
  check_provider "${subscription_id}" Microsoft.Resources
done
if parameter_is_true enableFirewallRouteGuardrails; then
  check_provider "${workload_subscription}" Microsoft.Network
fi
if parameter_is_true deployCentralLogAnalytics || [[ -n "$(optional_parameter_value existingLogAnalyticsWorkspaceResourceId)" ]]; then
  check_provider "${connectivity_subscription}" Microsoft.OperationalInsights
fi
if [[ "${approved_backup_vault_count}" -gt 0 ]] || parameter_is_true deployRecoveryServicesVault; then
  check_provider "${workload_subscription}" Microsoft.RecoveryServices
fi

check_resource() {
  local resource_id="$1"
  local expected_type="$2"
  local actual_type
  local normalized_actual_type
  local normalized_expected_type
  actual_type="$(az resource show --ids "${resource_id}" --query type --output tsv 2>/dev/null)" \
    || fail "Cannot read referenced resource ${resource_id}. Check its ID and permissions."
  normalized_actual_type="$(printf '%s' "${actual_type}" | tr '[:upper:]' '[:lower:]')"
  normalized_expected_type="$(printf '%s' "${expected_type}" | tr '[:upper:]' '[:lower:]')"
  [[ "${normalized_actual_type}" == "${normalized_expected_type}" ]] \
    || fail "Referenced resource ${resource_id} is ${actual_type}, not ${expected_type}."
}
workspace_id="$(optional_parameter_value existingLogAnalyticsWorkspaceResourceId)"
[[ -z "${workspace_id}" ]] || check_resource "${workspace_id}" Microsoft.OperationalInsights/workspaces
firewall_id="$(optional_parameter_value approvedFirewallResourceId)"
[[ -z "${firewall_id}" ]] || check_resource "${firewall_id}" Microsoft.Network/azureFirewalls
while IFS= read -r route_table_id; do
  [[ -z "${route_table_id}" ]] || check_resource "${route_table_id}" Microsoft.Network/routeTables
done < <(jq -r '.parameters.approvedRouteTableResourceIds.value[]? // empty' "${PARAMETER_FILE}")
while IFS=$'\t' read -r vault_id backup_policy_id; do
  [[ -z "${vault_id}" ]] && continue
  check_resource "${vault_id}" Microsoft.RecoveryServices/vaults
  check_resource "${backup_policy_id}" Microsoft.RecoveryServices/vaults/backupPolicies
done < <(jq -r '.parameters.approvedBackupVaults.value[]? | [.vaultResourceId, .backupPolicyResourceId] | @tsv' "${PARAMETER_FILE}")

while IFS=$'\t' read -r kind definition_id major_version; do
  [[ -z "${definition_id}" ]] && continue
  if [[ "${kind}" == 'policySetDefinition' ]]; then
    actual_version="$(az policy set-definition show --name "${definition_id}" --query properties.version --output tsv 2>/dev/null)" \
      || fail "Cannot read built-in policy initiative ${definition_id} in the active Azure cloud."
  else
    actual_version="$(az policy definition show --name "${definition_id}" --query properties.version --output tsv 2>/dev/null)" \
      || fail "Cannot read built-in policy definition ${definition_id} in the active Azure cloud."
  fi
  [[ "${actual_version}" == "${major_version}."* ]] \
    || fail "Built-in policy ${definition_id} is version ${actual_version}, not pinned major version ${major_version}."
done < <(jq -r '.controls[] | select(.mechanism.builtIn == true and (.mechanism.definitionId | type == "string") and (.mechanism.definitionId | test("^[0-9a-fA-F-]{36}$"))) | [.mechanism.kind, .mechanism.definitionId, .mechanism.majorVersion] | @tsv' "${PROJECT_DIR}/policy/control-catalog.json")

printf '\nPreflight passed.\n'
printf '  Active tenant: %s\n' "${signed_in_tenant}"
printf '  Tenant root MG: %s\n' "${tenant_root}"
printf '  Connectivity subscription: %s\n' "${connectivity_subscription}"
printf '  Workload subscription: %s\n' "${workload_subscription}"
printf '  Tenant deployment location: %s\n' "${deployment_location}"
printf '  Entra group IDs: GUID format and uniqueness verified where supplied (directory group type is not queried).\n'
