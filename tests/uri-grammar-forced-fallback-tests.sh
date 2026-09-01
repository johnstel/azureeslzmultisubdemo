#!/usr/bin/env bash
# Backend-isolated regression tests for the complete catalog schema and the
# single source-URL grammar shared by
# policy/control-catalog.schema.json, tests/validate-control-catalog.sh
# (Python jsonschema backend and jq fallback backend), and
# tests/validate-control-catalog.ps1 (Python jsonschema backend and native
# PowerShell fallback backend).
#
# Each of the four backends is invoked *explicitly* via SCHEMA_BACKEND /
# -SchemaBackend (rather than relying on whatever happens to be on PATH),
# so a run can never silently exercise the same fallback twice while
# believing it also tested the Python path. When a requested backend's
# runtime (python3 + jsonschema) is genuinely unavailable, the validator
# exits with a distinct "skipped" code (2) that this script reports as
# SKIPPED rather than counting it as a pass or a failure.
#
# -SchemaOnly / SCHEMA_ONLY=1 makes the validator exit immediately after the
# schema-equivalent check (step 9) succeeds, before the unrelated
# matrix-consistency check (step 10) runs. This isolation is required for
# correctness: mutating sourceIssue also breaks the "matrix header states
# the current sourceIssue" check regardless of whether the mutated value is
# itself a well-formed URL, so without isolating step 9 a rejected mutation
# would prove nothing about URI-grammar enforcement specifically.
#
# All test values (including raw control bytes such as NUL, which cannot be
# represented in a Bash string/array/argv at all) are generated and written
# directly to mutated catalog JSON files by a single Python process below,
# rather than passed through shell variables, so every case -- including
# LF/CR/NUL/unit-separator/DEL/non-ASCII -- is actually exercised end to end.
#
# The suite also mutates non-URI schema fields and matrix structure. It is
# committed, offline, deterministic coverage and does not deploy/query anything.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REAL_CATALOG="${PROJECT_DIR}/policy/control-catalog.json"

command -v jq >/dev/null 2>&1 || { printf 'ERROR: jq is required.\n' >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { printf 'ERROR: python3 is required to generate test fixtures.\n' >&2; exit 1; }

ARTIFACTS_PARENT="${PROJECT_DIR}/.test-artifacts"
TMP_ROOT="${ARTIFACTS_PARENT}/control-catalog-parity-$$"
mkdir -p "${TMP_ROOT}"
trap 'rm -rf "${TMP_ROOT}"; rmdir "${ARTIFACTS_PARENT}" 2>/dev/null || true' EXIT

MANIFEST="${TMP_ROOT}/manifest.json"
python3 - "${REAL_CATALOG}" "${TMP_ROOT}" "${MANIFEST}" <<'PYEOF'
import json
import sys

catalog_path, tmp_root, manifest_path = sys.argv[1:4]
with open(catalog_path, encoding="utf-8") as f:
    real_catalog = json.load(f)

# Negative values: the standard malformed-authority battery plus explicit
# control-byte/non-ASCII cases for the "a bare '$' anchor tolerates a
# trailing newline (or other character)" class of bug. NUL in particular
# can only be exercised this way -- it cannot survive a Bash variable,
# array element, or argv at all.
bad_values = [
    "https://",
    "https://.com",
    "https://example..com",
    "https://-example.com/x",
    "https://example-.com/x",
    "https://example.com:443/x",
    "https://example.com:/x",
    "https://example.com:",
    "https://user@example.com/x",
    "https://[::1]/x",
    "https://exa[mple.com/x",
    "https://example.com/%zz",
    "https://example.com/%2",
    "https://example.com/a b",
    "https://example.com/a\\b",
    "https://example.com/<x>",
    "https://example.com/a|b",
    "http://example.com/x",
    "https://192.168.1.1/x",
    "ftp://example.com/x",
    "   https://example.com/x",
    "https://example.com/x   ",
    "https://example.com/x\n",
    "https://example.com/x\r",
    "https://example.com/x\x00",
    "https://example.com/x\x1f",
    "https://example.com/x\x7f",
    "https://example.com/x\u00e9",
]

# Positive regression examples for all three approved hosts (plus a valid
# %20 escape). Schema-only isolation makes it safe to test sourceIssue
# positives too, since the unrelated matrix-header consistency check no
# longer runs in the same invocation.
good_values = [
    "https://learn.microsoft.com/en-us/azure/governance/policy/samples/some-sample-policy",
    "https://raw.githubusercontent.com/Azure/azure-policy/master/some/path%20with%20escape.json",
    "https://github.com/johnstel/azureeslzmultisubdemo/issues/3",
    "https://learn.microsoft.com/",
]

manifest = []


def write_catalog(catalog, path):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(catalog, f)


def add_case(kind, value, expect_success, index):
    catalog = json.loads(json.dumps(real_catalog))
    if kind == "sourceIssue":
        catalog["sourceIssue"] = value
    else:
        found = False
        for control in catalog["controls"]:
            if control.get("mechanism", {}).get("sourceUrl") is not None:
                control["mechanism"]["sourceUrl"] = value
                found = True
                break
        assert found, "no control with a non-null mechanism.sourceUrl found"
    path = f"{tmp_root}/case-{index:04d}.json"
    write_catalog(catalog, path)
    manifest.append({
        "path": path,
        "label": f"{kind} {'accepted' if expect_success else 'rejected'}: {value!r}",
        "expectSuccess": expect_success,
    })


i = 0
for value in bad_values:
    add_case("sourceIssue", value, 0, i); i += 1
    add_case("mechanism.sourceUrl", value, 0, i); i += 1
for value in good_values:
    add_case("sourceIssue", value, 1, i); i += 1
    add_case("mechanism.sourceUrl", value, 1, i); i += 1

# Non-URI schema-equivalence mutations exercise non-empty metadata and list
# entries plus optional-property and array-container typing in every explicitly
# selected backend.


def add_metadata_case(kind, expect_success, index):
    catalog = json.loads(json.dumps(real_catalog))
    if kind == "schema-empty":
        catalog["$schema"] = ""
        label = "top-level $schema rejected: empty string"
    elif kind == "catalogVersion-empty":
        catalog["catalogVersion"] = ""
        label = "top-level catalogVersion rejected: empty string"
    elif kind == "classificationValues-item-empty":
        catalog["classificationValues"] = catalog["classificationValues"] + [""]
        label = "classificationValues rejected: appended empty-string entry"
    elif kind == "enforcementPhaseValues-item-empty":
        catalog["enforcementPhaseValues"] = catalog["enforcementPhaseValues"] + [""]
        label = "enforcementPhaseValues rejected: appended empty-string entry"
    elif kind == "cautions-item-empty":
        catalog["cautions"] = catalog["cautions"] + [""]
        label = "cautions rejected: appended empty-string entry"
    elif kind == "requiredParameters-item-empty":
        found = False
        for control in catalog["controls"]:
            control.setdefault("requiredParameters", [])
            control["requiredParameters"] = control["requiredParameters"] + [""]
            found = True
            break
        assert found, "no control found to mutate requiredParameters"
        label = "requiredParameters rejected: appended empty-string entry"
    elif kind == "mechanism-category-array":
        catalog["controls"][0]["mechanism"]["category"] = []
        label = "optional mechanism.category rejected: array value"
    elif kind == "requiredParameters-object":
        catalog["controls"][0]["requiredParameters"] = {}
        label = "requiredParameters rejected: object container"
    elif kind == "valid-baseline":
        label = "unmodified real catalog metadata accepted"
    else:
        raise AssertionError(f"unknown metadata mutation kind: {kind}")
    path = f"{tmp_root}/meta-case-{index:04d}.json"
    write_catalog(catalog, path)
    manifest.append({
        "path": path,
        "label": label,
        "expectSuccess": expect_success,
    })


for kind in [
    "schema-empty",
    "catalogVersion-empty",
    "classificationValues-item-empty",
    "enforcementPhaseValues-item-empty",
    "cautions-item-empty",
    "requiredParameters-item-empty",
    "mechanism-category-array",
    "requiredParameters-object",
]:
    add_metadata_case(kind, 0, i); i += 1
add_metadata_case("valid-baseline", 1, i); i += 1

with open(manifest_path, "w", encoding="utf-8") as f:
    json.dump(manifest, f)
PYEOF

fail_count=0
skip_count=0
reported_sh_python_skip=0
reported_ps_python_skip=0
reported_ps_native_skip=0

report_backend_skip() {
  local runner="$1"
  case "${runner}" in
    sh-python)
      if [[ "${reported_sh_python_skip}" -eq 0 ]]; then
        printf '  SKIPPED [sh-python]: backend runtime unavailable in this environment (all cases explicitly skipped, not passed).\n'
        reported_sh_python_skip=1
      fi
      ;;
    ps-python)
      if [[ "${reported_ps_python_skip}" -eq 0 ]]; then
        printf '  SKIPPED [ps-python]: backend runtime unavailable in this environment (all cases explicitly skipped, not passed).\n'
        reported_ps_python_skip=1
      fi
      ;;
    ps-native)
      if [[ "${reported_ps_native_skip}" -eq 0 ]]; then
        printf '  SKIPPED [ps-native]: backend runtime unavailable in this environment (all cases explicitly skipped, not passed).\n'
        reported_ps_native_skip=1
      fi
      ;;
  esac
  skip_count=$((skip_count + 1))
}

# Runs one backend and returns via the global "backend_rc" variable:
#   0 = the backend ran and the catalog passed schema-only validation
#   1 = the backend ran and the catalog failed schema-only validation
#   2 = the backend's runtime is unavailable in this environment (skipped)
run_backend() {
  local runner="$1" catalog="$2"
  local output_file="${TMP_ROOT}/backend-output.txt"
  backend_rc=0
  case "${runner}" in
    sh-python)
      CATALOG="${catalog}" SCHEMA_BACKEND=python SCHEMA_ONLY=1 "${SCRIPT_DIR}/validate-control-catalog.sh" >"${output_file}" 2>&1 || backend_rc=$?
      ;;
    sh-jq)
      CATALOG="${catalog}" SCHEMA_BACKEND=jq SCHEMA_ONLY=1 "${SCRIPT_DIR}/validate-control-catalog.sh" >"${output_file}" 2>&1 || backend_rc=$?
      ;;
    ps-python)
      if ! command -v pwsh >/dev/null 2>&1; then backend_rc=2
      else pwsh -NoLogo -NoProfile -File "${SCRIPT_DIR}/validate-control-catalog.ps1" -CatalogPathOverride "${catalog}" -SchemaBackend python -SchemaOnly >"${output_file}" 2>&1 || backend_rc=$?
      fi
      ;;
    ps-native)
      if ! command -v pwsh >/dev/null 2>&1; then backend_rc=2
      else pwsh -NoLogo -NoProfile -File "${SCRIPT_DIR}/validate-control-catalog.ps1" -CatalogPathOverride "${catalog}" -SchemaBackend native -SchemaOnly >"${output_file}" 2>&1 || backend_rc=$?
      fi
      ;;
    *)
      printf 'ERROR: unknown runner "%s"\n' "${runner}" >&2
      exit 1
      ;;
  esac
  backend_output=""
  [[ -f "${output_file}" ]] && backend_output="$(cat "${output_file}")"
}

# Args: description, mutated-catalog-path, expect-success(0|1)
run_case() {
  local desc="$1" catalog="$2" expect_success="$3"
  local runners=(sh-python sh-jq ps-python ps-native)

  local ok=1
  local ran_at_least_one_forced_fallback=0
  for runner in "${runners[@]}"; do
    run_backend "${runner}" "${catalog}"
    case "${backend_rc}" in
      2)
        report_backend_skip "${runner}"
        continue
        ;;
      0)
        [[ "${expect_success}" -eq 1 ]] || { printf 'FAIL [%s / %s]: expected FAIL but backend PASSED.\n' "${desc}" "${runner}" >&2; ok=0; }
        ;;
      *)
        if [[ "${expect_success}" -eq 0 ]]; then
          if ! printf '%s' "${backend_output}" | rg -q 'Catalog failed (JSON Schema|the offline schema-equivalent) validation'; then
            printf 'FAIL [%s / %s]: rejection did not originate in the selected schema backend.\n' "${desc}" "${runner}" >&2
            ok=0
          fi
        else
          printf 'FAIL [%s / %s]: expected PASS but backend FAILED (rc=%s).\n' "${desc}" "${runner}" "${backend_rc}" >&2
          ok=0
        fi
        ;;
    esac
    [[ "${backend_rc}" -ne 2 && ("${runner}" == "sh-jq" || "${runner}" == "ps-native") ]] && ran_at_least_one_forced_fallback=1
  done

  # At least one of the jq/native-PowerShell fallbacks must always actually
  # run (they never require external runtimes), so a case can never report
  # "ok" purely on skipped backends.
  if [[ "${ran_at_least_one_forced_fallback}" -eq 0 ]]; then
    printf 'FAIL [%s]: no forced-fallback backend (jq or native PowerShell) actually ran.\n' "${desc}" >&2
    ok=0
  fi

  if [[ "${ok}" -eq 1 ]]; then
    printf '  ok: %s\n' "${desc}"
  else
    fail_count=$((fail_count + 1))
  fi
}

while IFS=$'\t' read -r path label expect; do
  run_case "${label}" "${path}" "${expect}"
done < <(jq -r '.[] | [.path, .label, (.expectSuccess | tostring)] | @tsv' "${MANIFEST}")

# Generate matrix-only fixtures separately so failures must reach step 10 and
# cannot be mistaken for schema failures or catalog/matrix row mismatches.
MATRIX_MANIFEST="${TMP_ROOT}/matrix-manifest.json"
python3 - "${PROJECT_DIR}/docs/CONTROL-MATRIX.md" "${TMP_ROOT}" "${MATRIX_MANIFEST}" <<'PYEOF'
import json
import sys

matrix_path, root, manifest_path = sys.argv[1:4]
matrix = open(matrix_path, encoding="utf-8").read()
cases = [("baseline matrix is accepted", matrix, True)]

first_caution = next(line for line in matrix.splitlines() if line.startswith("- Azure service security baselines"))
cases.append(("duplicate caution is rejected", matrix.replace(first_caution, first_caution + "\n" + first_caution, 1), False))

cases.append(("extra empty stale domain is rejected", matrix.replace("## Overlap notes", "## Retired stale domain\n\n## Overlap notes", 1), False))

source = "https://github.com/johnstel/azureeslzmultisubdemo/issues/3"
metadata_only_in_prose = matrix.replace(
    f"- **Source issue:** {source}",
    "- **Source issue:** https://github.com/johnstel/azureeslzmultisubdemo/issues/999",
    1,
) + f"\nUnrelated prose mentions {source} but is not keyed matrix metadata.\n"
cases.append(("metadata value only in unrelated prose is rejected", metadata_only_in_prose, False))

manifest = []
for index, (label, content, success) in enumerate(cases):
    path = f"{root}/matrix-{index:02d}.md"
    with open(path, "w", encoding="utf-8") as stream:
        stream.write(content)
    manifest.append({"path": path, "label": label, "expectSuccess": success})
with open(manifest_path, "w", encoding="utf-8") as stream:
    json.dump(manifest, stream)
PYEOF

run_matrix_case() {
  local desc="$1" matrix="$2" expect_success="$3"
  local runners=(sh-jq ps-native)
  local runner rc output_file ok=1
  for runner in "${runners[@]}"; do
    output_file="${TMP_ROOT}/matrix-output.txt"
    rc=0
    case "${runner}" in
      sh-jq)
        MATRIX="${matrix}" SCHEMA_BACKEND=jq "${SCRIPT_DIR}/validate-control-catalog.sh" >"${output_file}" 2>&1 || rc=$?
        ;;
      ps-native)
        if ! command -v pwsh >/dev/null 2>&1; then
          rc=2
        else
          pwsh -NoLogo -NoProfile -File "${SCRIPT_DIR}/validate-control-catalog.ps1" -MatrixPathOverride "${matrix}" -SchemaBackend native >"${output_file}" 2>&1 || rc=$?
        fi
        ;;
    esac
    if [[ "${rc}" -eq 2 ]]; then
      report_backend_skip "${runner}"
    elif [[ "${expect_success}" -eq 1 && "${rc}" -ne 0 ]]; then
      printf 'FAIL [%s / %s]: expected PASS but matrix validator failed.\n' "${desc}" "${runner}" >&2
      ok=0
    elif [[ "${expect_success}" -eq 0 ]]; then
      if [[ "${rc}" -eq 0 ]]; then
        printf 'FAIL [%s / %s]: expected matrix rejection but validator passed.\n' "${desc}" "${runner}" >&2
        ok=0
      elif ! rg -q '10/10 Validate every field' "${output_file}"; then
        printf 'FAIL [%s / %s]: rejection occurred before the isolated matrix checks.\n' "${desc}" "${runner}" >&2
        ok=0
      fi
    fi
  done
  if [[ "${ok}" -eq 1 ]]; then printf '  ok: %s\n' "${desc}"; else fail_count=$((fail_count + 1)); fi
}

while IFS=$'\t' read -r path label expect; do
  run_matrix_case "${label}" "${path}" "${expect}"
done < <(jq -r '.[] | [.path, .label, (.expectSuccess | if . then 1 else 0 end | tostring)] | @tsv' "${MATRIX_MANIFEST}")

if [[ "${fail_count}" -gt 0 ]]; then
  printf '\n%d schema/backend or structural-matrix regression case(s) failed.\n' "${fail_count}" >&2
  exit 1
fi
printf '\nAll schema/backend parity and structural-matrix regression cases passed (%d backend invocation(s) skipped due to unavailable runtimes).\n' "${skip_count}"
