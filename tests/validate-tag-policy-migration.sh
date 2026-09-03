#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEMP_DIR="${PROJECT_DIR}/.test-artifacts/tag-migration-sh-$$"
MOCK_BIN="${TEMP_DIR}/mockbin"
CALL_LOG="${TEMP_DIR}/az-calls.log"
PARAMETER_FILE="${TEMP_DIR}/parameters.json"
mkdir -p "${MOCK_BIN}"
trap 'rm -rf "${TEMP_DIR}"; rmdir "${PROJECT_DIR}/.test-artifacts" 2>/dev/null || true' EXIT

cat > "${PARAMETER_FILE}" <<'JSON'
{
  "parameters": {
    "tenantRootManagementGroupId": { "value": "tenant-root" },
    "namePrefix": { "value": "eslz-demo" },
    "workloadArchetype": { "value": "corp" },
    "connectivitySubscriptionId": { "value": "11111111-1111-1111-1111-111111111111" },
    "workloadSubscriptionId": { "value": "22222222-2222-2222-2222-222222222222" }
  }
}
JSON
cat > "${MOCK_BIN}/az" <<'MOCKAZ'
#!/usr/bin/env python3
import json
import os
import sys

args = sys.argv[1:]
with open(os.environ["AZ_CALL_LOG"], "a", encoding="utf-8") as stream:
    stream.write(" ".join(args) + "\n")
scenario = os.environ.get("AZ_MOCK_SCENARIO", "present")
command = " ".join(arg for arg in args if arg not in ("--output", "json"))
demo = "/providers/Microsoft.Management/managementGroups/eslz-demo"
landing = demo + "-landingzones"
workload = demo + "-corp"
legacy_definition = demo + "/providers/Microsoft.Authorization/policyDefinitions/eslz-demo-require-workload-rg-tags"
initiative = demo + "/providers/Microsoft.Authorization/policySetDefinitions/eslz-demo-required-rg-tags"
built_in = "/providers/Microsoft.Authorization/policyDefinitions/96670d01-0a4d-4649-9c89-2d3abc0a5025"
references = [
    ("require-cost-center", "CostCenter"),
    ("require-application-name", "ApplicationName"),
    ("require-owner", "Owner"),
    ("require-environment", "Environment"),
    ("require-data-classification", "DataClassification"),
    ("require-ssp-id", "SSP-ID"),
]

def emit(value):
    print(json.dumps(value))

if command == "account show":
    subscription = "99999999-9999-9999-9999-999999999999" if scenario == "wrong-active-subscription" else "11111111-1111-1111-1111-111111111111"
    emit({"tenantId": "tenant-a", "id": subscription, "state": "Enabled"})
elif command.startswith("account show --subscription "):
    tenant = "tenant-b" if scenario == "wrong-subscription-tenant" and command.endswith("22222222-2222-2222-2222-222222222222") else "tenant-a"
    subscription = command.rsplit(" ", 1)[1]
    state = "Disabled" if scenario == "disabled-subscription" and subscription.startswith("2222") else "Enabled"
    emit({"tenantId": tenant, "id": subscription, "state": state})
elif command == "account management-group show --name tenant-root":
    emit({"id": "/providers/Microsoft.Management/managementGroups/tenant-root"})
elif command == "account management-group show --name eslz-demo":
    emit({"id": demo, "details": {"parent": {"id": "/providers/Microsoft.Management/managementGroups/tenant-root"}}})
elif command == "account management-group show --name eslz-demo-landingzones":
    emit({"id": landing, "details": {"parent": {"id": demo}}})
elif command == "account management-group show --name eslz-demo-corp":
    parent = demo if scenario == "wrong-ancestry" else landing
    emit({"id": workload, "details": {"parent": {"id": parent}}})
elif command == "policy set-definition show --name eslz-demo-required-rg-tags --management-group eslz-demo":
    if scenario == "replacement-missing":
        print("ERROR: (ResourceNotFound) replacement missing", file=sys.stderr)
        sys.exit(3)
    policy_references = [
        {
            "policyDefinitionId": demo + "/providers/Microsoft.Authorization/policyDefinitions/unrelated"
                if scenario == "replacement-definition-wrong" and reference_id == "require-owner" else built_in,
            "definitionVersion": (
                None if scenario == "replacement-version-missing" and reference_id == "require-owner"
                else "2.*.*" if scenario == "replacement-version-wrong" and reference_id == "require-owner"
                else "1.*.*"
            ),
            "policyDefinitionReferenceId": reference_id,
            "parameters": {"tagName": {"value": (
                "Application" if scenario == "replacement-tag-renamed" and reference_id == "require-application-name"
                else tag_name
            )}},
        }
        for reference_id, tag_name in references
        if not (scenario == "replacement-reference-missing" and reference_id == "require-ssp-id")
    ]
    emit({"id": initiative, "properties": {"policyDefinitions": policy_references}})
elif command == "policy assignment show --name demo-require-rg-tags --scope " + landing:
    if scenario == "replacement-assignment-missing":
        print("ERROR: (PolicyAssignmentNotFound) replacement assignment missing", file=sys.stderr)
        sys.exit(3)
    replacement_link = demo + "/providers/Microsoft.Authorization/policySetDefinitions/unrelated" if scenario == "replacement-link-wrong" else initiative
    properties = {"policyDefinitionId": replacement_link}
    if scenario == "replacement-assignment-excluded":
        properties["notScopes"] = [workload]
    if scenario == "replacement-assignment-selected":
        properties["resourceSelectors"] = [{"name": "limited", "selectors": [{"kind": "resourceLocation", "in": ["eastus"]}]}]
    emit({"id": landing + "/providers/Microsoft.Authorization/policyAssignments/demo-require-rg-tags", "properties": properties})
elif command == "policy assignment show --name demo-require-rg-tags --scope " + workload:
    if scenario in ("assignment-absent", "both-absent"):
        print("ERROR: (PolicyAssignmentNotFound) legacy assignment absent", file=sys.stderr)
        sys.exit(3)
    if scenario == "assignment-read-error":
        print("ERROR: (AuthorizationFailed) access denied", file=sys.stderr)
        sys.exit(3)
    emit({"id": workload + "/providers/Microsoft.Authorization/policyAssignments/demo-require-rg-tags", "properties": {"policyDefinitionId": demo + "/providers/Microsoft.Authorization/policyDefinitions/unrelated" if scenario == "wrong-link" else legacy_definition}})
elif command == "policy definition show --name eslz-demo-require-workload-rg-tags --management-group eslz-demo":
    if scenario in ("definition-absent", "both-absent"):
        print("ERROR: (PolicyDefinitionNotFound) legacy definition absent", file=sys.stderr)
        sys.exit(3)
    if scenario == "definition-read-error":
        print("ERROR: (AuthorizationFailed) access denied", file=sys.stderr)
        sys.exit(3)
    emit({"id": legacy_definition})
elif " delete " in " " + command + " ":
    pass
else:
    print("ERROR: unexpected command: " + command, file=sys.stderr)
    sys.exit(4)
MOCKAZ
chmod +x "${MOCK_BIN}/az"

run_migration() {
  local scenario="$1"
  local confirmation="$2"
  local approval="$3"
  : > "${CALL_LOG}"
  printf '%s\n' "${confirmation}" | env \
    PATH="${MOCK_BIN}:${PATH}" \
    AZ_CALL_LOG="${CALL_LOG}" \
    AZ_MOCK_SCENARIO="${scenario}" \
    ESLZ_TAG_MIGRATION_CONFIRMATION="${approval}" \
    "${PROJECT_DIR}/scripts/migrate-legacy-rg-tags.sh" "${PARAMETER_FILE}" --execute
}

: > "${CALL_LOG}"
preview_output="$(PATH="${MOCK_BIN}:${PATH}" AZ_CALL_LOG="${CALL_LOG}" \
  "${PROJECT_DIR}/scripts/migrate-legacy-rg-tags.sh" "${PARAMETER_FILE}")"
[[ ! -s "${CALL_LOG}" ]]
printf '%s\n' "${preview_output}" | grep -Fq 'Dry run only.'

if run_migration present 'tenant-a/eslz-demo-corp' '' >/dev/null 2>&1; then
  printf 'ERROR: Migration unexpectedly succeeded without explicit approval.\n' >&2
  exit 1
fi
grep -Fq 'policy definition show' "${CALL_LOG}"
! grep -Fq ' delete ' "${CALL_LOG}"

run_migration present 'tenant-a/eslz-demo-corp' 'REMOVE-LEGACY-RG-TAG-POLICY' >/dev/null
delete_calls="$(grep ' delete ' "${CALL_LOG}")"
expected_deletes='policy assignment delete --name demo-require-rg-tags --scope /providers/Microsoft.Management/managementGroups/eslz-demo-corp
policy definition delete --name eslz-demo-require-workload-rg-tags --management-group eslz-demo'
[[ "${delete_calls}" == "${expected_deletes}" ]]

run_migration assignment-absent 'tenant-a/eslz-demo-corp' 'REMOVE-LEGACY-RG-TAG-POLICY' >/dev/null
[[ "$(grep ' delete ' "${CALL_LOG}")" == 'policy definition delete --name eslz-demo-require-workload-rg-tags --management-group eslz-demo' ]]
run_migration definition-absent 'tenant-a/eslz-demo-corp' 'REMOVE-LEGACY-RG-TAG-POLICY' >/dev/null
[[ "$(grep ' delete ' "${CALL_LOG}")" == 'policy assignment delete --name demo-require-rg-tags --scope /providers/Microsoft.Management/managementGroups/eslz-demo-corp' ]]
run_migration both-absent '' '' >/dev/null
! grep -Fq ' delete ' "${CALL_LOG}"

for scenario in wrong-active-subscription wrong-subscription-tenant disabled-subscription wrong-ancestry replacement-missing replacement-assignment-missing replacement-link-wrong replacement-reference-missing replacement-tag-renamed replacement-version-missing replacement-version-wrong replacement-definition-wrong replacement-assignment-excluded replacement-assignment-selected wrong-link assignment-read-error definition-read-error; do
  if run_migration "${scenario}" 'tenant-a/eslz-demo-corp' 'REMOVE-LEGACY-RG-TAG-POLICY' >/dev/null 2>&1; then
    printf 'ERROR: Migration unexpectedly succeeded for scenario %s.\n' "${scenario}" >&2
    exit 1
  fi
  ! grep -Fq ' delete ' "${CALL_LOG}"
done

if grep -Eq 'migrate-legacy-rg-tags' \
  "${PROJECT_DIR}/scripts/deploy.sh" "${PROJECT_DIR}/scripts/deploy.ps1" \
  "${PROJECT_DIR}/scripts/what-if.sh" "${PROJECT_DIR}/scripts/what-if.ps1" \
  "${PROJECT_DIR}/scripts/teardown.sh" "${PROJECT_DIR}/scripts/teardown.ps1"; then
  printf 'ERROR: Legacy tag migration must never run automatically from another lifecycle script.\n' >&2
  exit 1
fi
grep -Fq 'demo-require-rg-tags|${landing_zones_scope}' "${PROJECT_DIR}/scripts/teardown.sh"
if grep -Fq 'demo-require-rg-tags|${workload_scope}' "${PROJECT_DIR}/scripts/teardown.sh"; then
  printf 'ERROR: Bash teardown must not delete the resource-group tags assignment at the workload scope.\n' >&2
  exit 1
fi
grep -Fq 'policy set-definition delete --name "${prefix}-required-rg-tags" --management-group "${prefix}"' "${PROJECT_DIR}/scripts/teardown.sh"
if grep -Fq 'demo-require-workload-rg-tags' "${PROJECT_DIR}/scripts/teardown.sh"; then
  printf 'ERROR: Bash teardown still targets the nonexistent legacy assignment name.\n' >&2
  exit 1
fi

printf 'Tag policy migration Bash validation passed.\n'
