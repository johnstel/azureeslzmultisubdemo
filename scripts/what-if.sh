#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PARAMETER_FILE="${1:-${PROJECT_DIR}/parameters/demo.parameters.json}"

"${SCRIPT_DIR}/preflight.sh" "${PARAMETER_FILE}"

deployment_location="$(jq -er '.parameters.deploymentLocation.value' "${PARAMETER_FILE}")"

printf '\nRunning tenant-scope what-if. This previews changes and does not deploy them.\n'
az deployment tenant what-if \
  --name "eslz-demo-preview-$(date -u +%Y%m%d%H%M%S)" \
  --location "${deployment_location}" \
  --template-file "${PROJECT_DIR}/main.bicep" \
  --parameters "@${PARAMETER_FILE}" \
  --result-format FullResourcePayloads

