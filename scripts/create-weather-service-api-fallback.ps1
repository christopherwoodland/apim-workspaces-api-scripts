[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification='Script parameters are consumed via helper functions and optional execution branches.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$ApimName,

    [Parameter()]
    [string]$ApiId = "weather-api-public",

    [Parameter()]
    [string]$ApiDisplayName = "Weather API (Service Fallback)",

    [Parameter()]
    [string]$ApiPath = "weather",

    [Parameter()]
    [string]$BackendUrl = "https://weather-api-cw001.mangomeadow-171b7d7e.eastus2.azurecontainerapps.io",

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

function Invoke-AzCli {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Args,

        [switch]$ReadOnly
    )

    $displayArgs = $Args | ForEach-Object { if ($_ -match "\s") { '"' + $_ + '"' } else { $_ } }
    Write-Log -Level "DEBUG" -Message "Running command: az $($displayArgs -join ' ')"

    if ($WhatIfOnly -and -not $ReadOnly) {
        Write-Log -Level "INFO" -Message "WhatIfOnly is enabled. Skipping command execution."
        return $null
    }

    $output = & az @Args
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed: az $($displayArgs -join ' ')"
    }

    if ($null -eq $output) {
        return $null
    }

    return ($output -join "`n")
}

function Invoke-ApimRest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Method,

        [Parameter(Mandatory = $true)]
        [string]$ChildPath,

        [Parameter()]
        [object]$Body
    )

    $baseUrl = "https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.ApiManagement/service/{2}" -f $SubscriptionId, $ResourceGroupName, $ApimName
    $url = if ([string]::IsNullOrWhiteSpace($ChildPath)) { $baseUrl } else { $baseUrl.TrimEnd('/') + '/' + $ChildPath.TrimStart('/') }
    $azTokens = @("rest", "--method", $Method, "--url", $url, "--uri-parameters", "api-version=$ApiVersion")

    $bodyFile = $null
    try {
        if ($null -ne $Body) {
            $bodyFile = Join-Path $env:TEMP ("apim-service-api-body-" + [guid]::NewGuid().ToString() + ".json")
            Set-Content -Path $bodyFile -Value ($Body | ConvertTo-Json -Depth 20 -Compress) -Encoding UTF8
            $azTokens += @("--headers", "Content-Type=application/json", "--body", "@$bodyFile")
        }

        return Invoke-AzCli -Args $azTokens -ReadOnly:($Method -eq "GET")
    } finally {
        if ($bodyFile -and (Test-Path $bodyFile)) {
            Remove-Item -Path $bodyFile -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Log -Level "INFO" -Message "Run started. Log file: $LogFile"
Invoke-AzCli -Args @("account", "set", "--subscription", $SubscriptionId) -ReadOnly | Out-Null

$openApi = @{
    openapi = "3.0.3"
    info = @{ title = $ApiDisplayName; version = "1.0.0" }
    servers = @(@{ url = $BackendUrl })
    paths = @{
        "/health" = @{ get = @{ operationId = "getHealth"; responses = @{ "200" = @{ description = "Healthy" } } } }
        "/{city}" = @{ get = @{ operationId = "getWeatherByCity"; parameters = @(@{ name = "city"; in = "path"; required = $true; schema = @{ type = "string" } }); responses = @{ "200" = @{ description = "Weather response" } } } }
    }
}

$body = @{
    properties = @{
        displayName = $ApiDisplayName
        description = "Service-level fallback API when workspace runtime is unavailable"
        path = $ApiPath
        apiType = "http"
        format = "openapi+json"
        value = ($openApi | ConvertTo-Json -Depth 20 -Compress)
        serviceUrl = $BackendUrl
        protocols = @("https")
        subscriptionRequired = $false
    }
}

Write-Log -Level "INFO" -Message "Creating/updating service-level API '$ApiId'"
Invoke-ApimRest -Method "PUT" -ChildPath ("apis/{0}" -f $ApiId) -Body $body | Out-Null

$serviceUrl = "https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.ApiManagement/service/{2}?api-version={3}" -f $SubscriptionId, $ResourceGroupName, $ApimName, $ApiVersion
$serviceJson = Invoke-AzCli -Args @("rest", "--method", "get", "--url", $serviceUrl, "-o", "json") -ReadOnly
$serviceObj = $serviceJson | ConvertFrom-Json
$gatewayUrl = $serviceObj.properties.gatewayUrl
if ([string]::IsNullOrWhiteSpace($gatewayUrl)) {
    $gatewayUrl = "https://$ApimName.azure-api.net"
}
$testUrl = $gatewayUrl.TrimEnd('/') + "/" + $ApiPath + "/seattle"

Write-Log -Level "INFO" -Message "Service-level fallback API ready."
Write-Output "SERVICE_API_ID=$ApiId"
Write-Output "TEST_URL=$testUrl"
Write-Output "LOG_FILE=$LogFile"
