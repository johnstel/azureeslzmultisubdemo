#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARTIFACTS_PARENT="${PROJECT_DIR}/.test-artifacts"
TEMP_DIR="${ARTIFACTS_PARENT}/policy-assignment-sh-$$"
mkdir -p "${TEMP_DIR}"
trap 'rm -rf "${TEMP_DIR}"; rmdir "${ARTIFACTS_PARENT}" 2>/dev/null || true' EXIT

command -v az >/dev/null 2>&1 || {
  printf 'ERROR: Azure CLI is required for policy assignment validation.\n' >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  printf 'ERROR: jq is required for policy assignment validation.\n' >&2
  exit 1
}

compiled_main="${COMPILED_MAIN_TEMPLATE:-}"
if [[ -z "${compiled_main}" ]]; then
  compiled_main="${TEMP_DIR}/main.json"
  az bicep build --file "${PROJECT_DIR}/main.bicep" --outfile "${compiled_main}" >/dev/null
fi
[[ -f "${compiled_main}" ]] || {
  printf 'ERROR: Compiled main template not found: %s\n' "${compiled_main}" >&2
  exit 1
}

compiled_shapes="${TEMP_DIR}/policy-assignment-shapes.json"
az bicep build \
  --file "${SCRIPT_DIR}/fixtures/policy-assignment-shapes.bicep" \
  --outfile "${compiled_shapes}" >/dev/null

expect_bicep_build_failure() {
  local fixture="$1"
  local description="$2"
  local output
  if output="$(az bicep build --file "${fixture}" --stdout 2>&1)"; then
    printf 'ERROR: Bicep unexpectedly accepted %s.\n' "${description}" >&2
    exit 1
  fi
}

expect_bicep_build_failure \
  "${SCRIPT_DIR}/fixtures/invalid-policy-assignment-name.bicep" \
  'a management-group policy assignment name longer than 24 characters'
expect_bicep_build_failure \
  "${SCRIPT_DIR}/fixtures/invalid-policy-selector-kind.bicep" \
  'policyDefinitionReferenceId as a resource selector kind'

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
  printf 'ERROR: Policy assignment negative validation cases did not produce the expected results.\n' >&2
  exit 1
}

jq -e '
  . as $root
  | def deployments: [$root | .. | objects | select(.type? == "Microsoft.Resources/deployments")];
    def assignment($name): first(deployments[] | select(.name? == $name));
    (deployments
      | map(select(.name? as $name | [
          "assign-allowed-locations",
          "assign-audit-public-ip",
          "assign-expensive-resources",
          "assign-platform-tags",
          "assign-workload-rg-tags"
        ] | index($name)))
    ) as $assignments
  | ($assignments | length) == 5
    and (($assignments | map(.name) | sort) == [
      "assign-allowed-locations",
      "assign-audit-public-ip",
      "assign-expensive-resources",
      "assign-platform-tags",
      "assign-workload-rg-tags"
    ])
    and (assignment("assign-allowed-locations").scope | contains("variables(\u0027demoRootManagementGroupId\u0027)"))
    and (assignment("assign-audit-public-ip").scope | contains("variables(\u0027demoRootManagementGroupId\u0027)"))
    and (assignment("assign-expensive-resources").scope | contains("variables(\u0027demoRootManagementGroupId\u0027)"))
    and (assignment("assign-platform-tags").scope | contains("variables(\u0027platformManagementGroupId\u0027)"))
    and (assignment("assign-workload-rg-tags").scope | contains("variables(\u0027workloadManagementGroupId\u0027)"))
    and assignment("assign-allowed-locations").properties.parameters.enforcementMode.value == "[parameters(\u0027denyPolicyEnforcementMode\u0027)]"
    and assignment("assign-audit-public-ip").properties.parameters.enforcementMode.value == "Default"
    and assignment("assign-expensive-resources").properties.parameters.enforcementMode.value == "[parameters(\u0027denyPolicyEnforcementMode\u0027)]"
    and assignment("assign-platform-tags").properties.parameters.enforcementMode.value == "Default"
    and assignment("assign-workload-rg-tags").properties.parameters.enforcementMode.value == "[parameters(\u0027denyPolicyEnforcementMode\u0027)]"
    and assignment("assign-allowed-locations").properties.parameters.assignmentName.value == "demo-allowed-us-locs"
    and assignment("assign-audit-public-ip").properties.parameters.assignmentName.value == "demo-audit-public-ip"
    and assignment("assign-expensive-resources").properties.parameters.assignmentName.value == "demo-block-expensive"
    and assignment("assign-platform-tags").properties.parameters.assignmentName.value == "demo-audit-platform-tags"
    and assignment("assign-workload-rg-tags").properties.parameters.assignmentName.value == "demo-require-rg-tags"
    and (($assignments | map(.properties.parameters.assignmentName.value) | unique | length) == 5)
    and all($assignments[]; (.properties.parameters.assignmentName.value | length) <= 24)
    and assignment("assign-allowed-locations").properties.parameters.parameters.value.allowedLocations.value == "[parameters(\u0027allowedLocations\u0027)]"
    and assignment("assign-audit-public-ip").properties.parameters.parameters.value == {}
    and assignment("assign-expensive-resources").properties.parameters.parameters.value == {}
    and assignment("assign-platform-tags").properties.parameters.parameters.value == {}
    and assignment("assign-workload-rg-tags").properties.parameters.parameters.value == {}
    and all($assignments[];
      (.properties.template.resources.assignment | has("identity") | not)
      and (.properties.template.resources.assignment | has("location") | not)
    )
' "${compiled_main}" >/dev/null || {
  printf 'ERROR: Existing policy assignment effects, parameters, scopes, or identity-free shape changed.\n' >&2
  exit 1
}

jq -e '
  . as $root
  | first($root.resources[] | select(.type == "Microsoft.Resources/deployments" and .name == "root-deployment-restrictions")) as $rootRestrictions
  | first($root.resources[] | select(.type == "Microsoft.Resources/deployments" and (.name | contains("policy-library")))) as $policyLibrary
  | first($policyLibrary.properties.template.resources[] | select(.properties.displayName? == "Demo - allowed resource types (all resources)")) as $allowedResourceTypesPolicy
  | first($rootRestrictions.properties.template.resources[] | select(.name == "root-deployment-restrictions")) as $initiative
  | first($rootRestrictions.properties.template.resources[] | select(.name == "assign-root-deployment-restrictions")) as $assignment
  | $initiative.properties.parameters.policyDefinitionReferences.value as $references
  | $assignment.properties.parameters.nonComplianceMessages.value as $messages
  | ($rootRestrictions.scope | contains("variables(\u0027demoRootManagementGroupId\u0027)"))
    and $rootRestrictions.properties.parameters.allowedLocations.value == "[parameters(\u0027customerAllowedLocations\u0027)]"
    and $rootRestrictions.properties.parameters.allowedResourceTypes.value == "[parameters(\u0027customerAllowedResourceTypes\u0027)]"
    and $rootRestrictions.properties.parameters.allowedVmSkus.value == "[parameters(\u0027customerAllowedVmSkus\u0027)]"
    and $rootRestrictions.properties.parameters.enforcementMode.value == "[parameters(\u0027denyPolicyEnforcementMode\u0027)]"
    and ($rootRestrictions.properties.parameters.allowedResourceTypesPolicyDefinitionId.value | contains("allowedResourceTypesAllPolicyDefinitionId"))
    and $root.parameters.customerAllowedLocations.defaultValue == ["eastus", "eastus2"]
    and ($root.parameters.allowedLocations.defaultValue | length) == 9
    and $allowedResourceTypesPolicy.properties.mode == "All"
    and $allowedResourceTypesPolicy.properties.parameters.allowedResourceTypes.type == "Array"
    and $allowedResourceTypesPolicy.properties.policyRule.if.field == "type"
    and $allowedResourceTypesPolicy.properties.policyRule.if.notIn == "[[parameters(\u0027allowedResourceTypes\u0027)]"
    and $allowedResourceTypesPolicy.properties.policyRule.then.effect == "deny"
    and ($references | map(.policyDefinitionReferenceId) | sort) == [
      "allowed-locations",
      "allowed-resource-types",
      "allowed-vm-skus",
      "audit-managed-disks",
      "audit-public-ip"
    ]
    and $references[0].parameters.listOfAllowedLocations.value == "[[parameters(\u0027allowedLocations\u0027)]"
    and $references[0].parameters.effect.value == "Deny"
    and $references[1].policyDefinitionId == "[parameters(\u0027allowedResourceTypesPolicyDefinitionId\u0027)]"
    and $references[1].parameters.allowedResourceTypes.value == "[[parameters(\u0027allowedResourceTypes\u0027)]"
    and $references[2].parameters.listOfAllowedSKUs.value == "[[parameters(\u0027allowedVmSkus\u0027)]"
    and $assignment.properties.parameters.assignmentName.value == "demo-deploy-restrictions"
    and $assignment.properties.parameters.enforcementMode.value == "[parameters(\u0027enforcementMode\u0027)]"
    and ($messages | length) == 5
    and (($messages | map(.policyDefinitionReferenceId) | sort) == ($references | map(.policyDefinitionReferenceId) | sort))
    and ([
      "Microsoft.Authorization/policyDefinitions",
      "Microsoft.Authorization/policyExemptions",
      "Microsoft.Authorization/policySetDefinitions",
      "Microsoft.Insights/diagnosticSettings",
      "Microsoft.Compute/virtualMachines/extensions",
      "Microsoft.Network/networkInterfaces",
      "Microsoft.Network/privateEndpoints",
      "Microsoft.Network/privateEndpoints/privateDnsZoneGroups",
      "Microsoft.Network/privateDnsZones/virtualNetworkLinks",
      "Microsoft.Network/publicIPAddresses",
      "Microsoft.RecoveryServices/vaults/backupPolicies",
      "Microsoft.RecoveryServices/vaults/backupFabrics",
      "Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers",
      "Microsoft.PolicyInsights/remediations",
      "Microsoft.Resources/resourceGroups",
      "Microsoft.Network/networkSecurityGroups",
      "Microsoft.Network/virtualNetworks"
    ] - $root.parameters.customerAllowedResourceTypes.defaultValue | length) == 0
' "${compiled_main}" >/dev/null || {
  printf 'ERROR: Root deployment-restrictions initiative is not safely scoped, parameterized, or composed.\n' >&2
  exit 1
}

jq -e '
  . as $root
  | def deployment($name): first($root | .. | objects | select(.type? == "Microsoft.Resources/deployments" and .name? == $name));
    deployment("example-policy-assignment") as $policy
  | deployment("example-initiative-assignment") as $initiative
  | deployment("example-custom-policy-assignment") as $custom
  | $policy.properties.template as $module
  | $module.resources.assignment as $resource
  | $resource.properties as $propertiesExpression
  | ($policy.properties.parameters | keys | sort) == [
      "assignmentName",
      "description",
      "displayName",
      "policyDefinitionId"
    ]
    and $policy.properties.parameters.policyDefinitionId.value == "/providers/Microsoft.Authorization/policyDefinitions/11111111-1111-1111-1111-111111111111"
    and ($initiative.properties.parameters | keys | sort) == [
      "assignmentName",
      "definitionVersion",
      "description",
      "displayName",
      "enforcementMode",
      "metadata",
      "nonComplianceMessages",
      "notScopes",
      "parameters",
      "policyDefinitionId",
      "resourceSelectors"
    ]
    and $initiative.properties.parameters.policyDefinitionId.value == "/providers/Microsoft.Authorization/policySetDefinitions/22222222-2222-2222-2222-222222222222"
    and $initiative.properties.parameters.definitionVersion.value == "1.2.*"
    and $initiative.properties.parameters.enforcementMode.value == "Default"
    and $initiative.properties.parameters.parameters.value.effect.value == "Audit"
    and $initiative.properties.parameters.metadata.value == {
      "category": "Test",
      "owner": "Platform Team"
    }
    and ($initiative.properties.parameters.nonComplianceMessages.value | length) == 2
    and $initiative.properties.parameters.nonComplianceMessages.value[1].policyDefinitionReferenceId == "audit-reference"
    and $initiative.properties.parameters.notScopes.value == [
      "/providers/Microsoft.Management/managementGroups/excluded",
      "/subscriptions/33333333-3333-3333-3333-333333333333/resourceGroups/rg-excluded/providers/Microsoft.Network/virtualNetworks/vnet-excluded/subnets/default"
    ]
    and $initiative.properties.parameters.resourceSelectors.value[0].selectors[0].kind == "resourceLocation"
    and $initiative.properties.parameters.resourceSelectors.value[0].selectors[0].in == ["eastus2", "westus2"]
    and $initiative.properties.parameters.resourceSelectors.value[1].selectors[0].kind == "resourceType"
    and $initiative.properties.parameters.resourceSelectors.value[1].selectors[0].notIn == ["Microsoft.Compute/virtualMachines"]
    and $initiative.properties.parameters.resourceSelectors.value[2].selectors[0].kind == "resourceWithoutLocation"
    and $initiative.properties.parameters.resourceSelectors.value[2].selectors[0].in == ["subscriptionLevelResources"]
    and $custom.properties.parameters.policyDefinitionId.value == "/providers/Microsoft.Management/managementGroups/demo-root/providers/Microsoft.Authorization/policyDefinitions/custom-policy"
    and ($custom.properties.parameters | has("definitionVersion") | not)
    and $module.parameters.assignmentName.maxLength == 24
    and $module.parameters.enforcementMode.defaultValue == "DoNotEnforce"
    and $module.parameters.parameters.defaultValue == {}
    and $module.parameters.metadata.defaultValue == {
      "category": "Demo Landing Zone",
      "source": "Bicep"
    }
    and $module.parameters.nonComplianceMessages.defaultValue == []
    and $module.parameters.notScopes.defaultValue == []
    and $module.parameters.resourceSelectors.defaultValue == []
    and $module.parameters.resourceSelectors.maxLength == 10
    and $module.definitions.NonComplianceMessage.additionalProperties == false
    and $module.definitions.NonComplianceMessage.properties.message.minLength == 1
    and $module.definitions.NonComplianceMessage.properties.message.maxLength == 500
    and $module.definitions.Selector.additionalProperties == false
    and ($module.definitions.Selector.properties.kind.allowedValues | sort) == [
      "resourceLocation",
      "resourceType",
      "resourceWithoutLocation"
    ]
    and $module.definitions.ResourceSelector.additionalProperties == false
    and $module.definitions.ResourceSelector.properties.selectors.minLength == 1
    and $module.definitions.ResourceSelector.properties.selectors.maxLength == 10
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
    and $resource.type == "Microsoft.Authorization/policyAssignments"
    and $resource.apiVersion == "2025-03-01"
    and $resource.name == "[variables(\u0027validatedAssignmentName\u0027)]"
    and ($resource | has("identity") | not)
    and ($resource | has("location") | not)
    and ($propertiesExpression | type) == "string"
    and ($propertiesExpression | contains("if(not(empty(parameters(\u0027definitionVersion\u0027))), createObject(\u0027definitionVersion\u0027"))
    and ($propertiesExpression | contains("if(not(empty(parameters(\u0027parameters\u0027))), createObject(\u0027parameters\u0027"))
    and ($propertiesExpression | contains("if(not(empty(parameters(\u0027metadata\u0027))), createObject(\u0027metadata\u0027"))
    and ($propertiesExpression | contains("if(not(empty(parameters(\u0027nonComplianceMessages\u0027))), createObject(\u0027nonComplianceMessages\u0027"))
    and ($propertiesExpression | contains("if(not(empty(parameters(\u0027notScopes\u0027))), createObject(\u0027notScopes\u0027"))
    and ($propertiesExpression | contains("if(not(empty(parameters(\u0027resourceSelectors\u0027))), createObject(\u0027resourceSelectors\u0027"))
' "${compiled_shapes}" >/dev/null || {
  printf 'ERROR: Generalized policy and initiative assignment compiled shapes are invalid.\n' >&2
  exit 1
}

printf 'Policy assignment structural validation passed.\n'
