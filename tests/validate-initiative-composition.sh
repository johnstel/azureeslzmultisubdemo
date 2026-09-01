#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARTIFACTS_PARENT="${PROJECT_DIR}/.test-artifacts"
TEMP_DIR="${ARTIFACTS_PARENT}/initiative-sh-$$"
MODULE_JSON="${TEMP_DIR}/policy-initiative.json"
EXAMPLE_JSON="${TEMP_DIR}/initiative-composition.json"
mkdir -p "${TEMP_DIR}"
trap 'rm -rf "${TEMP_DIR}"; rmdir "${ARTIFACTS_PARENT}" 2>/dev/null || true' EXIT

command -v az >/dev/null 2>&1 || {
  printf 'ERROR: Azure CLI is required for Bicep validation.\n' >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  printf 'ERROR: jq is required for initiative structural tests.\n' >&2
  exit 1
}
command -v rg >/dev/null 2>&1 || {
  printf 'ERROR: ripgrep is required for initiative structural tests.\n' >&2
  exit 1
}

printf '1/8 Build the initiative module and compile-time example...\n'
az bicep build \
  --file "${PROJECT_DIR}/modules/policy-initiative.bicep" \
  --outfile "${MODULE_JSON}"
az bicep build \
  --file "${PROJECT_DIR}/examples/initiative-composition.bicep" \
  --outfile "${EXAMPLE_JSON}"

printf '2/8 Validate the typed management-group module contract...\n'
jq -e '
  .["$schema"] == "https://schema.management.azure.com/schemas/2019-08-01/managementGroupDeploymentTemplate.json#" and
  .languageVersion == "2.0" and
  .parameters.initiativeParameters.type == "object" and
  .parameters.policyDefinitionGroups.type == "array" and
  .parameters.policyDefinitionGroups.items["$ref"] == "#/definitions/policyDefinitionGroup" and
  .parameters.policyDefinitionReferences.type == "array" and
  .parameters.policyDefinitionReferences.minLength == 1 and
  .parameters.policyDefinitionReferences.items["$ref"] == "#/definitions/policyDefinitionReference" and
  .definitions.policyDefinitionReference.additionalProperties == false and
  .definitions.policyDefinitionReference.properties.policyDefinitionId.minLength == 1 and
  .definitions.policyDefinitionReference.properties.definitionVersion.type == "string" and
  .definitions.policyDefinitionReference.properties.definitionVersion.nullable == true and
  .definitions.policyDefinitionReference.properties.policyDefinitionReferenceId.minLength == 1 and
  .definitions.policyDefinitionReference.properties.parameters.type == "object" and
  .definitions.policyDefinitionReference.properties.groupNames.type == "array" and
  .definitions.policyDefinitionGroup.additionalProperties == false and
  .definitions.policyDefinitionGroup.properties.name.minLength == 1
' "${MODULE_JSON}" >/dev/null

printf '3/8 Validate initiative resource metadata and pass-through properties...\n'
jq -e '
  .resources.initiative.type == "Microsoft.Authorization/policySetDefinitions" and
  .resources.initiative.apiVersion == "2025-03-01" and
  .resources.initiative.properties.policyType == "Custom" and
  .resources.initiative.properties.displayName == "[parameters(\u0027initiativeDisplayName\u0027)]" and
  .resources.initiative.properties.description == "[parameters(\u0027initiativeDescription\u0027)]" and
  .resources.initiative.properties.parameters == "[parameters(\u0027initiativeParameters\u0027)]" and
  .resources.initiative.properties.policyDefinitionGroups == "[parameters(\u0027policyDefinitionGroups\u0027)]" and
  .resources.initiative.properties.version == "[parameters(\u0027initiativeVersion\u0027)]" and
  .resources.initiative.properties.metadata.category == "[parameters(\u0027initiativeCategory\u0027)]" and
  .resources.initiative.properties.metadata.version == "[parameters(\u0027initiativeVersion\u0027)]" and
  .resources.initiative.properties.metadata.governanceVersion == "2.0" and
  .resources.initiative.properties.metadata.managedBy == "Bicep" and
  .resources.initiative.properties.copy[0].name == "policyDefinitions" and
  (.resources.initiative.properties.copy[0].input | contains("validatedPolicyDefinitionReferences")) and
  (.resources.initiative.properties.copy[0].input | contains("definitionVersion")) and
  (.resources.initiative.properties.copy[0].input | contains(".parameters")) and
  (.resources.initiative.properties.copy[0].input | contains(".groupNames"))
' "${MODULE_JSON}" >/dev/null

printf '4/8 Validate empty and duplicate reference-ID guards...\n'
jq -e '
  .variables.copy[0].name == "normalizedPolicyDefinitionReferenceIds" and
  (.variables.copy[0].input | contains("toLower(")) and
  (.variables.hasDuplicatePolicyDefinitionReferenceIds | contains("union(")) and
  (.variables.validatedPolicyDefinitionReferences | contains("fail(\u0027policyDefinitionReferences must use non-empty, case-insensitively unique policyDefinitionReferenceId values.")) and
  .definitions.policyDefinitionReference.properties.policyDefinitionReferenceId.minLength == 1
' "${MODULE_JSON}" >/dev/null

printf '5/8 Validate deterministic module outputs...\n'
jq -e '
  (.outputs.policySetDefinitionId.value | contains("extensionResourceId(managementGroup().id")) and
  .outputs.policySetDefinitionName.value == "[parameters(\u0027initiativeName\u0027)]" and
  .outputs.policyDefinitionReferenceIds.type == "array" and
  (.outputs.policyDefinitionReferenceIds.copy.input | contains(".policyDefinitionReferenceId"))
' "${MODULE_JSON}" >/dev/null

printf '6/8 Validate dedicated demo-root scope, stable references, groups, and parameter mappings...\n'
jq -e '
  .["$schema"] == "https://schema.management.azure.com/schemas/2019-08-01/tenantDeploymentTemplate.json#" and
  (.resources.organizationalAuditInitiative.scope | contains("demoRootManagementGroupId")) and
  .resources.organizationalAuditInitiative.properties.parameters.policyDefinitionReferences.value as $references |
  .resources.organizationalAuditInitiative.properties.parameters.policyDefinitionGroups.value as $groups |
  ($references | length) == 2 and
  ($references | map(.policyDefinitionReferenceId | select(length > 0)) | length) == 2 and
  ($references | map(.policyDefinitionReferenceId | ascii_downcase) | unique | length) == 2 and
  ($groups | map(.name) | index("deployment-visibility")) != null and
  ($references | all(.groupNames | index("deployment-visibility") != null)) and
  $references[0].parameters.listOfAllowedLocations.value == "[[parameters(\u0027allowedLocations\u0027)]" and
  $references[0].parameters.effect.value == "[[parameters(\u0027effect\u0027)]" and
  .resources.organizationalAuditInitiative.properties.parameters.initiativeParameters.value.effect.defaultValue == "Audit" and
  .outputs.policySetDefinitionId and
  .outputs.policySetDefinitionName and
  .outputs.policyDefinitionReferenceIds
' "${EXAMPLE_JSON}" >/dev/null

printf '7/8 Confirm every sample definition identifier is authoritative...\n'
rg -o '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' \
  "${PROJECT_DIR}/examples/initiative-composition.bicep" |
  sort -u |
  while IFS= read -r definition_id; do
    jq -e --arg definition_id "${definition_id}" '
      [
        .controls[]
        | select(
            .classification == "azure-policy" and
            .mechanism.builtIn == true and
            ((.mechanism.definitionId | ascii_downcase) == ($definition_id | ascii_downcase))
          )
      ] | length >= 1
    ' "${PROJECT_DIR}/policy/control-catalog.json" >/dev/null || {
      printf 'ERROR: Example policy definition ID is not a verified built-in in the control catalog: %s\n' "${definition_id}" >&2
      exit 1
    }
  done
jq -e '
  [
    .controls[]
    | select(
        .classification == "azure-policy" and
        .mechanism.builtIn == false and
        .mechanism.definitionId == "${namePrefix}-audit-public-ip" and
        .mechanism.verificationMethod == "in-repository-custom-definition"
      )
  ] | length == 1
' "${PROJECT_DIR}/policy/control-catalog.json" >/dev/null
rg -q "'\\$\\{namePrefix\\}-audit-public-ip'" "${PROJECT_DIR}/examples/initiative-composition.bicep"

printf '8/8 Confirm the example is audit-first, unassigned, and no-cost-safe...\n'
jq -e '
  [
    .. | objects | .type?
    | select(type == "string" and startswith("Microsoft."))
  ]
  | all(
      . == "Microsoft.Resources/deployments" or
      . == "Microsoft.Authorization/policySetDefinitions"
    )
' "${EXAMPLE_JSON}" >/dev/null
if rg -q 'policyAssignments|roleAssignments|deployIfNotExists|modify' "${PROJECT_DIR}/examples/initiative-composition.bicep"; then
  printf 'ERROR: The compile-time example must remain unassigned and audit-first.\n' >&2
  exit 1
fi

printf '\nInitiative composition validation passed.\n'
