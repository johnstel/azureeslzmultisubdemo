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
  'a user-assigned remediation identity without a resource ID'
expect_bicep_build_failure \
  "${SCRIPT_DIR}/fixtures/invalid-remediating-assignment-name.bicep" \
  'a management-group remediating policy assignment name longer than 24 characters'
expect_bicep_build_failure \
  "${SCRIPT_DIR}/fixtures/invalid-remediating-policy-selector-kind.bicep" \
  'policyDefinitionReferenceId as a remediating resource selector kind'

validation_cases="${SCRIPT_DIR}/fixtures/policy-assignment-validation-cases.json"
jq -e '
  def valid_assignment_name:
    . as $name
    | ($name | length) >= 1
      and ($name | length) <= 24
      and (["#", "<", ">", "%", "&", ":", "\\", "?", "/"] | all(.[]; . as $character | ($name | contains($character) | not)))
      and ($name | test("[[:cntrl:]]") | not)
      and ($name | endswith(".") | not)
      and ($name | endswith(" ") | not);
  def built_in_definition_id:
    . == (gsub("^\\s+|\\s+$"; ""))
      and test("^/providers/Microsoft\\.Authorization/(policyDefinitions|policySetDefinitions)/[^/]+$"; "i");
  def management_group_definition_id:
    . == (gsub("^\\s+|\\s+$"; ""))
      and test("^/providers/Microsoft\\.Management/managementGroups/[^/]+/providers/Microsoft\\.Authorization/(policyDefinitions|policySetDefinitions)/[^/]+$"; "i");
  def valid_definition_version:
    test("^(0|[1-9][0-9]*)\\.(\\*|0|[1-9][0-9]*)\\.\\*$");
  def valid_definition_binding:
    .policyDefinitionId as $definition_id
    | ($definition_id | built_in_definition_id) as $built_in
    | (($built_in or ($definition_id | management_group_definition_id))
      and (.definitionVersion == "" or ($built_in and (.definitionVersion | valid_definition_version))));
  def valid_resource_id_segments:
    startswith("/")
      and (endswith("/") | not)
      and (split("/")[1:] | all(.[]; length > 0 and . == (gsub("^\\s+|\\s+$"; ""))));
  def management_group_scope_id:
    test("^/providers/Microsoft\\.Management/managementGroups/[^/]+$"; "i");
  def subscription_descendant_id:
    test("^/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(/resourceGroups/[^/]+(/providers/[^/]+/[^/]+/[^/]+(/[^/]+/[^/]+)*)?|/providers/[^/]+/[^/]+/[^/]+(/[^/]+/[^/]+)*)?$"; "i");
  def valid_not_scope($current):
    (ascii_downcase != ($current | ascii_downcase))
      and valid_resource_id_segments
      and (management_group_scope_id or subscription_descendant_id);
  def valid_resource_without_location:
    (.kind == "resourceWithoutLocation")
      and (has("in") != has("notIn"))
      and ((.in // .notIn) == ["subscriptionLevelResources"]);
  . as $cases
  | all($cases.assignmentNames[]; ((.value | valid_assignment_name) == .valid))
    and all($cases.definitionBindings[]; (valid_definition_binding == .valid))
    and all($cases.notScopes[]; ((.value | valid_not_scope($cases.currentManagementGroupId)) == .valid))
    and all($cases.resourceWithoutLocationSelectors[]; ((.selector | valid_resource_without_location) == .valid))
' "${validation_cases}" >/dev/null || {
  printf 'ERROR: Remediating policy assignment negative validation cases did not produce the expected results.\n' >&2
  exit 1
}

jq -e '
  def deployment($name): first(.resources[] | select(.name == $name));
  deployment("example-system-remediation") as $system
  | deployment("example-user-remediation") as $user
  | $system.properties.template as $module
  | $module.resources.assignment as $assignment
  | $module.resources.userAssignedIdentity as $existingIdentity
  | $module.resources.remediationRbac as $rbacDeployment
  | $rbacDeployment.properties.template.resources.remediationRoleAssignments as $roles
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
    and ($user.properties.parameters.identity.value | has("principalId") | not)
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
    and ($module.definitions.UserAssignedIdentity.properties | has("principalId") | not)
    and ($module.definitions.RemediationIdentity.discriminator.mapping | keys | sort) == ["SystemAssigned", "UserAssigned"]
    and ($module.parameters.verifiedRoleDefinitionIds | has("defaultValue") | not)
    and $module.parameters.verifiedRoleDefinitionIds.minLength == 1
    and $module.parameters.enforcementMode.defaultValue == "DoNotEnforce"
    and ($module.variables.validatedAssignmentName | contains("fail(\u0027assignmentName contains a character that is invalid"))
    and ($module.variables.validatedPolicyDefinitionId | contains("fail(\u0027policyDefinitionId must be an exact built-in or management-group"))
    and ($module.variables.validatedDefinitionVersion | contains("fail(\u0027definitionVersion is supported only for built-in definitions and must use N.*.* or N.N.*"))
    and ($module.variables.validatedNonComplianceMessages | contains("fail(\u0027policyDefinitionReferenceId must be non-empty"))
    and ($module.variables.validatedNotScopes | contains("fail(\u0027notScopes must contain only valid descendant management-group"))
    and ($module.variables.validatedResourceSelectors | contains("fail(\u0027resourceSelectors must use unique names"))
    and ($module.variables.validatedResourceSelectors | contains("fail(\u0027Each selector kind can be used only once within a resource selector"))
    and ($module.variables.validatedResourceSelectors | contains("fail(\u0027resourceLocation and resourceWithoutLocation cannot be used in the same resource selector"))
    and ($module.variables.validatedResourceSelectors | contains("fail(\u0027resourceWithoutLocation must use the single supported value subscriptionLevelResources"))
    and ($module.variables.validatedResourceSelectors | contains("fail(\u0027Each resource selector expression must provide one non-empty in or notIn array containing no more than 50 values"))
    and ($module.variables.validatedLocation | contains("location must be a non-global Azure region"))
    and ($module.variables.validatedUserAssignedIdentityResourceId | contains("UserAssigned identity configuration must contain a valid user-assigned managed identity resource ID"))
    and ($module.variables.validatedRoleDefinitionIds | contains("must not contain Owner or User Access Administrator"))
    and $assignment.type == "Microsoft.Authorization/policyAssignments"
    and $assignment.apiVersion == "2025-03-01"
    and $assignment.location == "[variables(\u0027validatedLocation\u0027)]"
    and ($assignment.identity | contains("parameters(\u0027identity\u0027).type"))
    and ($assignment.identity | contains("userAssignedIdentities"))
    and ($assignment.properties | contains("parameters(\u0027enforcementMode\u0027)"))
    and ($assignment.properties | contains("variables(\u0027validatedPolicyDefinitionId\u0027)"))
    and ($assignment.properties | contains("variables(\u0027validatedNonComplianceMessages\u0027)"))
    and ($assignment.properties | contains("variables(\u0027validatedNotScopes\u0027)"))
    and ($assignment.properties | contains("variables(\u0027validatedResourceSelectors\u0027)"))
    and $existingIdentity.existing == true
    and $existingIdentity.type == "Microsoft.ManagedIdentity/userAssignedIdentities"
    and $existingIdentity.apiVersion == "2024-11-30"
    and $existingIdentity.condition == "[equals(parameters(\u0027identity\u0027).type, \u0027UserAssigned\u0027)]"
    and $rbacDeployment.type == "Microsoft.Resources/deployments"
    and ($rbacDeployment.properties.parameters.principalId | tostring | contains("reference(\u0027userAssignedIdentity\u0027).principalId"))
    and ($rbacDeployment.properties.parameters.principalId | tostring | contains("reference(\u0027assignment\u0027"))
    and $rbacDeployment.properties.parameters.roleDefinitionIds.value == "[variables(\u0027validatedRoleDefinitionIds\u0027)]"
    and ($rbacDeployment.dependsOn | sort) == ["assignment", "userAssignedIdentity"]
    and $roles.type == "Microsoft.Authorization/roleAssignments"
    and $roles.apiVersion == "2022-04-01"
    and $roles.copy.count == "[length(parameters(\u0027roleDefinitionIds\u0027))]"
    and $roles.name == "[guid(managementGroup().id, parameters(\u0027principalId\u0027), parameters(\u0027roleDefinitionIds\u0027)[copyIndex()])]"
    and $roles.properties.principalType == "ServicePrincipal"
    and $roles.properties.principalId == "[parameters(\u0027principalId\u0027)]"
    and $roles.properties.roleDefinitionId == "[tenantResourceId(\u0027Microsoft.Authorization/roleDefinitions\u0027, parameters(\u0027roleDefinitionIds\u0027)[copyIndex()])]"
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
