[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot '../config/deployment.json'),
    [string] $IdentityPath = (Join-Path $PSScriptRoot '../.generated/identity.json'),
    [string] $OutputDirectory = (Join-Path $PSScriptRoot '../.generated/connectors'),
    [int] $CredentialLifetimeMonths = 6,
    [switch] $DefinitionOnly
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'config.ps1')

$config = Get-FabricDeploymentConfig -Path $ConfigPath
$configFingerprint = Get-FabricConfigFingerprint -Path $ConfigPath
$resourceTenantId = [string]$config.identity.resourceTenantId
$callerTenantId = [string]$config.identity.callerTenantId
$environmentId = [string](Get-FabricConfigValue -Config $config -Path 'powerPlatform.environmentId' -AllowEmpty)
$gatewayUri = [uri]([string]$config.apim.gatewayUrl)
$scope = [string]$config.identity.delegatedScope
$resolvedOutputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null

function New-OAuthDefinition {
    param(
        [string] $Title,
        [string] $Description,
        [string] $BasePath,
        [ValidateSet('lakehouse', 'dataAgent')] [string] $Kind
    )

    $paths = [ordered]@{}
    if ($Kind -eq 'lakehouse') {
        $paths['/knowledge'] = [ordered]@{
            post = [ordered]@{
                operationId = 'knowledge'
                summary = 'Search open Lakehouse shortages'
                description = 'Returns up to 15 citation-ready snippets under the signed-in user permissions.'
                consumes = @('application/json')
                produces = @('application/json')
                parameters = @([ordered]@{
                    name = 'body'
                    in = 'body'
                    required = $true
                    schema = [ordered]@{
                        type = 'object'
                        additionalProperties = $false
                        required = @('query')
                        properties = [ordered]@{
                            query = [ordered]@{
                                type = 'string'
                                minLength = 1
                                maxLength = 500
                                description = 'Context-aware knowledge search query.'
                                'x-ms-summary' = 'Knowledge query'
                            }
                        }
                    }
                })
                responses = [ordered]@{
                    '200' = [ordered]@{
                        description = 'Citation-ready Lakehouse knowledge results.'
                        schema = [ordered]@{
                            type = 'object'
                            required = @('query', 'results')
                            properties = [ordered]@{
                                query = [ordered]@{ type = 'string' }
                                results = [ordered]@{
                                    type = 'array'
                                    maxItems = 15
                                    items = [ordered]@{
                                        type = 'object'
                                        required = @('snippet', 'title', 'url')
                                        properties = [ordered]@{
                                            snippet = [ordered]@{ type = 'string' }
                                            title = [ordered]@{ type = 'string' }
                                            url = [ordered]@{ type = 'string'; format = 'uri' }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        $paths['/query'] = [ordered]@{
            post = [ordered]@{
                operationId = 'query'
                summary = 'Run a read-only Lakehouse query'
                description = 'Runs one read-only SQL statement under the signed-in user permissions.'
                consumes = @('application/json')
                produces = @('application/json')
                parameters = @([ordered]@{
                    name = 'body'
                    in = 'body'
                    required = $true
                    schema = [ordered]@{
                        type = 'object'
                        additionalProperties = $false
                        required = @('statement')
                        properties = [ordered]@{
                            statement = [ordered]@{
                                type = 'string'
                                minLength = 1
                                maxLength = [int]$config.broker.maxStatementLength
                                description = 'One read-only SQL SELECT or CTE statement.'
                                'x-ms-summary' = 'SQL statement'
                            }
                        }
                    }
                })
                responses = [ordered]@{ '200' = [ordered]@{ description = 'Lakehouse query result.' } }
            }
        }
        $paths['/tables'] = [ordered]@{
            get = [ordered]@{
                operationId = 'tables'
                summary = 'List visible Lakehouse tables'
                description = 'Lists Lakehouse tables visible under the signed-in user permissions.'
                produces = @('application/json')
                responses = [ordered]@{ '200' = [ordered]@{ description = 'Visible Lakehouse tables.' } }
            }
        }
    }
    else {
        $paths['/query'] = [ordered]@{
            post = [ordered]@{
                operationId = 'query'
                summary = 'Query the Fabric Data Agent'
                description = 'Asks a natural-language question under the signed-in user permissions.'
                consumes = @('application/json')
                produces = @('application/json')
                parameters = @([ordered]@{
                    name = 'body'
                    in = 'body'
                    required = $true
                    schema = [ordered]@{
                        type = 'object'
                        additionalProperties = $false
                        required = @('question')
                        properties = [ordered]@{
                            question = [ordered]@{
                                type = 'string'
                                minLength = 1
                                maxLength = 4000
                                description = 'The natural-language question for the published Fabric Data Agent.'
                                'x-ms-summary' = 'Question'
                            }
                        }
                    }
                })
                responses = [ordered]@{ '200' = [ordered]@{ description = 'Fabric Data Agent response.' } }
            }
        }
    }

    return [ordered]@{
        swagger = '2.0'
        info = [ordered]@{ title = $Title; version = '1.0.0'; description = $Description }
        host = $gatewayUri.Host
        basePath = $BasePath
        schemes = @('https')
        consumes = @('application/json')
        produces = @('application/json')
        paths = $paths
        securityDefinitions = [ordered]@{
            oauth2 = [ordered]@{
                type = 'oauth2'
                flow = 'accessCode'
                authorizationUrl = "https://login.microsoftonline.com/$resourceTenantId/oauth2/authorize"
                tokenUrl = "https://login.microsoftonline.com/$resourceTenantId/oauth2/token"
                scopes = [ordered]@{ $scope = 'Access Microsoft Fabric under the signed-in user permissions.' }
            }
        }
        security = @([ordered]@{ oauth2 = @($scope) })
    }
}

$definitions = @(
    [pscustomobject]@{
        Kind = 'lakehouse'
        ConnectorName = [string]$config.powerPlatform.lakehouseConnectorName
        BasePath = "/$($config.apim.lakehouseApiPath)"
        Description = 'Queries the private Microsoft Fabric Lakehouse API through APIM with delegated OBO authorization.'
        FileName = 'lakehouse-connector.swagger.json'
    },
    [pscustomobject]@{
        Kind = 'dataAgent'
        ConnectorName = [string]$config.powerPlatform.dataAgentConnectorName
        BasePath = "/$($config.apim.dataAgentApiPath)"
        Description = 'Queries the published Microsoft Fabric Data Agent through APIM with delegated OBO authorization.'
        FileName = 'data-agent-connector.swagger.json'
    }
)

foreach ($definition in $definitions) {
    $definition | Add-Member -NotePropertyName Swagger -NotePropertyValue (New-OAuthDefinition -Title $definition.ConnectorName -Description $definition.Description -BasePath $definition.BasePath -Kind $definition.Kind)
    $definition.Swagger | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath (Join-Path $resolvedOutputDirectory $definition.FileName) -Encoding utf8
}

if ($DefinitionOnly) {
    return $definitions | ForEach-Object {
        [pscustomobject]@{ Kind = $_.Kind; DefinitionPath = Join-Path $resolvedOutputDirectory $_.FileName }
    }
}

$environmentId = Assert-FabricGuid -Value $environmentId -Name 'powerPlatform.environmentId'
$resolvedIdentityPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($IdentityPath)
if (-not (Test-Path -LiteralPath $resolvedIdentityPath -PathType Leaf)) {
    throw "Run provision-identity.ps1 first. Identity metadata not found: $resolvedIdentityPath"
}
$identity = Get-Content -LiteralPath $resolvedIdentityPath -Raw | ConvertFrom-Json
if ($identity.schemaVersion -ne 1 -or $identity.configFingerprint -ne $configFingerprint -or $identity.resourceTenantId -ne $resourceTenantId -or $identity.callerTenantId -ne $callerTenantId) {
    throw 'Identity metadata fingerprint, schema, or tenant IDs do not match deployment.json.'
}
$identityConnectorKinds = @($identity.connectors.kind | Sort-Object)
if ($identityConnectorKinds.Count -ne 2 -or $identityConnectorKinds[0] -ne 'dataAgent' -or $identityConnectorKinds[1] -ne 'lakehouse') {
    throw 'Identity metadata must contain exactly one dataAgent and one lakehouse connector.'
}

$powerPlatformToken = Get-FabricAzAccessToken -TenantId $callerTenantId -Resource 'https://service.powerapps.com/' -SubscriptionId ([string]$config.apim.subscriptionId)
$resourceGraphToken = Get-FabricAzAccessToken -TenantId $resourceTenantId -Resource 'https://graph.microsoft.com/' -SubscriptionId ([string]$config.azure.subscriptionId)

function Invoke-ResourceGraph {
    param([ValidateSet('GET', 'POST', 'PATCH')] [string] $Method, [string] $Path, [object] $Body)
    $arguments = @{
        Method = $Method
        Uri = "https://graph.microsoft.com/v1.0/$Path"
        Headers = @{ Authorization = "Bearer $resourceGraphToken" }
    }
    if ($null -ne $Body) {
        $arguments.ContentType = 'application/json'
        $arguments.Body = ConvertTo-Json -InputObject $Body -Depth 20
    }
    return Invoke-RestMethod @arguments
}

function Get-CustomParameterValue {
    param([object] $Settings, [string] $Name)
    if (-not $Settings -or -not $Settings.PSObject.Properties['customParameters']) {
        return ''
    }
    $property = $Settings.customParameters.PSObject.Properties[$Name]
    if (-not $property -or -not $property.Value.PSObject.Properties['value']) {
        return ''
    }
    return [string]$property.Value.value
}

function Assert-ExistingConnector {
    param(
        [object] $Connector,
        [object] $Definition,
        [object] $IdentityConnector,
        [object] $Application
    )

    $expectedBackend = "https://$($gatewayUri.Host)$($Definition.BasePath)"
    if ([string]$Connector.properties.backendService.serviceUrl -ne $expectedBackend) {
        throw "Existing connector '$($Definition.ConnectorName)' backend does not match '$expectedBackend'. Delete and recreate it explicitly."
    }
    $oauthSettings = $Connector.properties.connectionParameters.token.oAuthSettings
    $expectedScopes = @($scope)
    $actualScopes = @($oauthSettings.scopes)
    if ([string]$oauthSettings.identityProvider -ne 'aad' -or [string]$oauthSettings.clientId -ne [string]$IdentityConnector.clientId -or
        (@($actualScopes | Sort-Object) -join ' ') -ne (@($expectedScopes | Sort-Object) -join ' ') -or
        (Get-CustomParameterValue -Settings $oauthSettings -Name 'TenantId') -ne $resourceTenantId -or
        (Get-CustomParameterValue -Settings $oauthSettings -Name 'ResourceUri') -ne "api://$($identity.resourceApi.clientId)" -or
        (Get-CustomParameterValue -Settings $oauthSettings -Name 'EnableOnbehalfOfLogin') -ne 'True') {
        throw "Existing connector '$($Definition.ConnectorName)' OAuth configuration has drifted. Delete and recreate it explicitly."
    }
    $openApiProperty = $Connector.properties.PSObject.Properties['openApiDefinition']
    $runtimeSwaggerProperty = $Connector.properties.PSObject.Properties['swagger']
    $isRuntimeSwagger = -not $openApiProperty -and $null -ne $runtimeSwaggerProperty
    $swagger = if ($openApiProperty) { $openApiProperty.Value } elseif ($runtimeSwaggerProperty) { $runtimeSwaggerProperty.Value } else { $null }
    if (-not $swagger) {
        throw "Existing connector '$($Definition.ConnectorName)' does not expose an OpenAPI definition."
    }
    $expectedSwagger = $Definition.Swagger | ConvertTo-Json -Depth 40 | ConvertFrom-Json
    $expectedOperations = @($expectedSwagger.paths.PSObject.Properties.Name | Sort-Object)
    $actualOperations = @($swagger.paths.PSObject.Properties.Name | ForEach-Object { $_ -replace '^/\{connectionId\}', '' } | Sort-Object)
    if ([string]$swagger.swagger -ne '2.0' -or
        (-not $isRuntimeSwagger -and ([string]$swagger.host -ne $gatewayUri.Host -or [string]$swagger.basePath -ne $Definition.BasePath)) -or
        ($actualOperations -join ' ') -ne ($expectedOperations -join ' ')) {
        throw "Existing connector '$($Definition.ConnectorName)' OpenAPI definition has drifted. Delete and recreate it explicitly."
    }
    foreach ($pathProperty in $expectedSwagger.paths.PSObject.Properties) {
        $actualPathName = if ($isRuntimeSwagger) { "/{connectionId}$($pathProperty.Name)" } else { $pathProperty.Name }
        $actualPathProperty = $swagger.paths.PSObject.Properties[$actualPathName]
        if (-not $actualPathProperty) {
            throw "Existing connector '$($Definition.ConnectorName)' is missing path '$($pathProperty.Name)'."
        }
        foreach ($methodProperty in $pathProperty.Value.PSObject.Properties) {
            $actualMethodProperty = $actualPathProperty.Value.PSObject.Properties[$methodProperty.Name]
            if (-not $actualMethodProperty -or [string]$actualMethodProperty.Value.operationId -ne [string]$methodProperty.Value.operationId) {
                throw "Existing connector '$($Definition.ConnectorName)' operation '$($methodProperty.Value.operationId)' has drifted."
            }
        }
    }
    $redirectUrl = [string]$oauthSettings.redirectUrl
    $redirectUri = $null
    if (-not [uri]::TryCreate($redirectUrl, [System.UriKind]::Absolute, [ref]$redirectUri) -or $redirectUri.Scheme -ne 'https' -or -not $redirectUri.Host.EndsWith('.consent.azure-apim.net')) {
        throw "Existing connector '$($Definition.ConnectorName)' has an invalid redirect URL."
    }
    if (@($Application.web.redirectUris) -notcontains $redirectUrl) {
        throw "Existing connector '$($Definition.ConnectorName)' redirect is not registered on its Entra application."
    }
    $credentialDisplayName = "$($Definition.ConnectorName) Power Platform"
    $minimumExpiry = [DateTimeOffset]::UtcNow.AddDays(30)
    $matchingCredentials = @($Application.passwordCredentials | Where-Object { $_.displayName -eq $credentialDisplayName })
    if ($matchingCredentials.Count -ne 1 -or [DateTimeOffset]::Parse([string]$matchingCredentials[0].endDateTime) -le $minimumExpiry) {
        throw "Existing connector '$($Definition.ConnectorName)' must have exactly one matching credential valid for more than 30 days. Rotate by explicit delete and recreate."
    }
}

try {
    $resourceApplication = Invoke-ResourceGraph -Method GET -Path "applications/$($identity.resourceApi.objectId)?`$select=id,appId,displayName" -Body $null
    $resourcePrincipal = Invoke-ResourceGraph -Method GET -Path "servicePrincipals/$($identity.resourceApi.servicePrincipalId)?`$select=id,appId" -Body $null
    if ($resourceApplication.id -ne $identity.resourceApi.objectId -or $resourceApplication.appId -ne $identity.resourceApi.clientId -or
        $resourceApplication.displayName -ne $config.identity.apiDisplayName -or $resourcePrincipal.id -ne $identity.resourceApi.servicePrincipalId -or
        $resourcePrincipal.appId -ne $identity.resourceApi.clientId) {
        throw 'Resource API identity metadata does not match the live Fabric-tenant application and service principal.'
    }
    $powerHeaders = @{ Authorization = "Bearer $powerPlatformToken" }
    $adminUri = "https://api.powerapps.com/providers/Microsoft.PowerApps/scopes/admin/environments/$environmentId/apis"
    $existingResponse = Invoke-RestMethod -Uri "${adminUri}?api-version=2016-11-01" -Headers $powerHeaders
    if ($existingResponse.PSObject.Properties['nextLink'] -and $existingResponse.nextLink) {
        throw 'Power Platform connector pagination requires explicit review.'
    }
    $results = @()
    foreach ($definition in $definitions) {
        $identityConnector = @($identity.connectors | Where-Object { $_.kind -eq $definition.Kind })
        if ($identityConnector.Count -ne 1) {
            throw "Identity metadata is missing the '$($definition.Kind)' connector application."
        }
        $existing = @($existingResponse.value | Where-Object { $_.properties.displayName -eq $definition.ConnectorName })
        if ($existing.Count -gt 1) {
            throw "Multiple connectors are named '$($definition.ConnectorName)'."
        }
        $application = Invoke-ResourceGraph -Method GET -Path "applications/$($identityConnector[0].objectId)?`$select=id,appId,displayName,web,passwordCredentials" -Body $null
        $applicationPrincipal = Invoke-ResourceGraph -Method GET -Path "servicePrincipals/$($identityConnector[0].servicePrincipalId)?`$select=id,appId" -Body $null
        if ($application.appId -ne $identityConnector[0].clientId -or $application.displayName -ne $identityConnector[0].displayName -or
            $applicationPrincipal.id -ne $identityConnector[0].servicePrincipalId -or $applicationPrincipal.appId -ne $identityConnector[0].clientId) {
            throw "Identity metadata for '$($definition.ConnectorName)' does not match its live Entra application and service principal."
        }
        if ($existing.Count -eq 1) {
            $detailFilter = [uri]::EscapeDataString("environment eq '$environmentId'")
            $detailUri = "https://api.powerapps.com/providers/Microsoft.PowerApps/apis/$($existing[0].name)?api-version=2016-11-01&`$filter=$detailFilter"
            $connector = Invoke-RestMethod -Uri $detailUri -Headers $powerHeaders
            Assert-ExistingConnector -Connector $connector -Definition $definition -IdentityConnector $identityConnector[0] -Application $application
            $results += [pscustomobject]@{
                kind = $definition.Kind
                name = $connector.name
                displayName = $definition.ConnectorName
                environmentId = $environmentId
                clientId = $identityConnector[0].clientId
                redirectUrl = [string]$connector.properties.connectionParameters.token.oAuthSettings.redirectUrl
                existing = $true
            }
            continue
        }

        $credentialDisplayName = "$($definition.ConnectorName) Power Platform"
        $orphanCredentials = @($application.passwordCredentials | Where-Object { $_.displayName -eq $credentialDisplayName })
        $consentRedirects = @($application.web.redirectUris | Where-Object {
            $redirectCandidate = $null
            [uri]::TryCreate([string]$_, [System.UriKind]::Absolute, [ref]$redirectCandidate) -and $redirectCandidate.Host.EndsWith('.consent.azure-apim.net')
        })
        if ($orphanCredentials.Count -gt 0 -or $consentRedirects.Count -gt 0) {
            $credentialIds = @($orphanCredentials.keyId) -join ', '
            $redirectList = $consentRedirects -join ', '
            throw "The target connector '$($definition.ConnectorName)' is absent, but its Entra app already has connector-owned assets. Review ownership before manual cleanup. Credential IDs: [$credentialIds]. Consent redirects: [$redirectList]."
        }
        $rollbackRedirects = @($application.web.redirectUris)

        $password = $null
        $connector = $null
        $connectorCreated = $false
        $redirectRegistered = $false
        try {
            $password = Invoke-ResourceGraph -Method POST -Path "applications/$($application.id)/addPassword" -Body @{
                passwordCredential = @{
                    displayName = "$($definition.ConnectorName) Power Platform"
                    endDateTime = [DateTime]::UtcNow.AddMonths($CredentialLifetimeMonths).ToString('o')
                }
            }
            $body = @{
                properties = @{
                    displayName = $definition.ConnectorName
                    description = $definition.Description
                    iconBrandColor = [string]$config.powerPlatform.iconBrandColor
                    environment = @{ name = $environmentId }
                    backendService = @{ serviceUrl = "https://$($gatewayUri.Host)$($definition.BasePath)" }
                    openApiDefinition = $definition.Swagger
                    connectionParameters = @{
                        token = @{
                            type = 'oAuthSetting'
                            uiDefinition = $null
                            oAuthSettings = @{
                                identityProvider = 'aad'
                                clientId = $identityConnector[0].clientId
                                clientSecret = $password.secretText
                                scopes = @($scope)
                                redirectMode = 'GlobalPerConnector'
                                customParameters = @{
                                    LoginUri = @{ value = 'https://login.microsoftonline.com' }
                                    TenantId = @{ value = $resourceTenantId }
                                    ResourceUri = @{ value = "api://$($identity.resourceApi.clientId)" }
                                    EnableOnbehalfOfLogin = @{ value = $true }
                                }
                            }
                        }
                    }
                }
            } | ConvertTo-Json -Depth 40
            $createUri = "https://api.powerapps.com/providers/Microsoft.PowerApps/apis?api-version=2016-11-01&`$filter=environment eq '$environmentId'"
            $connector = Invoke-RestMethod -Method POST -Uri $createUri -Headers $powerHeaders -ContentType 'application/json' -Body $body
            if ([string]::IsNullOrWhiteSpace([string]$connector.name)) {
                throw "Connector '$($definition.ConnectorName)' creation returned no connector name."
            }
            $connectorCreated = $true
            $redirectSettings = $connector.properties.connectionParameters.token.oAuthSettings
            $redirectUrl = if ($redirectSettings.PSObject.Properties['redirectUrl']) { [string]$redirectSettings.redirectUrl } else { '' }
            $redirectUri = $null
            if (-not [uri]::TryCreate($redirectUrl, [System.UriKind]::Absolute, [ref]$redirectUri) -or $redirectUri.Scheme -ne 'https' -or -not $redirectUri.Host.EndsWith('.consent.azure-apim.net')) {
                throw "Connector '$($definition.ConnectorName)' returned an unexpected redirect URL."
            }
            $redirects = @(@($application.web.redirectUris) + $redirectUrl | Where-Object { $_ } | Select-Object -Unique)
            Invoke-ResourceGraph -Method PATCH -Path "applications/$($application.id)" -Body @{ web = @{ redirectUris = $redirects } } | Out-Null
            $redirectRegistered = $true
            $updatedApplication = Invoke-ResourceGraph -Method GET -Path "applications/$($application.id)?`$select=id,passwordCredentials" -Body $null
            $managedCredentials = @($updatedApplication.passwordCredentials | Where-Object { $_.displayName -eq $credentialDisplayName })
            if ($managedCredentials.Count -ne 1 -or $managedCredentials[0].keyId -ne $password.keyId) {
                throw "Connector '$($definition.ConnectorName)' does not have exactly one newly bound Entra credential."
            }
            $results += [pscustomobject]@{
                kind = $definition.Kind
                name = $connector.name
                displayName = $definition.ConnectorName
                environmentId = $environmentId
                clientId = $identityConnector[0].clientId
                redirectUrl = $redirectUrl
                existing = $false
            }
        }
        catch {
            $creationFailure = $_
            $cleanupFailures = @()
            if ($connectorCreated -and $connector -and $connector.name) {
                try {
                    Invoke-RestMethod -Method DELETE -Uri "$adminUri/$($connector.name)?api-version=2016-11-01" -Headers $powerHeaders | Out-Null
                }
                catch {
                    $cleanupFailures += "connector delete: $($_.Exception.Message)"
                }
            }
            if ($password -and $password.keyId) {
                try {
                    Invoke-ResourceGraph -Method POST -Path "applications/$($application.id)/removePassword" -Body @{ keyId = $password.keyId } | Out-Null
                }
                catch {
                    $cleanupFailures += "credential delete: $($_.Exception.Message)"
                }
            }
            if ($redirectRegistered) {
                try {
                    Invoke-ResourceGraph -Method PATCH -Path "applications/$($application.id)" -Body @{ web = @{ redirectUris = $rollbackRedirects } } | Out-Null
                }
                catch {
                    $cleanupFailures += "redirect restore: $($_.Exception.Message)"
                }
            }
            if ($cleanupFailures.Count -gt 0) {
                throw "Connector '$($definition.ConnectorName)' creation failed: $($creationFailure.Exception.Message). Cleanup also failed: $($cleanupFailures -join '; ')"
            }
            throw $creationFailure
        }
        finally {
            $body = $null
            if ($password -and $password.PSObject.Properties['secretText']) {
                $password.secretText = $null
            }
            $password = $null
        }
    }

    $metadataPath = Join-Path $resolvedOutputDirectory 'connectors.json'
    [ordered]@{ schemaVersion = 1; environmentId = $environmentId; connectors = $results } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $metadataPath -Encoding utf8
    return $results
}
finally {
    $powerPlatformToken = $null
    $resourceGraphToken = $null
    $powerHeaders = $null
    $password = $null
    $body = $null
}