#!/usr/bin/env bash
# Offline structural validation for policy/control-catalog.json.
# Re-implements the rules documented in policy/control-catalog.schema.json using
# jq only, since a generic JSON Schema validator CLI is not assumed to be present.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CATALOG="${PROJECT_DIR}/policy/control-catalog.json"
MATRIX="${PROJECT_DIR}/docs/CONTROL-MATRIX.md"

command -v jq >/dev/null 2>&1 || {
  printf 'ERROR: jq is required for control-catalog validation.\n' >&2
  exit 1
}
command -v rg >/dev/null 2>&1 || {
  printf 'ERROR: ripgrep (rg) is required for control-catalog validation.\n' >&2
  exit 1
}

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

printf '1/9 Validate catalog JSON syntax...\n'
jq empty "${CATALOG}"

printf '2/9 Validate required top-level fields...\n'
jq -e '
  (.["$schema"] | type == "string") and
  (.catalogVersion | type == "string") and
  (.generatedOn | type == "string") and
  (.classificationValues | type == "array" and length > 0) and
  (.enforcementPhaseValues | type == "array" and length > 0) and
  (.controls | type == "array" and length > 0) and
  (.overlapNotes | type == "array")
' "${CATALOG}" >/dev/null || fail "Catalog is missing a required top-level field."

printf '3/9 Validate required per-control fields and enums...\n'
jq -e '
  (.classificationValues) as $classifications |
  (.enforcementPhaseValues) as $phases |
  [.controls[] |
    select(
      (.id | type != "string") or
      (.domain | type != "string") or
      (.customerRequirement | type != "string") or
      (.scope | type != "string") or
      (.classification as $c | $classifications | index($c) | not) or
      (.mechanism | type != "object") or
      (.mechanism.displayName | type != "string") or
      (.mechanism.builtIn | type != "boolean") or
      (.mechanism.verifiedOn | type != "string") or
      (.mechanism.verificationMethod | type != "string") or
      (.supportedEffects | type != "array" or length == 0) or
      (.requiredParameters | type != "array") or
      (.roleDefinitionIds | type != "array") or
      (.remediationIdentityRequired | type != "boolean") or
      (.dependencies | type != "array") or
      (.enforcementPhase as $p | $phases | index($p) | not) or
      (.evidenceSource | type != "string")
    )
  ] | length == 0
' "${CATALOG}" >/dev/null || fail "One or more control records are missing a required field or use an undeclared classification/enforcementPhase value."

printf '4/9 Validate no "unknown" version/GUID placeholders remain...\n'
jq -e '
  [.controls[] | select(.mechanism.majorVersion == "unknown" or .mechanism.verifiedVersion == "unknown")] | length == 0
' "${CATALOG}" >/dev/null || fail "A control record still uses the literal placeholder \"unknown\" for majorVersion/verifiedVersion."
jq -e '
  [.controls[] | select(.mechanism.sourceUrl != null and (.mechanism.sourceUrl | test("raw\\.githubusercontent\\.com")) and (.mechanism.sourceUrl | endswith("/")))] | length == 0
' "${CATALOG}" >/dev/null || fail "A control record points sourceUrl at a directory listing instead of a file."

printf '5/9 Validate control IDs are unique and correctly formatted...\n'
jq -e '
  [.controls[].id] as $ids |
  ($ids | length) == ($ids | unique | length) and
  ([$ids[] | select(test("^REQ-[A-Z]+-[0-9]{2}$") | not)] | length == 0)
' "${CATALOG}" >/dev/null || fail "Control IDs are not unique or do not match the REQ-<DOMAIN>-<NN> pattern."

printf '6/9 Validate dependency references resolve to existing IDs...\n'
jq -e '
  [.controls[].id] as $ids |
  [.controls[].dependencies[]? | select(. as $d | $ids | index($d) | not)] | length == 0
' "${CATALOG}" >/dev/null || fail "A control record depends on an ID that does not exist in the catalog."

printf '7/9 Validate GUID formats for definitionId and roleDefinitionIds...\n'
guid_pattern='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
jq -e --arg re "${guid_pattern}" '
  [.controls[] |
    select(.mechanism.builtIn == true and (.mechanism.verificationMethod == "raw-json" or .mechanism.verificationMethod == "initiative-json-member")) |
    select((.mechanism.definitionId // "") | test($re) | not)
  ] | length == 0
' "${CATALOG}" >/dev/null || fail "A directly-verified built-in control record has a definitionId that is not a well-formed GUID."
jq -e --arg re "${guid_pattern}" '
  [.controls[].roleDefinitionIds[]? | select(test($re) | not)] | length == 0
' "${CATALOG}" >/dev/null || fail "A roleDefinitionIds entry is not a well-formed bare GUID."

printf '8/9 Validate remediation-identity requirements are backed by roles...\n'
jq -e '
  [.controls[] |
    select(.remediationIdentityRequired == true) |
    select(((.roleDefinitionIds | length) == 0) and (.rolesVaryByMember != true))
  ] | length == 0
' "${CATALOG}" >/dev/null || fail "A control record sets remediationIdentityRequired=true but has neither a populated roleDefinitionIds array nor rolesVaryByMember=true."

printf '9/9 Validate consistency between the JSON catalog and the human-readable matrix...\n'
json_count="$(jq '.controls | length' "${CATALOG}")"
matrix_count="$(rg -o '\*\*Total control records:\*\* ([0-9]+)' -r '$1' "${MATRIX}")"
[[ "${json_count}" == "${matrix_count}" ]] || fail "Catalog has ${json_count} control records but the matrix states ${matrix_count}."
missing_from_matrix=0
while IFS= read -r control_id; do
  rg -q -- "^\| ${control_id} \|" "${MATRIX}" || {
    printf 'ERROR: Control %s is present in the JSON catalog but not found as a table row in %s.\n' "${control_id}" "${MATRIX}" >&2
    missing_from_matrix=1
  }
done < <(jq -r '.controls[].id' "${CATALOG}")
[[ "${missing_from_matrix}" -eq 0 ]] || exit 1

printf '\nControl catalog validation passed.\n'
