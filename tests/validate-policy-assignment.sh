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
  | def deployment($name): first($root | .. | objects | select(.type? == "Microsoft.Resources/deployments" and .name? == $name));
    deployment("example-policy-assignment") as $policy
  | deployment("example-initiative-assignment") as $initiative
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
      "/providers/Microsoft.Management/managementGroups/excluded"
    ]
    and $initiative.properties.parameters.resourceSelectors.value[0].selectors[0].kind == "resourceLocation"
    and $initiative.properties.parameters.resourceSelectors.value[0].selectors[0].in == ["eastus2", "westus2"]
    and $initiative.properties.parameters.resourceSelectors.value[1].selectors[0].kind == "resourceType"
    and $initiative.properties.parameters.resourceSelectors.value[1].selectors[0].notIn == ["Microsoft.Compute/virtualMachines"]
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
    and ($module.variables.validatedPolicyDefinitionId | contains("fail(\u0027policyDefinitionId must be the full resource ID"))
    and ($module.variables.validatedDefinitionVersion | contains("fail(\u0027definitionVersion must not contain leading or trailing whitespace"))
    and ($module.variables.validatedNonComplianceMessages | contains("fail(\u0027policyDefinitionReferenceId must be non-empty"))
    and ($module.variables.validatedNotScopes | contains("fail(\u0027notScopes must contain only non-empty resource IDs"))
    and ($module.variables.validatedResourceSelectors | contains("fail(\u0027resourceSelectors must use unique names"))
    and ($module.variables.validatedResourceSelectors | contains("fail(\u0027Each selector kind can be used only once within a resource selector"))
    and ($module.variables.validatedResourceSelectors | contains("fail(\u0027resourceLocation and resourceWithoutLocation cannot be used in the same resource selector"))
    and ($module.variables.validatedResourceSelectors | contains("fail(\u0027Each resource selector expression must provide one non-empty in or notIn array containing no more than 50 values"))
    and $resource.type == "Microsoft.Authorization/policyAssignments"
    and $resource.apiVersion == "2025-03-01"
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
