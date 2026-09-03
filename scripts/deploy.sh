#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PARAMETER_FILE="${1:-${PROJECT_DIR}/parameters/demo.parameters.json}"

"${SCRIPT_DIR}/preflight.sh" "${PARAMETER_FILE}"
"${SCRIPT_DIR}/what-if.sh" "${PARAMETER_FILE}"

if [[ "${ESLZ_DEPLOY_CONFIRMATION:-}" != 'DEPLOY-ESLZ-DEMO' ]]; then
  printf 'Deployment is locked.\n' >&2
  printf 'Set ESLZ_DEPLOY_CONFIRMATION=DEPLOY-ESLZ-DEMO only after reviewing what-if.\n' >&2
  exit 2
fi

demo_root="$(jq -er '.parameters.namePrefix.value' "${PARAMETER_FILE}")"
connectivity_subscription="$(jq -er '.parameters.connectivitySubscriptionId.value' "${PARAMETER_FILE}")"
workload_subscription="$(jq -er '.parameters.workloadSubscriptionId.value' "${PARAMETER_FILE}")"
deployment_location="$(jq -er '.parameters.deploymentLocation.value' "${PARAMETER_FILE}")"

printf '\nLIVE DEPLOYMENT TARGET\n'
printf '  Demo root: %s\n' "${demo_root}"
printf '  Connectivity subscription: %s\n' "${connectivity_subscription}"
printf '  Workload subscription: %s\n' "${workload_subscription}"
printf 'Type the demo root ID (%s) to continue: ' "${demo_root}"
read -r typed_confirmation
[[ "${typed_confirmation}" == "${demo_root}" ]] || {
  printf 'Confirmation did not match; deployment cancelled.\n' >&2
  exit 2
}

az deployment tenant create \
  --name "eslz-demo-$(date -u +%Y%m%d%H%M%S)" \
  --location "${deployment_location}" \
  --template-file "${PROJECT_DIR}/main.bicep" \
  --parameters "@${PARAMETER_FILE}"
