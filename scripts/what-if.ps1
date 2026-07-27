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

& (Join-Path $ScriptDir 'preflight.ps1') -ParameterFile $ParameterFile
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

$parameters = Get-Content -LiteralPath $ParameterFile -Raw | ConvertFrom-Json
$deploymentLocation = [string]$parameters.parameters.deploymentLocation.value
$deploymentName = 'eslz-demo-preview-{0}' -f (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')

Write-Host ''
Write-Host 'Running tenant-scope what-if. This previews changes and does not deploy them.'
& az deployment tenant what-if `
    --name $deploymentName `
    --location $deploymentLocation `
    --template-file (Join-Path $ProjectDir 'main.bicep') `
    --parameters "@$ParameterFile" `
    --result-format FullResourcePayloads

if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

