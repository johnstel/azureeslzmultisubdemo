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

compiled_exemption_shapes="${TEMP_DIR}/policy-exemption-shapes.json"
az bicep build \
  --file "${SCRIPT_DIR}/fixtures/policy-exemption-shapes.bicep" \
  --outfile "${compiled_exemption_shapes}" >/dev/null

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
expect_bicep_build_failure \
  "${SCRIPT_DIR}/fixtures/invalid-policy-exemption-expiry.bicep" \
  'a policy exemption with an empty expiresOn value'
expect_bicep_build_failure \
  "${SCRIPT_DIR}/fixtures/invalid-policy-exemption-scope.bicep" \
  'a policy exemption with an unsupported exemptionScopeType value'

compile_exemption_fixture() {
  local fixture="$1"
  local description="$2"
  local output="${TEMP_DIR}/$(basename "${fixture}" .bicep).json"
  az bicep build --file "${fixture}" --outfile "${output}" >/dev/null
  jq -e '
    [
      .. | objects
      | select(.variables? and .variables.validatedScopedPolicyAssignmentId? and .variables.validatedPolicyDefinitionReferenceIds?)
    ] | length > 0
  ' "${output}" >/dev/null || {
    printf 'ERROR: Exemption fixture did not compile through the policy-exemption module validation path: %s\n' "${description}" >&2
    exit 1
  }
}

compile_exemption_fixture \
  "${SCRIPT_DIR}/fixtures/invalid-policy-exemption-assignment-ancestry.bicep" \
  'assignment ancestry negative fixture'
compile_exemption_fixture \
  "${SCRIPT_DIR}/fixtures/invalid-policy-exemption-assignment-shape.bicep" \
  'assignment shape negative fixture'
compile_exemption_fixture \
  "${SCRIPT_DIR}/fixtures/invalid-policy-exemption-reference-contract.bicep" \
  'reference contract negative fixture'
compile_exemption_fixture \
  "${SCRIPT_DIR}/fixtures/invalid-policy-exemption-reference-missing-allowlist.bicep" \
  'missing reference allowlist negative fixture'
compile_exemption_fixture \
  "${SCRIPT_DIR}/fixtures/invalid-policy-exemption-timestamp-date.bicep" \
  'timestamp calendar-date negative fixture'
compile_exemption_fixture \
  "${SCRIPT_DIR}/fixtures/invalid-policy-exemption-timestamp-format.bicep" \
  'timestamp format negative fixture'
compile_exemption_fixture \
  "${SCRIPT_DIR}/fixtures/invalid-policy-exemption-whitespace-fields.bicep" \
  'whitespace-required-fields negative fixture'

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

exemption_validation_cases="${SCRIPT_DIR}/fixtures/policy-exemption-validation-cases.json"
jq -e '
  def is_trimmed_non_empty:
    . as $value
    | ($value | type) == "string"
      and ($value != "")
      and ($value == ($value | gsub("^\\s+|\\s+$"; "")));
  def is_rfc3339_utc:
    . as $value
    | ($value | type) == "string"
      and ($value | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
      and (($value[0:4] | tonumber) as $year
        | ($value[5:7] | tonumber) as $month
        | ($value[8:10] | tonumber) as $day
        | ($value[11:13] | tonumber) as $hour
        | ($value[14:16] | tonumber) as $minute
        | ($value[17:19] | tonumber) as $second
        | ($month >= 1 and $month <= 12)
          and ($day >= 1 and $day <= (if $month == 2 then (if (($year % 4 == 0 and $year % 100 != 0) or ($year % 400 == 0)) then 29 else 28 end) elif ($month == 4 or $month == 6 or $month == 9 or $month == 11) then 30 else 31 end))
          and ($hour >= 0 and $hour <= 23)
          and ($minute >= 0 and $minute <= 59)
          and ($second >= 0 and $second <= 59));
  def is_guid:
    test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"; "i");
  def is_valid_resource_id:
    startswith("/")
      and (endswith("/") | not)
      and (split("/")[1:] | all(.[]; length > 0 and . == (gsub("^\\s+|\\s+$"; ""))));
  def is_management_group_scope_id:
    test("^/providers/Microsoft\\.Management/managementGroups/[^/]+$"; "i");
  def is_subscription_scope_id:
    test("^/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"; "i");
  def assignment_scope:
    if test("^/providers/Microsoft\\.Management/managementGroups/[^/]+/providers/Microsoft\\.Authorization/policyAssignments/[^/]+$"; "i") then
      { assignmentScopeId: ("/providers/Microsoft.Management/managementGroups/" + (split("/")[4]) | ascii_downcase), assignmentScopeType: "managementGroup" }
    elif test("^/subscriptions/[0-9a-f-]{36}/providers/Microsoft\\.Authorization/policyAssignments/[^/]+$"; "i") then
      { assignmentScopeId: ("/subscriptions/" + (split("/")[2]) | ascii_downcase), assignmentScopeType: "subscription" }
    elif test("^/subscriptions/[0-9a-f-]{36}/resourceGroups/[^/]+/providers/Microsoft\\.Authorization/policyAssignments/[^/]+$"; "i") then
      { assignmentScopeId: ("/subscriptions/" + (split("/")[2]) + "/resourceGroups/" + (split("/")[4]) | ascii_downcase), assignmentScopeType: "resourceGroup" }
    else null end;
  def valid_policy_assignment_scope_contract:
    . as $case
    | [$case.permittedAncestorAssignmentScopeIds[] | gsub("^\\s+|\\s+$"; "") | ascii_downcase] as $permitted
    | ($permitted | all(.[]; . != "" and (is_management_group_scope_id or is_subscription_scope_id))) as $permittedShapesValid
    | (($permitted | unique | length) == ($permitted | length)) as $permittedUnique
    | ($case.policyAssignmentId | assignment_scope) as $assignment
    | if ($case.policyAssignmentId | is_valid_resource_id | not) or $assignment == null or ($permittedShapesValid | not) or ($permittedUnique | not) then false else
        if $case.scopeType == "managementGroup" then
          ($case.managementGroupName | is_trimmed_non_empty)
          and ($case.subscriptionId == "")
          and ($case.resourceGroupName == "")
          and ([$permitted[] | select((is_management_group_scope_id | not) or . == ("/providers/Microsoft.Management/managementGroups/" + $case.managementGroupName | ascii_downcase))] | length == 0)
          and (
            $assignment.assignmentScopeId == ("/providers/Microsoft.Management/managementGroups/" + $case.managementGroupName | ascii_downcase)
            or ($assignment.assignmentScopeType == "managementGroup" and ($permitted | index($assignment.assignmentScopeId) != null))
          )
        elif $case.scopeType == "subscription" then
          ($case.subscriptionId | is_guid)
          and ($case.managementGroupName == "")
          and ($case.resourceGroupName == "")
          and ([$permitted[] | select(is_management_group_scope_id | not)] | length == 0)
          and (
            $assignment.assignmentScopeId == ("/subscriptions/" + $case.subscriptionId | ascii_downcase)
            or ($assignment.assignmentScopeType == "managementGroup" and ($permitted | index($assignment.assignmentScopeId) != null))
          )
        else
          ($case.subscriptionId | is_guid)
          and ($case.resourceGroupName | is_trimmed_non_empty)
          and ($case.managementGroupName == "")
          and ([$permitted[] | select((is_management_group_scope_id or . == ("/subscriptions/" + $case.subscriptionId | ascii_downcase)) | not)] | length == 0)
          and (
            $assignment.assignmentScopeId == ("/subscriptions/" + $case.subscriptionId + "/resourceGroups/" + $case.resourceGroupName | ascii_downcase)
            or ($assignment.assignmentScopeType == "managementGroup" and ($permitted | index($assignment.assignmentScopeId) != null))
            or ($assignment.assignmentScopeType == "subscription" and $assignment.assignmentScopeId == ("/subscriptions/" + $case.subscriptionId | ascii_downcase) and ($permitted | index($assignment.assignmentScopeId) != null))
          )
        end
      end;
  def valid_reference_contract:
    [.allowed[] | ascii_downcase | gsub("^\\s+|\\s+$"; "")] as $allowed
    | [.provided[] | gsub("^\\s+|\\s+$"; "")] as $provided_trimmed
    | [$provided_trimmed[] | ascii_downcase] as $provided
    | (($allowed | all(. != "")) and (($allowed | unique | length) == ($allowed | length)))
      and (($provided_trimmed | all(. != "")))
      and (($provided | unique | length) == ($provided | length))
      and ($provided | length == 0 or ($allowed | length > 0))
      and (([$provided[] as $providedReferenceId | select(($allowed | index($providedReferenceId)) == null)] | length) == 0);
  . as $cases
  | all($cases.trimmedRequiredStrings[]; ((.value | is_trimmed_non_empty) == .valid))
    and all($cases.rfc3339UtcTimestamps[]; ((.value | is_rfc3339_utc) == .valid))
    and all($cases.policyAssignmentScopeContracts[]; (valid_policy_assignment_scope_contract == .valid))
    and all($cases.policyDefinitionReferenceContracts[]; (valid_reference_contract == .valid))
' "${exemption_validation_cases}" >/dev/null || {
  printf 'ERROR: Policy exemption string/timestamp validation vectors did not produce expected results.\n' >&2
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
      "Microsoft.Network/virtualNetworks",
      "Microsoft.SecurityInsights/onboardingStates"
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

jq -e '
  . as $root
  | def deployments: [$root | .. | objects | select(.type? == "Microsoft.Resources/deployments")];
    def deployment($name): first(deployments[] | select(.name? == $name));
    deployment("example-management-group-exemption") as $mg
  | deployment("example-subscription-exemption") as $sub
  | deployment("example-resource-group-exemption") as $rg
  | deployment("example-inherited-assignment-exemption") as $inherited
  | $mg.properties.template as $module
  | $module.resources.managementGroupExemption.properties.template.resources.exemption as $mgResource
  | ($mg.properties.parameters | keys | sort) == [
      "approver",
      "createdOn",
      "description",
      "displayName",
      "exemptionCategory",
      "exemptionName",
      "exemptionScopeType",
      "expiresOn",
      "justification",
      "managementGroupName",
      "owner",
      "policyAssignmentId",
      "reviewedOn",
      "ticketReference"
    ]
    and (($sub.properties.parameters | keys | sort) == [
      "approver",
      "createdOn",
      "description",
      "displayName",
      "exemptionCategory",
      "exemptionName",
      "exemptionScopeType",
      "expiresOn",
      "justification",
      "owner",
      "policyAssignmentId",
      "reviewedOn",
      "subscriptionId",
      "ticketReference"
    ])
    and (($rg.properties.parameters | keys | sort) == [
      "allowedPolicyDefinitionReferenceIds",
      "approver",
      "createdOn",
      "description",
      "displayName",
      "exemptionCategory",
      "exemptionName",
      "exemptionScopeType",
      "expiresOn",
      "governanceOwner",
      "justification",
      "owner",
      "policyAssignmentId",
      "policyDefinitionReferenceIds",
      "resourceGroupName",
      "reviewedOn",
      "source",
      "subscriptionId",
      "ticketReference"
    ])
    and $mg.properties.parameters.exemptionCategory.value == "Waiver"
    and $sub.properties.parameters.exemptionCategory.value == "Mitigated"
    and $inherited.properties.parameters.permittedAncestorAssignmentScopeIds.value == [
      "/subscriptions/44444444-4444-4444-4444-444444444444"
    ]
    and $inherited.properties.parameters.policyAssignmentId.value == "/subscriptions/44444444-4444-4444-4444-444444444444/providers/Microsoft.Authorization/policyAssignments/network-ingress-initiative"
    and $rg.properties.parameters.allowedPolicyDefinitionReferenceIds.value == [
      "public-management-ingress",
      "require-subnet-nsg"
    ]
    and $rg.properties.parameters.policyDefinitionReferenceIds.value == [
      "public-management-ingress",
      "require-subnet-nsg"
    ]
    and $mgResource.type == "Microsoft.Authorization/policyExemptions"
    and $mgResource.apiVersion == "2024-12-01-preview"
    and $mgResource.name == "[parameters(\u0027exemptionName\u0027)]"
    and (($mgResource.properties | type) == "string")
    and ($mgResource.properties | contains("policyAssignmentId"))
    and ($mgResource.properties | contains("exemptionCategory"))
    and ($mgResource.properties | contains("expiresOn"))
    and ($mgResource.properties | contains("ticketReference"))
    and ($mgResource.properties | contains("governanceVersion"))
    and ($mgResource.properties | contains("policyDefinitionReferenceIds"))
    and ($module.variables.managementGroupDeploymentName | contains("uniqueString("))
    and ($module.variables.subscriptionDeploymentName | contains("uniqueString("))
    and ($module.variables.resourceGroupDeploymentName | contains("uniqueString("))
    and $module.parameters.owner.minLength == 1
    and $module.parameters.expiresOn.minLength == 1
    and $module.parameters.ticketReference.minLength == 1
    and $module.parameters.subscriptionId.defaultValue == ""
    and $module.parameters.resourceGroupName.defaultValue == ""
    and $module.parameters.permittedAncestorAssignmentScopeIds.defaultValue == []
    and $module.parameters.source.defaultValue == "Bicep"
    and $module.parameters.governanceOwner.defaultValue == "eslz-v2-governance"
    and (($module.parameters.exemptionCategory.allowedValues | sort) == ["Mitigated", "Waiver"])
    and ($module.variables.validatedDisplayName | contains("fail(\u0027displayName must be non-empty and cannot include leading or trailing whitespace.\u0027"))
    and ($module.variables.validatedPolicyAssignmentId | contains("fail(\u0027policyAssignmentId must be an exact Azure Policy assignment resource ID without trailing separators or whitespace.\u0027"))
    and ($module.variables.validatedScopedPolicyAssignmentId | contains("fail(\u0027resourceGroup exemptions require policyAssignmentId at the target scope or an explicitly permitted ancestor scope.\u0027"))
    and ($module.variables.validatedPermittedAncestorAssignmentScopeIds | contains("fail(\u0027permittedAncestorAssignmentScopeIds must include only supported ancestor scope IDs for the selected exemptionScopeType.\u0027"))
    and ($module.variables.validatedExpiresOn | contains("fail(\u0027expiresOn must be a canonical RFC3339 UTC timestamp with a valid calendar date"))
    and ($module.variables.validatedScopeType | contains("fail(\u0027resourceGroup exemptions require valid subscriptionId and resourceGroupName"))
    and ($module.variables.validatedPolicyDefinitionReferenceIds | contains("fail(\u0027policyDefinitionReferenceIds must be present in allowedPolicyDefinitionReferenceIds.\u0027"))
' "${compiled_exemption_shapes}" >/dev/null || {
  printf 'ERROR: Generalized policy exemption compiled shapes are invalid.\n' >&2
  exit 1
}

printf 'Policy assignment structural validation passed.\n'
