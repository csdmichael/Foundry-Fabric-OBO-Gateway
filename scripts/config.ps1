Set-StrictMode -Version Latest

function Get-FabricDeploymentConfig {
    [CmdletBinding()]
    param(
        [string] $Path = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config/deployment.json')
    )

    $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        throw "Fabric deployment configuration not found: $resolvedPath"
    }

    try {
        $config = Get-Content -LiteralPath $resolvedPath -Raw | ConvertFrom-Json
    }
    catch {
        throw "Fabric deployment configuration is not valid JSON: $resolvedPath. $($_.Exception.Message)"
    }

    if ($config.schemaVersion -ne 1) {
        throw "Unsupported Fabric deployment schema version '$($config.schemaVersion)'."
    }
    foreach ($section in 'azure', 'fabric', 'apim', 'foundry', 'identity', 'network', 'broker', 'powerPlatform', 'deployment', 'tags') {
        if (-not $config.PSObject.Properties[$section]) {
            throw "Fabric deployment configuration is missing the '$section' section."
        }
    }

    return $config
}

function Get-FabricConfigFingerprint {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string] $Path)

    $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        throw "Fabric deployment configuration not found: $resolvedPath"
    }
    return (Get-FileHash -LiteralPath $resolvedPath -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-FabricConfigValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object] $Config,
        [Parameter(Mandatory = $true)] [string] $Path,
        [object] $Override,
        [switch] $AllowEmpty
    )

    if ($null -ne $Override) {
        if ($Override -isnot [string] -or $AllowEmpty -or -not [string]::IsNullOrWhiteSpace($Override)) {
            return $Override
        }
    }

    $value = $Config
    foreach ($segment in $Path.Split('.')) {
        $property = $value.PSObject.Properties[$segment]
        if ($null -eq $property) {
            throw "Fabric deployment configuration value '$Path' is missing."
        }
        $value = $property.Value
    }

    if (-not $AllowEmpty -and $value -is [string] -and [string]::IsNullOrWhiteSpace($value)) {
        throw "Fabric deployment configuration value '$Path' cannot be empty."
    }
    return $value
}

function Assert-FabricGuid {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object] $Value,
        [Parameter(Mandatory = $true)] [string] $Name
    )

    $parsed = [guid]::Empty
    if (-not [guid]::TryParse([string]$Value, [ref]$parsed) -or $parsed -eq [guid]::Empty) {
        throw "$Name must be a nonempty GUID."
    }
    return $parsed.ToString()
}

function Assert-FabricGuidList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $Values,
        [Parameter(Mandatory = $true)] [string] $Name,
        [switch] $AllowEmpty
    )

    $items = @($Values | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) })
    if (-not $AllowEmpty -and $items.Count -eq 0) {
        throw "$Name must contain at least one GUID."
    }
    foreach ($item in $items) {
        $null = Assert-FabricGuid -Value $item -Name $Name
    }
    $normalized = @($items | ForEach-Object { ([guid]$_).ToString().ToLowerInvariant() } | Select-Object -Unique)
    Write-Output -NoEnumerate $normalized
}

function Assert-FabricAzureContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $SubscriptionId,
        [Parameter(Mandatory = $true)] [string] $TenantId
    )

    $contextJson = az account show --subscription $SubscriptionId -o json
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read Azure CLI context for subscription '$SubscriptionId'."
    }
    $context = $contextJson | ConvertFrom-Json
    if ($context.id -ne $SubscriptionId -or $context.tenantId -ne $TenantId) {
        throw "Azure CLI context does not match subscription '$SubscriptionId' in tenant '$TenantId'."
    }
    return $context
}

function Get-FabricAzAccessToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $TenantId,
        [Parameter(Mandatory = $true)] [string] $Resource,
        [string] $SubscriptionId
    )

    $arguments = @('account', 'get-access-token', '--resource', $Resource, '--query', 'accessToken', '-o', 'tsv')
    if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
        $subscriptionTenant = az account show --subscription $SubscriptionId --query tenantId -o tsv
        if ($LASTEXITCODE -ne 0 -or $subscriptionTenant -ne $TenantId) {
            throw "Subscription '$SubscriptionId' is not available in tenant '$TenantId'."
        }
        $arguments += @('--subscription', $SubscriptionId)
    }
    else {
        $arguments += @('--tenant', $TenantId)
    }
    $token = az @arguments
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
        throw "Unable to acquire a token for '$Resource' in tenant '$TenantId'."
    }
    return $token
}

function Invoke-FabricNative {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $FilePath,
        [Parameter(Mandatory = $true)] [string[]] $ArgumentList,
        [Parameter(Mandatory = $true)] [string] $Description
    )

    & $FilePath @ArgumentList | Out-Host
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "$Description failed with exit code $exitCode."
    }
}

function Assert-FabricWhatIfChanges {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $Changes,
        [switch] $AllowModify
    )

    $allowedTypes = @('Create', 'NoChange', 'Ignore')
    if ($AllowModify) {
        $allowedTypes += 'Modify'
    }
    $blocked = @($Changes | Where-Object { $allowedTypes -notcontains $_.changeType })
    if ($blocked.Count -gt 0) {
        $summary = @($blocked | ForEach-Object { "$($_.changeType) $($_.resourceId)" })
        throw "Azure what-if contains blocked changes: $($summary -join '; ')."
    }
    return @($Changes | Group-Object changeType | Sort-Object Name | ForEach-Object {
        [pscustomobject]@{ ChangeType = $_.Name; Count = $_.Count }
    })
}

function Get-FabricAgentPackageEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $PackagePath,
        [Parameter(Mandatory = $true)] [string] $SchemaName,
        [Parameter(Mandatory = $true)] [string] $ConnectorName,
        [Parameter(Mandatory = $true)] [string] $PromptName
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PackagePath)
    $archive = [System.IO.Compression.ZipFile]::OpenRead($resolvedPath)
    try {
        $names = @($archive.Entries.FullName)
        $botPrefix = "bots/$SchemaName/"
        foreach ($required in "${botPrefix}bot.xml", "${botPrefix}configuration.json") {
            if ($names -notcontains $required) {
                throw "Agent package '$(Split-Path -Leaf $resolvedPath)' is missing '$required'."
            }
        }
        $boundComponents = @($names | Where-Object { $_ -match '(^|/)(botcomponents|actions|connectionreferences|workflows|prompts)/' })
        $textParts = @()
        foreach ($archiveEntry in $archive.Entries | Where-Object { $_.Length -le 5242880 -and $_.FullName -match '\.(xml|json|ya?ml|txt)$' }) {
            $stream = $archiveEntry.Open()
            $reader = [System.IO.StreamReader]::new($stream)
            try {
                $textParts += $reader.ReadToEnd()
            }
            finally {
                $reader.Dispose()
                $stream.Dispose()
            }
        }
        $packageText = $textParts -join "`n"
        $hasConnector = $packageText.IndexOf($ConnectorName, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
        $hasPrompt = $packageText.IndexOf($PromptName, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
        $hasConnectionReference = $packageText -match '(?i)connection\s*reference|connectionreference'
        return [pscustomobject]@{
            BoundComponentCount = $boundComponents.Count
            HasExpectedConnector = $hasConnector
            HasExpectedPrompt = $hasPrompt
            HasConnectionReference = $hasConnectionReference
        }
    }
    finally {
        $archive.Dispose()
    }
}