#!/usr/bin/env bash
# Regression tests for the single source-URL grammar shared by
# policy/control-catalog.schema.json, tests/validate-control-catalog.sh
# (Python jsonschema path and jq fallback path), and
# tests/validate-control-catalog.ps1 (Python jsonschema path and native
# PowerShell fallback path).
#
# Exercises all four validation paths against a battery of malformed and
# well-formed sourceIssue/mechanism.sourceUrl values on temporary mutated
# copies of the real catalog, forcing the jq/native-PowerShell fallbacks by
# hiding python3 from PATH. This is committed, offline, deterministic
# coverage for the "explicit forced-path negative/positive tests" requested
# during review; it does not deploy or query anything.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REAL_CATALOG="${PROJECT_DIR}/policy/control-catalog.json"

command -v jq >/dev/null 2>&1 || { printf 'ERROR: jq is required.\n' >&2; exit 1; }

TMP_ROOT="$(mktemp -d)"
STUB_DIR="${TMP_ROOT}/stubbin"
mkdir -p "${STUB_DIR}"
trap 'rm -rf "${TMP_ROOT}"' EXIT

# Build a stub PATH containing every tool the validators use, except
# python3/python -- this forces both validators onto their jq/native
# fallback implementations.
for tool in jq rg awk sed sort comm tr cut date dirname id bash pwsh git mktemp cat mkdir printf chmod ln mv rm cp grep basename readlink pwd wc head tail uniq env; do
  tool_path="$(command -v "${tool}" 2>/dev/null || true)"
  [[ -n "${tool_path}" ]] && ln -sf "${tool_path}" "${STUB_DIR}/${tool}"
done
FORCED_PATH="${STUB_DIR}"

have_pwsh=0
command -v pwsh >/dev/null 2>&1 && have_pwsh=1

fail_count=0

# Args: description, mutated-catalog-path, expect-success(0|1)
run_case() {
  local desc="$1" catalog="$2" expect_success="$3"

  local sh_normal_rc=0 sh_forced_rc=0 ps_normal_rc=0 ps_forced_rc=0
  CATALOG="${catalog}" "${SCRIPT_DIR}/validate-control-catalog.sh" >/dev/null 2>&1 || sh_normal_rc=$?
  CATALOG="${catalog}" PATH="${FORCED_PATH}" "${SCRIPT_DIR}/validate-control-catalog.sh" >/dev/null 2>&1 || sh_forced_rc=$?

  if [[ "${have_pwsh}" -eq 1 ]]; then
    pwsh -NoLogo -NoProfile -File "${SCRIPT_DIR}/validate-control-catalog.ps1" -CatalogPathOverride "${catalog}" >/dev/null 2>&1 || ps_normal_rc=$?
    PATH="${FORCED_PATH}" pwsh -NoLogo -NoProfile -File "${SCRIPT_DIR}/validate-control-catalog.ps1" -CatalogPathOverride "${catalog}" >/dev/null 2>&1 || ps_forced_rc=$?
  fi

  local ok=1
  if [[ "${expect_success}" -eq 1 ]]; then
    [[ "${sh_normal_rc}" -eq 0 ]] || { printf 'FAIL [%s]: expected bash/python path to PASS but it failed.\n' "${desc}" >&2; ok=0; }
    [[ "${sh_forced_rc}" -eq 0 ]] || { printf 'FAIL [%s]: expected bash/jq-fallback path to PASS but it failed.\n' "${desc}" >&2; ok=0; }
    if [[ "${have_pwsh}" -eq 1 ]]; then
      [[ "${ps_normal_rc}" -eq 0 ]] || { printf 'FAIL [%s]: expected pwsh/python path to PASS but it failed.\n' "${desc}" >&2; ok=0; }
      [[ "${ps_forced_rc}" -eq 0 ]] || { printf 'FAIL [%s]: expected pwsh/native-fallback path to PASS but it failed.\n' "${desc}" >&2; ok=0; }
    fi
  else
    [[ "${sh_normal_rc}" -ne 0 ]] || { printf 'FAIL [%s]: expected bash/python path to FAIL but it passed.\n' "${desc}" >&2; ok=0; }
    [[ "${sh_forced_rc}" -ne 0 ]] || { printf 'FAIL [%s]: expected bash/jq-fallback path to FAIL but it passed.\n' "${desc}" >&2; ok=0; }
    if [[ "${have_pwsh}" -eq 1 ]]; then
      [[ "${ps_normal_rc}" -ne 0 ]] || { printf 'FAIL [%s]: expected pwsh/python path to FAIL but it passed.\n' "${desc}" >&2; ok=0; }
      [[ "${ps_forced_rc}" -ne 0 ]] || { printf 'FAIL [%s]: expected pwsh/native-fallback path to FAIL but it passed.\n' "${desc}" >&2; ok=0; }
    fi
  fi

  if [[ "${ok}" -eq 1 ]]; then
    printf '  ok: %s\n' "${desc}"
  else
    fail_count=$((fail_count + 1))
  fi
}

mutate_source_issue() {
  local value="$1" out="$2"
  jq --arg v "${value}" '.sourceIssue = $v' "${REAL_CATALOG}" > "${out}"
}

mutate_mechanism_source_url() {
  local value="$1" out="$2"
  jq --arg v "${value}" '
    (.controls | to_entries | map(select(.value.mechanism.sourceUrl != null)) | .[0].key) as $i |
    .controls[$i].mechanism.sourceUrl = $v
  ' "${REAL_CATALOG}" > "${out}"
}

# --- sourceIssue: negative cases only (mutating sourceIssue also changes the
# expected matrix-header literal, which is an unrelated consistency rule, so
# positive sourceIssue coverage is provided by the unmutated real catalog
# passing all four paths in tests/test.sh / tests/test.ps1 step 19/20). ---
bad_source_issues=(
  'https://'
  'https://.com'
  'https://example..com'
  'https://-example.com/x'
  'https://example-.com/x'
  'https://example.com:443/x'
  'https://example.com:/x'
  'https://user@example.com/x'
  'https://[::1]/x'
  'https://exa[mple.com/x'
  'https://example.com/%zz'
  'https://example.com/%2'
  'https://example.com/a b'
  'https://example.com/a\b'
  'https://example.com/<x>'
  'https://example.com/a|b'
  'http://example.com/x'
  'https://192.168.1.1/x'
  'https://example.com'
  'ftp://example.com/x'
  '   https://example.com/x'
  'https://example.com/x   '
)
for value in "${bad_source_issues[@]}"; do
  tmp="${TMP_ROOT}/bad-source-issue.json"
  mutate_source_issue "${value}" "${tmp}"
  run_case "sourceIssue rejected: ${value}" "${tmp}" 0
done

# --- mechanism.sourceUrl: negative and positive cases (safe to test in both
# directions because sourceUrl is not part of the per-row matrix comparison
# string, so a valid-but-different sourceUrl does not trip an unrelated
# matrix-consistency rule). ---
bad_source_urls=(
  'https://'
  'https://.com/x'
  'https://example..com/x'
  'https://-learn.microsoft.com/x'
  'https://learn.microsoft.com-/x'
  'https://learn.microsoft.com:443/x'
  'https://learn.microsoft.com:/x'
  'https://user@learn.microsoft.com/x'
  'https://[::1]/x'
  'https://gith[ub.com/x'
  'https://learn.microsoft.com/%zz'
  'https://learn.microsoft.com/%2'
  'https://learn.microsoft.com/a b'
  'https://learn.microsoft.com/a\b'
  'https://learn.microsoft.com/<x>'
  'https://learn.microsoft.com/a|b'
  'http://learn.microsoft.com/x'
  'https://192.168.1.1/x'
  'https://learn.microsoft.com:'
)
for value in "${bad_source_urls[@]}"; do
  tmp="${TMP_ROOT}/bad-source-url.json"
  mutate_mechanism_source_url "${value}" "${tmp}"
  run_case "mechanism.sourceUrl rejected: ${value}" "${tmp}" 0
done

good_source_urls=(
  'https://learn.microsoft.com/en-us/azure/governance/policy/samples/some-sample-policy'
  'https://raw.githubusercontent.com/Azure/azure-policy/master/some/path%20with%20escape.json'
  'https://github.com/johnstel/azureeslzmultisubdemo/issues/3'
  'https://learn.microsoft.com/'
)
for value in "${good_source_urls[@]}"; do
  tmp="${TMP_ROOT}/good-source-url.json"
  mutate_mechanism_source_url "${value}" "${tmp}"
  run_case "mechanism.sourceUrl accepted: ${value}" "${tmp}" 1
done

if [[ "${fail_count}" -gt 0 ]]; then
  printf '\n%d forced-fallback URI grammar regression case(s) failed.\n' "${fail_count}" >&2
  exit 1
fi
printf '\nAll forced-fallback URI grammar regression cases passed (bash/python, bash/jq-fallback%s).\n' "$( [[ ${have_pwsh} -eq 1 ]] && printf ', pwsh/python, pwsh/native-fallback' )"
