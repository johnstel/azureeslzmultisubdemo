# Self-contained jq re-implementation of policy/control-catalog.schema.json.
# Produces a JSON array of human-readable error strings (empty array = valid).
# Used as the offline fallback for step 9/10 of tests/validate-control-catalog.sh
# when python3 + the jsonschema package are not available, so that the fallback
# path enforces the *complete* schema (required fields, types, enums,
# patterns/formats, uniqueness, references, and the remediation-role rule)
# rather than a partial subset. Keep in sync with policy/control-catalog.schema.json
# and with the PowerShell equivalent in tests/validate-control-catalog.ps1.

def guid_re: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$";
def id_re: "^REQ-[A-Z]+-[0-9]{2}$";
def date_re: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$";
def classifications: ["azure-policy","entra-pim","defender-cspm-ciem","shared-service-architecture","manual-evidence"];
def phases: ["audit-only","deny-do-not-enforce","deployifnotexists-opt-in","manual-evidence"];
def methods: ["raw-json","initiative-json-member","ms-learn-page","documentation-pattern","internal-design","in-repository-custom-definition","not-yet-selected","not-yet-created"];

def is_nonempty_string: type == "string" and length >= 1;

[
  (if (.["$schema"]? // null | type) != "string" then "top-level: missing/invalid $schema" else empty end),
  (if (.catalogVersion? // null | type) != "string" then "top-level: missing/invalid catalogVersion" else empty end),
  (if (.generatedOn? // null | type) != "string" or ((.generatedOn // "") | test(date_re) | not) then "top-level: missing/invalid generatedOn date" else empty end),
  (if (.purpose? // null | is_nonempty_string | not) then "top-level: missing/invalid purpose" else empty end),
  (if (.sourceIssue? // null | type) != "string" or ((.sourceIssue // "") | test("^https?://") | not) then "top-level: missing/invalid sourceIssue uri" else empty end),
  (if (.classificationValues? // null | type) != "array" or ((.classificationValues // []) | length) < 1 then "top-level: missing/invalid classificationValues" else empty end),
  (if ((.classificationValues // []) | unique | length) != ((.classificationValues // []) | length) then "top-level: classificationValues entries are not unique" else empty end),
  (if (.enforcementPhaseValues? // null | type) != "array" or ((.enforcementPhaseValues // []) | length) < 1 then "top-level: missing/invalid enforcementPhaseValues" else empty end),
  (if ((.enforcementPhaseValues // []) | unique | length) != ((.enforcementPhaseValues // []) | length) then "top-level: enforcementPhaseValues entries are not unique" else empty end),
  (if (.cautions? // null | type) != "array" then "top-level: missing/invalid cautions array" else empty end),
  ((.cautions // [])[] | select(type != "string") | "top-level: a cautions entry is not a string"),
  (if (.overlapNotes? // null | type) != "array" then "top-level: missing/invalid overlapNotes array" else empty end),
  ((.overlapNotes // [])[] | select(((.topic? // "") | is_nonempty_string | not) or ((.note? // "") | is_nonempty_string | not)) | "overlapNotes: an entry is missing a non-empty topic/note"),
  (if (.controls? // null | type) != "array" or ((.controls // []) | length) < 1 then "top-level: missing/invalid controls array" else empty end),

  (.controls[]? |
    . as $c |
    ($c.id // "?") as $id |
    (if ($c.id? // null | type) != "string" or (($c.id // "") | test(id_re) | not) then "\($id): invalid or malformed id" else empty end),
    (if ($c.domain? // null | is_nonempty_string | not) then "\($id): missing/invalid domain" else empty end),
    (if ($c.customerRequirement? // null | is_nonempty_string | not) then "\($id): missing/invalid customerRequirement" else empty end),
    (if ($c.scope? // null | is_nonempty_string | not) then "\($id): missing/invalid scope" else empty end),
    (if (classifications | index($c.classification)) == null then "\($id): undeclared classification '\($c.classification // "null")'" else empty end),
    (if ($c.mechanism? // null | type) != "object" then "\($id): missing mechanism object" else empty end),
    (if ($c.mechanism.kind? // null | is_nonempty_string | not) then "\($id): mechanism.kind missing/invalid" else empty end),
    (if ($c.mechanism.builtIn | type) != "boolean" then "\($id): mechanism.builtIn missing/invalid" else empty end),
    (if ($c.mechanism.displayName? // null | is_nonempty_string | not) then "\($id): mechanism.displayName missing/invalid" else empty end),
    (if ($c.mechanism.verifiedOn? // null | type) != "string" or ((($c.mechanism.verifiedOn // "")) | test(date_re) | not) then "\($id): mechanism.verifiedOn missing/invalid date" else empty end),
    (if (methods | index($c.mechanism.verificationMethod)) == null then "\($id): undeclared mechanism.verificationMethod '\($c.mechanism.verificationMethod // "null")'" else empty end),
    (if ($c.mechanism | has("majorVersion")) and (($c.mechanism.majorVersion | is_nonempty_string | not) or ($c.mechanism.majorVersion == "unknown") or ($c.mechanism.majorVersion == "n/a")) then "\($id): mechanism.majorVersion invalid or placeholder" else empty end),
    (if ($c.mechanism | has("verifiedVersion")) and (($c.mechanism.verifiedVersion | is_nonempty_string | not) or ($c.mechanism.verifiedVersion == "unknown") or ($c.mechanism.verifiedVersion == "n/a")) then "\($id): mechanism.verifiedVersion invalid or placeholder" else empty end),
    (if ($c.mechanism | has("sourceUrl")) and ($c.mechanism.sourceUrl != null) and (($c.mechanism.sourceUrl | type) != "string") then "\($id): mechanism.sourceUrl must be string or null" else empty end),
    (if ($c.mechanism | has("sourceUrl")) and ($c.mechanism.sourceUrl != null) and ($c.mechanism.sourceUrl | test("raw\\.githubusercontent\\.com")) and ($c.mechanism.sourceUrl | endswith("/")) then "\($id): mechanism.sourceUrl points at a directory listing" else empty end),
    (if ($c.mechanism.builtIn == true and (($c.mechanism.verificationMethod == "raw-json") or ($c.mechanism.verificationMethod == "initiative-json-member"))) and ((($c.mechanism.definitionId? // "")) | test(guid_re) | not) then "\($id): definitionId is not a well-formed GUID for a directly-verified built-in" else empty end),
    (if ($c.supportedEffects? // null | type) != "array" or (($c.supportedEffects // []) | length) < 1 then "\($id): supportedEffects missing/empty" else empty end),
    (($c.supportedEffects // [])[] | select(is_nonempty_string | not) | "\($id): a supportedEffects entry is not a non-empty string"),
    (if ($c.requiredParameters? // null | type) != "array" then "\($id): requiredParameters must be an array" else empty end),
    (if ($c.roleDefinitionIds? // null | type) != "array" then "\($id): roleDefinitionIds must be an array" else empty end),
    (($c.roleDefinitionIds // [])[] | select(test(guid_re) | not) | "\($id): a roleDefinitionIds entry is not a well-formed bare GUID"),
    (if ($c.remediationIdentityRequired | type) != "boolean" then "\($id): remediationIdentityRequired missing/invalid" else empty end),
    (if ($c | has("rolesVaryByMember")) and (($c.rolesVaryByMember | type) != "boolean") then "\($id): rolesVaryByMember must be boolean" else empty end),
    (if ($c.remediationIdentityRequired == true) and ((($c.roleDefinitionIds // []) | length) == 0) and ($c.rolesVaryByMember != true) then "\($id): remediationIdentityRequired=true without a populated roleDefinitionIds array or rolesVaryByMember=true" else empty end),
    (if ($c.dependencies? // null | type) != "array" then "\($id): dependencies must be an array" else empty end),
    (($c.dependencies // [])[] | select(test(id_re) | not) | "\($id): a dependencies entry is not a well-formed control id"),
    (if (phases | index($c.enforcementPhase)) == null then "\($id): undeclared enforcementPhase '\($c.enforcementPhase // "null")'" else empty end),
    (if ($c.evidenceSource? // null | is_nonempty_string | not) then "\($id): missing/invalid evidenceSource" else empty end)
  )
] | map(select(. != null and . != ""))
