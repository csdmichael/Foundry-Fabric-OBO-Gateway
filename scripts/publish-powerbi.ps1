[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot '../config/deployment.json'),
    [string] $ReportName = 'Fabric Parts Shortages Executive Analytics',
    [string] $OutputPath = (Join-Path $PSScriptRoot '../.generated/powerbi/executive-report.definition.json'),
    [switch] $DefinitionOnly
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'config.ps1')

$config = Get-FabricDeploymentConfig -Path $ConfigPath
$workspaceId = Assert-FabricGuid -Value $config.fabric.workspaceId -Name 'fabric.workspaceId'
$semanticModelId = Assert-FabricGuid -Value $config.powerBi.semanticModelId -Name 'powerBi.semanticModelId'
$tenantId = Assert-FabricGuid -Value $config.azure.tenantId -Name 'azure.tenantId'
$subscriptionId = Assert-FabricGuid -Value $config.azure.subscriptionId -Name 'azure.subscriptionId'
$entityName = 'ecc_zspm_shortages'

function New-ColumnSelect {
    param(
        [string] $Property,
        [string] $Entity = $entityName
    )

    return [ordered]@{
        Column = [ordered]@{
            Expression = [ordered]@{ SourceRef = [ordered]@{ Source = 's' } }
            Property = $Property
        }
        Name = "$Entity.$Property"
    }
}

function New-MeasureSelect {
    param(
        [string] $Property,
        [string] $Entity = $entityName
    )

    return [ordered]@{
        Measure = [ordered]@{
            Expression = [ordered]@{ SourceRef = [ordered]@{ Source = 's' } }
            Property = $Property
        }
        Name = "$Entity.$Property"
    }
}

function New-Projection {
    param(
        [string] $Property,
        [string] $Entity = $entityName,
        [switch] $Active
    )

    $projection = [ordered]@{ queryRef = "$Entity.$Property" }
    if ($Active) {
        $projection.active = $true
    }
    return $projection
}

function New-VisualContainer {
    param(
        [string] $VisualType,
        [string] $Title,
        [double] $X,
        [double] $Y,
        [double] $Width,
        [double] $Height,
        [int] $Z,
        [string] $Entity = $entityName,
        [Parameter(Mandatory = $true)] [System.Collections.Specialized.OrderedDictionary] $Projections,
        [Parameter(Mandatory = $true)] [object[]] $Select
    )

    $name = [guid]::NewGuid().ToString('N').Substring(0, 20)
    $position = [ordered]@{
        x = $X
        y = $Y
        z = $Z
        width = $Width
        height = $Height
        tabOrder = $Z
    }
    $visual = [ordered]@{
        visualType = $VisualType
        projections = $Projections
        prototypeQuery = [ordered]@{
            Version = 2
            From = @([ordered]@{ Name = 's'; Entity = $Entity; Type = 0 })
            Select = $Select
        }
        drillFilterOtherVisuals = $true
        vcObjects = [ordered]@{
            title = @([ordered]@{
                properties = [ordered]@{
                    show = [ordered]@{ expr = [ordered]@{ Literal = [ordered]@{ Value = 'true' } } }
                    text = [ordered]@{ expr = [ordered]@{ Literal = [ordered]@{ Value = "'$Title'" } } }
                }
            })
        }
    }
    $visualConfig = [ordered]@{
        name = $name
        layouts = @([ordered]@{ id = 0; position = $position })
        singleVisual = $visual
    }

    return [ordered]@{
        config = $visualConfig | ConvertTo-Json -Depth 40 -Compress
        filters = '[]'
        height = $Height
        width = $Width
        x = $X
        y = $Y
        z = [double]$Z
    }
}

function New-Page {
    param(
        [string] $Name,
        [string] $DisplayName,
        [object[]] $Visuals
    )

    return [ordered]@{
        config = '{}'
        displayName = $DisplayName
        displayOption = 1
        filters = '[]'
        height = 720.0
        name = $Name
        visualContainers = $Visuals
        width = 1280.0
    }
}

function ConvertTo-InlinePart {
    param([string] $Path, [string] $Content)

    return [ordered]@{
        path = $Path
        payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Content))
        payloadType = 'InlineBase64'
    }
}

$hierarchyProjections = [ordered]@{
    Category = @(
        (New-Projection -Property 'werks' -Active),
        (New-Projection -Property 'customer'),
        (New-Projection -Property 'majmod'),
        (New-Projection -Property 'matnr')
    )
    Y = @((New-Projection -Property 'Open Shortages'))
}
$hierarchySelect = @(
    (New-ColumnSelect -Property 'werks'),
    (New-ColumnSelect -Property 'customer'),
    (New-ColumnSelect -Property 'majmod'),
    (New-ColumnSelect -Property 'matnr'),
    (New-MeasureSelect -Property 'Open Shortages')
)

$overviewVisuals = @(
    (New-VisualContainer -VisualType 'card' -Title 'Open Shortages' -X 16 -Y 16 -Width 200 -Height 96 -Z 1000 -Projections ([ordered]@{ Values = @((New-Projection -Property 'Open Shortages')) }) -Select @((New-MeasureSelect -Property 'Open Shortages'))),
    (New-VisualContainer -VisualType 'card' -Title 'Affected Materials' -X 232 -Y 16 -Width 200 -Height 96 -Z 2000 -Projections ([ordered]@{ Values = @((New-Projection -Property 'Affected Materials')) }) -Select @((New-MeasureSelect -Property 'Affected Materials'))),
    (New-VisualContainer -VisualType 'card' -Title 'Affected Suppliers' -X 448 -Y 16 -Width 200 -Height 96 -Z 3000 -Projections ([ordered]@{ Values = @((New-Projection -Property 'Affected Suppliers')) }) -Select @((New-MeasureSelect -Property 'Affected Suppliers'))),
    (New-VisualContainer -VisualType 'clusteredBarChart' -Title 'Shortages by Country, Plant, Customer, Model, and Material' -X 16 -Y 128 -Width 616 -Height 280 -Z 4000 -Projections $hierarchyProjections -Select $hierarchySelect),
    (New-VisualContainer -VisualType 'map' -Title 'Open Shortages by Plant Location' -X 648 -Y 128 -Width 616 -Height 280 -Z 5000 -Entity 'mdm_plant_geography' -Projections ([ordered]@{ Category = @((New-Projection -Entity 'mdm_plant_geography' -Property 'location_label' -Active)); Size = @((New-Projection -Entity 'mdm_plant_geography' -Property 'Geo Open Shortages')) }) -Select @((New-ColumnSelect -Entity 'mdm_plant_geography' -Property 'location_label'), (New-MeasureSelect -Entity 'mdm_plant_geography' -Property 'Geo Open Shortages'))),
    (New-VisualContainer -VisualType 'pieChart' -Title 'Shortage Types' -X 16 -Y 424 -Width 400 -Height 280 -Z 6000 -Projections ([ordered]@{ Category = @((New-Projection -Property 'ztype' -Active)); Y = @((New-Projection -Property 'Open Shortages')) }) -Select @((New-ColumnSelect -Property 'ztype'), (New-MeasureSelect -Property 'Open Shortages'))),
    (New-VisualContainer -VisualType 'tableEx' -Title 'Open Shortage Detail' -X 432 -Y 424 -Width 832 -Height 280 -Z 7000 -Projections ([ordered]@{ Values = @((New-Projection -Property 'zshortno'), (New-Projection -Property 'werks'), (New-Projection -Property 'customer'), (New-Projection -Property 'matnr'), (New-Projection -Property 'lifnr'), (New-Projection -Property 'ztype'), (New-Projection -Property 'gap'), (New-Projection -Property 'zsupway')) }) -Select @((New-ColumnSelect -Property 'zshortno'), (New-ColumnSelect -Property 'werks'), (New-ColumnSelect -Property 'customer'), (New-ColumnSelect -Property 'matnr'), (New-ColumnSelect -Property 'lifnr'), (New-ColumnSelect -Property 'ztype'), (New-ColumnSelect -Property 'gap'), (New-ColumnSelect -Property 'zsupway')))
)

$trendVisuals = @(
    (New-VisualContainer -VisualType 'lineChart' -Title 'Open Shortages by Need Date' -X 16 -Y 16 -Width 1248 -Height 320 -Z 1000 -Projections ([ordered]@{ Y = @((New-Projection -Property 'Open Shortages')); Category = @((New-Projection -Property 'zneed_dt' -Active)) }) -Select @((New-MeasureSelect -Property 'Open Shortages'), (New-ColumnSelect -Property 'zneed_dt'))),
    (New-VisualContainer -VisualType 'clusteredColumnChart' -Title 'Shortage Quantity by Plant and Type' -X 16 -Y 352 -Width 616 -Height 352 -Z 2000 -Projections ([ordered]@{ Category = @((New-Projection -Property 'werks' -Active)); Y = @((New-Projection -Property 'Shortage Quantity')); Series = @((New-Projection -Property 'ztype')) }) -Select @((New-ColumnSelect -Property 'werks'), (New-MeasureSelect -Property 'Shortage Quantity'), (New-ColumnSelect -Property 'ztype'))),
    (New-VisualContainer -VisualType 'tableEx' -Title 'Supplier and Material Exposure' -X 648 -Y 352 -Width 616 -Height 352 -Z 3000 -Projections ([ordered]@{ Values = @((New-Projection -Property 'werks'), (New-Projection -Property 'name1'), (New-Projection -Property 'lifnr'), (New-Projection -Property 'matnr'), (New-Projection -Property 'maktx'), (New-Projection -Property 'Shortage Quantity'), (New-Projection -Property 'Supply Gap')) }) -Select @((New-ColumnSelect -Property 'werks'), (New-ColumnSelect -Property 'name1'), (New-ColumnSelect -Property 'lifnr'), (New-ColumnSelect -Property 'matnr'), (New-ColumnSelect -Property 'maktx'), (New-MeasureSelect -Property 'Shortage Quantity'), (New-MeasureSelect -Property 'Supply Gap')))
)

$reportConfig = [ordered]@{
    version = '5.70'
    themeCollection = [ordered]@{}
    activeSectionIndex = 0
    defaultDrillFilterOtherVisuals = $true
    linguisticSchemaSyncVersion = 0
    settings = [ordered]@{
        useNewFilterPaneExperience = $true
        allowChangeFilterTypes = $true
        useStylableVisualContainerHeader = $true
        queryLimitOption = 6
        useEnhancedTooltips = $true
        exportDataMode = 1
        useDefaultAggregateDisplayName = $true
    }
}
$legacyReport = [ordered]@{
    config = $reportConfig | ConvertTo-Json -Depth 20 -Compress
    filters = '[]'
    layoutOptimization = 0
    resourcePackages = @()
    sections = @(
        (New-Page -Name 'ReportSectionExecutiveOverview' -DisplayName 'Executive Overview' -Visuals $overviewVisuals),
        (New-Page -Name 'ReportSectionSupplyTrends' -DisplayName 'Supply Trends' -Visuals $trendVisuals)
    )
}
$definitionProperties = [ordered]@{
    '$schema' = 'https://developer.microsoft.com/json-schemas/fabric/item/report/definitionProperties/2.0.0/schema.json'
    version = '4.0'
    datasetReference = [ordered]@{
        byConnection = [ordered]@{ connectionString = "semanticmodelid=$semanticModelId" }
    }
}
$platform = [ordered]@{
    '$schema' = 'https://developer.microsoft.com/json-schemas/fabric/gitIntegration/platformProperties/2.0.0/schema.json'
    metadata = [ordered]@{
        type = 'Report'
        displayName = $ReportName
        description = 'Executive Power BI analytics over the migrated Caldova Fabric Lakehouse.'
    }
    config = [ordered]@{ version = '2.0'; logicalId = '00000000-0000-0000-0000-000000000000' }
}
$definition = [ordered]@{
    format = 'PBIR-Legacy'
    parts = @(
        (ConvertTo-InlinePart -Path 'definition.pbir' -Content ($definitionProperties | ConvertTo-Json -Depth 20)),
        (ConvertTo-InlinePart -Path 'report.json' -Content ($legacyReport | ConvertTo-Json -Depth 100)),
        (ConvertTo-InlinePart -Path '.platform' -Content ($platform | ConvertTo-Json -Depth 20))
    )
}

$resolvedOutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
New-Item -ItemType Directory -Path (Split-Path -Parent $resolvedOutputPath) -Force | Out-Null
$definition | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $resolvedOutputPath -Encoding utf8

if ($DefinitionOnly) {
    return [pscustomobject]@{ DefinitionPath = $resolvedOutputPath; ReportName = $ReportName }
}

$token = Get-FabricAzAccessToken -TenantId $tenantId -SubscriptionId $subscriptionId -Resource 'https://api.fabric.microsoft.com/'
try {
    $headers = @{ Authorization = "Bearer $token" }
    $itemsUri = "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/items"
    $existing = @((Invoke-RestMethod -Headers $headers -Uri $itemsUri).value | Where-Object { $_.type -eq 'Report' -and $_.displayName -eq $ReportName })
    if ($existing.Count -gt 1) {
        throw "Multiple target reports are named '$ReportName'."
    }

    if ($existing.Count -eq 1) {
        $uri = "$itemsUri/$($existing[0].id)/updateDefinition"
        $body = @{ definition = $definition } | ConvertTo-Json -Depth 100
        $response = Invoke-WebRequest -Method Post -Headers $headers -ContentType 'application/json' -Uri $uri -Body $body -SkipHttpErrorCheck
        $reportId = $existing[0].id
    }
    else {
        $body = @{
            displayName = $ReportName
            description = 'Executive Power BI analytics over the migrated Caldova Fabric Lakehouse.'
            type = 'Report'
            definition = $definition
        } | ConvertTo-Json -Depth 100
        $response = Invoke-WebRequest -Method Post -Headers $headers -ContentType 'application/json' -Uri $itemsUri -Body $body -SkipHttpErrorCheck
        $reportId = $null
    }

    if ([int]$response.StatusCode -notin @(200, 201, 202)) {
        throw "Power BI report publication returned HTTP $([int]$response.StatusCode): $($response.Content)"
    }

    [pscustomobject]@{
        DefinitionPath = $resolvedOutputPath
        ReportId = $reportId
        OperationId = if ($response.Headers.ContainsKey('x-ms-operation-id')) { $response.Headers['x-ms-operation-id'] -join '' } else { '' }
        Location = if ($response.Headers.ContainsKey('Location')) { $response.Headers['Location'] -join '' } else { '' }
        StatusCode = [int]$response.StatusCode
    }
}
finally {
    $token = $null
    $headers = $null
    $body = $null
}