[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot '../config/deployment.json'),
    [string] $OutputPath = (Join-Path $PSScriptRoot '../.generated/packages/fabric-obo-broker.zip'),
    [switch] $SkipInstall,
    [switch] $SkipTests
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'config.ps1')

$null = Get-FabricDeploymentConfig -Path $ConfigPath
$fabricRoot = Split-Path -Parent $PSScriptRoot
$sourceDirectory = Join-Path $fabricRoot 'functions/obo-broker'
$stageDirectory = Join-Path $fabricRoot '.generated/packages/broker-stage'
$resolvedOutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)

if (-not $SkipInstall) {
    Invoke-FabricNative -FilePath 'npm' -ArgumentList @('ci', '--prefix', $sourceDirectory) -Description 'Broker dependency installation'
}
if ($SkipTests) {
    Invoke-FabricNative -FilePath 'npm' -ArgumentList @('run', 'build', '--prefix', $sourceDirectory) -Description 'Broker build'
}
else {
    Invoke-FabricNative -FilePath 'npm' -ArgumentList @('test', '--prefix', $sourceDirectory) -Description 'Broker tests'
}

Remove-Item -LiteralPath $stageDirectory -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path (Join-Path $stageDirectory 'dist/src') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $sourceDirectory 'host.json') -Destination $stageDirectory
Copy-Item -LiteralPath (Join-Path $sourceDirectory 'package.json') -Destination $stageDirectory
Copy-Item -LiteralPath (Join-Path $sourceDirectory 'package-lock.json') -Destination $stageDirectory
Copy-Item -Path (Join-Path $sourceDirectory 'dist/src/*') -Destination (Join-Path $stageDirectory 'dist/src') -Recurse

Invoke-FabricNative -FilePath 'npm' -ArgumentList @('ci', '--omit=dev', '--ignore-scripts', '--prefix', $stageDirectory) -Description 'Production dependency installation'

$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) {
    throw 'Python 3 is required to create a portable deployment ZIP.'
}
Invoke-FabricNative -FilePath $python.Source -ArgumentList @((Join-Path $PSScriptRoot 'create_zip.py'), $stageDirectory, $resolvedOutputPath) -Description 'Deployment ZIP creation'

$archive = Get-Item -LiteralPath $resolvedOutputPath
$hash = Get-FileHash -LiteralPath $resolvedOutputPath -Algorithm SHA256
[pscustomobject]@{
    PackagePath = $archive.FullName
    SizeBytes = $archive.Length
    Sha256 = $hash.Hash.ToLowerInvariant()
}