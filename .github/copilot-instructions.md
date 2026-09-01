# Copilot instructions for this repository

## Repeatable main vs. one-shot artifacts

`main.bicep` must remain safely redeployable at any time. Never add
non-idempotent or one-time Azure resources to it — e.g. anything with a
deterministic request GUID such as `Microsoft.Authorization/roleEligibilityScheduleRequests`.
One-time/opt-in privileged operations belong in separate, explicit operator
workflows (see `scripts/owner-eligibility-request.*`), which require a
caller-supplied unique request ID and are never wired into the repeatable
deployment path. When adding a new module or resource, confirm it can be
deployed repeatedly without side effects before it goes into `main.bicep`.

## Azure resource/policy naming and validation limits

Validate against real Azure constraints, not assumed/generous ones:
- Management-group policy/initiative assignment names are limited to 24
  characters — check this explicitly rather than allowing longer names.
- `policyDefinitionId` / `policySetDefinitionId` and `definitionVersion`
  validation must accept only exact, supported forms (e.g. valid 3-component
  semantic version selectors like `1.*.*`), not merely non-blank or
  loosely-patterned strings.
- `notScopes` must be validated as real descendant scope/resource IDs under
  the current management group, not just checked for non-blank values.

## Bash/PowerShell parity

This repo maintains dual Bash (`*.sh`) and PowerShell (`*.ps1`) versions of
every operator script in `scripts/`. Any behavioral fix or validation change
made to one must be mirrored in the other (pagination handling, scope
matching, snapshot-before-what-if binding, etc.). Treat a one-sided fix as
incomplete.

## Test rigor

Reviewers repeatedly reject tests that merely grep assertion text instead of
exercising real failure conditions. When adding validation logic, write
negative fixtures that actually trigger a build failure or validator
rejection (e.g. malformed Bicep input, invalid version selectors), not just
string-matching on expected messages. Run `tests/test.ps1` (or the
corresponding Bash tests) before considering a change complete.
