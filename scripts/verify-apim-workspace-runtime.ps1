[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification='Parameters are consumed via helper functions and optional flows.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$ApimName,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceId,

    [Parameter()]
    [string]$ResourceGroupName,

    [Parameter()]
    [string]$ApiId,

    [Parameter()]
    [string]$ApiPath = "weather",

    [Parameter()]
    [string]$GatewayUrl,

    [Parameter()]
    [string]$ProbePath = "/weather/seattle",

    [Parameter()]
    [ValidateRange(1, 600)]
    [int]$HttpTimeoutSeconds = 30,

    [Parameter()]
    [int[]]$ExpectedStatusCodes = @(200),

    [Parameter()]
    [string]$ApiVersion = "2024-05-01",

    [Parameter()]
    [string]$LogDirectory = (Join-Path $PSScriptRoot "logs"),

    [Parameter()]
    [switch]$CollectDiagnostics,

    [Parameter()]
    [string]$DiagnosticsOutputPath
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
        [string[]]$Args
    )

    $displayArgs = $Args | ForEach-Object {
        if ($_ -match "\s") { '"' + $_ + '"' } else { $_ }
    }
    Write-Log -Level "DEBUG" -Message "Running command: az $($displayArgs -join ' ')"

    $output = & az @Args
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed: az $($displayArgs -join ' ')"
    }

    if ($null -eq $output) {
        return $null
    }

    return ($output -join "`n")
}

function Invoke-AzCliSafe {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Args
    )

    try {
        $text = Invoke-AzCli -Args $Args
        return [pscustomobject]@{
            Succeeded = $true
            Text = $text
            Error = $null
        }
    } catch {
        return [pscustomobject]@{
            Succeeded = $false
            Text = $null
            Error = $_.Exception.Message
        }
    }
}

function Get-ApimService {
    $json = Invoke-AzCli -Args @("apim", "list", "--query", "[?name=='$ApimName'] | [0]", "-o", "json")
    if (-not $json) {
        throw "Could not resolve APIM instance '$ApimName'."
    }

    $apim = $json | ConvertFrom-Json
    if (-not $apim) {
        throw "APIM instance '$ApimName' was not found in subscription '$SubscriptionId'."
    }

    return $apim
}

function Get-WorkspaceResource {
    param([Parameter(Mandatory = $true)][string]$EffectiveResourceGroup)

    $workspaceUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$EffectiveResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName/workspaces/$WorkspaceId"
    $json = Invoke-AzCli -Args @("rest", "--method", "get", "--url", $workspaceUrl, "--uri-parameters", "api-version=$ApiVersion", "-o", "json")
    if (-not $json) {
        throw "Workspace '$WorkspaceId' was not returned by ARM."
    }

    return ($json | ConvertFrom-Json)
}

function Test-WorkspaceApiResource {
    param(
        [Parameter(Mandatory = $true)]
        [string]$EffectiveResourceGroup,

        [Parameter(Mandatory = $true)]
        [string]$EffectiveApiId
    )

    $url = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$EffectiveResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName/workspaces/$WorkspaceId/apis/$EffectiveApiId"
    $json = Invoke-AzCli -Args @("rest", "--method", "get", "--url", $url, "--uri-parameters", "api-version=$ApiVersion", "-o", "json")
    if (-not $json) {
        throw "Workspace API '$EffectiveApiId' was not returned by ARM."
    }

    return ($json | ConvertFrom-Json)
}

function Get-ApimGatewayUrl {
    param([Parameter(Mandatory = $true)][string]$EffectiveResourceGroup)

    $resourceUrl = "https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.ApiManagement/service/{2}?api-version={3}" -f $SubscriptionId, $EffectiveResourceGroup, $ApimName, $ApiVersion
    $json = Invoke-AzCli -Args @("rest", "--method", "get", "--url", $resourceUrl, "-o", "json")
    if (-not $json) {
        throw "Unable to resolve APIM service details for '$ApimName'."
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

    throw "APIM gateway URL could not be resolved from service properties."
}

function Invoke-GatewayProbe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )

    $statusCode = $null
    $responseBody = $null
    $errorMessage = $null

    try {
        $response = Invoke-WebRequest -Uri $Uri -Method Get -TimeoutSec $TimeoutSeconds -UseBasicParsing -ErrorAction Stop
        $statusCode = [int]$response.StatusCode
        $responseBody = $response.Content
    } catch {
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $statusCode = [int]$_.Exception.Response.StatusCode
            $stream = $_.Exception.Response.GetResponseStream()
            if ($stream) {
                $reader = New-Object System.IO.StreamReader($stream)
                $responseBody = $reader.ReadToEnd()
                $reader.Close()
            }
        }
        $errorMessage = $_.Exception.Message
    }

    return [pscustomobject]@{
        StatusCode = $statusCode
        Body = $responseBody
        ErrorMessage = $errorMessage
    }
}

Test-ToolAvailable -Name "az"
Write-Log -Level "INFO" -Message "Run started. Log file: $LogFile"

Write-Log -Level "INFO" -Message "Selecting subscription"
Invoke-AzCli -Args @("account", "set", "--subscription", $SubscriptionId) | Out-Null

$apim = Get-ApimService
$effectiveResourceGroup = if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) { $apim.resourceGroup } else { $ResourceGroupName }
if ([string]::IsNullOrWhiteSpace($effectiveResourceGroup)) {
    throw "Could not determine APIM resource group."
}

$workspace = Get-WorkspaceResource -EffectiveResourceGroup $effectiveResourceGroup
Write-Log -Level "INFO" -Message "Workspace exists: $($workspace.id)"

if (-not [string]::IsNullOrWhiteSpace($ApiId)) {
    $workspaceApi = Test-WorkspaceApiResource -EffectiveResourceGroup $effectiveResourceGroup -EffectiveApiId $ApiId
    Write-Log -Level "INFO" -Message "Workspace API exists: $($workspaceApi.id)"

    if ([string]::IsNullOrWhiteSpace($ApiPath) -and $workspaceApi.properties.path) {
        $ApiPath = $workspaceApi.properties.path
    }
}

if ([string]::IsNullOrWhiteSpace($ApiPath)) {
    throw "ApiPath is required when ApiId is not supplied or API path cannot be resolved."
}

$effectiveGatewayUrl = if ([string]::IsNullOrWhiteSpace($GatewayUrl)) { Get-ApimGatewayUrl -EffectiveResourceGroup $effectiveResourceGroup } else { $GatewayUrl }
$normalizedProbePath = if ($ProbePath.StartsWith('/')) { $ProbePath } else { "/$ProbePath" }
$normalizedApiPath = $ApiPath.Trim('/')
$probeUrl = $effectiveGatewayUrl.TrimEnd('/') + "/" + $normalizedApiPath + $normalizedProbePath

Write-Log -Level "INFO" -Message "Gateway probe URL: $probeUrl"
$probe = Invoke-GatewayProbe -Uri $probeUrl -TimeoutSeconds $HttpTimeoutSeconds

$statusCodesText = ($ExpectedStatusCodes | ForEach-Object { $_.ToString() }) -join ","
$result = [pscustomobject]@{
    SubscriptionId = $SubscriptionId
    ResourceGroupName = $effectiveResourceGroup
    ApimName = $ApimName
    WorkspaceId = $WorkspaceId
    ApiId = $ApiId
    ApiPath = $normalizedApiPath
    GatewayUrl = $effectiveGatewayUrl
    ProbeUrl = $probeUrl
    StatusCode = $probe.StatusCode
    ExpectedStatusCodes = $ExpectedStatusCodes
    Passed = ($null -ne $probe.StatusCode -and ($ExpectedStatusCodes -contains [int]$probe.StatusCode))
    ProbeError = $probe.ErrorMessage
    ProbeBodyPreview = if ($probe.Body) { ($probe.Body.Substring(0, [Math]::Min(400, $probe.Body.Length))) } else { $null }
    LogFile = $LogFile
}

if ($CollectDiagnostics) {
    if ([string]::IsNullOrWhiteSpace($DiagnosticsOutputPath)) {
        $DiagnosticsOutputPath = Join-Path $LogDirectory ("$scriptName-report-$runId.json")
    }

    $apisListUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$effectiveResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName/workspaces/$WorkspaceId/apis"
    $apisList = Invoke-AzCliSafe -Args @("rest", "--method", "get", "--url", $apisListUrl, "--uri-parameters", "api-version=$ApiVersion", "-o", "json")
    $apisListObj = $null
    if ($apisList.Succeeded -and $apisList.Text) {
        $apisListObj = $apisList.Text | ConvertFrom-Json
    }

    $resolvedApi = $null
    if (-not [string]::IsNullOrWhiteSpace($ApiId) -and $workspaceApi) {
        $resolvedApi = $workspaceApi
    } elseif ($apisListObj -and $apisListObj.value) {
        $resolvedApi = $apisListObj.value | Where-Object { $_.properties.path -eq $normalizedApiPath } | Select-Object -First 1
    }

    $resolvedApiId = if ($resolvedApi) { $resolvedApi.name } else { $null }

    $operationsList = $null
    $operationsListObj = $null
    if (-not [string]::IsNullOrWhiteSpace($resolvedApiId)) {
        $operationsListUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$effectiveResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName/workspaces/$WorkspaceId/apis/$resolvedApiId/operations"
        $operationsList = Invoke-AzCliSafe -Args @("rest", "--method", "get", "--url", $operationsListUrl, "--uri-parameters", "api-version=$ApiVersion", "-o", "json")
        if ($operationsList.Succeeded -and $operationsList.Text) {
            $operationsListObj = $operationsList.Text | ConvertFrom-Json
        }
    }

    $productsListUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$effectiveResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName/workspaces/$WorkspaceId/products"
    $productsList = Invoke-AzCliSafe -Args @("rest", "--method", "get", "--url", $productsListUrl, "--uri-parameters", "api-version=$ApiVersion", "-o", "json")
    $productsListObj = $null
    if ($productsList.Succeeded -and $productsList.Text) {
        $productsListObj = $productsList.Text | ConvertFrom-Json
    }

    $apiProductLinks = @()
    if (-not [string]::IsNullOrWhiteSpace($resolvedApiId) -and $productsListObj -and $productsListObj.value) {
        foreach ($product in $productsListObj.value) {
            $productApiLinkPath = "products/{0}/apis/{1}" -f $product.name, $resolvedApiId
            $productApiLinkUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$effectiveResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName/workspaces/$WorkspaceId/$productApiLinkPath"
            $linkCheck = Invoke-AzCliSafe -Args @("rest", "--method", "get", "--url", $productApiLinkUrl, "--uri-parameters", "api-version=$ApiVersion", "-o", "json")
            $apiProductLinks += [pscustomobject]@{
                ProductId = $product.name
                ProductDisplayName = $product.properties.displayName
                LinkPath = $productApiLinkPath
                LinkExists = $linkCheck.Succeeded
                LinkError = $linkCheck.Error
            }
        }
    }

    $serviceResourceUrl = "https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.ApiManagement/service/{2}?api-version={3}" -f $SubscriptionId, $effectiveResourceGroup, $ApimName, $ApiVersion
    $serviceResource = Invoke-AzCliSafe -Args @("rest", "--method", "get", "--url", $serviceResourceUrl, "-o", "json")
    $serviceResourceObj = $null
    if ($serviceResource.Succeeded -and $serviceResource.Text) {
        $serviceResourceObj = $serviceResource.Text | ConvertFrom-Json
    }

    $productsItems = @()
    if ($productsListObj -and $productsListObj.value) {
        $productsItems = @($productsListObj.value | ForEach-Object {
            [pscustomobject]@{
                ProductId = $_.name
                DisplayName = $_.properties.displayName
                State = $_.properties.state
                SubscriptionRequired = $_.properties.subscriptionRequired
            }
        })
    }

    $diagnostics = [pscustomobject]@{
        GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        SubscriptionId = $SubscriptionId
        ResourceGroupName = $effectiveResourceGroup
        ApimName = $ApimName
        WorkspaceId = $WorkspaceId
        ApiVersion = $ApiVersion
        Gateway = [pscustomobject]@{
            GatewayUrl = $effectiveGatewayUrl
            ProbeUrl = $probeUrl
            ProbePath = $normalizedProbePath
            ExpectedStatusCodes = $ExpectedStatusCodes
            ActualStatusCode = $probe.StatusCode
            ProbeError = $probe.ErrorMessage
            ProbeBodyPreview = if ($probe.Body) { ($probe.Body.Substring(0, [Math]::Min(400, $probe.Body.Length))) } else { $null }
        }
        Workspace = [pscustomobject]@{
            Id = $workspace.id
            Name = $workspace.name
            DisplayName = $workspace.properties.displayName
            Description = $workspace.properties.description
        }
        Api = [pscustomobject]@{
            RequestedApiId = $ApiId
            RequestedApiPath = $normalizedApiPath
            ResolvedApiId = $resolvedApiId
            ResolvedApiPath = if ($resolvedApi) { $resolvedApi.properties.path } else { $null }
            ResolvedApiDisplayName = if ($resolvedApi) { $resolvedApi.properties.displayName } else { $null }
            ResolvedApiServiceUrl = if ($resolvedApi) { $resolvedApi.properties.serviceUrl } else { $null }
            TotalWorkspaceApis = if ($apisListObj -and $apisListObj.value) { $apisListObj.value.Count } else { $null }
            OperationsCount = if ($operationsListObj -and $operationsListObj.value) { $operationsListObj.value.Count } else { $null }
            Operations = if ($operationsListObj -and $operationsListObj.value) {
                $operationsListObj.value | ForEach-Object {
                    [pscustomobject]@{
                        Name = $_.name
                        DisplayName = $_.properties.displayName
                        Method = $_.properties.method
                        UrlTemplate = $_.properties.urlTemplate
                    }
                }
            } else { @() }
            LinkedProducts = $apiProductLinks
        }
        Products = [pscustomobject]@{
            TotalWorkspaceProducts = if ($productsListObj -and $productsListObj.value) { $productsListObj.value.Count } else { $null }
            Items = $productsItems
        }
        Service = [pscustomobject]@{
            Id = if ($serviceResourceObj) { $serviceResourceObj.id } else { $null }
            SkuName = if ($serviceResourceObj) { $serviceResourceObj.sku.name } else { $null }
            ProvisioningState = if ($serviceResourceObj) { $serviceResourceObj.properties.provisioningState } else { $null }
            PublicNetworkAccess = if ($serviceResourceObj) { $serviceResourceObj.properties.publicNetworkAccess } else { $null }
            GatewayUrl = if ($serviceResourceObj) { $serviceResourceObj.properties.gatewayUrl } else { $null }
        }
        Collection = [pscustomobject]@{
            ApisListSucceeded = $apisList.Succeeded
            ApisListError = $apisList.Error
            OperationsListSucceeded = if ($operationsList) { $operationsList.Succeeded } else { $null }
            OperationsListError = if ($operationsList) { $operationsList.Error } else { $null }
            ProductsListSucceeded = $productsList.Succeeded
            ProductsListError = $productsList.Error
            ServiceReadSucceeded = $serviceResource.Succeeded
            ServiceReadError = $serviceResource.Error
            LogFile = $LogFile
        }
    }

    $diagnosticsJson = $diagnostics | ConvertTo-Json -Depth 12
    Set-Content -Path $DiagnosticsOutputPath -Value $diagnosticsJson -Encoding UTF8
    Write-Log -Level "INFO" -Message "Diagnostics report written: $DiagnosticsOutputPath"
    $result | Add-Member -NotePropertyName DiagnosticsReportPath -NotePropertyValue $DiagnosticsOutputPath
}

$result | ConvertTo-Json -Depth 8

if (-not $result.Passed) {
    Write-Log -Level "ERROR" -Message "Runtime probe failed. Expected one of [$statusCodesText], got '$($probe.StatusCode)'."
    if ($probe.ErrorMessage) {
        Write-Log -Level "ERROR" -Message "Probe error: $($probe.ErrorMessage)"
    }
    exit 1
}

Write-Log -Level "INFO" -Message "Runtime probe passed with status code $($probe.StatusCode)."
Write-Output "LOG_FILE=$LogFile"
