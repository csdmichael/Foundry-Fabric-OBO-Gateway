[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot '../config/deployment.json'),
    [switch] $EnsureManaged,
    [switch] $WriteConfig
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'config.ps1')

$config = Get-FabricDeploymentConfig -Path $ConfigPath
$tenantId = [string]$config.powerPlatform.tenantId
$displayName = [string]$config.powerPlatform.environmentDisplayName
$token = Get-FabricAzAccessToken -TenantId $tenantId -Resource 'https://service.powerapps.com/' -SubscriptionId ([string]$config.apim.subscriptionId)
try {
    $headers = @{ Authorization = "Bearer $token" }
    $uri = 'https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments?api-version=2021-04-01'
    $response = Invoke-RestMethod -Method GET -Uri $uri -Headers $headers
    if ($response.PSObject.Properties['nextLink'] -and $response.nextLink) {
        throw 'Power Platform environment pagination requires explicit review.'
    }
    $environmentMatches = @($response.value | Where-Object { $_.properties.displayName -eq $displayName })
    if ($environmentMatches.Count -ne 1) {
        throw "Expected exactly one Power Platform environment named '$displayName'; found $($environmentMatches.Count)."
    }
    $environment = $environmentMatches[0]
    $environmentId = Assert-FabricGuid -Value $environment.name -Name 'Power Platform environment ID'
    $linkedMetadata = if ($environment.properties.PSObject.Properties['linkedEnvironmentMetadata']) { $environment.properties.linkedEnvironmentMetadata } else { $null }
    $dataverseUrl = if ($linkedMetadata -and $linkedMetadata.PSObject.Properties['instanceUrl']) { [string]$linkedMetadata.instanceUrl } else { '' }
    if ([string]::IsNullOrWhiteSpace($dataverseUrl)) {
        throw "Power Platform environment '$displayName' has no Dataverse instance."
    }
    $governance = if ($environment.properties.PSObject.Properties['governanceConfiguration']) { $environment.properties.governanceConfiguration } else { $null }
    $protectionLevel = if ($governance -and $governance.PSObject.Properties['protectionLevel']) { [string]$governance.protectionLevel } else { '' }
    if ($protectionLevel -ne 'Standard' -and $EnsureManaged) {
        Invoke-RestMethod -Method PUT -Uri "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments/$environmentId/governanceConfiguration?api-version=2021-04-01" -Headers $headers -ContentType 'application/json' -Body (@{ protectionLevel = 'Standard' } | ConvertTo-Json) | Out-Null
        $environment = Invoke-RestMethod -Method GET -Uri "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments/$environmentId`?api-version=2021-04-01" -Headers $headers
        $governance = if ($environment.properties.PSObject.Properties['governanceConfiguration']) { $environment.properties.governanceConfiguration } else { $null }
        $protectionLevel = if ($governance -and $governance.PSObject.Properties['protectionLevel']) { [string]$governance.protectionLevel } else { '' }
    }
    if ($protectionLevel -ne 'Standard') {
        throw "Power Platform environment '$displayName' is not Managed. Rerun with -EnsureManaged after approval."
    }

    if ($WriteConfig) {
        $config.powerPlatform.environmentId = $environmentId
        $resolvedConfigPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ConfigPath)
        $config | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $resolvedConfigPath -Encoding utf8
    }

    [pscustomobject]@{
        EnvironmentId = $environmentId
        DisplayName = $displayName
        TenantId = $tenantId
        Geo = [string]$environment.location
        AzureRegion = [string]$environment.properties.azureRegion
        DataverseUrl = $dataverseUrl
        ProtectionLevel = $protectionLevel
        ConfigUpdated = [bool]$WriteConfig
    }
}
finally {
    $token = $null
    $headers = $null
}
