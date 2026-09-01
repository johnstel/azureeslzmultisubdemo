#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEMP_DIR="${PROJECT_DIR}/.test-artifacts/tag-migration-sh-$$"
MOCK_BIN="${TEMP_DIR}/mockbin"
CALL_LOG="${TEMP_DIR}/az-calls.log"
mkdir -p "${MOCK_BIN}"
trap 'rm -rf "${TEMP_DIR}"; rmdir "${PROJECT_DIR}/.test-artifacts" 2>/dev/null || true' EXIT

cat > "${TEMP_DIR}/parameters.json" <<'JSON'
{
  "parameters": {
    "namePrefix": { "value": "eslz-demo" },
    "workloadArchetype": { "value": "corp" }
  }
}
JSON
cat > "${MOCK_BIN}/az" <<'MOCKAZ'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${AZ_CALL_LOG}"
MOCKAZ
chmod +x "${MOCK_BIN}/az"

expect_failure_without_calls() {
  local description="$1"
  shift
  : > "${CALL_LOG}"
  if "$@" >/dev/null 2>&1; then
    printf 'ERROR: Migration unexpectedly succeeded for %s.\n' "${description}" >&2
    exit 1
  fi
  [[ ! -s "${CALL_LOG}" ]] || {
    printf 'ERROR: Migration invoked Azure CLI before rejecting %s.\n' "${description}" >&2
    exit 1
  }
}

: > "${CALL_LOG}"
preview_output="$(PATH="${MOCK_BIN}:${PATH}" AZ_CALL_LOG="${CALL_LOG}" \
  "${PROJECT_DIR}/scripts/migrate-legacy-rg-tags.sh" "${TEMP_DIR}/parameters.json")"
[[ ! -s "${CALL_LOG}" ]]
printf '%s\n' "${preview_output}" | grep -Fq 'Dry run only.'
printf '%s\n' "${preview_output}" | grep -Fq 'demo-require-rg-tags'
printf '%s\n' "${preview_output}" | grep -Fq 'eslz-demo-require-workload-rg-tags'

expect_failure_without_calls 'missing approval confirmation' \
  env PATH="${MOCK_BIN}:${PATH}" AZ_CALL_LOG="${CALL_LOG}" \
  "${PROJECT_DIR}/scripts/migrate-legacy-rg-tags.sh" "${TEMP_DIR}/parameters.json" --execute

expect_failure_without_calls 'mismatched workload scope confirmation' \
  env PATH="${MOCK_BIN}:${PATH}" AZ_CALL_LOG="${CALL_LOG}" \
  ESLZ_TAG_MIGRATION_CONFIRMATION='REMOVE-LEGACY-RG-TAG-POLICY' \
  bash -c 'printf "eslz-demo-online\n" | "$@"' _ \
  "${PROJECT_DIR}/scripts/migrate-legacy-rg-tags.sh" "${TEMP_DIR}/parameters.json" --execute

: > "${CALL_LOG}"
printf 'eslz-demo-corp\n' | PATH="${MOCK_BIN}:${PATH}" AZ_CALL_LOG="${CALL_LOG}" \
  ESLZ_TAG_MIGRATION_CONFIRMATION='REMOVE-LEGACY-RG-TAG-POLICY' \
  "${PROJECT_DIR}/scripts/migrate-legacy-rg-tags.sh" "${TEMP_DIR}/parameters.json" --execute >/dev/null
expected_calls='policy assignment delete --name demo-require-rg-tags --scope /providers/Microsoft.Management/managementGroups/eslz-demo-corp
policy definition delete --name eslz-demo-require-workload-rg-tags --management-group eslz-demo'
[[ "$(cat "${CALL_LOG}")" == "${expected_calls}" ]] || {
  printf 'ERROR: Bash migration invoked commands outside the two exact legacy artifacts.\n' >&2
  cat "${CALL_LOG}" >&2
  exit 1
}

jq '.parameters.workloadArchetype.value = "corp-unrelated"' \
  "${TEMP_DIR}/parameters.json" > "${TEMP_DIR}/invalid.parameters.json"
expect_failure_without_calls 'an unrelated workload scope' \
  env PATH="${MOCK_BIN}:${PATH}" AZ_CALL_LOG="${CALL_LOG}" \
  ESLZ_TAG_MIGRATION_CONFIRMATION='REMOVE-LEGACY-RG-TAG-POLICY' \
  "${PROJECT_DIR}/scripts/migrate-legacy-rg-tags.sh" "${TEMP_DIR}/invalid.parameters.json" --execute

if grep -Eq 'migrate-legacy-rg-tags' \
  "${PROJECT_DIR}/scripts/deploy.sh" "${PROJECT_DIR}/scripts/deploy.ps1" \
  "${PROJECT_DIR}/scripts/what-if.sh" "${PROJECT_DIR}/scripts/what-if.ps1" \
  "${PROJECT_DIR}/scripts/teardown.sh" "${PROJECT_DIR}/scripts/teardown.ps1"; then
  printf 'ERROR: Legacy tag migration must never run automatically from deploy or what-if.\n' >&2
  exit 1
fi
grep -Fq "delete_policy_assignment 'demo-require-rg-tags' \"\${landing_zones_scope}\"" "${PROJECT_DIR}/scripts/teardown.sh"
grep -Fq "delete_policy_assignment 'demo-require-rg-tags' \"\${workload_scope}\"" "${PROJECT_DIR}/scripts/teardown.sh"
grep -Fq 'policy set-definition delete --name "${prefix}-required-rg-tags"' "${PROJECT_DIR}/scripts/teardown.sh"
if grep -Fq 'demo-require-workload-rg-tags' "${PROJECT_DIR}/scripts/teardown.sh"; then
  printf 'ERROR: Bash teardown still targets the nonexistent legacy assignment name.\n' >&2
  exit 1
fi

printf 'Tag policy migration Bash validation passed.\n'
