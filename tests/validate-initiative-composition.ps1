[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir
$ArtifactsParent = Join-Path $ProjectDir '.test-artifacts'
$TempDir = Join-Path $ArtifactsParent ("initiative-ps1-" + [guid]::NewGuid().ToString('N'))
$ModuleJsonPath = Join-Path $TempDir 'policy-initiative.json'
$ExampleJsonPath = Join-Path $TempDir 'initiative-composition.json'
New-Item -ItemType Directory -Path $ArtifactsParent -Force | Out-Null
New-Item -ItemType Directory -Path $TempDir | Out-Null

function Stop-Test {
    param([string]$Message)
    throw $Message
}

function Assert-Test {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if (-not $Condition) {
        Stop-Test $Message
    }
}

function Get-AzureResourceTypes {
    param($Node)

    $types = @()
    if ($null -eq $Node) {
        return $types
    }
    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        $typeProperty = $Node.PSObject.Properties['type']
        if ($null -ne $typeProperty -and $typeProperty.Value -is [string] -and $typeProperty.Value.StartsWith('Microsoft.')) {
            $types += $typeProperty.Value
        }
        foreach ($property in $Node.PSObject.Properties) {
            $types += Get-AzureResourceTypes -Node $property.Value
        }
    }
    elseif ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
        foreach ($item in $Node) {
            $types += Get-AzureResourceTypes -Node $item
        }
    }
    return $types
}

try {
    if ($null -eq (Get-Command az -ErrorAction SilentlyContinue)) {
        Stop-Test 'Azure CLI is required for Bicep validation.'
    }

    Write-Host '1/8 Build the initiative module and compile-time example...'
    & az bicep build --file (Join-Path $ProjectDir 'modules/policy-initiative.bicep') --outfile $ModuleJsonPath
    if ($LASTEXITCODE -ne 0) { Stop-Test 'Initiative module Bicep build failed.' }
    & az bicep build --file (Join-Path $ProjectDir 'examples/initiative-composition.bicep') --outfile $ExampleJsonPath
    if ($LASTEXITCODE -ne 0) { Stop-Test 'Initiative example Bicep build failed.' }

    $moduleTemplate = Get-Content -LiteralPath $ModuleJsonPath -Raw | ConvertFrom-Json
    $exampleTemplate = Get-Content -LiteralPath $ExampleJsonPath -Raw | ConvertFrom-Json

    Write-Host '2/8 Validate the typed management-group module contract...'
    Assert-Test ($moduleTemplate.'$schema' -eq 'https://schema.management.azure.com/schemas/2019-08-01/managementGroupDeploymentTemplate.json#') 'Initiative module must target management-group scope.'
    Assert-Test ($moduleTemplate.languageVersion -eq '2.0') 'Initiative module must emit typed languageVersion 2.0 definitions.'
    Assert-Test ($moduleTemplate.parameters.initiativeParameters.type -eq 'object') 'initiativeParameters must be an object.'
    Assert-Test ($moduleTemplate.parameters.policyDefinitionGroups.type -eq 'array') 'policyDefinitionGroups must be a typed array.'
    Assert-Test ($moduleTemplate.parameters.policyDefinitionGroups.items.'$ref' -eq '#/definitions/policyDefinitionGroup') 'policyDefinitionGroups must use the policyDefinitionGroup type.'
    Assert-Test ($moduleTemplate.parameters.policyDefinitionReferences.type -eq 'array') 'policyDefinitionReferences must be a typed array.'
    Assert-Test ($moduleTemplate.parameters.policyDefinitionReferences.minLength -eq 1) 'policyDefinitionReferences must require at least one item.'
    Assert-Test ($moduleTemplate.parameters.policyDefinitionReferences.items.'$ref' -eq '#/definitions/policyDefinitionReference') 'policyDefinitionReferences must use the policyDefinitionReference type.'
    Assert-Test ($moduleTemplate.definitions.policyDefinitionReference.additionalProperties -eq $false) 'policyDefinitionReference must reject undeclared fields.'
    Assert-Test ($moduleTemplate.definitions.policyDefinitionReference.properties.policyDefinitionId.minLength -eq 1) 'policyDefinitionId must reject empty values.'
    Assert-Test ($moduleTemplate.definitions.policyDefinitionReference.properties.policyDefinitionReferenceId.minLength -eq 1) 'policyDefinitionReferenceId must reject empty values.'
    Assert-Test ($moduleTemplate.definitions.policyDefinitionReference.properties.parameters.type -eq 'object') 'Reference parameters must be typed as an object.'
    Assert-Test ($moduleTemplate.definitions.policyDefinitionReference.properties.groupNames.type -eq 'array') 'Reference groupNames must be typed as an array.'
    Assert-Test ($moduleTemplate.definitions.policyDefinitionGroup.additionalProperties -eq $false) 'policyDefinitionGroup must reject undeclared fields.'
    Assert-Test ($moduleTemplate.definitions.policyDefinitionGroup.properties.name.minLength -eq 1) 'Policy definition group names must reject empty values.'

    Write-Host '3/8 Validate initiative resource metadata and pass-through properties...'
    $initiative = $moduleTemplate.resources.initiative
    Assert-Test ($initiative.type -eq 'Microsoft.Authorization/policySetDefinitions') 'Module must create a policySetDefinitions resource.'
    Assert-Test ($initiative.apiVersion -eq '2025-03-01') 'Initiative must use the repository-aligned 2025-03-01 API.'
    Assert-Test ($initiative.properties.policyType -eq 'Custom') 'Initiative policyType must be Custom.'
    Assert-Test ($initiative.properties.displayName -eq "[parameters('initiativeDisplayName')]") 'Initiative display name must pass through.'
    Assert-Test ($initiative.properties.description -eq "[parameters('initiativeDescription')]") 'Initiative description must pass through.'
    Assert-Test ($initiative.properties.parameters -eq "[parameters('initiativeParameters')]") 'Initiative parameters must pass through.'
    Assert-Test ($initiative.properties.policyDefinitionGroups -eq "[parameters('policyDefinitionGroups')]") 'Policy definition groups must pass through.'
    Assert-Test ($initiative.properties.version -eq "[parameters('initiativeVersion')]") 'Initiative version property must pass through.'
    Assert-Test ($initiative.properties.metadata.category -eq "[parameters('initiativeCategory')]") 'Initiative category metadata must pass through.'
    Assert-Test ($initiative.properties.metadata.version -eq "[parameters('initiativeVersion')]") 'Initiative version metadata must pass through.'
    Assert-Test ($initiative.properties.metadata.governanceVersion -eq '2.0') 'Initiative metadata must identify v2 governance.'
    Assert-Test ($initiative.properties.metadata.managedBy -eq 'Bicep') 'Initiative metadata must identify Bicep management.'
    Assert-Test ($initiative.properties.copy[0].name -eq 'policyDefinitions') 'Module must compose policy definitions with a property loop.'
    Assert-Test ($initiative.properties.copy[0].input.Contains('validatedPolicyDefinitionReferences')) 'Per-reference values must pass through.'
    Assert-Test ($initiative.properties.copy[0].input.Contains("'definitionVersion'")) 'Optional per-reference definition versions must pass through.'
    Assert-Test ($initiative.properties.copy[0].input.Contains("'parameters'")) 'Per-reference parameters must pass through.'
    Assert-Test ($initiative.properties.copy[0].input.Contains("'groupNames'")) 'Per-reference group names must pass through.'

    Write-Host '4/8 Validate empty and duplicate reference-ID guards...'
    Assert-Test ($moduleTemplate.variables.copy[0].name -eq 'normalizedPolicyDefinitionReferenceIds') 'Reference IDs must be normalized before duplicate detection.'
    Assert-Test ($moduleTemplate.variables.copy[0].input.Contains('toLower(')) 'Reference ID duplicate detection must be case-insensitive.'
    Assert-Test ($moduleTemplate.variables.hasDuplicatePolicyDefinitionReferenceIds.Contains('union(')) 'Reference ID duplicate detection must compare the unique set.'
    Assert-Test ($moduleTemplate.variables.validatedPolicyDefinitionReferences.Contains("fail('policyDefinitionReferences must use non-empty, case-insensitively unique policyDefinitionReferenceId values.")) 'Duplicate reference IDs must fail explicitly.'

    Write-Host '5/8 Validate deterministic module outputs...'
    Assert-Test ($moduleTemplate.outputs.policySetDefinitionId.value.Contains('extensionResourceId(managementGroup().id')) 'Definition ID output must be deterministic at the current management group.'
    Assert-Test ($moduleTemplate.outputs.policySetDefinitionName.value -eq "[parameters('initiativeName')]") 'Definition name output must match initiativeName.'
    Assert-Test ($moduleTemplate.outputs.policyDefinitionReferenceIds.type -eq 'array') 'Reference ID output must be an array.'
    Assert-Test ($moduleTemplate.outputs.policyDefinitionReferenceIds.copy.input.Contains('.policyDefinitionReferenceId')) 'Reference ID output must preserve stable caller IDs.'

    Write-Host '6/8 Validate dedicated demo-root scope, stable references, groups, and parameter mappings...'
    $exampleDeployment = $exampleTemplate.resources.organizationalAuditInitiative
    Assert-Test ($exampleTemplate.'$schema' -eq 'https://schema.management.azure.com/schemas/2019-08-01/tenantDeploymentTemplate.json#') 'Example must be a tenant-scope composition entry point.'
    Assert-Test ($exampleDeployment.scope.Contains('demoRootManagementGroupId')) 'Example module scope must use the dedicated demo-root parameter.'
    $references = @($exampleDeployment.properties.parameters.policyDefinitionReferences.value)
    $groups = @($exampleDeployment.properties.parameters.policyDefinitionGroups.value)
    Assert-Test ($references.Count -eq 2) 'Example must combine exactly one built-in and one custom definition.'
    $referenceIds = @($references | ForEach-Object { [string]$_.policyDefinitionReferenceId })
    Assert-Test (@($referenceIds | Where-Object { $_.Length -eq 0 }).Count -eq 0) 'Example reference IDs must be non-empty.'
    $uniqueReferenceIds = @($referenceIds | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
    Assert-Test ($uniqueReferenceIds.Count -eq $referenceIds.Count) 'Example reference IDs must be case-insensitively unique.'
    Assert-Test (@($groups | Where-Object { $_.name -eq 'deployment-visibility' }).Count -eq 1) 'Example must define its reference group.'
    Assert-Test (@($references | Where-Object { $_.groupNames -notcontains 'deployment-visibility' }).Count -eq 0) 'Every example reference must use the declared group.'
    Assert-Test ($references[0].parameters.listOfAllowedLocations.value -eq "[[parameters('allowedLocations')]") 'Allowed locations must map from the initiative parameter.'
    Assert-Test ($references[0].parameters.effect.value -eq "[[parameters('effect')]") 'Effect must map from the initiative parameter.'
    Assert-Test ($exampleDeployment.properties.parameters.initiativeParameters.value.effect.defaultValue -eq 'Audit') 'Example effect must default to Audit.'
    foreach ($outputName in @('policySetDefinitionId', 'policySetDefinitionName', 'policyDefinitionReferenceIds')) {
        Assert-Test ($null -ne $exampleTemplate.outputs.PSObject.Properties[$outputName]) "Example output is missing: $outputName"
    }

    Write-Host '7/8 Confirm every sample definition identifier is authoritative...'
    $exampleSource = Get-Content -LiteralPath (Join-Path $ProjectDir 'examples/initiative-composition.bicep') -Raw
    $catalog = Get-Content -LiteralPath (Join-Path $ProjectDir 'policy/control-catalog.json') -Raw | ConvertFrom-Json
    $definitionIds = @([regex]::Matches($exampleSource, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') | ForEach-Object { $_.Value } | Sort-Object -Unique)
    Assert-Test ($definitionIds.Count -gt 0) 'Example must include a catalog-backed built-in policy definition ID.'
    foreach ($definitionId in $definitionIds) {
        $catalogMatches = @($catalog.controls | Where-Object {
            $_.classification -eq 'azure-policy' -and
            $_.mechanism.builtIn -eq $true -and
            [string]::Equals([string]$_.mechanism.definitionId, $definitionId, [System.StringComparison]::OrdinalIgnoreCase)
        })
        Assert-Test ($catalogMatches.Count -ge 1) "Example policy definition ID is not a verified built-in in the control catalog: $definitionId"
    }
    $customCatalogMatches = @($catalog.controls | Where-Object {
        $_.classification -eq 'azure-policy' -and
        $_.mechanism.builtIn -eq $false -and
        $_.mechanism.definitionId -eq '${namePrefix}-audit-public-ip' -and
        $_.mechanism.verificationMethod -eq 'in-repository-custom-definition'
    })
    Assert-Test ($customCatalogMatches.Count -eq 1) 'The example custom policy definition must match the authoritative catalog entry.'
    Assert-Test ($exampleSource.Contains("'`${namePrefix}-audit-public-ip'")) 'The example custom policy definition ID must preserve the catalog name pattern.'

    Write-Host '8/8 Confirm the example is audit-first, unassigned, and no-cost-safe...'
    $allowedResourceTypes = @(
        'Microsoft.Resources/deployments',
        'Microsoft.Authorization/policySetDefinitions'
    )
    foreach ($resourceType in @(Get-AzureResourceTypes -Node $exampleTemplate)) {
        Assert-Test ($resourceType -in $allowedResourceTypes) "Example declares an out-of-scope or potentially metered resource type: $resourceType"
    }
    Assert-Test ($exampleSource -notmatch 'policyAssignments|roleAssignments|deployIfNotExists|modify') 'Example must remain unassigned and audit-first.'

    Write-Host ''
    Write-Host 'Initiative composition validation passed.'
}
finally {
    if (Test-Path -LiteralPath $TempDir) {
        Remove-Item -LiteralPath $TempDir -Recurse -Force
    }
    if (Test-Path -LiteralPath $ArtifactsParent) {
        $remainingArtifacts = @(Get-ChildItem -LiteralPath $ArtifactsParent -Force)
        if ($remainingArtifacts.Count -eq 0) {
            Remove-Item -LiteralPath $ArtifactsParent -Force
        }
    }
}
