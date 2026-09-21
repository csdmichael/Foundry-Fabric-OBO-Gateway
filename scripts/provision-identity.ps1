[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot '../config/deployment.json'),
    [string] $OutputPath = (Join-Path $PSScriptRoot '../.generated/identity.json'),
    [string] $KeyVaultName,
    [string] $KeyVaultAccessIpAddress,
    [string] $OboClientSecretName = 'obo-client-secret',
    [int] $CredentialLifetimeMonths = 6,
    [string] $ApimPrincipalId,
    [string[]] $AllowedUserObjectIds,
    [string] $ResourceApiObjectId,
    [string] $LakehouseConnectorObjectId,
    [string] $DataAgentConnectorObjectId,
    [string] $DashboardClientObjectId,
    [string] $FoundryLakehouseOAuthClientObjectId,
    [string] $FoundryDataAgentOAuthClientObjectId,
    [string] $BrokerApiObjectId,
    [switch] $DeploymentReady,
    [switch] $InviteConfiguredAdmin,
    [switch] $RemoveStaleGrants,
    [switch] $RotateOboCredential
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'config.ps1')

$config = Get-FabricDeploymentConfig -Path $ConfigPath
$configFingerprint = Get-FabricConfigFingerprint -Path $ConfigPath
$resourceTenantId = [string]$config.identity.resourceTenantId
$callerTenantId = [string]$config.identity.callerTenantId
$resourceGraphToken = Get-FabricAzAccessToken -TenantId $resourceTenantId -Resource 'https://graph.microsoft.com/' -SubscriptionId ([string]$config.azure.subscriptionId)
$callerGraphToken = Get-FabricAzAccessToken -TenantId $callerTenantId -Resource 'https://graph.microsoft.com/' -SubscriptionId ([string]$config.apim.subscriptionId)
$credential = $null
$credentialStored = $false
$credentialApplicationId = $null
$managementToken = $null

$resolvedOutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
if (Test-Path -LiteralPath $resolvedOutputPath -PathType Leaf) {
    $existingMetadata = Get-Content -LiteralPath $resolvedOutputPath -Raw | ConvertFrom-Json
    if ($existingMetadata.schemaVersion -ne 1 -or $existingMetadata.configFingerprint -ne $configFingerprint -or
        $existingMetadata.resourceTenantId -ne $resourceTenantId -or $existingMetadata.callerTenantId -ne $callerTenantId) {
        throw "Existing identity metadata does not match the current configuration: $resolvedOutputPath"
    }
    if ([string]::IsNullOrWhiteSpace($ResourceApiObjectId)) { $ResourceApiObjectId = [string]$existingMetadata.resourceApi.objectId }
    if ([string]::IsNullOrWhiteSpace($BrokerApiObjectId)) { $BrokerApiObjectId = [string]$existingMetadata.brokerApi.objectId }
    $metadataLakehouseConnector = @($existingMetadata.connectors | Where-Object { $_.kind -eq 'lakehouse' })
    $metadataDataAgentConnector = @($existingMetadata.connectors | Where-Object { $_.kind -eq 'dataAgent' })
    if ($metadataLakehouseConnector.Count -ne 1 -or $metadataDataAgentConnector.Count -ne 1) {
        throw 'Existing identity metadata does not contain exactly one connector of each required kind.'
    }
    if ([string]::IsNullOrWhiteSpace($LakehouseConnectorObjectId)) { $LakehouseConnectorObjectId = [string]$metadataLakehouseConnector[0].objectId }
    if ([string]::IsNullOrWhiteSpace($DataAgentConnectorObjectId)) { $DataAgentConnectorObjectId = [string]$metadataDataAgentConnector[0].objectId }
    if ([string]::IsNullOrWhiteSpace($DashboardClientObjectId) -and $existingMetadata.PSObject.Properties['dashboardClient']) { $DashboardClientObjectId = [string]$existingMetadata.dashboardClient.objectId }
    if ($existingMetadata.PSObject.Properties['foundryOAuthClients']) {
        $metadataLakehouseOAuth = @($existingMetadata.foundryOAuthClients | Where-Object { $_.kind -eq 'lakehouse' })
        $metadataDataAgentOAuth = @($existingMetadata.foundryOAuthClients | Where-Object { $_.kind -eq 'dataAgent' })
        if ($metadataLakehouseOAuth.Count -ne 1 -or $metadataDataAgentOAuth.Count -ne 1) {
            throw 'Existing identity metadata does not contain exactly one Foundry OAuth client of each required kind.'
        }
        if ([string]::IsNullOrWhiteSpace($FoundryLakehouseOAuthClientObjectId)) { $FoundryLakehouseOAuthClientObjectId = [string]$metadataLakehouseOAuth[0].objectId }
        if ([string]::IsNullOrWhiteSpace($FoundryDataAgentOAuthClientObjectId)) { $FoundryDataAgentOAuthClientObjectId = [string]$metadataDataAgentOAuth[0].objectId }
    }
}

function Invoke-Graph {
    param(
        [Parameter(Mandatory = $true)] [string] $Token,
        [Parameter(Mandatory = $true)] [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')] [string] $Method,
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

function Ensure-Application {
    param(
        [Parameter(Mandatory = $true)] [string] $Token,
        [Parameter(Mandatory = $true)] [string] $DisplayName,
        [string] $ExpectedObjectId
    )

    $escapedName = $DisplayName.Replace("'", "''")
    $filter = [uri]::EscapeDataString("displayName eq '$escapedName'")
    $applications = @((Invoke-Graph -Token $Token -Method GET -Path "applications?`$filter=$filter&`$select=id,appId,displayName,api,appRoles,requiredResourceAccess,web,spa,passwordCredentials" -Body $null).value)
    if (-not [string]::IsNullOrWhiteSpace($ExpectedObjectId)) {
        $ExpectedObjectId = Assert-FabricGuid -Value $ExpectedObjectId -Name "$DisplayName application object ID"
        $expectedApplication = Invoke-Graph -Token $Token -Method GET -Path "applications/${ExpectedObjectId}?`$select=id,appId,displayName,api,appRoles,requiredResourceAccess,web,spa,passwordCredentials" -Body $null
        if ($expectedApplication.displayName -ne $DisplayName -or @($applications | Where-Object { $_.id -ne $ExpectedObjectId }).Count -gt 0) {
            throw "Application object '$ExpectedObjectId' does not uniquely match '$DisplayName'."
        }
        return $expectedApplication
    }
    if ($applications.Count -gt 0) {
        throw "Existing app registration '$DisplayName' requires explicit adoption by object ID. Candidate IDs: $(@($applications.id) -join ', ')."
    }
    return Invoke-Graph -Token $Token -Method POST -Path 'applications' -Body @{
        displayName = $DisplayName
        signInAudience = 'AzureADMyOrg'
        isFallbackPublicClient = $false
    }
}

function Get-Application {
    param([string] $Token, [string] $ObjectId)
    return Invoke-Graph -Token $Token -Method GET -Path "applications/${ObjectId}?`$select=id,appId,displayName,api,appRoles,requiredResourceAccess,web,spa,passwordCredentials" -Body $null
}

function Ensure-ServicePrincipal {
    param([string] $Token, [string] $AppId)
    $filter = [uri]::EscapeDataString("appId eq '$AppId'")
    $principals = @((Invoke-Graph -Token $Token -Method GET -Path "servicePrincipals?`$filter=$filter&`$select=id,appId,displayName,appRoles,oauth2PermissionScopes" -Body $null).value)
    if ($principals.Count -gt 1) {
        throw "Multiple service principals use application ID '$AppId'."
    }
    if ($principals.Count -eq 1) {
        return $principals[0]
    }
    return Invoke-Graph -Token $Token -Method POST -Path 'servicePrincipals' -Body @{ appId = $AppId }
}

function Ensure-PrincipalGrant {
    param(
        [string] $Token,
        [string] $ClientPrincipalId,
        [string] $ResourcePrincipalId,
        [string] $UserObjectId,
        [string[]] $Scopes
    )

    $filter = [uri]::EscapeDataString("clientId eq '$ClientPrincipalId' and resourceId eq '$ResourcePrincipalId'")
    $allGrants = @((Invoke-Graph -Token $Token -Method GET -Path "oauth2PermissionGrants?`$filter=$filter" -Body $null).value)
    if ($allGrants | Where-Object { $_.consentType -eq 'AllPrincipals' }) {
        throw 'Tenant-wide OAuth consent exists where principal-scoped consent is required.'
    }
    $grants = @($allGrants | Where-Object { $_.consentType -eq 'Principal' -and $_.principalId -eq $UserObjectId })
    if ($grants.Count -gt 1) {
        throw 'Duplicate principal-scoped OAuth grants require explicit review.'
    }
    $scopeText = (@($Scopes | Where-Object { $_ } | Select-Object -Unique) -join ' ')
    if ($grants.Count -eq 1) {
        Invoke-Graph -Token $Token -Method PATCH -Path "oauth2PermissionGrants/$($grants[0].id)" -Body @{ scope = $scopeText } | Out-Null
        return
    }
    Invoke-Graph -Token $Token -Method POST -Path 'oauth2PermissionGrants' -Body @{
        clientId = $ClientPrincipalId
        resourceId = $ResourcePrincipalId
        consentType = 'Principal'
        principalId = $UserObjectId
        scope = $scopeText
    } | Out-Null
}

function Assert-PrincipalGrantSet {
    param(
        [string] $Token,
        [string] $ClientPrincipalId,
        [string] $ResourcePrincipalId,
        [string[]] $ExpectedUserObjectIds,
        [string[]] $ExpectedScopes,
        [switch] $AllowExpectedScopeDrift
    )

    $filter = [uri]::EscapeDataString("clientId eq '$ClientPrincipalId' and resourceId eq '$ResourcePrincipalId'")
    $grants = @((Invoke-Graph -Token $Token -Method GET -Path "oauth2PermissionGrants?`$filter=$filter" -Body $null).value)
    if ($grants | Where-Object { $_.consentType -eq 'AllPrincipals' }) {
        throw 'Tenant-wide OAuth consent exists where principal-scoped consent is required.'
    }
    $unexpected = @($grants | Where-Object { $_.consentType -ne 'Principal' -or $ExpectedUserObjectIds -notcontains $_.principalId })
    if ($unexpected.Count -gt 0) {
        if (-not $RemoveStaleGrants) {
            throw "Unexpected or stale principal-scoped OAuth grants require explicit removal before deployment: $(@($unexpected.id) -join ', '). Rerun with -RemoveStaleGrants after review."
        }
        foreach ($grant in $unexpected) {
            Invoke-Graph -Token $Token -Method DELETE -Path "oauth2PermissionGrants/$($grant.id)" -Body $null | Out-Null
        }
        $grants = @($grants | Where-Object { $unexpected.id -notcontains $_.id })
    }
    if (-not $AllowExpectedScopeDrift) {
        $expectedScopeText = @($ExpectedScopes | Sort-Object -Unique) -join ' '
        foreach ($grant in $grants) {
            $actualScopeText = @($grant.scope -split ' ' | Where-Object { $_ } | Sort-Object -Unique) -join ' '
            if ($actualScopeText -ne $expectedScopeText) {
                throw "OAuth grant '$($grant.id)' does not contain the exact approved scope set."
            }
        }
    }
}

function Ensure-AppRoleAssignment {
    param(
        [string] $Token,
        [string] $ClientPrincipalId,
        [string] $ResourcePrincipalId,
        [string] $AppRoleId
    )

    $assignments = @((Invoke-Graph -Token $Token -Method GET -Path "servicePrincipals/$ClientPrincipalId/appRoleAssignments" -Body $null).value)
    if ($assignments | Where-Object { $_.resourceId -eq $ResourcePrincipalId -and $_.appRoleId -eq $AppRoleId }) {
        return
    }
    Invoke-Graph -Token $Token -Method POST -Path "servicePrincipals/$ClientPrincipalId/appRoleAssignments" -Body @{
        principalId = $ClientPrincipalId
        resourceId = $ResourcePrincipalId
        appRoleId = $AppRoleId
    } | Out-Null
}

function Invoke-TransientRestMethod {
    param(
        [Parameter(Mandatory = $true)] [hashtable] $Arguments,
        [int] $MaximumAttempts = 12
    )
    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try {
            return Invoke-RestMethod @Arguments
        }
        catch {
            $statusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            $errorText = "$($_.ErrorDetails.Message) $($_.Exception)"
            $transient = $statusCode -in 408, 429, 500, 502, 503, 504 -or
                $errorText -match 'No such host|Name or service not known|temporarily unavailable|connection.*(?:closed|reset|timed out)'
            if (-not $transient -or $attempt -eq $MaximumAttempts) { throw }
            Start-Sleep -Seconds 5
        }
    }
}

try {
    if ($PSBoundParameters.ContainsKey('AllowedUserObjectIds')) {
        $effectiveAllowedUsers = Assert-FabricGuidList -Values @($AllowedUserObjectIds) -Name 'AllowedUserObjectIds' -AllowEmpty
    }
    else {
        $effectiveAllowedUsers = Assert-FabricGuidList -Values @($config.identity.allowedUserObjectIds) -Name 'identity.allowedUserObjectIds' -AllowEmpty
    }
    if ($effectiveAllowedUsers.Count -eq 0) {
        $configuredAdmin = [string]$config.identity.allowedUserPrincipalName
        $escapedAdmin = $configuredAdmin.Replace("'", "''")
        $filter = [uri]::EscapeDataString("mail eq '$escapedAdmin' or userPrincipalName eq '$escapedAdmin'")
        $users = @((Invoke-Graph -Token $resourceGraphToken -Method GET -Path "users?`$filter=$filter&`$select=id,displayName,userPrincipalName,mail,userType" -Body $null).value)
        if ($users.Count -gt 1) {
            throw "Multiple Fabric-tenant users match '$configuredAdmin'."
        }
        if ($users.Count -eq 1) {
            $effectiveAllowedUsers = @(Assert-FabricGuid -Value $users[0].id -Name 'configured administrator object ID')
        }
        elseif ($InviteConfiguredAdmin) {
            $invitation = Invoke-Graph -Token $resourceGraphToken -Method POST -Path 'invitations' -Body @{
                invitedUserEmailAddress = $configuredAdmin
                inviteRedirectUrl = 'https://myapplications.microsoft.com/'
                sendInvitationMessage = $true
            }
            $effectiveAllowedUsers = @(Assert-FabricGuid -Value $invitation.invitedUser.id -Name 'invited administrator object ID')
            $invitation = $null
            Write-Warning "Invited '$configuredAdmin' to the Fabric resource tenant. The user must redeem the invitation before live delegated tests."
        }
    }
    if ($DeploymentReady -and $effectiveAllowedUsers.Count -eq 0) {
        throw 'At least one Fabric-tenant user object ID is required for deployment-ready identity provisioning.'
    }

    $resourceApi = Ensure-Application -Token $resourceGraphToken -DisplayName ([string]$config.identity.apiDisplayName) -ExpectedObjectId $ResourceApiObjectId
    $resourceApi = Get-Application -Token $resourceGraphToken -ObjectId $resourceApi.id
    $delegatedScope = @($resourceApi.api.oauth2PermissionScopes | Where-Object { $_.value -eq $config.identity.delegatedScope }) | Select-Object -First 1
    if (-not $delegatedScope) {
        $delegatedScope = [pscustomobject]@{
            id = [guid]::NewGuid().ToString()
            value = [string]$config.identity.delegatedScope
            type = 'Admin'
            isEnabled = $true
            adminConsentDisplayName = 'Access Microsoft Fabric as the signed-in user'
            adminConsentDescription = 'Allows the broker to exchange the signed-in user token for permission-trimmed Microsoft Fabric access.'
            userConsentDisplayName = 'Access Microsoft Fabric as you'
            userConsentDescription = 'Allows this connector to access Microsoft Fabric through the OBO broker under your permissions.'
        }
    }
    $resourceApiScopes = @($resourceApi.api.oauth2PermissionScopes | Where-Object { $_.value -ne $config.identity.delegatedScope }) + $delegatedScope

    $powerBiFilter = [uri]::EscapeDataString("servicePrincipalNames/any(name:name eq 'https://api.fabric.microsoft.com')")
    $powerBiPrincipals = @((Invoke-Graph -Token $resourceGraphToken -Method GET -Path "servicePrincipals?`$filter=$powerBiFilter&`$select=id,appId,displayName,oauth2PermissionScopes" -Body $null).value)
    if ($powerBiPrincipals.Count -ne 1) {
        throw 'Unable to resolve the Microsoft Fabric enterprise application unambiguously.'
    }
    $powerBiPrincipal = $powerBiPrincipals[0]
    $downstreamPermissions = @($config.identity.downstreamDelegatedPermissions)
    $downstreamScopeDefinitions = @($powerBiPrincipal.oauth2PermissionScopes | Where-Object { $_.isEnabled -and $downstreamPermissions -contains $_.value })
    if ($downstreamScopeDefinitions.Count -ne $downstreamPermissions.Count) {
        $resolvedNames = @($downstreamScopeDefinitions.value)
        $missingNames = @($downstreamPermissions | Where-Object { $resolvedNames -notcontains $_ })
        throw "Microsoft Fabric delegated permissions were not found: $($missingNames -join ', ')."
    }
    $requiredResourceAccess = @($resourceApi.requiredResourceAccess | Where-Object { $_.resourceAppId -ne $powerBiPrincipal.appId })
    $requiredResourceAccess += @{
        resourceAppId = $powerBiPrincipal.appId
        resourceAccess = @($downstreamScopeDefinitions | ForEach-Object { @{ id = $_.id; type = 'Scope' } })
    }
    Invoke-Graph -Token $resourceGraphToken -Method PATCH -Path "applications/$($resourceApi.id)" -Body @{
        identifierUris = @("api://$($resourceApi.appId)")
        api = @{ requestedAccessTokenVersion = 2; oauth2PermissionScopes = $resourceApiScopes }
        optionalClaims = @{ accessToken = @(@{ name = 'idtyp'; essential = $false; additionalProperties = @() }) }
        requiredResourceAccess = $requiredResourceAccess
        isFallbackPublicClient = $false
    } | Out-Null
    $resourceApi = Get-Application -Token $resourceGraphToken -ObjectId $resourceApi.id
    $resourceApiPrincipal = Ensure-ServicePrincipal -Token $resourceGraphToken -AppId $resourceApi.appId

    $connectorDefinitions = @(
        [pscustomobject]@{ Kind = 'lakehouse'; DisplayName = [string]$config.identity.lakehouseConnectorDisplayName; ObjectId = $LakehouseConnectorObjectId },
        [pscustomobject]@{ Kind = 'dataAgent'; DisplayName = [string]$config.identity.dataAgentConnectorDisplayName; ObjectId = $DataAgentConnectorObjectId }
    )
    $connectors = @()
    foreach ($definition in $connectorDefinitions) {
        $connector = Ensure-Application -Token $resourceGraphToken -DisplayName $definition.DisplayName -ExpectedObjectId $definition.ObjectId
        $connector = Get-Application -Token $resourceGraphToken -ObjectId $connector.id
        $connectorAccess = @($connector.requiredResourceAccess | Where-Object { $_.resourceAppId -ne $resourceApi.appId })
        $connectorAccess += @{
            resourceAppId = $resourceApi.appId
            resourceAccess = @(@{ id = $delegatedScope.id; type = 'Scope' })
        }
        Invoke-Graph -Token $resourceGraphToken -Method PATCH -Path "applications/$($connector.id)" -Body @{
            requiredResourceAccess = $connectorAccess
            isFallbackPublicClient = $false
        } | Out-Null
        $connector = Get-Application -Token $resourceGraphToken -ObjectId $connector.id
        $connectorPrincipal = Ensure-ServicePrincipal -Token $resourceGraphToken -AppId $connector.appId
        Assert-PrincipalGrantSet -Token $resourceGraphToken -ClientPrincipalId $connectorPrincipal.id -ResourcePrincipalId $resourceApiPrincipal.id -ExpectedUserObjectIds $effectiveAllowedUsers -ExpectedScopes @([string]$config.identity.delegatedScope) -AllowExpectedScopeDrift
        foreach ($userObjectId in $effectiveAllowedUsers) {
            Ensure-PrincipalGrant -Token $resourceGraphToken -ClientPrincipalId $connectorPrincipal.id -ResourcePrincipalId $resourceApiPrincipal.id -UserObjectId $userObjectId -Scopes @([string]$config.identity.delegatedScope)
        }
        Assert-PrincipalGrantSet -Token $resourceGraphToken -ClientPrincipalId $connectorPrincipal.id -ResourcePrincipalId $resourceApiPrincipal.id -ExpectedUserObjectIds $effectiveAllowedUsers -ExpectedScopes @([string]$config.identity.delegatedScope)
        $connectors += [pscustomobject]@{
            kind = $definition.Kind
            displayName = $definition.DisplayName
            clientId = $connector.appId
            objectId = $connector.id
            servicePrincipalId = $connectorPrincipal.id
        }
    }

    $foundryOAuthDefinitions = @(
        [pscustomobject]@{ Kind = 'lakehouse'; DisplayName = [string]$config.foundry.mcpConnections.lakehouse.appDisplayName; ObjectId = $FoundryLakehouseOAuthClientObjectId },
        [pscustomobject]@{ Kind = 'dataAgent'; DisplayName = [string]$config.foundry.mcpConnections.dataAgent.appDisplayName; ObjectId = $FoundryDataAgentOAuthClientObjectId }
    )
    $foundryOAuthClients = @()
    foreach ($definition in $foundryOAuthDefinitions) {
        $oauthClient = Ensure-Application -Token $resourceGraphToken -DisplayName $definition.DisplayName -ExpectedObjectId $definition.ObjectId
        $oauthClient = Get-Application -Token $resourceGraphToken -ObjectId $oauthClient.id
        $oauthClientAccess = @($oauthClient.requiredResourceAccess | Where-Object { $_.resourceAppId -ne $resourceApi.appId })
        $oauthClientAccess += @{
            resourceAppId = $resourceApi.appId
            resourceAccess = @(@{ id = $delegatedScope.id; type = 'Scope' })
        }
        Invoke-Graph -Token $resourceGraphToken -Method PATCH -Path "applications/$($oauthClient.id)" -Body @{
            requiredResourceAccess = $oauthClientAccess
            isFallbackPublicClient = $false
        } | Out-Null
        $oauthClient = Get-Application -Token $resourceGraphToken -ObjectId $oauthClient.id
        $oauthClientPrincipal = Ensure-ServicePrincipal -Token $resourceGraphToken -AppId $oauthClient.appId
        Assert-PrincipalGrantSet -Token $resourceGraphToken -ClientPrincipalId $oauthClientPrincipal.id -ResourcePrincipalId $resourceApiPrincipal.id -ExpectedUserObjectIds $effectiveAllowedUsers -ExpectedScopes @([string]$config.identity.delegatedScope) -AllowExpectedScopeDrift
        foreach ($userObjectId in $effectiveAllowedUsers) {
            Ensure-PrincipalGrant -Token $resourceGraphToken -ClientPrincipalId $oauthClientPrincipal.id -ResourcePrincipalId $resourceApiPrincipal.id -UserObjectId $userObjectId -Scopes @([string]$config.identity.delegatedScope)
        }
        Assert-PrincipalGrantSet -Token $resourceGraphToken -ClientPrincipalId $oauthClientPrincipal.id -ResourcePrincipalId $resourceApiPrincipal.id -ExpectedUserObjectIds $effectiveAllowedUsers -ExpectedScopes @([string]$config.identity.delegatedScope)
        $foundryOAuthClients += [pscustomobject]@{
            kind = $definition.Kind
            displayName = $definition.DisplayName
            clientId = $oauthClient.appId
            objectId = $oauthClient.id
            servicePrincipalId = $oauthClientPrincipal.id
        }
    }

    $dashboardClient = Ensure-Application -Token $resourceGraphToken -DisplayName ([string]$config.identity.dashboardClientDisplayName) -ExpectedObjectId $DashboardClientObjectId
    $dashboardClient = Get-Application -Token $resourceGraphToken -ObjectId $dashboardClient.id
    $dashboardAccess = @($dashboardClient.requiredResourceAccess | Where-Object { $_.resourceAppId -ne $resourceApi.appId })
    $dashboardAccess += @{
        resourceAppId = $resourceApi.appId
        resourceAccess = @(@{ id = $delegatedScope.id; type = 'Scope' })
    }
    Invoke-Graph -Token $resourceGraphToken -Method PATCH -Path "applications/$($dashboardClient.id)" -Body @{
        requiredResourceAccess = $dashboardAccess
        spa = @{ redirectUris = @($config.ui.redirectUris) }
        isFallbackPublicClient = $false
    } | Out-Null
    $dashboardClient = Get-Application -Token $resourceGraphToken -ObjectId $dashboardClient.id
    $dashboardPrincipal = Ensure-ServicePrincipal -Token $resourceGraphToken -AppId $dashboardClient.appId
    Assert-PrincipalGrantSet -Token $resourceGraphToken -ClientPrincipalId $dashboardPrincipal.id -ResourcePrincipalId $resourceApiPrincipal.id -ExpectedUserObjectIds $effectiveAllowedUsers -ExpectedScopes @([string]$config.identity.delegatedScope) -AllowExpectedScopeDrift
    foreach ($userObjectId in $effectiveAllowedUsers) {
        Ensure-PrincipalGrant -Token $resourceGraphToken -ClientPrincipalId $dashboardPrincipal.id -ResourcePrincipalId $resourceApiPrincipal.id -UserObjectId $userObjectId -Scopes @([string]$config.identity.delegatedScope)
    }
    Assert-PrincipalGrantSet -Token $resourceGraphToken -ClientPrincipalId $dashboardPrincipal.id -ResourcePrincipalId $resourceApiPrincipal.id -ExpectedUserObjectIds $effectiveAllowedUsers -ExpectedScopes @([string]$config.identity.delegatedScope)

    Assert-PrincipalGrantSet -Token $resourceGraphToken -ClientPrincipalId $resourceApiPrincipal.id -ResourcePrincipalId $powerBiPrincipal.id -ExpectedUserObjectIds $effectiveAllowedUsers -ExpectedScopes $downstreamPermissions -AllowExpectedScopeDrift
    foreach ($userObjectId in $effectiveAllowedUsers) {
        Ensure-PrincipalGrant -Token $resourceGraphToken -ClientPrincipalId $resourceApiPrincipal.id -ResourcePrincipalId $powerBiPrincipal.id -UserObjectId $userObjectId -Scopes $downstreamPermissions
    }
    Assert-PrincipalGrantSet -Token $resourceGraphToken -ClientPrincipalId $resourceApiPrincipal.id -ResourcePrincipalId $powerBiPrincipal.id -ExpectedUserObjectIds $effectiveAllowedUsers -ExpectedScopes $downstreamPermissions

    $brokerApi = Ensure-Application -Token $callerGraphToken -DisplayName ([string]$config.identity.brokerApiDisplayName) -ExpectedObjectId $BrokerApiObjectId
    $brokerApi = Get-Application -Token $callerGraphToken -ObjectId $brokerApi.id
    $brokerRole = @($brokerApi.appRoles | Where-Object { $_.value -eq $config.identity.brokerApplicationRole }) | Select-Object -First 1
    if (-not $brokerRole) {
        $brokerRole = [pscustomobject]@{
            id = [guid]::NewGuid().ToString()
            value = [string]$config.identity.brokerApplicationRole
            displayName = 'Invoke the private Fabric OBO broker'
            description = 'Allows the assigned APIM managed identity to invoke the private Fabric OBO broker.'
            allowedMemberTypes = @('Application')
            isEnabled = $true
        }
    }
    $brokerRoles = @($brokerApi.appRoles | Where-Object { $_.value -ne $config.identity.brokerApplicationRole }) + $brokerRole
    Invoke-Graph -Token $callerGraphToken -Method PATCH -Path "applications/$($brokerApi.id)" -Body @{
        identifierUris = @("api://$($brokerApi.appId)")
        api = @{ requestedAccessTokenVersion = 2; oauth2PermissionScopes = @($brokerApi.api.oauth2PermissionScopes | Where-Object { $_ }) }
        appRoles = $brokerRoles
        optionalClaims = @{ accessToken = @(@{ name = 'idtyp'; essential = $false; additionalProperties = @() }) }
    } | Out-Null
    $brokerApi = Get-Application -Token $callerGraphToken -ObjectId $brokerApi.id
    $brokerApiPrincipal = Ensure-ServicePrincipal -Token $callerGraphToken -AppId $brokerApi.appId

    if ([string]::IsNullOrWhiteSpace($ApimPrincipalId)) {
        Assert-FabricAzureContext -SubscriptionId ([string]$config.apim.subscriptionId) -TenantId $callerTenantId | Out-Null
        $ApimPrincipalId = az apim show --subscription $config.apim.subscriptionId --resource-group $config.apim.resourceGroup --name $config.apim.serviceName --query identity.principalId -o tsv
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($ApimPrincipalId)) {
            throw 'Unable to resolve the APIM system-assigned managed identity.'
        }
    }
    $ApimPrincipalId = Assert-FabricGuid -Value $ApimPrincipalId -Name 'ApimPrincipalId'
    $apimPrincipal = Invoke-Graph -Token $callerGraphToken -Method GET -Path "servicePrincipals/${ApimPrincipalId}?`$select=id,displayName" -Body $null
    Ensure-AppRoleAssignment -Token $callerGraphToken -ClientPrincipalId $apimPrincipal.id -ResourcePrincipalId $brokerApiPrincipal.id -AppRoleId $brokerRole.id

    if (-not [string]::IsNullOrWhiteSpace($KeyVaultName)) {
        $secretArmUri = "https://management.azure.com/subscriptions/$($config.azure.subscriptionId)/resourceGroups/$($config.azure.resourceGroup)/providers/Microsoft.KeyVault/vaults/${KeyVaultName}/secrets/${OboClientSecretName}?api-version=2025-05-01"
        $managementToken = Get-FabricAzAccessToken -TenantId $resourceTenantId -Resource 'https://management.azure.com/' -SubscriptionId ([string]$config.azure.subscriptionId)
        $managementHeaders = @{ Authorization = "Bearer $managementToken" }
        $secretMetadata = $null
        try {
            $secretMetadata = Invoke-TransientRestMethod -Arguments @{
                Method = 'GET'
                Uri = $secretArmUri
                Headers = $managementHeaders
            }
        }
        catch {
            $statusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            if ($statusCode -ne 404) { throw }
        }
        $resourceApi = Get-Application -Token $resourceGraphToken -ObjectId $resourceApi.id
        $credentialDisplayName = 'Fabric OBO broker Key Vault credential'
        $managedCredentials = @($resourceApi.passwordCredentials | Where-Object { $_.displayName -eq $credentialDisplayName })
        $minimumExpiry = [DateTimeOffset]::UtcNow.AddDays(30)
        $secretAttributes = if ($secretMetadata -and $secretMetadata.properties.PSObject.Properties['attributes']) { $secretMetadata.properties.attributes } else { $null }
        $secretExpires = if ($secretAttributes -and $secretAttributes.PSObject.Properties['exp']) { [DateTimeOffset]::FromUnixTimeSeconds([long]$secretAttributes.exp) } else { [DateTimeOffset]::MinValue }
        $secretTags = if ($secretMetadata -and $secretMetadata.PSObject.Properties['tags']) { $secretMetadata.tags } else { $null }
        $secretApplicationObjectId = if ($secretTags -and $secretTags.PSObject.Properties['applicationObjectId']) { [string]$secretTags.applicationObjectId } else { '' }
        $secretApplicationClientId = if ($secretTags -and $secretTags.PSObject.Properties['applicationClientId']) { [string]$secretTags.applicationClientId } else { '' }
        $secretCredentialKeyId = if ($secretTags -and $secretTags.PSObject.Properties['credentialKeyId']) { [string]$secretTags.credentialKeyId } else { '' }
        $activeCredentials = @($managedCredentials | Where-Object { $_.keyId -eq $secretCredentialKeyId -and [DateTimeOffset]::Parse([string]$_.endDateTime) -gt $minimumExpiry })
        $needsCredential = $RotateOboCredential -or -not $secretMetadata -or $secretExpires -le $minimumExpiry -or
            $secretApplicationObjectId -ne $resourceApi.id -or $secretApplicationClientId -ne $resourceApi.appId -or $activeCredentials.Count -ne 1
        if ($needsCredential) {
            $credentialExpiry = [DateTimeOffset]::UtcNow.AddMonths($CredentialLifetimeMonths)
            $oldCredentialIds = @($managedCredentials | ForEach-Object { $_.keyId })
            $credential = Invoke-Graph -Token $resourceGraphToken -Method POST -Path "applications/$($resourceApi.id)/addPassword" -Body @{
                passwordCredential = @{
                    displayName = $credentialDisplayName
                    endDateTime = $credentialExpiry.ToString('o')
                }
            }
            $newCredentialKeyId = [string]$credential.keyId
            $credentialApplicationId = $resourceApi.id
            try {
                $secretBody = @{
                    properties = @{
                        value = $credential.secretText
                        attributes = @{
                            enabled = $true
                            exp = $credentialExpiry.ToUnixTimeSeconds()
                        }
                    }
                    tags = @{
                        purpose = 'fabric-obo-broker'
                        applicationObjectId = $resourceApi.id
                        applicationClientId = $resourceApi.appId
                        credentialKeyId = [string]$credential.keyId
                    }
                } | ConvertTo-Json -Depth 5
                Invoke-TransientRestMethod -Arguments @{
                    Method = 'PUT'
                    Uri = $secretArmUri
                    Headers = $managementHeaders
                    ContentType = 'application/json'
                    Body = $secretBody
                } | Out-Null
                $credentialStored = $true
            }
            finally {
                $secretBody = $null
            }
            if (-not $credentialStored) {
                throw 'Unable to store the OBO credential in Key Vault.'
            }
            foreach ($oldCredentialId in $oldCredentialIds) {
                if ($oldCredentialId -and $oldCredentialId -ne $credential.keyId) {
                    Invoke-Graph -Token $resourceGraphToken -Method POST -Path "applications/$($resourceApi.id)/removePassword" -Body @{ keyId = $oldCredentialId } | Out-Null
                }
            }
            $credential = $null
            $secretCredentialKeyId = $newCredentialKeyId
        }
        else {
            $secretCredentialKeyId = [string]$activeCredentials[0].keyId
        }
        $resourceApi = Get-Application -Token $resourceGraphToken -ObjectId $resourceApi.id
        $managedCredentials = @($resourceApi.passwordCredentials | Where-Object { $_.displayName -eq $credentialDisplayName })
        foreach ($orphanCredential in @($managedCredentials | Where-Object { $_.keyId -ne $secretCredentialKeyId })) {
            Invoke-Graph -Token $resourceGraphToken -Method POST -Path "applications/$($resourceApi.id)/removePassword" -Body @{ keyId = $orphanCredential.keyId } | Out-Null
        }
        $resourceApi = Get-Application -Token $resourceGraphToken -ObjectId $resourceApi.id
        $managedCredentials = @($resourceApi.passwordCredentials | Where-Object { $_.displayName -eq $credentialDisplayName })
        if ($managedCredentials.Count -ne 1 -or $managedCredentials[0].keyId -ne $secretCredentialKeyId) {
            throw 'The OBO resource application does not have exactly one Key Vault-bound managed credential.'
        }
        $managementToken = $null
    }

    $metadata = [ordered]@{
        schemaVersion = 1
        configFingerprint = $configFingerprint
        resourceTenantId = $resourceTenantId
        callerTenantId = $callerTenantId
        resourceApi = [ordered]@{
            displayName = [string]$config.identity.apiDisplayName
            clientId = $resourceApi.appId
            objectId = $resourceApi.id
            servicePrincipalId = $resourceApiPrincipal.id
            delegatedScope = [string]$config.identity.delegatedScope
            delegatedScopeId = $delegatedScope.id
            downstreamPermissions = $downstreamPermissions
        }
        brokerApi = [ordered]@{
            displayName = [string]$config.identity.brokerApiDisplayName
            clientId = $brokerApi.appId
            objectId = $brokerApi.id
            servicePrincipalId = $brokerApiPrincipal.id
            appRole = [string]$config.identity.brokerApplicationRole
            appRoleId = $brokerRole.id
        }
        apimPrincipalId = $ApimPrincipalId
        connectors = $connectors
        foundryOAuthClients = $foundryOAuthClients
        dashboardClient = [ordered]@{
            displayName = [string]$config.identity.dashboardClientDisplayName
            clientId = $dashboardClient.appId
            objectId = $dashboardClient.id
            servicePrincipalId = $dashboardPrincipal.id
            redirectUris = @($config.ui.redirectUris)
        }
        allowedUserObjectIds = $effectiveAllowedUsers
        keyVaultName = $KeyVaultName
        oboClientSecretName = $OboClientSecretName
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $resolvedOutputPath) -Force | Out-Null
    $metadata | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $resolvedOutputPath -Encoding utf8
    [pscustomobject]@{
        OutputPath = $resolvedOutputPath
        ResourceApiClientId = $resourceApi.appId
        BrokerAudience = $brokerApi.appId
        ConnectorClientIds = @($connectors.clientId)
        FoundryOAuthClientIds = @($foundryOAuthClients.clientId)
        DashboardClientId = $dashboardClient.appId
        AllowedUserObjectIds = $effectiveAllowedUsers
        ApimPrincipalId = $ApimPrincipalId
        CredentialStored = -not [string]::IsNullOrWhiteSpace($KeyVaultName)
    }
}
finally {
    if ($credential -and -not $credentialStored -and $credentialApplicationId) {
        try {
            Invoke-Graph -Token $resourceGraphToken -Method POST -Path "applications/$credentialApplicationId/removePassword" -Body @{ keyId = $credential.keyId } | Out-Null
        }
        catch {
            Write-Warning 'Failed to remove the newly created Graph credential after Key Vault storage failed. Remove it immediately in Microsoft Entra ID.'
        }
    }
    $resourceGraphToken = $null
    $callerGraphToken = $null
    $credential = $null
    $managementToken = $null
}