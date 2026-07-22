[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification='Several script parameters are consumed through helper functions at script scope.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$ApimName,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceId,

    [Parameter()]
    [string]$BackendUrl = "https://weather-api-cw001.mangomeadow-171b7d7e.eastus2.azurecontainerapps.io",

    [Parameter()]
    [string]$ApiId = "weather-api",

    [Parameter()]
    [string]$ApiDisplayName = "Weather API",

    [Parameter()]
    [string]$ApiPath = "weather",

    [Parameter()]
    [string]$ProductId = "weather-tests",

    [Parameter()]
    [string]$ProductDisplayName = "Weather Tests",

    [Parameter()]
    [string]$ProductDescription = "Test product for the weather API",

    [Parameter()]
    [bool]$CreateProduct = $true,

    [Parameter()]
    [ValidateRange(30, 3600)]
    [int]$VerificationTimeoutSeconds = 180,

    [Parameter()]
    [string]$ApiVersion = "2024-05-01",

    [Parameter()]
    [string]$LogDirectory = (Join-Path $PSScriptRoot "logs"),

    [switch]$WhatIfOnly
)

$ErrorActionPreference = "Stop"

$runId = Get-Date -Format "yyyyMMdd-HHmmss"
$scriptName = [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
if (-not (Test-Path $LogDirectory)) {
    New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
}
$LogFile = Join-Path $LogDirectory ("$scriptName-$runId.log")

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("DEBUG", "INFO", "WARN", "ERROR")]
        [string]$Level,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "o"), $Level, $Message
    Add-Content -Path $LogFile -Value $line

    switch ($Level) {
        "DEBUG" { Write-Verbose $Message }
        "INFO" { Write-Output "[INFO] $Message" }
        "WARN" { Write-Warning $Message }
        "ERROR" { Write-Output "[ERROR] $Message" }
    }
}

function Test-ToolAvailable {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required tool '$Name' not found in PATH."
    }
}

function Invoke-AzCli {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$AzTokens,

        [switch]$ReadOnly
    )

    $displayTokens = $AzTokens | ForEach-Object {
        if ($_ -match "\s") { '"' + $_ + '"' } else { $_ }
    }
    Write-Log -Level "DEBUG" -Message "Running command: az $($displayTokens -join ' ')"

    if ($WhatIfOnly -and -not $ReadOnly) {
        Write-Log -Level "INFO" -Message "WhatIfOnly is enabled. Skipping command execution."
        return $null
    }

    $output = & az @AzTokens
    if ($LASTEXITCODE -ne 0) {
        Write-Log -Level "ERROR" -Message "Azure CLI command failed with exit code $LASTEXITCODE"
        throw "Azure CLI command failed: az $($displayTokens -join ' ')"
    }

    if ($null -eq $output) {
        return $null
    }

    $outputText = $output -join "`n"
    if ($outputText) {
        Write-Log -Level "DEBUG" -Message "Command output: $outputText"
    }

    return $outputText
}

function Get-WorkspaceUrl {
    param([string]$ChildPath)

    $base = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.ApiManagement/service/$ApimName/workspaces/$WorkspaceId"
    if ([string]::IsNullOrWhiteSpace($ChildPath)) {
        return $base
    }

    return "$base/$($ChildPath.TrimStart('/'))"
}

function Invoke-WorkspaceRest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Method,

        [Parameter()]
        [string]$ChildPath,

        [Parameter()]
        [object]$BodyObject
    )

    $url = Get-WorkspaceUrl -ChildPath $ChildPath
    $cliTokens = @(
        "rest",
        "--method", $Method,
        "--url", $url,
        "--uri-parameters", "api-version=$ApiVersion"
    )

    $bodyFile = $null
    try {
        if ($null -ne $BodyObject) {
            $payload = $BodyObject | ConvertTo-Json -Depth 20 -Compress
            $bodyFile = Join-Path $env:TEMP ("apim-weather-body-" + [guid]::NewGuid().ToString() + ".json")
            Set-Content -Path $bodyFile -Value $payload -Encoding UTF8
            $cliTokens += @("--headers", "Content-Type=application/json", "--body", "@$bodyFile")
        }

        return Invoke-AzCli -AzTokens $cliTokens -ReadOnly:($Method -eq "GET")
    } finally {
        if ($bodyFile -and (Test-Path $bodyFile)) {
            Remove-Item -Path $bodyFile -Force -ErrorAction SilentlyContinue
            Write-Log -Level "DEBUG" -Message "Temporary request body removed: $bodyFile"
        }
    }
}

function Get-ApimGatewayUrl {
    $resourceUrl = "https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.ApiManagement/service/{2}?api-version={3}" -f $SubscriptionId, $ResourceGroupName, $ApimName, $ApiVersion
    $json = Invoke-AzCli -AzTokens @("rest", "--method", "get", "--url", $resourceUrl) -ReadOnly
    if (-not $json) {
        return $null
    }

    $service = $json | ConvertFrom-Json
    if ($service.properties.gatewayUrl) {
        return $service.properties.gatewayUrl
    }

    $proxyHostName = $service.properties.hostnameConfigurations |
        Where-Object { $_.type -eq "Proxy" -and $_.defaultSslBinding } |
        Select-Object -ExpandProperty hostName -First 1

    if ($proxyHostName) {
        return "https://$proxyHostName"
    }

    return $null
}

function Wait-WorkspaceResource {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ChildPath,

        [Parameter(Mandatory = $true)]
        [string]$ExpectName,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastErrorMessage = "No successful response was received."

    while ((Get-Date) -lt $deadline) {
        try {
            $json = Invoke-WorkspaceRest -Method "GET" -ChildPath $ChildPath
            if (-not $json) {
                $lastErrorMessage = "Empty response."
                Start-Sleep -Seconds 5
                continue
            }

            $obj = $json | ConvertFrom-Json
            if ($obj -and $obj.name -eq $ExpectName) {
                return $obj
            }

            $lastErrorMessage = "Resource did not match expected values."
        } catch {
            $lastErrorMessage = $_.Exception.Message
        }

        Start-Sleep -Seconds 5
    }

    throw "Timed out waiting for '$ExpectName'. Last error: $lastErrorMessage"
}

function Test-RequiredValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "Parameter '$Name' is required."
    }
}

Test-ToolAvailable -Name "az"
Write-Log -Level "INFO" -Message "Run started. Log file: $LogFile"

Write-Log -Level "INFO" -Message "Selecting subscription"
Invoke-AzCli -AzTokens @("account", "set", "--subscription", $SubscriptionId) -ReadOnly | Out-Null

Test-RequiredValue -Name "BackendUrl" -Value $BackendUrl
Test-RequiredValue -Name "ApiId" -Value $ApiId
Test-RequiredValue -Name "ApiDisplayName" -Value $ApiDisplayName
Test-RequiredValue -Name "ApiPath" -Value $ApiPath

$openApiDocument = @{
    openapi = "3.0.3"
    info = @{
        title = $ApiDisplayName
        version = "1.0.0"
        description = "A simple fake weather API backed by Azure Container Apps"
    }
    servers = @(
        @{
            url = $BackendUrl
        }
    )
    paths = @{
        "/health" = @{
            get = @{
                operationId = "getHealth"
                summary = "Health check"
                responses = @{
                    "200" = @{
                        description = "Healthy"
                    }
                }
            }
        }
        "/weather/{city}" = @{
            get = @{
                operationId = "getWeatherByCity"
                summary = "Get fake weather for a city"
                parameters = @(
                    @{
                        name = "city"
                        in = "path"
                        required = $true
                        schema = @{
                            type = "string"
                        }
                    }
                )
                responses = @{
                    "200" = @{
                        description = "Weather response"
                    }
                }
            }
        }
    }
}

$openApiJson = $openApiDocument | ConvertTo-Json -Depth 20 -Compress
$apiBody = @{
    properties = @{
        displayName = $ApiDisplayName
        path = $ApiPath
        apiType = "http"
        format = "openapi+json"
        value = $openApiJson
        serviceUrl = $BackendUrl
        protocols = @("https")
        subscriptionRequired = $false
    }
}

Write-Log -Level "INFO" -Message "Creating workspace API '$ApiId'"
[void](Invoke-WorkspaceRest -Method "PUT" -ChildPath "apis/$ApiId" -BodyObject $apiBody)

Write-Log -Level "INFO" -Message "Waiting for API provisioning to settle"
$workspaceApi = Wait-WorkspaceResource -ChildPath "apis/$ApiId" -ExpectName $ApiId -TimeoutSeconds $VerificationTimeoutSeconds

if ($workspaceApi.properties.path -ne $ApiPath) {
    Write-Log -Level "WARN" -Message "APIM stored API path '$($workspaceApi.properties.path)' instead of expected path '$ApiPath'. Applying a follow-up update."

    $pathFixBody = @{
        properties = @{
            displayName = $ApiDisplayName
            description = "A simple fake weather API backed by Azure Container Apps"
            path = $ApiPath
            protocols = @("https")
            serviceUrl = $BackendUrl
            subscriptionRequired = $false
        }
    }

    [void](Invoke-WorkspaceRest -Method "PUT" -ChildPath "apis/$ApiId" -BodyObject $pathFixBody)
    $workspaceApi = Wait-WorkspaceResource -ChildPath "apis/$ApiId" -ExpectName $ApiId -TimeoutSeconds $VerificationTimeoutSeconds
}

$apimGatewayUrl = Get-ApimGatewayUrl
if (-not $apimGatewayUrl) {
    throw "Unable to resolve APIM gateway URL."
}

$publicApiUrl = ($apimGatewayUrl.TrimEnd('/') + "/" + $ApiPath + "/weather/seattle")
Write-Log -Level "INFO" -Message "Public APIM test URL: $publicApiUrl"

if ($CreateProduct) {
    $productBody = @{
        properties = @{
            displayName = $ProductDisplayName
            description = $ProductDescription
            subscriptionRequired = $false
            state = "published"
        }
    }

    Write-Log -Level "INFO" -Message "Creating workspace product '$ProductId'"
    $productJson = Invoke-WorkspaceRest -Method "PUT" -ChildPath "products/$ProductId" -BodyObject $productBody
    if (-not $productJson) {
        throw "Product create/update returned no response."
    }

    Write-Log -Level "WARN" -Message "Workspace product association is not attempted here because the APIM workspace link path is returning service-side errors in this environment. Use the CLI add-api-to-product command if you want to retry diagnostics separately."
}

Write-Log -Level "INFO" -Message "Workspace API created successfully."
Write-Log -Level "WARN" -Message "APIM workspace runtime should still be validated separately after import. Control-plane API creation does not guarantee successful gateway routing in every workspace configuration."
Write-Output "APIM_GW_URL=$apimGatewayUrl"
Write-Output "TEST_URL=$publicApiUrl"
Write-Output "API_ID=$ApiId"
Write-Output "PRODUCT_ID=$ProductId"
Write-Output "LOG_FILE=$LogFile"
