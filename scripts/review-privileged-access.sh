#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_CRITERIA_FILE="${PROJECT_DIR}/policy/access-review-criteria.json"
DEFAULT_OUTPUT_DIR="${PROJECT_DIR}/.access-reviews"
REPORT_SCHEMA_VERSION='1.0'

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  ./scripts/review-privileged-access.sh \
    --tenant-id <guid> \
    --subscription-id <guid> [--subscription-id <guid> ...] \
    [--management-group <management-group-id> ...] \
    [--criteria-file <criteria.json>] \
    [--output-dir <directory>] \
    [--assignments-file <exported-assignments.json>]

Produces a read-only privileged access inventory report for Azure role
assignments, highlighting high-privilege roles, broad scopes, and direct
service-principal or managed-identity grants for human review.

The script never creates, updates, or removes a role assignment, an access
review, or any other Azure or Microsoft Entra object.

--assignments-file classifies a previously exported assignment list offline and
makes no Azure calls. Without it, the script reads live role assignments with
Azure CLI using the explicitly supplied tenant and subscription context.
EOF
}

is_guid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

is_management_group_id() {
  [[ "$1" =~ ^[-_().a-zA-Z0-9]{1,90}$ ]]
}

tenant_id=''
criteria_file="${DEFAULT_CRITERIA_FILE}"
output_dir="${DEFAULT_OUTPUT_DIR}"
assignments_file=''
subscription_ids=''
management_group_ids=''

contains_line() {
  local haystack="$1"
  local needle="$2"
  printf '%s\n' "${haystack}" | grep -Fxq -- "${needle}"
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --tenant-id)
      [[ "$#" -ge 2 ]] || fail '--tenant-id requires a value.'
      [[ -z "${tenant_id}" ]] || fail '--tenant-id may only be supplied once.'
      tenant_id="$2"
      shift 2
      ;;
    --subscription-id)
      [[ "$#" -ge 2 ]] || fail '--subscription-id requires a value.'
      is_guid "$2" || fail "Subscription ID must be a canonical GUID: $2"
      if contains_line "${subscription_ids}" "$2"; then
        fail "Duplicate subscription ID: $2"
      fi
      subscription_ids="${subscription_ids}$2"$'\n'
      shift 2
      ;;
    --management-group)
      [[ "$#" -ge 2 ]] || fail '--management-group requires a value.'
      is_management_group_id "$2" || fail "Management group ID contains unsupported characters: $2"
      if contains_line "${management_group_ids}" "$2"; then
        fail "Duplicate management group ID: $2"
      fi
      management_group_ids="${management_group_ids}$2"$'\n'
      shift 2
      ;;
    --criteria-file)
      [[ "$#" -ge 2 ]] || fail '--criteria-file requires a value.'
      criteria_file="$2"
      shift 2
      ;;
    --output-dir)
      [[ "$#" -ge 2 ]] || fail '--output-dir requires a value.'
      output_dir="$2"
      shift 2
      ;;
    --assignments-file)
      [[ "$#" -ge 2 ]] || fail '--assignments-file requires a value.'
      assignments_file="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "Unknown argument: $1"
      ;;
  esac
done

command -v jq >/dev/null 2>&1 || fail "Required command 'jq' is not installed."
[[ -n "${tenant_id}" ]] || fail '--tenant-id is required; this review never guesses the directory context.'
is_guid "${tenant_id}" || fail 'Tenant ID must be a canonical GUID.'
subscription_ids="${subscription_ids%$'\n'}"
management_group_ids="${management_group_ids%$'\n'}"
[[ -n "${subscription_ids}" ]] \
  || fail 'At least one --subscription-id is required; this review never enumerates the whole tenant implicitly.'
[[ -f "${criteria_file}" ]] || fail "Criteria file not found: ${criteria_file}"

jq -e '
  (.criteriaVersion | type == "string" and (. | length) > 0)
  and (.reviewCadenceDays | type == "number" and . >= 1 and . == floor)
  and (.maxOwnersPerSubscription | type == "number" and . >= 1 and . == floor)
  and ([.broadScopeTypes, .nonHumanPrincipalTypes, .highPrivilegeRoleNames, .elevatedRoleNames]
    | all(type == "array" and length > 0 and all(.[]; type == "string" and length > 0)))
' "${criteria_file}" >/dev/null \
  || fail "Criteria file is not a valid access-review criteria document: ${criteria_file}"

assignments_source="${output_dir%/}/.collected-assignments.json"
mkdir -p "${output_dir}"
chmod 700 "${output_dir}" 2>/dev/null || true

collect_live_assignments() {
  command -v az >/dev/null 2>&1 || fail "Required command 'az' is not installed."
  local signed_in_tenant
  signed_in_tenant="$(az account show --query tenantId --output tsv 2>/dev/null || true)"
  [[ -n "${signed_in_tenant}" ]] \
    || fail 'Azure CLI is not signed in. Sign in read-only before running this review.'
  [[ "$(printf '%s' "${signed_in_tenant}" | tr 'A-Z' 'a-z')" == "$(printf '%s' "${tenant_id}" | tr 'A-Z' 'a-z')" ]] \
    || fail "Signed-in tenant ${signed_in_tenant} does not match the requested --tenant-id."

  local collected="[]"
  local subscription_id
  local management_group_id
  local page
  while IFS= read -r subscription_id; do
    [[ -n "${subscription_id}" ]] || continue
    page="$(az role assignment list \
      --subscription "${subscription_id}" \
      --all \
      --include-inherited \
      --output json)" || fail "Unable to read role assignments for subscription ${subscription_id}."
    collected="$(jq -n --argjson current "${collected}" --argjson page "${page}" '$current + $page')"
  done <<EOF
${subscription_ids}
EOF

  while IFS= read -r management_group_id; do
    [[ -n "${management_group_id}" ]] || continue
    page="$(az role assignment list \
      --scope "/providers/Microsoft.Management/managementGroups/${management_group_id}" \
      --include-inherited \
      --output json)" || fail "Unable to read role assignments for management group ${management_group_id}."
    collected="$(jq -n --argjson current "${collected}" --argjson page "${page}" '$current + $page')"
  done <<EOF
${management_group_ids}
EOF

  printf '%s\n' "${collected}" > "${assignments_source}"
}

if [[ -n "${assignments_file}" ]]; then
  [[ -f "${assignments_file}" ]] || fail "Assignments file not found: ${assignments_file}"
  jq -e 'type == "array" or (type == "object" and (.value | type == "array"))' "${assignments_file}" >/dev/null \
    || fail 'Assignments file must be a JSON array or an object with a "value" array.'
  jq '(if type == "array" then . else .value end)' "${assignments_file}" > "${assignments_source}"
  review_mode='offline-file'
else
  collect_live_assignments
  review_mode='live-read-only'
fi

jq -e '
  all(.[];
    type == "object"
    and (.roleDefinitionName | type == "string" and length > 0)
    and (.scope | type == "string" and length > 0)
    and (.principalId | type == "string" and length > 0)
    and (.principalType | type == "string" and length > 0))
' "${assignments_source}" >/dev/null \
  || fail 'Every role assignment must supply string roleDefinitionName, scope, principalId, and principalType values.'

generated_on="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
report_stamp="$(printf '%s' "${generated_on}" | tr -d ':-')"
report_json="${output_dir%/}/privileged-access-review-${report_stamp}.json"
report_markdown="${output_dir%/}/privileged-access-review-${report_stamp}.md"

jq -n \
  --slurpfile assignments "${assignments_source}" \
  --slurpfile criteria "${criteria_file}" \
  --arg schemaVersion "${REPORT_SCHEMA_VERSION}" \
  --arg generatedOn "${generated_on}" \
  --arg mode "${review_mode}" \
  --arg tenantId "${tenant_id}" \
  --arg subscriptionIds "${subscription_ids}" \
  --arg managementGroupIds "${management_group_ids}" '
  def lower_all: map(ascii_downcase);
  def scope_type($scope):
    if $scope == "/" then "tenantRoot"
    elif ($scope | test("^/providers/[Mm]icrosoft\\.[Mm]anagement/managementGroups/[^/]+$")) then "managementGroup"
    elif ($scope | test("^/subscriptions/[^/]+$")) then "subscription"
    elif ($scope | test("^/subscriptions/[^/]+/[Rr]esource[Gg]roups/[^/]+$")) then "resourceGroup"
    elif ($scope | test("^/subscriptions/[^/]+/[Rr]esource[Gg]roups/[^/]+/.+$")) then "resource"
    else "unknown"
    end;
  def subscription_of($scope):
    ($scope | capture("^/subscriptions/(?<id>[^/]+)") | .id) // null;
  def severity_rank($severity):
    if $severity == "high" then 0 elif $severity == "medium" then 1 else 2 end;

  ($criteria[0]) as $criteria |
  ($criteria.highPrivilegeRoleNames | lower_all) as $highPrivilegeRoles |
  ($criteria.elevatedRoleNames | lower_all) as $elevatedRoles |
  ($criteria.nonHumanPrincipalTypes | lower_all) as $nonHumanTypes |
  ($criteria.broadScopeTypes | lower_all) as $broadScopes |
  ($subscriptionIds | split("\n") | map(select(length > 0))) as $subscriptions |
  ($managementGroupIds | split("\n") | map(select(length > 0))) as $managementGroups |
  ($assignments[0] | map(
    . as $assignment |
    (scope_type($assignment.scope)) as $scopeType |
    ($assignment.roleDefinitionName | ascii_downcase) as $roleKey |
    ($assignment.principalType | ascii_downcase) as $principalKey |
    ((($highPrivilegeRoles | index($roleKey)) != null)) as $isHighPrivilegeRole |
    ((($elevatedRoles | index($roleKey)) != null)) as $isElevatedRole |
    ((($nonHumanTypes | index($principalKey)) != null)) as $isNonHuman |
    ((($broadScopes | index($scopeType | ascii_downcase)) != null)) as $isBroadScope |
    {
      assignmentId: ($assignment.id // null),
      principalId: $assignment.principalId,
      principalType: $assignment.principalType,
      roleDefinitionName: $assignment.roleDefinitionName,
      scope: $assignment.scope,
      scopeType: $scopeType,
      subscriptionId: subscription_of($assignment.scope),
      isHighPrivilegeRole: $isHighPrivilegeRole,
      isElevatedRole: $isElevatedRole,
      isNonHumanPrincipal: $isNonHuman,
      isBroadScope: $isBroadScope,
      reasons: ([
        (if $isHighPrivilegeRole then "high-privilege-role" else empty end),
        (if $isElevatedRole then "elevated-role" else empty end),
        (if ($isHighPrivilegeRole or $isElevatedRole) then empty else "unclassified-role" end),
        (if $isNonHuman then "direct-non-human-principal-assignment" else empty end),
        (if $isBroadScope then "broad-scope" else empty end)
      ])
    }
  )) as $evaluated |

  ($evaluated
    | map(select(
        .isHighPrivilegeRole
        or (.isElevatedRole and .isBroadScope)
        or (.isNonHumanPrincipal and .isBroadScope)))
    | map(. + {
        severity: (
          if (.isHighPrivilegeRole and (.isBroadScope or .isNonHumanPrincipal)) then "high"
          elif (.isHighPrivilegeRole or (.isNonHumanPrincipal and .isBroadScope)) then "medium"
          else "low"
          end),
        reviewAction: "manual-review-required"
      })
    | map({
        assignmentId,
        principalId,
        principalType,
        roleDefinitionName,
        scope,
        scopeType,
        subscriptionId,
        severity,
        reasons,
        reviewAction
      })
    | sort_by([severity_rank(.severity), .scope, .roleDefinitionName, .principalId])) as $findings |

  ($evaluated
    | map(select(.roleDefinitionName == "Owner" and .scopeType == "subscription" and .subscriptionId != null))
    | group_by(.subscriptionId)
    | map({
        subscriptionId: .[0].subscriptionId,
        ownerPrincipalCount: (map(.principalId) | unique | length),
        exceedsThreshold: ((map(.principalId) | unique | length) > $criteria.maxOwnersPerSubscription)
      })
    | sort_by(.subscriptionId)) as $ownerCounts |

  {
    schemaVersion: $schemaVersion,
    generatedOn: $generatedOn,
    mode: $mode,
    tenantId: $tenantId,
    subscriptionIds: $subscriptions,
    managementGroupIds: $managementGroups,
    criteria: {
      criteriaVersion: $criteria.criteriaVersion,
      reviewCadenceDays: $criteria.reviewCadenceDays,
      maxOwnersPerSubscription: $criteria.maxOwnersPerSubscription,
      highPrivilegeRoleNames: $criteria.highPrivilegeRoleNames,
      elevatedRoleNames: $criteria.elevatedRoleNames,
      nonHumanPrincipalTypes: $criteria.nonHumanPrincipalTypes,
      broadScopeTypes: $criteria.broadScopeTypes
    },
    summary: {
      assignmentsEvaluated: ($evaluated | length),
      findingCount: ($findings | length),
      highSeverityFindingCount: ($findings | map(select(.severity == "high")) | length),
      mediumSeverityFindingCount: ($findings | map(select(.severity == "medium")) | length),
      lowSeverityFindingCount: ($findings | map(select(.severity == "low")) | length),
      nonHumanHighPrivilegeAssignmentCount: ($evaluated
        | map(select(.isNonHumanPrincipal and .isHighPrivilegeRole)) | length),
      managementGroupScopedAssignmentCount: ($evaluated
        | map(select(.scopeType == "managementGroup" or .scopeType == "tenantRoot")) | length),
      subscriptionOwnerCounts: $ownerCounts,
      subscriptionsExceedingOwnerThreshold: ($ownerCounts
        | map(select(.exceedsThreshold) | .subscriptionId))
    },
    findings: $findings
  }
' > "${report_json}"

jq -r '
  "# Privileged access review",
  "",
  "- Generated (UTC): \(.generatedOn)",
  "- Mode: \(.mode)",
  "- Tenant: \(.tenantId)",
  "- Subscriptions: \(.subscriptionIds | join(", "))",
  "- Management groups: \(if (.managementGroupIds | length) > 0 then (.managementGroupIds | join(", ")) else "(none supplied)" end)",
  "- Criteria version: \(.criteria.criteriaVersion) (review cadence \(.criteria.reviewCadenceDays) days, Owner threshold \(.criteria.maxOwnersPerSubscription))",
  "",
  "This report highlights assignments for human review. It never concludes that",
  "a principal is excessive, and it changes nothing in Azure or Microsoft Entra.",
  "",
  "## Summary",
  "",
  "| Measure | Value |",
  "| --- | --- |",
  "| Assignments evaluated | \(.summary.assignmentsEvaluated) |",
  "| Findings | \(.summary.findingCount) |",
  "| High severity | \(.summary.highSeverityFindingCount) |",
  "| Medium severity | \(.summary.mediumSeverityFindingCount) |",
  "| Low severity | \(.summary.lowSeverityFindingCount) |",
  "| Service-principal or managed-identity high-privilege grants | \(.summary.nonHumanHighPrivilegeAssignmentCount) |",
  "| Management-group or tenant-root scoped assignments | \(.summary.managementGroupScopedAssignmentCount) |",
  "",
  "## Subscription Owner counts",
  "",
  "| Subscription | Distinct Owner principals | Exceeds threshold |",
  "| --- | --- | --- |",
  (if (.summary.subscriptionOwnerCounts | length) > 0
    then (.summary.subscriptionOwnerCounts[]
      | "| \(.subscriptionId) | \(.ownerPrincipalCount) | \(if .exceedsThreshold then "yes" else "no" end) |")
    else "| (no subscription-scoped Owner assignments found) | 0 | no |"
    end),
  "",
  "Owner assignments inherited from a management group are reported as findings",
  "with a management-group scope and must be added to these counts by the",
  "reviewer.",
  "",
  "## Findings",
  "",
  "| Severity | Principal type | Principal ID | Role | Scope | Reasons |",
  "| --- | --- | --- | --- | --- | --- |",
  (if (.findings | length) > 0
    then (.findings[]
      | "| \(.severity) | \(.principalType) | \(.principalId) | \(.roleDefinitionName) | \(.scope) | \(.reasons | join(", ")) |")
    else "| (none) | | | | | |"
    end),
  "",
  "Every finding requires a documented reviewer decision: keep, reduce scope,",
  "replace with a time-bound eligible assignment, or remove.",
  ""
' "${report_json}" > "${report_markdown}"

rm -f "${assignments_source}"

printf 'Privileged access review complete (mode: %s, read-only).\n' "${review_mode}"
printf '  Assignments evaluated: %s\n' "$(jq -r '.summary.assignmentsEvaluated' "${report_json}")"
printf '  Findings: %s (high: %s, medium: %s, low: %s)\n' \
  "$(jq -r '.summary.findingCount' "${report_json}")" \
  "$(jq -r '.summary.highSeverityFindingCount' "${report_json}")" \
  "$(jq -r '.summary.mediumSeverityFindingCount' "${report_json}")" \
  "$(jq -r '.summary.lowSeverityFindingCount' "${report_json}")"
printf '  JSON report: %s\n' "${report_json}"
printf '  Markdown report: %s\n' "${report_markdown}"
printf 'Reports contain directory identifiers. Keep them out of source control.\n'
