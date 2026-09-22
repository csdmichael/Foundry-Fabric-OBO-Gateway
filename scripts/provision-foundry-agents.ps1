[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot '../config/deployment.json'),
    [string] $IdentityPath = (Join-Path $PSScriptRoot '../.generated/identity.json'),
    [string] $OutputPath = (Join-Path $PSScriptRoot '../.generated/foundry-agents.json'),
    [string] $FoundryAccessIpAddress,
    [int] $CredentialLifetimeMonths = 6,
    [switch] $SkipSmokeTest,
    [switch] $SkipEvaluations
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'config.ps1')

$config = Get-FabricDeploymentConfig -Path $ConfigPath
$configFingerprint = Get-FabricConfigFingerprint -Path $ConfigPath
$resolvedIdentityPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($IdentityPath)
if (-not (Test-Path -LiteralPath $resolvedIdentityPath -PathType Leaf)) {
    throw "Identity metadata not found: $resolvedIdentityPath"
}
$identity = Get-Content -LiteralPath $resolvedIdentityPath -Raw | ConvertFrom-Json
if ($identity.schemaVersion -ne 1 -or $identity.configFingerprint -ne $configFingerprint) {
    throw 'Identity metadata does not match the active deployment configuration.'
}
$oauthClients = @($identity.foundryOAuthClients)
if ($oauthClients.Count -ne 2 -or @($oauthClients.kind | Sort-Object) -join ',' -ne 'dataAgent,lakehouse') {
    throw 'Identity metadata must contain exactly one OAuth client for each Foundry agent.'
}

function Invoke-Graph {
    param(
        [Parameter(Mandatory = $true)] [string] $Token,
        [Parameter(Mandatory = $true)] [ValidateSet('GET', 'POST', 'PATCH')] [string] $Method,
        [Parameter(Mandatory = $true)] [string] $Path,
        [object] $Body
    )
    $arguments = @{
        Method = $Method
        Uri = "https://graph.microsoft.com/v1.0/$Path"
        Headers = @{ Authorization = "Bearer $Token" }
    }
    if ($null -ne $Body) {
        $arguments.ContentType = 'application/json'
        $arguments.Body = ConvertTo-Json -InputObject $Body -Depth 30
    }
    return Invoke-RestMethod @arguments
}

function Resolve-AccessIpAddress {
    param([string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        $Value = ([string](Invoke-RestMethod -Uri 'https://api.ipify.org')).Trim()
    }
    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($Value, [ref]$parsed) -or $parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw 'FoundryAccessIpAddress must be one IPv4 address without a CIDR suffix.'
    }
    return $parsed.ToString()
}

function Get-NetworkAclFingerprint {
    param([object] $NetworkAcls)
    if ($null -eq $NetworkAcls) { return '<null>' }
    return ([ordered]@{
        bypass = [string]$NetworkAcls.bypass
        defaultAction = [string]$NetworkAcls.defaultAction
        ipRules = @($NetworkAcls.ipRules | ForEach-Object { [string]$_.value } | Sort-Object)
        virtualNetworkRules = @($NetworkAcls.virtualNetworkRules | ForEach-Object { "$($_.id)|$($_.ignoreMissingVnetServiceEndpoint)" } | Sort-Object)
    } | ConvertTo-Json -Depth 8 -Compress)
}

function Find-RedirectUrl {
    param([object] $Value)
    if ($null -eq $Value) { return $null }
    foreach ($property in $Value.PSObject.Properties) {
        if ($property.Name -match 'redirect' -and $property.Value -is [string] -and $property.Value -match '^https://') {
            return [string]$property.Value
        }
        if ($property.Value -is [pscustomobject]) {
            $nested = Find-RedirectUrl -Value $property.Value
            if ($nested) { return $nested }
        }
    }
    return $null
}

function Write-ConnectionCheckpoint {
    param(
        [string] $Path,
        [ValidateSet('in-progress', 'ready', 'incomplete')] [string] $Status,
        [object[]] $Connections
    )
    [ordered]@{
        schemaVersion = 1
        configFingerprint = $configFingerprint
        status = $Status
        updatedAt = [DateTimeOffset]::UtcNow.ToString('o')
        connections = @($Connections)
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding utf8
}

$tenantId = [string]$config.azure.tenantId
$subscriptionId = [string]$config.azure.subscriptionId
$resourceGroup = [string]$config.azure.resourceGroup
$accountName = [string]$config.foundry.accountName
$projectName = [string]$config.foundry.projectName
$projectEndpoint = "https://$accountName.services.ai.azure.com/api/projects/$projectName"
$accountArmUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.CognitiveServices/accounts/${accountName}?api-version=2025-06-01"
$projectConnectionBase = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.CognitiveServices/accounts/$accountName/projects/$projectName/connections"
$authorizationUrl = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/authorize"
$tokenUrl = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
$oauthScope = "api://$($identity.resourceApi.clientId)/$($config.identity.delegatedScope)"
$managementToken = Get-FabricAzAccessToken -TenantId $tenantId -Resource 'https://management.azure.com/' -SubscriptionId $subscriptionId
$graphToken = Get-FabricAzAccessToken -TenantId $tenantId -Resource 'https://graph.microsoft.com/' -SubscriptionId $subscriptionId
$managementHeaders = @{ Authorization = "Bearer $managementToken" }
$callerIpAddress = Resolve-AccessIpAddress -Value $FoundryAccessIpAddress
$priorAccountState = Invoke-RestMethod -Method GET -Uri $accountArmUri -Headers $managementHeaders
$priorPublicNetworkAccess = [string]$priorAccountState.properties.publicNetworkAccess
$priorNetworkAcls = $priorAccountState.properties.networkAcls
$priorNetworkFingerprint = Get-NetworkAclFingerprint -NetworkAcls $priorNetworkAcls
$temporaryIpRule = $callerIpAddress
$existingIpRules = @($priorNetworkAcls.ipRules)
$temporaryIpRules = @($existingIpRules | Where-Object { $_.value -ne $callerIpAddress -and $_.value -ne $temporaryIpRule }) + @([pscustomobject]@{ value = $temporaryIpRule })
$temporaryNetworkAcls = [ordered]@{
    bypass = if ([string]::IsNullOrWhiteSpace([string]$priorNetworkAcls.bypass)) { 'AzureServices' } else { [string]$priorNetworkAcls.bypass }
    defaultAction = 'Deny'
    ipRules = $temporaryIpRules
    virtualNetworkRules = @($priorNetworkAcls.virtualNetworkRules)
}
$temporaryAccessAttempted = $false
$connectionMetadataPath = Join-Path (Split-Path -Parent $resolvedIdentityPath) 'foundry-connections.json'
$connectionBody = $null
$newCredential = $null
$connections = @()

try {
    $temporaryAccessAttempted = $true
    $temporaryAccountBody = @{ properties = @{ publicNetworkAccess = 'Enabled'; networkAcls = $temporaryNetworkAcls } } | ConvertTo-Json -Depth 20
    Invoke-RestMethod -Method PATCH -Uri $accountArmUri -Headers $managementHeaders -ContentType 'application/json' -Body $temporaryAccountBody | Out-Null

    Write-ConnectionCheckpoint -Path $connectionMetadataPath -Status 'in-progress' -Connections $connections
    foreach ($kind in 'lakehouse', 'dataAgent') {
        $oauthClient = @($oauthClients | Where-Object { $_.kind -eq $kind })[0]
        $connectionConfig = $config.foundry.mcpConnections.$kind
        $application = Invoke-Graph -Token $graphToken -Method GET -Path "applications/$($oauthClient.objectId)?`$select=id,appId,displayName,passwordCredentials,web" -Body $null
        if ($application.appId -ne $oauthClient.clientId -or $application.displayName -ne $connectionConfig.appDisplayName) {
            throw "Foundry OAuth client '$kind' does not match live Entra state."
        }
        $credentialDisplayName = "Foundry $kind MCP OAuth connection credential"
        $oldCredentials = @($application.passwordCredentials | Where-Object { $_.displayName -eq $credentialDisplayName })
        $newCredential = Invoke-Graph -Token $graphToken -Method POST -Path "applications/$($application.id)/addPassword" -Body @{
            passwordCredential = @{
                displayName = $credentialDisplayName
                endDateTime = [DateTimeOffset]::UtcNow.AddMonths($CredentialLifetimeMonths).ToString('o')
            }
        }
        $connectionCreated = $false
        try {
            $connectionBody = @{
                properties = @{
                    authType = 'OAuth2'
                    authorizationUrl = $authorizationUrl
                    category = 'RemoteTool'
                    credentials = @{
                        clientId = [string]$application.appId
                        clientSecret = [string]$newCredential.secretText
                    }
                    isSharedToAll = $true
                    metadata = @{ type = 'custom_MCP' }
                    refreshUrl = $tokenUrl
                    scopes = @($oauthScope, 'offline_access')
                    target = "$($config.apim.gatewayUrl)/$($connectionConfig.apiPath)"
                    tokenUrl = $tokenUrl
                }
            } | ConvertTo-Json -Depth 20
            $connectionUri = "$projectConnectionBase/$($connectionConfig.name)?api-version=2025-04-01-preview"
            $connection = Invoke-RestMethod -Method PUT -Uri $connectionUri -Headers $managementHeaders -ContentType 'application/json' -Body $connectionBody
            $connectionCreated = $true
            $connection = Invoke-RestMethod -Method GET -Uri $connectionUri -Headers $managementHeaders
            $redirectUrl = Find-RedirectUrl -Value $connection
            if ([string]::IsNullOrWhiteSpace($redirectUrl)) {
                throw "Foundry OAuth connection '$($connectionConfig.name)' did not return a redirect URL."
            }
            Invoke-Graph -Token $graphToken -Method PATCH -Path "applications/$($application.id)" -Body @{ web = @{ redirectUris = @($redirectUrl) } } | Out-Null
            foreach ($oldCredential in $oldCredentials) {
                Invoke-Graph -Token $graphToken -Method POST -Path "applications/$($application.id)/removePassword" -Body @{ keyId = $oldCredential.keyId } | Out-Null
            }
            $verifiedApplication = Invoke-Graph -Token $graphToken -Method GET -Path "applications/$($application.id)?`$select=passwordCredentials,web" -Body $null
            $managedCredentials = @($verifiedApplication.passwordCredentials | Where-Object { $_.displayName -eq $credentialDisplayName })
            if ($managedCredentials.Count -ne 1 -or $managedCredentials[0].keyId -ne $newCredential.keyId -or @($verifiedApplication.web.redirectUris) -notcontains $redirectUrl) {
                throw "Foundry OAuth client '$kind' credential or redirect validation failed."
            }
            $connections += [ordered]@{
                kind = $kind
                id = [string]$connection.id
                name = [string]$connection.name
                target = [string]$connection.properties.target
            }
            Write-ConnectionCheckpoint -Path $connectionMetadataPath -Status 'in-progress' -Connections $connections
        }
        catch {
            if (-not $connectionCreated -and $newCredential) {
                Invoke-Graph -Token $graphToken -Method POST -Path "applications/$($application.id)/removePassword" -Body @{ keyId = $newCredential.keyId } | Out-Null
            }
            throw
        }
        finally {
            $connectionBody = $null
            $newCredential = $null
        }
    }

    Write-ConnectionCheckpoint -Path $connectionMetadataPath -Status 'ready' -Connections $connections
    $generatedRoot = Split-Path -Parent $resolvedIdentityPath
    $venvRoot = Join-Path $generatedRoot 'foundry-venv'
    $venvPython = Join-Path $venvRoot 'Scripts/python.exe'
    if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
        & python -m venv $venvRoot
        if ($LASTEXITCODE -ne 0) { throw 'Unable to create the Foundry provisioning virtual environment.' }
    }
    & $venvPython -m pip install --disable-pip-version-check --quiet -r (Join-Path $PSScriptRoot 'requirements-foundry.txt')
    if ($LASTEXITCODE -ne 0) { throw 'Unable to install pinned Foundry provisioning dependencies.' }
    & $venvPython (Join-Path $PSScriptRoot 'test/test_foundry_knowledge.py')
    if ($LASTEXITCODE -ne 0) { throw 'Foundry knowledge-source tests failed.' }
    & $venvPython (Join-Path $PSScriptRoot 'test/test_foundry_evaluations.py')
    if ($LASTEXITCODE -ne 0) { throw 'Foundry managed-evaluation tests failed.' }
    $pythonArguments = @(
        (Join-Path $PSScriptRoot 'provision-foundry-agents.py'),
        '--config', $ConfigPath,
        '--connections', $connectionMetadataPath,
        '--output', $OutputPath
    )
    if ($SkipSmokeTest) { $pythonArguments += '--skip-smoke-test' }
    if ($SkipEvaluations) { $pythonArguments += '--skip-evaluations' }
    & $venvPython @pythonArguments
    if ($LASTEXITCODE -ne 0) { throw 'Foundry Prompt Agent provisioning or smoke testing failed.' }
    $resolvedOutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    $agentMetadata = Get-Content -LiteralPath $resolvedOutputPath -Raw | ConvertFrom-Json
    $agentMetadata | Add-Member -NotePropertyName configFingerprint -NotePropertyValue $configFingerprint -Force
    $agentMetadata | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $resolvedOutputPath -Encoding utf8
    [pscustomobject]@{
        OutputPath = $resolvedOutputPath
        ProjectEndpoint = $projectEndpoint
        Agents = @($agentMetadata.agents.name)
        SmokeTests = @($agentMetadata.agents.smokeTest)
        Evaluations = @($agentMetadata.agents.evaluation.status)
    }
}
catch {
    Write-ConnectionCheckpoint -Path $connectionMetadataPath -Status 'incomplete' -Connections $connections
    throw
}
finally {
    if ($temporaryAccessAttempted) {
        $restoreAccountBody = @{ properties = @{ publicNetworkAccess = $priorPublicNetworkAccess; networkAcls = $priorNetworkAcls } } | ConvertTo-Json -Depth 20
        $networkRestored = $false
        for ($attempt = 1; $attempt -le 12; $attempt++) {
            Invoke-RestMethod -Method PATCH -Uri $accountArmUri -Headers $managementHeaders -ContentType 'application/json' -Body $restoreAccountBody | Out-Null
            $restoredAccountState = Invoke-RestMethod -Method GET -Uri $accountArmUri -Headers $managementHeaders
            if ([string]$restoredAccountState.properties.publicNetworkAccess -eq $priorPublicNetworkAccess -and
                (Get-NetworkAclFingerprint -NetworkAcls $restoredAccountState.properties.networkAcls) -eq $priorNetworkFingerprint) {
                $networkRestored = $true
                break
            }
            Start-Sleep -Seconds 5
        }
        if (-not $networkRestored) {
            throw 'Foundry network restoration did not reproduce the exact prior state. Inspect the account before continuing.'
        }
    }
    $connectionBody = $null
    $newCredential = $null
    $managementToken = $null
    $graphToken = $null
}