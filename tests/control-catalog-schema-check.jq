# Self-contained jq re-implementation of policy/control-catalog.schema.json.
# Produces a JSON array of human-readable error strings (empty array = valid).
# Used as the offline fallback for step 9/10 of tests/validate-control-catalog.sh
# when python3 + the jsonschema package are not available, so that the fallback
# path enforces the *complete* schema (required fields, types, enums,
# patterns/formats, uniqueness, references, and the remediation-role rule)
# rather than a partial subset. Keep in sync with policy/control-catalog.schema.json
# and with the PowerShell equivalent in tests/validate-control-catalog.ps1.
#
# All array-item checks below first confirm the container is actually an array
# before iterating (jq's `[]` operator throws a hard error when applied to a
# scalar such as a string or number rather than treating it as zero items), and
# all pattern/regex checks first confirm the value is a string before calling
# `test(...)` (jq's `test` throws a hard error on non-string input). This keeps
# the fallback from crashing outright on malformed/mistyped input -- which
# would otherwise look like "validation passed" to a caller that only checks
# the array is empty on success, when in fact the script errored out before
# producing any array at all.

def guid_re: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$";
def id_re: "^REQ-[A-Z]+-[0-9]{2}$";
def date_re: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$";
def classifications: ["azure-policy","entra-pim","defender-cspm-ciem","shared-service-architecture","manual-evidence"];
def phases: ["audit-only","deny-do-not-enforce","deployifnotexists-opt-in","manual-evidence"];
def methods: ["raw-json","initiative-json-member","ms-learn-page","documentation-pattern","internal-design","in-repository-custom-definition","not-yet-selected","not-yet-created"];

def is_nonempty_string: type == "string" and length >= 1;
def matches_safely(re): type == "string" and test(re);

# Emits `label` for every element of `arr` that is not a non-empty string.
# No-op (and does not itself flag anything) if `arr` is not an array; the
# caller is expected to separately flag a non-array container.
def bad_string_items(arr; msg):
  if (arr | type) == "array" then (arr[] | select(is_nonempty_string | not) | msg) else empty end;

# Emits `label` for every element of `arr` that does not match `re` as a string.
def bad_pattern_items(arr; re; msg):
  if (arr | type) == "array" then (arr[] | select(matches_safely(re) | not) | msg) else empty end;

[
  (if (.["$schema"]? // null | type) != "string" then "top-level: missing/invalid $schema" else empty end),
  (if (.catalogVersion? // null | type) != "string" then "top-level: missing/invalid catalogVersion" else empty end),
  (if (.generatedOn? // null | matches_safely(date_re) | not) then "top-level: missing/invalid generatedOn date" else empty end),
  (if (.purpose? // null | is_nonempty_string | not) then "top-level: missing/invalid purpose" else empty end),
  (if (.sourceIssue? // null | matches_safely("^https?://") | not) then "top-level: missing/invalid sourceIssue uri" else empty end),
  (if (.classificationValues? // null | type) != "array" or ((.classificationValues // []) | length) < 1 then "top-level: missing/invalid classificationValues" else empty end),
  (if (.classificationValues? // null | type) == "array" and ((.classificationValues | unique | length) != (.classificationValues | length)) then "top-level: classificationValues entries are not unique" else empty end),
  bad_string_items(.classificationValues?; "top-level: a classificationValues entry is not a non-empty string"),
  (if (.enforcementPhaseValues? // null | type) != "array" or ((.enforcementPhaseValues // []) | length) < 1 then "top-level: missing/invalid enforcementPhaseValues" else empty end),
  (if (.enforcementPhaseValues? // null | type) == "array" and ((.enforcementPhaseValues | unique | length) != (.enforcementPhaseValues | length)) then "top-level: enforcementPhaseValues entries are not unique" else empty end),
  bad_string_items(.enforcementPhaseValues?; "top-level: an enforcementPhaseValues entry is not a non-empty string"),
  (if (.cautions? // null | type) != "array" then "top-level: missing/invalid cautions array" else empty end),
  (if (.cautions? // null | type) == "array" then (.cautions[] | select(type != "string") | "top-level: a cautions entry is not a string") else empty end),
  (if (.overlapNotes? // null | type) != "array" then "top-level: missing/invalid overlapNotes array" else empty end),
  (if (.overlapNotes? // null | type) == "array" then
    (.overlapNotes[] | select(((.topic? // "") | is_nonempty_string | not) or ((.note? // "") | is_nonempty_string | not)) | "overlapNotes: an entry is missing a non-empty topic/note")
  else empty end),
  (if (.controls? // null | type) != "array" or ((.controls // []) | length) < 1 then "top-level: missing/invalid controls array" else empty end),

  (.controls[]? |
    . as $c |
    ($c.id // "?") as $id |
    (if ($c.id? // null | matches_safely(id_re) | not) then "\($id): invalid or malformed id" else empty end),
    (if ($c.domain? // null | is_nonempty_string | not) then "\($id): missing/invalid domain" else empty end),
    (if ($c.customerRequirement? // null | is_nonempty_string | not) then "\($id): missing/invalid customerRequirement" else empty end),
    (if ($c.scope? // null | is_nonempty_string | not) then "\($id): missing/invalid scope" else empty end),
    (if (classifications | index($c.classification)) == null then "\($id): undeclared classification '\($c.classification // "null")'" else empty end),
    (if ($c.mechanism? // null | type) != "object" then "\($id): missing mechanism object" else empty end),
    (if ($c.mechanism.kind? // null | is_nonempty_string | not) then "\($id): mechanism.kind missing/invalid" else empty end),
    (if ($c.mechanism.builtIn | type) != "boolean" then "\($id): mechanism.builtIn missing/invalid" else empty end),
    (if ($c.mechanism.displayName? // null | is_nonempty_string | not) then "\($id): mechanism.displayName missing/invalid" else empty end),
    (if ($c.mechanism.verifiedOn? // null | matches_safely(date_re) | not) then "\($id): mechanism.verifiedOn missing/invalid date" else empty end),
    (if (methods | index($c.mechanism.verificationMethod)) == null then "\($id): undeclared mechanism.verificationMethod '\($c.mechanism.verificationMethod // "null")'" else empty end),
    (if ($c.mechanism | has("majorVersion")) and (($c.mechanism.majorVersion | is_nonempty_string | not) or ($c.mechanism.majorVersion == "unknown") or ($c.mechanism.majorVersion == "n/a")) then "\($id): mechanism.majorVersion invalid or placeholder" else empty end),
    (if ($c.mechanism | has("verifiedVersion")) and (($c.mechanism.verifiedVersion | is_nonempty_string | not) or ($c.mechanism.verifiedVersion == "unknown") or ($c.mechanism.verifiedVersion == "n/a")) then "\($id): mechanism.verifiedVersion invalid or placeholder" else empty end),
    (if ($c.mechanism | has("sourceUrl")) and ($c.mechanism.sourceUrl != null) and (($c.mechanism.sourceUrl | type) != "string") then "\($id): mechanism.sourceUrl must be string or null" else empty end),
    (if ($c.mechanism | has("sourceUrl")) and ($c.mechanism.sourceUrl != null) and ($c.mechanism.sourceUrl | matches_safely("raw\\.githubusercontent\\.com")) and ($c.mechanism.sourceUrl | type == "string" and endswith("/")) then "\($id): mechanism.sourceUrl points at a directory listing" else empty end),
    (if ($c.mechanism.builtIn == true and (($c.mechanism.verificationMethod == "raw-json") or ($c.mechanism.verificationMethod == "initiative-json-member"))) and (($c.mechanism.definitionId? // "") | matches_safely(guid_re) | not) then "\($id): definitionId is not a well-formed GUID for a directly-verified built-in" else empty end),
    (if ($c.supportedEffects? // null | type) != "array" or (($c.supportedEffects // []) | length) < 1 then "\($id): supportedEffects missing/empty" else empty end),
    bad_string_items($c.supportedEffects?; "\($id): a supportedEffects entry is not a non-empty string"),
    (if ($c.requiredParameters? // null | type) != "array" then "\($id): requiredParameters must be an array" else empty end),
    (if ($c.requiredParameters? // null | type) == "array" then ($c.requiredParameters[] | select(type != "string") | "\($id): a requiredParameters entry is not a string") else empty end),
    (if ($c.roleDefinitionIds? // null | type) != "array" then "\($id): roleDefinitionIds must be an array" else empty end),
    bad_pattern_items($c.roleDefinitionIds?; guid_re; "\($id): a roleDefinitionIds entry is not a well-formed bare GUID"),
    (if ($c.remediationIdentityRequired | type) != "boolean" then "\($id): remediationIdentityRequired missing/invalid" else empty end),
    (if ($c | has("rolesVaryByMember")) and (($c.rolesVaryByMember | type) != "boolean") then "\($id): rolesVaryByMember must be boolean" else empty end),
    (if ($c.remediationIdentityRequired == true) and ((($c.roleDefinitionIds? // []) | if type == "array" then length else 1 end) == 0) and ($c.rolesVaryByMember != true) then "\($id): remediationIdentityRequired=true without a populated roleDefinitionIds array or rolesVaryByMember=true" else empty end),
    (if ($c.dependencies? // null | type) != "array" then "\($id): dependencies must be an array" else empty end),
    bad_pattern_items($c.dependencies?; id_re; "\($id): a dependencies entry is not a well-formed control id"),
    (if (phases | index($c.enforcementPhase)) == null then "\($id): undeclared enforcementPhase '\($c.enforcementPhase // "null")'" else empty end),
    (if ($c.evidenceSource? // null | is_nonempty_string | not) then "\($id): missing/invalid evidenceSource" else empty end)
  )
] | map(select(. != null and . != ""))
