#!/usr/bin/env bash
# Offline structural validation for policy/control-catalog.json.
# Re-implements the rules documented in policy/control-catalog.schema.json using
# jq only, since a generic JSON Schema validator CLI is not assumed to be present.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CATALOG="${CATALOG:-${PROJECT_DIR}/policy/control-catalog.json}"
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

printf '1/10 Validate catalog JSON syntax...\n'
jq empty "${CATALOG}"

printf '2/10 Validate required top-level fields...\n'
jq -e '
  (.["$schema"] | type == "string") and
  (.catalogVersion | type == "string") and
  (.generatedOn | type == "string") and
  (.classificationValues | type == "array" and length > 0) and
  (.enforcementPhaseValues | type == "array" and length > 0) and
  (.controls | type == "array" and length > 0) and
  (.overlapNotes | type == "array")
' "${CATALOG}" >/dev/null || fail "Catalog is missing a required top-level field."

printf '3/10 Validate required per-control fields and enums...\n'
verification_methods='["raw-json","initiative-json-member","ms-learn-page","documentation-pattern","internal-design","in-repository-custom-definition","not-yet-selected","not-yet-created"]'
jq -e --argjson methods "${verification_methods}" '
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
      (.mechanism.kind | type != "string") or
      (.mechanism.displayName | type != "string") or
      (.mechanism.builtIn | type != "boolean") or
      (.mechanism.verifiedOn | type != "string") or
      (.mechanism.verificationMethod as $vm | $methods | index($vm) | not) or
      (.supportedEffects | type != "array" or length == 0) or
      (.requiredParameters | type != "array") or
      (.roleDefinitionIds | type != "array") or
      (.remediationIdentityRequired | type != "boolean") or
      (.dependencies | type != "array") or
      (.enforcementPhase as $p | $phases | index($p) | not) or
      (.evidenceSource | type != "string")
    )
  ] | length == 0
' "${CATALOG}" >/dev/null || fail "One or more control records are missing a required field or use an undeclared classification/enforcementPhase/verificationMethod value."

printf '4/10 Validate no "unknown"/"n/a" version/GUID placeholders remain...\n'
jq -e '
  [.controls[] | select(.mechanism.majorVersion == "unknown" or .mechanism.majorVersion == "n/a" or .mechanism.verifiedVersion == "unknown" or .mechanism.verifiedVersion == "n/a")] | length == 0
' "${CATALOG}" >/dev/null || fail "A control record still uses the literal placeholder \"unknown\" or \"n/a\" for majorVersion/verifiedVersion; either verify a real version or omit the field entirely when it does not apply."
jq -e '
  [.controls[] | select(.mechanism.sourceUrl != null and (.mechanism.sourceUrl | test("raw\\.githubusercontent\\.com")) and (.mechanism.sourceUrl | endswith("/")))] | length == 0
' "${CATALOG}" >/dev/null || fail "A control record points sourceUrl at a directory listing instead of a file."

printf '5/10 Validate control IDs are unique and correctly formatted...\n'
jq -e '
  [.controls[].id] as $ids |
  ($ids | length) == ($ids | unique | length) and
  ([$ids[] | select(test("^REQ-[A-Z]+-[0-9]{2}$") | not)] | length == 0)
' "${CATALOG}" >/dev/null || fail "Control IDs are not unique or do not match the REQ-<DOMAIN>-<NN> pattern."

printf '6/10 Validate dependency references resolve to existing IDs...\n'
jq -e '
  [.controls[].id] as $ids |
  [.controls[].dependencies[]? | select(. as $d | $ids | index($d) | not)] | length == 0
' "${CATALOG}" >/dev/null || fail "A control record depends on an ID that does not exist in the catalog."

printf '7/10 Validate GUID formats for definitionId and roleDefinitionIds...\n'
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

printf '8/10 Validate remediation-identity requirements are backed by roles...\n'
jq -e '
  [.controls[] |
    select(.remediationIdentityRequired == true) |
    select(((.roleDefinitionIds | length) == 0) and (.rolesVaryByMember != true))
  ] | length == 0
' "${CATALOG}" >/dev/null || fail "A control record sets remediationIdentityRequired=true but has neither a populated roleDefinitionIds array nor rolesVaryByMember=true."

printf '9/10 Validate the catalog against policy/control-catalog.schema.json...\n'
# SCHEMA_BACKEND selects which of the two schema-equivalent implementations
# runs (rather than silently auto-detecting), so callers -- notably
# tests/uri-grammar-forced-fallback-tests.sh -- can assert that a *specific*
# backend actually executed instead of accidentally exercising the jq
# fallback twice under two different invocations that both happened to lack
# python3+jsonschema:
#   - "python": require python3 + the jsonschema module; exit 2 (a distinct
#     "skipped, backend unavailable" code, not a validation failure) if
#     either is missing, rather than silently falling back to jq.
#   - "jq": always use the jq fallback, regardless of what is on PATH.
#   - unset (default): auto-detect, preserving prior behavior.
schema_backend="${SCHEMA_BACKEND:-auto}"
case "${schema_backend}" in
  python)
    if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import jsonschema' >/dev/null 2>&1; then
      printf '  SKIPPED: SCHEMA_BACKEND=python requested but python3 and/or the jsonschema module is not available.\n' >&2
      exit 2
    fi
    use_python=1
    ;;
  jq)
    use_python=0
    ;;
  auto)
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' >/dev/null 2>&1; then
      use_python=1
    else
      use_python=0
    fi
    ;;
  *)
    fail "Unknown SCHEMA_BACKEND value \"${schema_backend}\"; expected \"python\", \"jq\", or unset."
    ;;
esac

if [[ "${use_python}" -eq 1 ]]; then
  python3 - "${CATALOG}" "${SCHEMA:-${PROJECT_DIR}/policy/control-catalog.schema.json}" <<'PYEOF' || fail "Catalog failed JSON Schema validation."
import json
import sys

import jsonschema

catalog_path, schema_path = sys.argv[1:3]
with open(catalog_path, encoding="utf-8") as f:
    catalog = json.load(f)
with open(schema_path, encoding="utf-8") as f:
    schema = json.load(f)
# The schema's "pattern" constraint on sourceIssue/mechanism.sourceUrl (a
# conservative, intentionally narrow source-URL grammar: HTTPS only,
# non-empty DNS labels with no leading/trailing hyphen, no userinfo/IP
# literal/port, and path/query/fragment restricted to safe ASCII URI
# characters with well-formed percent-escapes, terminated by an absolute
# end-of-string assertion that rejects any trailing character at all --
# including a trailing newline/control byte that a bare "$" anchor would
# tolerate) is the single source of truth for URL validity --
# jsonschema.validate() below enforces it exactly as declared, so no
# supplemental ad hoc URI check is layered on top here. Keep the
# jq/PowerShell fallbacks reading the *same* pattern strings out of this
# schema file (rather than a hand-copied duplicate) so all four validation
# paths can never diverge.
jsonschema.validate(catalog, schema, format_checker=jsonschema.FormatChecker())
PYEOF
else
  printf '  (using the full schema-equivalent jq re-implementation in tests/control-catalog-schema-check.jq.)\n'
  schema_errors="$(jq -f "${SCRIPT_DIR}/control-catalog-schema-check.jq" --slurpfile schema_holder "${SCHEMA:-${PROJECT_DIR}/policy/control-catalog.schema.json}" "${CATALOG}")"
  [[ "$(printf '%s' "${schema_errors}" | jq 'length')" -eq 0 ]] || {
    printf 'ERROR: Catalog failed the offline schema-equivalent validation:\n' >&2
    printf '%s\n' "${schema_errors}" | jq -r '.[] | "  - " + .' >&2
    exit 1
  }
fi

if [[ "${SCHEMA_ONLY:-0}" == "1" ]]; then
  printf 'Schema-only validation passed (SCHEMA_ONLY=1; skipping matrix consistency checks).\n'
  exit 0
fi

printf '10/10 Validate every field represented in the human-readable matrix matches the JSON catalog...\n'
json_count="$(jq '.controls | length' "${CATALOG}")"
matrix_count="$(rg -o '\*\*Total control records:\*\* ([0-9]+)' -r '$1' "${MATRIX}")"
[[ "${json_count}" == "${matrix_count}" ]] || fail "Catalog has ${json_count} control records but the matrix states ${matrix_count}."

# Bidirectional ID-set comparison: parse the actual "| REQ-XXX-NN | ..." table
# rows present in the matrix (not merely search for expected rows), so that a
# stale, duplicated, or otherwise-untracked extra row is caught even though it
# never matches any JSON-derived expected string.
# Note: uses a `while read` loop, not the Bash 4.0+ builtin that reads lines
# directly into an array, so this script stays syntax- and behavior-compatible
# with the stock Bash 3.2 shipped on macOS.
matrix_ids=()
while IFS= read -r matrix_id; do
  matrix_ids+=("${matrix_id}")
done < <(rg -o '^\| (REQ-[A-Z]+-[0-9]{2}) \|' -r '$1' "${MATRIX}")
json_ids=()
while IFS= read -r json_id; do
  json_ids+=("${json_id}")
done < <(jq -r '.controls[].id' "${CATALOG}")

sorted_matrix_ids="$(printf '%s\n' "${matrix_ids[@]}" | sort)"
sorted_unique_matrix_ids="$(printf '%s\n' "${matrix_ids[@]}" | sort -u)"
[[ "${sorted_matrix_ids}" == "${sorted_unique_matrix_ids}" ]] || fail "The matrix contains one or more duplicate control ID rows: $(comm -13 <(printf '%s\n' "${sorted_unique_matrix_ids}") <(printf '%s\n' "${sorted_matrix_ids}") | sort -u | tr '\n' ' ')"

sorted_json_ids="$(printf '%s\n' "${json_ids[@]}" | sort -u)"
extra_ids="$(comm -13 <(printf '%s\n' "${sorted_json_ids}") <(printf '%s\n' "${sorted_unique_matrix_ids}"))"
missing_ids="$(comm -23 <(printf '%s\n' "${sorted_json_ids}") <(printf '%s\n' "${sorted_unique_matrix_ids}"))"
[[ -z "${extra_ids}" ]] || fail "The matrix contains stale/extra control ID row(s) not present in the JSON catalog: $(printf '%s' "${extra_ids}" | tr '\n' ' ')"
[[ -z "${missing_ids}" ]] || fail "The matrix is missing control ID row(s) present in the JSON catalog: $(printf '%s' "${missing_ids}" | tr '\n' ' ')"

mismatch=0
while IFS= read -r expected_row; do
  control_id="$(printf '%s\n' "${expected_row}" | cut -d'|' -f2 | tr -d ' ')"
  if ! rg -qF -- "${expected_row}" "${MATRIX}"; then
    printf 'ERROR: Control %s row in %s does not match the JSON catalog (scope, classification, mechanism, built-in ID, version, effects, or enforcement phase differs, or the row is missing).\n' "${control_id}" "${MATRIX}" >&2
    mismatch=1
  fi
done < <(jq -r '
  .controls[] |
  ("| " + .id + " | " + .customerRequirement + " | " + .scope + " | " + .classification + " | " +
   .mechanism.displayName + " (built-in: " + (if .mechanism.builtIn then "Yes" else "No" end) + ") | " +
   (if .mechanism.definitionId then ("`" + .mechanism.definitionId + "`") else "`\u2014`" end) + " | " +
   (.mechanism.verifiedVersion // "\u2014") + " | " +
   (.supportedEffects | join(", ")) + " | " + .enforcementPhase + " |")
' "${CATALOG}")
[[ "${mismatch}" -eq 0 ]] || exit 1

# Validate catalog-level metadata (version/generated date/source issue) is
# represented in the matrix header, not just the per-row content above.
catalog_version="$(jq -r '.catalogVersion' "${CATALOG}")"
generated_on="$(jq -r '.generatedOn' "${CATALOG}")"
source_issue="$(jq -r '.sourceIssue' "${CATALOG}")"
rg -qF -- "**Catalog version:** \`${catalog_version}\`" "${MATRIX}" || fail "Matrix header does not state the current catalogVersion (${catalog_version})."
rg -qF -- "**Generated on:** \`${generated_on}\`" "${MATRIX}" || fail "Matrix header does not state the current generatedOn date (${generated_on})."
rg -qF -- "${source_issue}" "${MATRIX}" || fail "Matrix header does not reference the current sourceIssue (${source_issue})."

# Every declared classification value must be represented in the classification legend.
while IFS= read -r classification; do
  rg -qF -- "\`${classification}\`" "${MATRIX}" || fail "Classification legend in the matrix is missing the declared classification value: ${classification}."
done < <(jq -r '.classificationValues[]' "${CATALOG}")

# Every top-level caution must be represented (as a normalized substring, since
# the matrix may format the same caution with additional markdown emphasis).
normalize() { tr -s '[:space:]`' ' ' | sed -e 's/^ *//' -e 's/ *$//'; }
normalized_matrix="$(normalize < "${MATRIX}")"
while IFS= read -r caution; do
  normalized_caution="$(printf '%s' "${caution}" | normalize)"
  [[ "${normalized_matrix}" == *"${normalized_caution}"* ]] || fail "Matrix does not represent a declared caution: ${caution}"
done < <(jq -r '.cautions[]' "${CATALOG}")

# Overlap-notes pairs are validated structurally and bidirectionally below
# (exact {topic, note} multiset comparison), which subsumes a one-way
# substring check and additionally catches a stale topic reusing an existing
# note, or a topic whose note text was changed in only one place.

# --- Structural bidirectional checks: domain sections, cautions, overlap topics ---
# Unlike the substring checks above (which only prove every JSON entry is
# represented somewhere in the matrix), the checks below parse the matrix's
# own structure (headings, bullet lists) as real data and compare it against
# the JSON catalog as an exact, keyed set in both directions -- so a changed
# `domain`, or an extra/stale caution or overlap-topic bullet added directly to
# the matrix, is caught even though it never produces a literal-string diff
# against an "expected" value derived only from the JSON.

domain_to_heading() {
  case "$1" in
    identity) printf '%s' 'Identity (Entra Conditional Access, PIM, access review)' ;;
    deployment-restrictions) printf '%s' 'Deployment restrictions' ;;
    tagging) printf '%s' 'Tagging' ;;
    network-security) printf '%s' 'Network security' ;;
    logging) printf '%s' 'Logging' ;;
    data-protection) printf '%s' 'Data protection' ;;
    security-baseline) printf '%s' 'MCSB / CIS / NIST / service baselines' ;;
    defender-for-cloud) printf '%s' 'Defender for Cloud' ;;
    backup) printf '%s' 'Backup' ;;
    nerc-cip) printf '%s' 'NERC CIP' ;;
    *) printf '%s' '' ;;
  esac
}

# Parse "id<TAB>heading" pairs for every control row actually present in the
# matrix (heading is whatever "## " section the row currently falls under).
id_heading_pairs="$(awk '
  /^## / { heading = substr($0, 4) }
  /^\| REQ-[A-Z]+-[0-9]+ \|/ {
    line = $0
    sub(/^\| /, "", line)
    split(line, parts, / \| /)
    print parts[1] "\t" heading
  }
' "${MATRIX}")"

domain_mismatch=0
while IFS=$'\t' read -r ctrl_id ctrl_domain; do
  expected_heading="$(domain_to_heading "${ctrl_domain}")"
  [[ -n "${expected_heading}" ]] || fail "Control ${ctrl_id} declares an unrecognized domain \"${ctrl_domain}\" with no known matrix heading mapping."
  actual_heading="$(printf '%s\n' "${id_heading_pairs}" | awk -F'\t' -v id="${ctrl_id}" '$1 == id { print $2; exit }')"
  if [[ "${actual_heading}" != "${expected_heading}" ]]; then
    printf 'ERROR: Control %s has domain "%s" (expected matrix heading "%s") but its matrix row is under heading "%s".\n' "${ctrl_id}" "${ctrl_domain}" "${expected_heading}" "${actual_heading}" >&2
    domain_mismatch=1
  fi
done < <(jq -r '.controls[] | .id + "\t" + .domain' "${CATALOG}")
[[ "${domain_mismatch}" -eq 0 ]] || exit 1

# Exact bidirectional set comparison of "Important caveats" bullets against
# JSON .cautions[] (normalized so markdown emphasis/backticks don't cause
# false mismatches), catching both a missing caution and an extra/stale one.
matrix_cautions="$(awk '
  /^## Important caveats$/ { flag = 1; next }
  /^## / { if (flag) exit }
  flag && /^- / { sub(/^- /, ""); print }
' "${MATRIX}")"
normalized_matrix_cautions="$(printf '%s\n' "${matrix_cautions}" | while IFS= read -r line; do [[ -n "${line}" ]] && printf '%s\n' "${line}" | normalize; done | sort -u)"
normalized_json_cautions="$(jq -r '.cautions[]' "${CATALOG}" | while IFS= read -r line; do printf '%s\n' "${line}" | normalize; done | sort -u)"
[[ "${normalized_matrix_cautions}" == "${normalized_json_cautions}" ]] || fail "The matrix's \"Important caveats\" bullets do not exactly match the JSON catalog's .cautions[] (an entry was added, removed, or reworded in only one place). Matrix: [$(printf '%s' "${normalized_matrix_cautions}" | tr '\n' ';')] JSON: [$(printf '%s' "${normalized_json_cautions}" | tr '\n' ';')]"

# Exact bidirectional multiset comparison of Overlap-notes {topic, note}
# pairs: parse the "- **Topic:** note" bullets under "## Overlap notes" and
# compare the complete (topic, note) pair set (not merely the topic set with
# a separate one-way note substring search) against JSON .overlapNotes[]. A
# multiset (not a de-duplicated set) is compared so a duplicated bullet in
# either the matrix or the JSON is also caught. This catches a matrix bullet
# that reuses an existing topic but carries stale/reworded note text, which a
# topic-only comparison would miss.
matrix_overlap_pairs="$(awk '
  /^## Overlap notes/ { flag = 1; next }
  /^## / { if (flag) exit }
  flag && /^- \*\*/ {
    line = $0
    sub(/^- \*\*/, "", line)
    colon = index(line, ":**")
    topic = substr(line, 1, colon - 1)
    note = substr(line, colon + 3)
    sub(/^ */, "", note)
    print topic "\t" note
  }
' "${MATRIX}")"
normalized_matrix_overlap_pairs="$(printf '%s\n' "${matrix_overlap_pairs}" | while IFS=$'\t' read -r topic note; do
  [[ -n "${topic}" || -n "${note}" ]] || continue
  printf '%s\t%s\n' "$(printf '%s' "${topic}" | normalize)" "$(printf '%s' "${note}" | normalize)"
done | sort)"
normalized_json_overlap_pairs="$(jq -r '.overlapNotes[] | .topic + "\t" + .note' "${CATALOG}" | while IFS=$'\t' read -r topic note; do
  printf '%s\t%s\n' "$(printf '%s' "${topic}" | normalize)" "$(printf '%s' "${note}" | normalize)"
done | sort)"
[[ "${normalized_matrix_overlap_pairs}" == "${normalized_json_overlap_pairs}" ]] || fail "The matrix's \"Overlap notes\" {topic, note} bullets do not exactly match the JSON catalog's .overlapNotes[] (a topic/note pair was added, removed, or reworded in only one place). Matrix pairs: [$(printf '%s' "${normalized_matrix_overlap_pairs}" | tr '\n' ';')] JSON pairs: [$(printf '%s' "${normalized_json_overlap_pairs}" | tr '\n' ';')]"

printf '\nControl catalog validation passed.\n'
