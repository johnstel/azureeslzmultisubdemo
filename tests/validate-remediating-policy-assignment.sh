#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARTIFACTS_PARENT="${PROJECT_DIR}/.test-artifacts"
TEMP_DIR="${ARTIFACTS_PARENT}/remediating-policy-assignment-sh-$$"
mkdir -p "${TEMP_DIR}"
trap 'rm -rf "${TEMP_DIR}"; rmdir "${ARTIFACTS_PARENT}" 2>/dev/null || true' EXIT

command -v az >/dev/null 2>&1 || {
  printf 'ERROR: Azure CLI is required for remediating policy assignment validation.\n' >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  printf 'ERROR: jq is required for remediating policy assignment validation.\n' >&2
  exit 1
}

compiled_shapes="${TEMP_DIR}/remediating-policy-assignment-shapes.json"
az bicep build \
  --file "${SCRIPT_DIR}/fixtures/remediating-policy-assignment-shapes.bicep" \
  --outfile "${compiled_shapes}" >/dev/null

expect_bicep_build_failure() {
  local fixture="$1"
  local description="$2"
  if az bicep build --file "${fixture}" --stdout >/dev/null 2>&1; then
    printf 'ERROR: Bicep unexpectedly accepted %s.\n' "${description}" >&2
    exit 1
  fi
}

expect_bicep_build_failure \
  "${SCRIPT_DIR}/fixtures/invalid-remediating-assignment-missing-identity.bicep" \
  'a remediating assignment without an identity type'
expect_bicep_build_failure \
  "${SCRIPT_DIR}/fixtures/invalid-remediating-assignment-missing-location.bicep" \
  'a remediating assignment without a location'
expect_bicep_build_failure \
  "${SCRIPT_DIR}/fixtures/invalid-remediating-assignment-incomplete-user-identity.bicep" \
  'a user-assigned remediation identity without a principal ID'

jq -e '
  def deployment($name): first(.resources[] | select(.name == $name));
  deployment("example-system-remediation") as $system
  | deployment("example-user-remediation") as $user
  | $system.properties.template as $module
  | $module.resources.assignment as $assignment
  | $module.resources.remediationRoleAssignments as $roles
  | (.resources | length) == 2
    and $system.properties.parameters.location.value == "eastus2"
    and $system.properties.parameters.identity.value == {
      "type": "SystemAssigned"
    }
    and $system.properties.parameters.verifiedRoleDefinitionIds.value == [
      "22222222-2222-2222-2222-222222222222"
    ]
    and $user.properties.parameters.location.value == "westus2"
    and $user.properties.parameters.identity.value.type == "UserAssigned"
    and $user.properties.parameters.identity.value.resourceId == "/subscriptions/44444444-4444-4444-4444-444444444444/resourceGroups/identities/providers/Microsoft.ManagedIdentity/userAssignedIdentities/policy-remediation"
    and $user.properties.parameters.identity.value.principalId == "55555555-5555-5555-5555-555555555555"
    and $user.properties.parameters.verifiedRoleDefinitionIds.value == [
      "66666666-6666-6666-6666-666666666666",
      "77777777-7777-7777-7777-777777777777"
    ]
    and $user.properties.parameters.definitionVersion.value == "1.2.*"
    and $user.properties.parameters.enforcementMode.value == "Default"
    and $user.properties.parameters.parameters.value.effect.value == "Modify"
    and $user.properties.parameters.metadata.value.owner == "Platform Team"
    and ($user.properties.parameters.nonComplianceMessages.value | length) == 1
    and ($user.properties.parameters.notScopes.value | length) == 1
    and ($user.properties.parameters.resourceSelectors.value | length) == 1
    and ($module.parameters.location | has("defaultValue") | not)
    and $module.parameters.location.minLength == 1
    and ($module.parameters.identity | has("defaultValue") | not)
    and $module.parameters.identity["$ref"] == "#/definitions/RemediationIdentity"
    and $module.definitions.SystemAssignedIdentity.additionalProperties == false
    and $module.definitions.UserAssignedIdentity.additionalProperties == false
    and $module.definitions.UserAssignedIdentity.properties.resourceId.minLength == 1
    and $module.definitions.UserAssignedIdentity.properties.principalId.minLength == 1
    and ($module.definitions.RemediationIdentity.discriminator.mapping | keys | sort) == ["SystemAssigned", "UserAssigned"]
    and ($module.parameters.verifiedRoleDefinitionIds | has("defaultValue") | not)
    and $module.parameters.verifiedRoleDefinitionIds.minLength == 1
    and $module.parameters.enforcementMode.defaultValue == "DoNotEnforce"
    and ($module.variables.validatedLocation | contains("location must be a non-global Azure region"))
    and ($module.variables.validatedUserAssignedIdentityResourceId | contains("UserAssigned identity configuration must contain a valid identity resource ID and principal ID"))
    and ($module.variables.validatedRoleDefinitionIds | contains("must not contain Owner or User Access Administrator"))
    and $assignment.type == "Microsoft.Authorization/policyAssignments"
    and $assignment.apiVersion == "2025-03-01"
    and $assignment.location == "[variables(\u0027validatedLocation\u0027)]"
    and ($assignment.identity | contains("parameters(\u0027identity\u0027).type"))
    and ($assignment.identity | contains("userAssignedIdentities"))
    and ($assignment.properties | contains("parameters(\u0027enforcementMode\u0027)"))
    and ($assignment.properties | contains("variables(\u0027validatedPolicyDefinitionId\u0027)"))
    and $roles.type == "Microsoft.Authorization/roleAssignments"
    and $roles.apiVersion == "2022-04-01"
    and $roles.copy.count == "[length(variables(\u0027validatedRoleDefinitionIds\u0027))]"
    and $roles.name == "[guid(managementGroup().id, variables(\u0027roleAssignmentPrincipalSeed\u0027), variables(\u0027validatedRoleDefinitionIds\u0027)[copyIndex()])]"
    and $roles.properties.principalType == "ServicePrincipal"
    and ($roles.properties.principalId | contains("reference(\u0027assignment\u0027"))
    and $roles.properties.roleDefinitionId == "[tenantResourceId(\u0027Microsoft.Authorization/roleDefinitions\u0027, variables(\u0027validatedRoleDefinitionIds\u0027)[copyIndex()])]"
    and $roles.dependsOn == ["assignment"]
    and ($module.outputs | keys | sort) == [
      "identityPrincipalId",
      "identityResourceId",
      "policyAssignmentId",
      "roleAssignmentIds"
    ]
    and ([.. | objects | select(.type? == "Microsoft.PolicyInsights/remediations")] | length) == 0
' "${compiled_shapes}" >/dev/null || {
  printf 'ERROR: Remediating policy assignment identity, location, role, or output wiring is invalid.\n' >&2
  exit 1
}

printf 'Remediating policy assignment structural validation passed.\n'
