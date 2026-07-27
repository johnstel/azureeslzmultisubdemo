[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$ParameterFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir
if ([string]::IsNullOrWhiteSpace($ParameterFile)) {
    $ParameterFile = Join-Path $ProjectDir 'parameters/demo.parameters.json'
}

if ($env:ESLZ_DEPLOY_CONFIRMATION -ne 'DEPLOY-ESLZ-DEMO') {
    Write-Error 'Deployment is locked. Set ESLZ_DEPLOY_CONFIRMATION=DEPLOY-ESLZ-DEMO only after reviewing what-if.' -ErrorAction Continue
    exit 2
}

& (Join-Path $ScriptDir 'preflight.ps1') -ParameterFile $ParameterFile
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
& (Join-Path $ScriptDir 'what-if.ps1') -ParameterFile $ParameterFile
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

$parameters = Get-Content -LiteralPath $ParameterFile -Raw | ConvertFrom-Json
$demoRoot = [string]$parameters.parameters.namePrefix.value
$connectivitySubscription = [string]$parameters.parameters.connectivitySubscriptionId.value
$workloadSubscription = [string]$parameters.parameters.workloadSubscriptionId.value
$deploymentLocation = [string]$parameters.parameters.deploymentLocation.value

Write-Host ''
Write-Host 'LIVE DEPLOYMENT TARGET'
Write-Host "  Demo root: $demoRoot"
Write-Host "  Connectivity subscription: $connectivitySubscription"
Write-Host "  Workload subscription: $workloadSubscription"
$typedConfirmation = Read-Host "Type the demo root ID ($demoRoot) to continue"
if ($typedConfirmation -ne $demoRoot) {
    Write-Error 'Confirmation did not match; deployment cancelled.' -ErrorAction Continue
    exit 2
}

$deploymentName = 'eslz-demo-{0}' -f (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
& az deployment tenant create `
    --name $deploymentName `
    --location $deploymentLocation `
    --template-file (Join-Path $ProjectDir 'main.bicep') `
    --parameters "@$ParameterFile"

if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
