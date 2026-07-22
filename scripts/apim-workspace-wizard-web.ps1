[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Local helper saves web wizard preferences to a local JSON file and is not an exported cmdlet.')]
[CmdletBinding()]
param(
    [int]$Port = 5077,
    [switch]$NoBrowser
)

$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $PSCommandPath
$webRoot = Join-Path $scriptRoot "web"
$manageScriptPath = Join-Path $scriptRoot "manage-apim-workspace.ps1"
$verifyRuntimeScriptPath = Join-Path $scriptRoot "verify-apim-workspace-runtime.ps1"
$diagnoseGatewayScriptPath = Join-Path $scriptRoot "diagnose-apim-workspace-gateway.ps1"
$weatherScriptPath = Join-Path $scriptRoot "create-weather-workspace-api.ps1"
$echoScriptPath = Join-Path $scriptRoot "create-echo-workspace-api.ps1"
$settingsPath = Join-Path $scriptRoot ".apim-workspace-wizard-web.settings.json"

foreach ($requiredPath in @($webRoot, $manageScriptPath, $verifyRuntimeScriptPath, $diagnoseGatewayScriptPath, $weatherScriptPath, $echoScriptPath)) {
    if (-not (Test-Path $requiredPath)) {
        throw "Required path not found: $requiredPath"
    }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI (az) is required and was not found in PATH."
}

function Read-RequestBody {
    param([System.Net.HttpListenerRequest]$Request)

    $reader = New-Object System.IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
    try {
        return $reader.ReadToEnd()
    } finally {
        $reader.Dispose()
    }
}

function Send-Json {
    param(
        [System.Net.HttpListenerResponse]$Response,
        [object]$Payload,
        [int]$StatusCode = 200,
        [int]$JsonDepth = 10
    )

    $json = $Payload | ConvertTo-Json -Depth $JsonDepth
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)

    $Response.StatusCode = $StatusCode
    $Response.ContentType = "application/json; charset=utf-8"
    $Response.ContentEncoding = [System.Text.Encoding]::UTF8
    $Response.Headers.Add("Cache-Control", "no-store")
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

function Send-Text {
    param(
        [System.Net.HttpListenerResponse]$Response,
        [string]$Content,
        [string]$ContentType = "text/plain; charset=utf-8",
        [int]$StatusCode = 200
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Content)

    $Response.StatusCode = $StatusCode
    $Response.ContentType = $ContentType
    $Response.ContentEncoding = [System.Text.Encoding]::UTF8
    $Response.Headers.Add("Cache-Control", "no-store")
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

function Send-File {
    param(
        [System.Net.HttpListenerResponse]$Response,
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        Send-Text -Response $Response -Content "Not Found" -StatusCode 404
        return
    }

    $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    $contentType = switch ($extension) {
        ".html" { "text/html; charset=utf-8" }
        ".css" { "text/css; charset=utf-8" }
        ".js" { "application/javascript; charset=utf-8" }
        ".svg" { "image/svg+xml" }
        ".json" { "application/json; charset=utf-8" }
        default { "application/octet-stream" }
    }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $Response.StatusCode = 200
    $Response.ContentType = $contentType
    $Response.ContentLength64 = $bytes.Length
    $Response.Headers.Add("Cache-Control", "no-store")
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

function Invoke-AzJson {
    param([string[]]$CliArgs)

    $output = & az @CliArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        $message = ($output | ForEach-Object { $_.ToString() }) -join "`n"
        throw "Azure CLI command failed: az $($CliArgs -join ' ')`n$message"
    }

    if (-not $output) {
        return $null
    }

    return (($output -join "`n") | ConvertFrom-Json)
}

function Invoke-AzRaw {
    param([string[]]$CliArgs)

    $output = @()
    $exitCode = 0

    try {
        $output = & az @CliArgs 2>&1
        $exitCode = $LASTEXITCODE
    } catch {
        $exitCode = 1
        if ($_.Exception -and -not [string]::IsNullOrWhiteSpace([string]$_.Exception.Message)) {
            $output += [string]$_.Exception.Message
        } else {
            $output += "Azure CLI command failed with an unknown error."
        }
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = @($output | ForEach-Object { $_.ToString() })
    }
}

function Invoke-PowerShellScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $true)]
        [hashtable]$NamedArgs
    )

    $outputLines = @()
    $success = $true

    try {
        $result = & $ScriptPath @NamedArgs 2>&1
        if ($result) {
            $outputLines = @($result | ForEach-Object { $_.ToString() })
        }

        if ($LASTEXITCODE -ne 0) {
            $success = $false
        }
    } catch {
        $success = $false
        $outputLines += "ERROR: $($_.Exception.Message)"
    }

    return [pscustomobject]@{
        Success = $success
        ExitCode = if ($success) { 0 } else { 1 }
        Output = $outputLines
    }
}

function Convert-ArgToTraceLine {
    param([hashtable]$NamedArgs)

    $lines = @()
    foreach ($entry in ($NamedArgs.GetEnumerator() | Sort-Object Name)) {
        $valueText = ""
        if ($entry.Value -is [System.Array]) {
            $valueText = ($entry.Value | ForEach-Object { $_.ToString() }) -join ","
        } else {
            $valueText = [string]$entry.Value
        }

        $lines += ("arg.{0} = {1}" -f $entry.Key, $valueText)
    }

    return $lines
}

function Get-ApimGatewayUrl {
    param(
        [string]$SubscriptionId,
        [string]$ResourceGroupName,
        [string]$ApimName
    )

    try {
        $serviceUrl = "https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.ApiManagement/service/{2}?api-version=2024-05-01" -f $SubscriptionId, $ResourceGroupName, $ApimName
        $json = Invoke-AzJson -CliArgs @("rest", "--method", "get", "--url", $serviceUrl, "-o", "json")
        if ($json.properties.gatewayUrl) {
            return [string]$json.properties.gatewayUrl
        }
    } catch {
        return $null
    }

    return $null
}

function Get-AbsoluteManagementUrl {
    param([string]$ResourceIdOrUrl)

    if ([string]::IsNullOrWhiteSpace($ResourceIdOrUrl)) {
        return $null
    }

    $value = [string]$ResourceIdOrUrl
    if ($value -match '^https?://') {
        return $value
    }

    if (-not $value.StartsWith('/')) {
        $value = '/' + $value
    }

    return ('https://management.azure.com' + $value)
}

function Get-PortalResourceUrl {
    param([string]$ResourceIdOrUrl)

    if ([string]::IsNullOrWhiteSpace($ResourceIdOrUrl)) {
        return $null
    }

    $resourceId = [string]$ResourceIdOrUrl
    if ($resourceId -match '^https?://management\.azure\.com') {
        $resourceId = ($resourceId -replace '^https?://management\.azure\.com', '')
    }

    if (-not $resourceId.StartsWith('/')) {
        $resourceId = '/' + $resourceId
    }

    return ('https://portal.azure.com/#resource' + $resourceId + '/overview')
}

function Get-RunUrlInfo {
    param(
        [object]$Body,
        [object]$SampleResult
    )

    $workspaceResourceId = "/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.ApiManagement/service/{2}/workspaces/{3}" -f $Body.subscriptionId, $Body.apimResourceGroup, $Body.apimName, $Body.workspaceId
    $workspaceArmUrl = (Get-AbsoluteManagementUrl -ResourceIdOrUrl $workspaceResourceId) + "?api-version=2024-05-01"
    $workspacePortalUrl = Get-PortalResourceUrl -ResourceIdOrUrl $workspaceResourceId
    $gatewayUrl = $null

    # Prefer values emitted by sample deployment scripts when available.
    if ($SampleResult -and $SampleResult.Output) {
        foreach ($line in $SampleResult.Output) {
            if ($line -like "APIM_GW_URL=*") {
                $gatewayUrl = ($line -replace "^APIM_GW_URL=", "").Trim()
                break
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($gatewayUrl) -and $Body.gatewayUrl) {
        $gatewayUrl = [string]$Body.gatewayUrl
    }

    if ([string]::IsNullOrWhiteSpace($gatewayUrl)) {
        $gatewayUrl = Get-ApimGatewayUrl -SubscriptionId $Body.subscriptionId -ResourceGroupName $Body.apimResourceGroup -ApimName $Body.apimName
    }

    $runtimeUrl = $null
    if (-not [string]::IsNullOrWhiteSpace($gatewayUrl)) {
        if ($Body.mode -eq "verify-runtime" -and $Body.apiPath -and $Body.probePath) {
            $normalizedProbe = [string]$Body.probePath
            if (-not $normalizedProbe.StartsWith("/")) {
                $normalizedProbe = "/" + $normalizedProbe
            }

            $runtimeUrl = ($gatewayUrl.TrimEnd('/') + "/" + [string]$Body.apiPath + $normalizedProbe)
        } elseif ($Body.deploySampleApi -and $Body.sampleProfile -eq "Echo API") {
            $runtimeUrl = ($gatewayUrl.TrimEnd('/') + "/echo/get")
        } elseif ($Body.deploySampleApi) {
            $runtimeUrl = ($gatewayUrl.TrimEnd('/') + "/weather/weather/seattle")
        }

        if ([string]::IsNullOrWhiteSpace($runtimeUrl)) {
            $runtimeUrl = $gatewayUrl
        }
    }

    return [pscustomobject]@{
        WorkspacePortalUrl = $workspacePortalUrl
        WorkspaceArmUrl = $workspaceArmUrl
        GatewayUrl = $gatewayUrl
        RuntimeUrl = $runtimeUrl
    }
}

function Get-WorkspaceInventory {
    param(
        [string]$SubscriptionId,
        [string]$ResourceGroupName,
        [string]$ApimName
    )

    $url = "https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.ApiManagement/service/{2}/workspaces?api-version=2024-05-01" -f $SubscriptionId, $ResourceGroupName, $ApimName
    $json = Invoke-AzJson -CliArgs @("rest", "--method", "get", "--url", $url, "-o", "json")
    $items = @()

    if ($json.value) {
        foreach ($entry in $json.value) {
            $workspaceId = [string]$entry.name
            $associatedGateways = $null
            $resourceId = [string]$entry.id
            if ([string]::IsNullOrWhiteSpace($resourceId)) {
                $resourceId = "/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.ApiManagement/service/{2}/workspaces/{3}" -f $SubscriptionId, $ResourceGroupName, $ApimName, $workspaceId
            }

            $armUrl = Get-AbsoluteManagementUrl -ResourceIdOrUrl $resourceId
            if ([string]::IsNullOrWhiteSpace($armUrl)) {
                $armUrl = "https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.ApiManagement/service/{2}/workspaces/{3}" -f $SubscriptionId, $ResourceGroupName, $ApimName, $workspaceId
            }

            $portalUrl = Get-PortalResourceUrl -ResourceIdOrUrl $resourceId

            $state = $null
            $stateSource = $null
            foreach ($candidate in @(
                [string]$entry.properties.provisioningState,
                [string]$entry.properties.state,
                [string]$entry.properties.workspaceState,
                [string]$entry.provisioningState,
                [string]$entry.state
            )) {
                if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                    $state = $candidate
                    break
                }
            }

            if (-not [string]::IsNullOrWhiteSpace([string]$entry.properties.provisioningState)) {
                $stateSource = "list.properties.provisioningState"
            } elseif (-not [string]::IsNullOrWhiteSpace([string]$entry.properties.state)) {
                $stateSource = "list.properties.state"
            } elseif (-not [string]::IsNullOrWhiteSpace([string]$entry.properties.workspaceState)) {
                $stateSource = "list.properties.workspaceState"
            } elseif (-not [string]::IsNullOrWhiteSpace([string]$entry.provisioningState)) {
                $stateSource = "list.provisioningState"
            } elseif (-not [string]::IsNullOrWhiteSpace([string]$entry.state)) {
                $stateSource = "list.state"
            }

            if ([string]::IsNullOrWhiteSpace($state)) {
                try {
                    $detailUrl = "https://management.azure.com{0}?api-version=2024-05-01" -f $resourceId
                    $detail = Invoke-AzJson -CliArgs @("rest", "--method", "get", "--url", $detailUrl, "-o", "json")

                    foreach ($candidate in @(
                        [string]$detail.properties.provisioningState,
                        [string]$detail.properties.state,
                        [string]$detail.properties.workspaceState,
                        [string]$detail.provisioningState,
                        [string]$detail.state
                    )) {
                        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                            $state = $candidate
                            break
                        }
                    }

                    if (-not [string]::IsNullOrWhiteSpace([string]$detail.properties.provisioningState)) {
                        $stateSource = "detail.properties.provisioningState"
                    } elseif (-not [string]::IsNullOrWhiteSpace([string]$detail.properties.state)) {
                        $stateSource = "detail.properties.state"
                    } elseif (-not [string]::IsNullOrWhiteSpace([string]$detail.properties.workspaceState)) {
                        $stateSource = "detail.properties.workspaceState"
                    } elseif (-not [string]::IsNullOrWhiteSpace([string]$detail.provisioningState)) {
                        $stateSource = "detail.provisioningState"
                    } elseif (-not [string]::IsNullOrWhiteSpace([string]$detail.state)) {
                        $stateSource = "detail.state"
                    }

                    $gateways = @()
                    if ($detail.properties -and $detail.properties.gateways) {
                        $gateways = @($detail.properties.gateways)
                    } elseif ($detail.properties -and $detail.properties.gatewayIds) {
                        $gateways = @($detail.properties.gatewayIds)
                    } elseif ($detail.properties -and $detail.properties.associatedGateways) {
                        $gateways = @($detail.properties.associatedGateways)
                    }

                    if ($gateways.Count -gt 0) {
                        $associatedGateways = ($gateways | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ", "
                    }
                } catch {
                    # Keep unknown state if the detail request fails.
                }
            }

            if ([string]::IsNullOrWhiteSpace($state)) {
                $state = "unknown"
                if ([string]::IsNullOrWhiteSpace($stateSource)) {
                    $stateSource = "not-returned-by-arm"
                }
            }

            if (-not $associatedGateways) {
                $listGateways = @()
                if ($entry.properties -and $entry.properties.gateways) {
                    $listGateways = @($entry.properties.gateways)
                } elseif ($entry.properties -and $entry.properties.gatewayIds) {
                    $listGateways = @($entry.properties.gatewayIds)
                } elseif ($entry.properties -and $entry.properties.associatedGateways) {
                    $listGateways = @($entry.properties.associatedGateways)
                }

                if ($listGateways.Count -gt 0) {
                    $associatedGateways = ($listGateways | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ", "
                }
            }

            if (-not $associatedGateways) {
                $associatedGateways = "not-returned-by-arm"
            }

            $assoc = Get-WorkspaceAssociationSnapshot -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -ApimName $ApimName -WorkspaceId $workspaceId

            if ($assoc.WorkspaceGatewaysText -and $assoc.WorkspaceGatewaysText -ne "not-returned-by-arm") {
                $associatedGateways = $assoc.WorkspaceGatewaysText
            } elseif ($assoc.DefaultGatewayAssociated -eq "yes" -and $associatedGateways -eq "not-returned-by-arm") {
                # Some SKUs/API versions do not return workspace gateway list; infer default gateway path from serveOn.
                $associatedGateways = "default-shared-gateway-inferred"
            }

            $items += [pscustomobject]@{
                id = $workspaceId
                name = $workspaceId
                displayName = [string]$entry.properties.displayName
                state = $state
                stateSource = $stateSource
                associatedGateways = $associatedGateways
                defaultGatewayAssociated = $assoc.DefaultGatewayAssociated
                defaultGatewayAssociationSource = $assoc.DefaultGatewayAssociationSource
                apiCount = $assoc.ApiCount
                apiNames = $assoc.ApiNames
                associationCheckError = $assoc.Error
                portalUrl = $portalUrl
                armUrl = $armUrl
            }
        }
    }

    return $items
}

function Convert-JsonTextOrNull {
    param([string[]]$Lines)

    if (-not $Lines) {
        return $null
    }

    $text = ($Lines -join "`n")
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    try {
        return ($text | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Get-WorkspaceAssociationSnapshot {
    param(
        [string]$SubscriptionId,
        [string]$ResourceGroupName,
        [string]$ApimName,
        [string]$WorkspaceId
    )

    $result = [pscustomobject]@{
        DefaultGatewayAssociated = "unknown"
        DefaultGatewayAssociationSource = "not-returned-by-arm"
        WorkspaceGatewaysText = "not-returned-by-arm"
        ApiCount = $null
        ApiNames = @()
        Error = $null
    }

    $workspaceUrlPreview = "https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.ApiManagement/service/{2}/workspaces/{3}?api-version=2024-10-01-preview" -f $SubscriptionId, $ResourceGroupName, $ApimName, $WorkspaceId
    $workspaceRaw = Invoke-AzRaw -CliArgs @("rest", "--method", "get", "--url", $workspaceUrlPreview, "-o", "json")
    $workspaceObj = $null
    if ($workspaceRaw.ExitCode -eq 0) {
        $workspaceObj = Convert-JsonTextOrNull -Lines $workspaceRaw.Output
    }

    if ($workspaceObj -and -not [string]::IsNullOrWhiteSpace([string]$workspaceObj.properties.serveOn)) {
        $serveOn = [string]$workspaceObj.properties.serveOn
        if ($serveOn -match "workspaceAndDefault") {
            $result.DefaultGatewayAssociated = "yes"
        } else {
            $result.DefaultGatewayAssociated = "no"
        }

        $result.DefaultGatewayAssociationSource = "workspace.properties.serveOn"
    }

    $gatewaysUrlPreview = "https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.ApiManagement/service/{2}/workspaces/{3}/gateways?api-version=2024-10-01-preview" -f $SubscriptionId, $ResourceGroupName, $ApimName, $WorkspaceId
    $gatewaysRaw = Invoke-AzRaw -CliArgs @("rest", "--method", "get", "--url", $gatewaysUrlPreview, "-o", "json")
    if ($gatewaysRaw.ExitCode -eq 0) {
        $gatewaysObj = Convert-JsonTextOrNull -Lines $gatewaysRaw.Output
        if ($gatewaysObj -and $gatewaysObj.value -is [System.Array]) {
            $gatewayNames = @($gatewaysObj.value | ForEach-Object {
                if ($_.name) { [string]$_.name } elseif ($_.id) { [string]$_.id } else { $null }
            } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

            if ($gatewayNames.Count -gt 0) {
                $result.WorkspaceGatewaysText = ($gatewayNames -join ", ")
            } else {
                $result.WorkspaceGatewaysText = "none"
            }
        }
    }

    $apisUrlPreview = "https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.ApiManagement/service/{2}/workspaces/{3}/apis?api-version=2024-10-01-preview" -f $SubscriptionId, $ResourceGroupName, $ApimName, $WorkspaceId
    $apisRaw = Invoke-AzRaw -CliArgs @("rest", "--method", "get", "--url", $apisUrlPreview, "-o", "json")
    if ($apisRaw.ExitCode -eq 0) {
        $apisObj = Convert-JsonTextOrNull -Lines $apisRaw.Output
        if ($apisObj -and $apisObj.value -is [System.Array]) {
            $result.ApiCount = @($apisObj.value).Count
            $result.ApiNames = @($apisObj.value | ForEach-Object {
                if ($_.name) { [string]$_.name } elseif ($_.properties.displayName) { [string]$_.properties.displayName } else { $null }
            } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
    }

    if ($workspaceRaw.ExitCode -ne 0 -or $gatewaysRaw.ExitCode -ne 0 -or $apisRaw.ExitCode -ne 0) {
        $result.Error = "One or more preview association endpoints did not return data."
    }

    return $result
}

function Set-WorkspaceDefaultGatewayAssociation {
    param(
        [string]$SubscriptionId,
        [string]$ResourceGroupName,
        [string]$ApimName,
        [string]$WorkspaceId
    )

    $apiVersions = @("2024-10-01-preview", "2024-05-01")
    $workspaceObj = $null

    foreach ($apiVersion in $apiVersions) {
        $getUrl = "https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.ApiManagement/service/{2}/workspaces/{3}?api-version={4}" -f $SubscriptionId, $ResourceGroupName, $ApimName, $WorkspaceId, $apiVersion
        $getRaw = Invoke-AzRaw -CliArgs @("rest", "--method", "get", "--url", $getUrl, "-o", "json")
        if ($getRaw.ExitCode -eq 0) {
            $workspaceObj = Convert-JsonTextOrNull -Lines $getRaw.Output
            if ($workspaceObj) { break }
        }
    }

    if (-not $workspaceObj) {
        throw "Could not read workspace '$WorkspaceId' before association update."
    }

    $displayName = [string]$workspaceObj.properties.displayName
    if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = $WorkspaceId }
    $description = [string]$workspaceObj.properties.description

    $payload = [pscustomobject]@{
        properties = [pscustomobject]@{
            displayName = $displayName
            description = $description
            serveOn = "workspaceAndDefault"
        }
    } | ConvertTo-Json -Depth 10 -Compress

    $bodyFile = Join-Path $env:TEMP ("apim-workspace-assoc-" + [guid]::NewGuid().ToString() + ".json")
    Set-Content -Path $bodyFile -Value $payload -Encoding UTF8

    try {
        $attempts = @()
        foreach ($apiVersion in $apiVersions) {
            $putUrl = "https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.ApiManagement/service/{2}/workspaces/{3}?api-version={4}" -f $SubscriptionId, $ResourceGroupName, $ApimName, $WorkspaceId, $apiVersion
            $putRaw = Invoke-AzRaw -CliArgs @("rest", "--method", "put", "--url", $putUrl, "--headers", "Content-Type=application/json", "--body", "@$bodyFile", "-o", "json")
            $attempts += [pscustomobject]@{ ApiVersion = $apiVersion; ExitCode = $putRaw.ExitCode; Output = $putRaw.Output }
            if ($putRaw.ExitCode -eq 0) {
                return [pscustomobject]@{ Success = $true; ApiVersion = $apiVersion; Attempts = $attempts }
            }
        }

        $messages = @($attempts | ForEach-Object { "api-version={0}, exitCode={1}" -f $_.ApiVersion, $_.ExitCode }) -join "; "
        throw "Failed to set serveOn=workspaceAndDefault for workspace '$WorkspaceId'. Attempts: $messages"
    } finally {
        if (Test-Path $bodyFile) {
            Remove-Item -Path $bodyFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Remove-WorkspaceById {
    param(
        [string]$SubscriptionId,
        [string]$ResourceGroupName,
        [string]$ApimName,
        [string]$WorkspaceId
    )

    $url = "https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.ApiManagement/service/{2}/workspaces/{3}?api-version=2024-05-01" -f $SubscriptionId, $ResourceGroupName, $ApimName, $WorkspaceId
    $result = Invoke-AzRaw -CliArgs @("rest", "--method", "delete", "--url", $url)
    if ($result.ExitCode -ne 0) {
        $message = ($result.Output -join "`n")
        throw "Workspace delete failed for '$WorkspaceId'. $message"
    }
}

function Invoke-AutoVerifyRuntime {
    param(
        [object]$Body,
        [string]$GatewayUrlOverride
    )

    $timeoutSeconds = [int]$Body.autoTimeoutSeconds
    if ($timeoutSeconds -le 0) { $timeoutSeconds = 900 }

    $retrySeconds = [int]$Body.autoRetryIntervalSeconds
    if ($retrySeconds -le 0) { $retrySeconds = 20 }

    $apiPath = [string]$Body.autoApiPath
    if ([string]::IsNullOrWhiteSpace($apiPath)) { $apiPath = "weather" }

    $probePath = [string]$Body.autoProbePath
    if ([string]::IsNullOrWhiteSpace($probePath)) { $probePath = "/weather/seattle" }

    $statusText = [string]$Body.autoExpectedStatusCodes
    if ([string]::IsNullOrWhiteSpace($statusText)) { $statusText = "200" }

    $codes = @($statusText -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $expectedCodes = @()
    foreach ($code in $codes) {
        $parsed = 0
        if (-not [int]::TryParse($code, [ref]$parsed)) {
            throw "Invalid autoExpectedStatusCodes value '$code'."
        }
        $expectedCodes += $parsed
    }

    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    $attempt = 0
    $allOutput = @()
    $lastResult = $null

    while ((Get-Date) -lt $deadline) {
        $attempt++
        $allOutput += ("Auto verify-runtime attempt {0} (timeout={1}s, retry={2}s)" -f $attempt, $timeoutSeconds, $retrySeconds)

        $verifyArgs = @{
            SubscriptionId = [string]$Body.subscriptionId
            ResourceGroupName = [string]$Body.apimResourceGroup
            ApimName = [string]$Body.apimName
            WorkspaceId = [string]$Body.workspaceId
            ApiPath = $apiPath
            ProbePath = $probePath
            ExpectedStatusCodes = $expectedCodes
        }

        if (-not [string]::IsNullOrWhiteSpace($GatewayUrlOverride)) {
            $verifyArgs["GatewayUrl"] = $GatewayUrlOverride
        }

        $lastResult = Invoke-PowerShellScript -ScriptPath $verifyRuntimeScriptPath -NamedArgs $verifyArgs
        if ($lastResult.Output) {
            foreach ($line in $lastResult.Output) {
                $allOutput += ("[attempt {0}] {1}" -f $attempt, $line)
            }
        }

        if ($lastResult.Success) {
            return [pscustomobject]@{
                Success = $true
                Attempts = $attempt
                Output = $allOutput
                ExitCode = 0
            }
        }

        if ((Get-Date).AddSeconds($retrySeconds) -ge $deadline) {
            break
        }

        $allOutput += ("Auto verify-runtime not ready; retrying in {0}s..." -f $retrySeconds)
        Start-Sleep -Seconds $retrySeconds
    }

    if ($lastResult -and $lastResult.Output) {
        $allOutput += "Auto verify-runtime timed out before success."
    }

    return [pscustomobject]@{
        Success = $false
        Attempts = $attempt
        Output = $allOutput
        ExitCode = 1
    }
}

function Invoke-RuntimeQuickProbe {
    param(
        [string]$Url,
        [int]$TimeoutSeconds = 20
    )

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return [pscustomobject]@{
            Success = $false
            StatusCode = $null
            Error = "Runtime URL is empty."
        }
    }

    try {
        $resp = Invoke-WebRequest -Uri $Url -Method Get -TimeoutSec $TimeoutSeconds -UseBasicParsing -ErrorAction Stop
        return [pscustomobject]@{
            Success = $true
            StatusCode = [int]$resp.StatusCode
            Error = $null
        }
    } catch {
        $status = $null
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $status = [int]$_.Exception.Response.StatusCode
        }

        return [pscustomobject]@{
            Success = $false
            StatusCode = $status
            Error = $_.Exception.Message
        }
    }
}

function Get-WebSettingState {
    if (-not (Test-Path $settingsPath)) {
        return $null
    }

    try {
        $raw = Get-Content -Path $settingsPath -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $null
        }

        return ($raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Set-WebSettingState {
    param([object]$Body)

    $settings = [pscustomobject]@{
        SubscriptionId = $Body.subscriptionId
        ApimName = $Body.apimName
        Mode = $Body.mode
        WorkspaceId = $Body.workspaceId
        DisplayName = $Body.displayName
        Description = $Body.description
        NetworkResourceGroup = $Body.networkResourceGroup
        Location = $Body.location
        NetworkMode = $Body.networkMode
        SkipWorkspaceCreate = [bool]$Body.skipWorkspaceCreate
        StrictVerify = [bool]$Body.strictVerify
        ApiPath = $Body.apiPath
        ProbePath = $Body.probePath
        ExpectedStatusCodes = $Body.expectedStatusCodes
        GatewayUrl = $Body.gatewayUrl
        CollectDiagnostics = [bool]$Body.collectDiagnostics
        DiagnosticsOutputPath = $Body.diagnosticsOutputPath
        WhatIfOnly = [bool]$Body.whatIfOnly
        DeploySampleApi = [bool]$Body.deploySampleApi
        SampleProfile = $Body.sampleProfile
        CreateSampleProduct = [bool]$Body.createSampleProduct
        SampleBackendUrl = $Body.sampleBackendUrl
        AutoVerifyRuntime = [bool]$Body.autoVerifyRuntime
        AutoApiPath = $Body.autoApiPath
        AutoProbePath = $Body.autoProbePath
        AutoExpectedStatusCodes = $Body.autoExpectedStatusCodes
        AutoRetryIntervalSeconds = [int]$Body.autoRetryIntervalSeconds
        AutoTimeoutSeconds = [int]$Body.autoTimeoutSeconds
    }

    $settings | ConvertTo-Json -Depth 10 | Set-Content -Path $settingsPath -Encoding UTF8
}

$listener = New-Object System.Net.HttpListener
$prefix = "http://localhost:$Port/"
$listener.Prefixes.Add($prefix)
$listener.Start()

Write-Output "APIM web wizard is running at $prefix"
Write-Output "Press Ctrl+C to stop."

if (-not $NoBrowser) {
    Start-Process $prefix | Out-Null
}

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response

        try {
            $path = $request.Url.AbsolutePath
            $method = $request.HttpMethod.ToUpperInvariant()

            if ($method -eq "GET" -and $path -eq "/") {
                Send-File -Response $response -Path (Join-Path $webRoot "index.html")
                continue
            }

            if ($method -eq "GET" -and $path -eq "/styles.css") {
                Send-File -Response $response -Path (Join-Path $webRoot "styles.css")
                continue
            }

            if ($method -eq "GET" -and $path -eq "/app.js") {
                Send-File -Response $response -Path (Join-Path $webRoot "app.js")
                continue
            }

            if ($method -eq "GET" -and $path -eq "/favicon.svg") {
                Send-File -Response $response -Path (Join-Path $webRoot "favicon.svg")
                continue
            }

            if ($method -eq "GET" -and $path -eq "/api/health") {
                Send-Json -Response $response -Payload @{ ok = $true; status = "ready" }
                continue
            }

            if ($method -eq "GET" -and $path -eq "/api/settings") {
                Send-Json -Response $response -Payload @{ ok = $true; settings = (Get-WebSettingState) }
                continue
            }

            if ($method -eq "POST" -and $path -eq "/api/reset-settings") {
                if (Test-Path $settingsPath) {
                    Remove-Item -Path $settingsPath -Force -ErrorAction Stop
                }

                Send-Json -Response $response -Payload @{ ok = $true }
                continue
            }

            if ($method -eq "GET" -and $path -eq "/api/subscriptions") {
                $subs = Invoke-AzJson -CliArgs @("account", "list", "-o", "json")
                Send-Json -Response $response -Payload @{ ok = $true; subscriptions = @($subs) }
                continue
            }

            if ($method -eq "POST" -and $path -eq "/api/apim") {
                $bodyText = Read-RequestBody -Request $request
                $body = if ([string]::IsNullOrWhiteSpace($bodyText)) { @{} } else { $bodyText | ConvertFrom-Json }

                if (-not $body.subscriptionId) {
                    throw "subscriptionId is required."
                }

                & az account set --subscription $body.subscriptionId | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to select subscription $($body.subscriptionId)."
                }

                $services = Invoke-AzJson -CliArgs @("apim", "list", "-o", "json")
                Send-Json -Response $response -Payload @{ ok = $true; services = @($services) }
                continue
            }

            if ($method -eq "POST" -and $path -eq "/api/workspaces/list") {
                $bodyText = Read-RequestBody -Request $request
                $body = if ([string]::IsNullOrWhiteSpace($bodyText)) { @{} } else { $bodyText | ConvertFrom-Json }

                if (-not $body.subscriptionId) { throw "subscriptionId is required." }
                if (-not $body.resourceGroupName) { throw "resourceGroupName is required." }
                if (-not $body.apimName) { throw "apimName is required." }

                & az account set --subscription $body.subscriptionId | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to select subscription $($body.subscriptionId)."
                }

                $items = Get-WorkspaceInventory -SubscriptionId $body.subscriptionId -ResourceGroupName $body.resourceGroupName -ApimName $body.apimName
                Send-Json -Response $response -Payload @{ ok = $true; workspaces = @($items) }
                continue
            }

            if ($method -eq "POST" -and $path -eq "/api/workspaces/delete") {
                $bodyText = Read-RequestBody -Request $request
                $body = if ([string]::IsNullOrWhiteSpace($bodyText)) { @{} } else { $bodyText | ConvertFrom-Json }

                if (-not $body.subscriptionId) { throw "subscriptionId is required." }
                if (-not $body.resourceGroupName) { throw "resourceGroupName is required." }
                if (-not $body.apimName) { throw "apimName is required." }
                if (-not $body.workspaceId) { throw "workspaceId is required." }

                & az account set --subscription $body.subscriptionId | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to select subscription $($body.subscriptionId)."
                }

                Remove-WorkspaceById -SubscriptionId $body.subscriptionId -ResourceGroupName $body.resourceGroupName -ApimName $body.apimName -WorkspaceId $body.workspaceId
                Send-Json -Response $response -Payload @{ ok = $true }
                continue
            }

            if ($method -eq "POST" -and $path -eq "/api/workspaces/associate-default") {
                $bodyText = Read-RequestBody -Request $request
                $body = if ([string]::IsNullOrWhiteSpace($bodyText)) { @{} } else { $bodyText | ConvertFrom-Json }

                if (-not $body.subscriptionId) { throw "subscriptionId is required." }
                if (-not $body.resourceGroupName) { throw "resourceGroupName is required." }
                if (-not $body.apimName) { throw "apimName is required." }
                if (-not $body.workspaceId) { throw "workspaceId is required." }

                & az account set --subscription $body.subscriptionId | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to select subscription $($body.subscriptionId)."
                }

                $serverOutput = @()
                $serverOutput += "Default gateway association request received."
                $serverOutput += ("WorkspaceId: {0}" -f [string]$body.workspaceId)

                $setResult = Set-WorkspaceDefaultGatewayAssociation -SubscriptionId $body.subscriptionId -ResourceGroupName $body.resourceGroupName -ApimName $body.apimName -WorkspaceId $body.workspaceId
                $serverOutput += ("Association update completed. Success={0} ApiVersion={1}" -f $setResult.Success, $setResult.ApiVersion)

                $assoc = Get-WorkspaceAssociationSnapshot -SubscriptionId $body.subscriptionId -ResourceGroupName $body.resourceGroupName -ApimName $body.apimName -WorkspaceId $body.workspaceId
                $serverOutput += ("DefaultGatewayAssociated={0} Source={1}" -f $assoc.DefaultGatewayAssociated, $assoc.DefaultGatewayAssociationSource)
                $serverOutput += ("WorkspaceGateways={0}" -f $assoc.WorkspaceGatewaysText)
                if ($assoc.ApiCount -ne $null) {
                    $serverOutput += ("WorkspaceApiCount={0}" -f $assoc.ApiCount)
                }

                Send-Json -Response $response -Payload @{
                    ok = $true
                    serverOutput = $serverOutput
                    association = $assoc
                }
                continue
            }

            if ($method -eq "POST" -and $path -eq "/api/workspaces/check-association") {
                $bodyText = Read-RequestBody -Request $request
                $body = if ([string]::IsNullOrWhiteSpace($bodyText)) { @{} } else { $bodyText | ConvertFrom-Json }

                if (-not $body.subscriptionId) { throw "subscriptionId is required." }
                if (-not $body.resourceGroupName) { throw "resourceGroupName is required." }
                if (-not $body.apimName) { throw "apimName is required." }
                if (-not $body.workspaceId) { throw "workspaceId is required." }

                & az account set --subscription $body.subscriptionId | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to select subscription $($body.subscriptionId)."
                }

                $serverOutput = @()
                $serverOutput += "Association check request received."
                $serverOutput += ("WorkspaceId: {0}" -f [string]$body.workspaceId)

                $assoc = Get-WorkspaceAssociationSnapshot -SubscriptionId $body.subscriptionId -ResourceGroupName $body.resourceGroupName -ApimName $body.apimName -WorkspaceId $body.workspaceId
                $serverOutput += ("DefaultGatewayAssociated={0} Source={1}" -f $assoc.DefaultGatewayAssociated, $assoc.DefaultGatewayAssociationSource)
                $serverOutput += ("WorkspaceGateways={0}" -f $assoc.WorkspaceGatewaysText)
                if ($assoc.ApiCount -ne $null) {
                    $serverOutput += ("WorkspaceApiCount={0}" -f $assoc.ApiCount)
                }
                if ($assoc.Error) {
                    $serverOutput += ("AssociationCheckError={0}" -f $assoc.Error)
                }

                Send-Json -Response $response -Payload @{
                    ok = $true
                    serverOutput = $serverOutput
                    association = $assoc
                }
                continue
            }

            if ($method -eq "POST" -and $path -eq "/api/workspaces/diagnose-gateway") {
                $body = $null
                $invokeArgs = @{}
                $serverOutput = @()
                try {
                    $bodyText = Read-RequestBody -Request $request
                    $body = if ([string]::IsNullOrWhiteSpace($bodyText)) { @{} } else { $bodyText | ConvertFrom-Json }

                    if (-not $body.subscriptionId) { throw "subscriptionId is required." }
                    if (-not $body.resourceGroupName) { throw "resourceGroupName is required." }
                    if (-not $body.apimName) { throw "apimName is required." }
                    if (-not $body.workspaceId) { throw "workspaceId is required." }

                    & az account set --subscription $body.subscriptionId | Out-Null
                    if ($LASTEXITCODE -ne 0) {
                        throw "Failed to select subscription $($body.subscriptionId)."
                    }

                    $invokeArgs = @{
                        SubscriptionId = [string]$body.subscriptionId
                        ResourceGroupName = [string]$body.resourceGroupName
                        ApimName = [string]$body.apimName
                        WorkspaceId = [string]$body.workspaceId
                    }

                    if ($body.gatewayUrl) {
                        $invokeArgs["GatewayUrl"] = [string]$body.gatewayUrl
                    }

                    if ($body.apiPath) {
                        $invokeArgs["ApiPath"] = [string]$body.apiPath
                    }

                    if ($body.probePath) {
                        $invokeArgs["ProbePath"] = [string]$body.probePath
                    }

                    if ($body.fixDefaultGatewayAssociation) {
                        $invokeArgs["FixDefaultGatewayAssociation"] = $true
                    }

                    $serverOutput += "Workspace gateway diagnosis request received."
                    $serverOutput += ("WorkspaceId: {0}" -f [string]$body.workspaceId)
                    $serverOutput += ("FixDefaultGatewayAssociation: {0}" -f [bool]$body.fixDefaultGatewayAssociation)
                    $serverOutput += "Invoking diagnose-apim-workspace-gateway.ps1 with arguments:"
                    $serverOutput += (Convert-ArgToTraceLine -NamedArgs $invokeArgs)

                    $diagnoseResult = Invoke-PowerShellScript -ScriptPath $diagnoseGatewayScriptPath -NamedArgs $invokeArgs
                    $serverOutput += ("diagnose-apim-workspace-gateway.ps1 completed. Success={0} ExitCode={1}" -f $diagnoseResult.Success, $diagnoseResult.ExitCode)
                    if ($diagnoseResult.Output) {
                        $serverOutput += "--- Diagnose Script Output ---"
                        foreach ($line in $diagnoseResult.Output) {
                            $serverOutput += $line
                        }
                    }

                    $reportPath = $null
                    if ($diagnoseResult.Output) {
                        $reportLine = $diagnoseResult.Output | Where-Object { $_ -like "ReportPath:*" } | Select-Object -Last 1
                        if ($reportLine) {
                            $reportPath = ($reportLine -replace "^ReportPath:\s*", "").Trim()
                        }
                    }

                    $diagnosticReport = $null
                    if (-not [string]::IsNullOrWhiteSpace($reportPath) -and (Test-Path $reportPath)) {
                        try {
                            $diagnosticReport = Get-Content -Path $reportPath -Raw | ConvertFrom-Json
                        } catch {
                            $serverOutput += ("WARNING: Unable to parse report JSON at {0}" -f $reportPath)
                        }
                    } else {
                        $serverOutput += "WARNING: ReportPath was not detected from diagnose script output."
                    }

                    $workspaceResourceId = "/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.ApiManagement/service/{2}/workspaces/{3}" -f $body.subscriptionId, $body.resourceGroupName, $body.apimName, $body.workspaceId

                    $httpStatus = if ($diagnoseResult.Success) { 200 } else { 500 }
                    Send-Json -Response $response -Payload @{
                        ok = $diagnoseResult.Success
                        serverOutput = $serverOutput
                        diagnose = $diagnoseResult
                        reportPath = $reportPath
                        report = $diagnosticReport
                        urls = [pscustomobject]@{
                            WorkspacePortalUrl = Get-PortalResourceUrl -ResourceIdOrUrl $workspaceResourceId
                            WorkspaceArmUrl = (Get-AbsoluteManagementUrl -ResourceIdOrUrl $workspaceResourceId) + "?api-version=2024-05-01"
                        }
                    } -StatusCode $httpStatus -JsonDepth 32
                } catch {
                    $err = $_.Exception.Message
                    $serverOutput += "ERROR: Diagnose endpoint failed before completion."
                    $serverOutput += ("ERROR: " + $err)
                    if ($invokeArgs.Count -gt 0) {
                        $serverOutput += "Args at failure:"
                        $serverOutput += (Convert-ArgToTraceLine -NamedArgs $invokeArgs)
                    }
                    if ($_.ScriptStackTrace) {
                        $serverOutput += "ScriptStackTrace:"
                        $serverOutput += $_.ScriptStackTrace
                    }

                    Send-Json -Response $response -Payload @{
                        ok = $false
                        error = $err
                        serverOutput = $serverOutput
                        requestContext = @{
                            method = $method
                            path = $path
                            workspaceId = if ($body) { [string]$body.workspaceId } else { $null }
                            apimName = if ($body) { [string]$body.apimName } else { $null }
                            resourceGroupName = if ($body) { [string]$body.resourceGroupName } else { $null }
                            subscriptionId = if ($body) { [string]$body.subscriptionId } else { $null }
                        }
                        exception = $_.ToString()
                    } -StatusCode 500 -JsonDepth 32
                }
                continue
            }

            if ($method -eq "POST" -and $path -eq "/api/workspaces/verify-runtime") {
                $bodyText = Read-RequestBody -Request $request
                $body = if ([string]::IsNullOrWhiteSpace($bodyText)) { @{} } else { $bodyText | ConvertFrom-Json }

                if (-not $body.subscriptionId) { throw "subscriptionId is required." }
                if (-not $body.resourceGroupName) { throw "resourceGroupName is required." }
                if (-not $body.apimName) { throw "apimName is required." }
                if (-not $body.workspaceId) { throw "workspaceId is required." }

                & az account set --subscription $body.subscriptionId | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to select subscription $($body.subscriptionId)."
                }

                $runStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

                $apiPath = [string]$body.apiPath
                if ([string]::IsNullOrWhiteSpace($apiPath)) { $apiPath = "weather" }

                $probePath = [string]$body.probePath
                if ([string]::IsNullOrWhiteSpace($probePath)) { $probePath = "/weather/seattle" }

                $statusText = [string]$body.expectedStatusCodes
                if ([string]::IsNullOrWhiteSpace($statusText)) { $statusText = "200" }

                $statusParts = @($statusText -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                $expectedCodes = @()
                foreach ($part in $statusParts) {
                    $parsed = 0
                    if (-not [int]::TryParse($part, [ref]$parsed)) {
                        throw "Invalid expected status code '$part'."
                    }
                    $expectedCodes += $parsed
                }

                $gatewayUrl = [string]$body.gatewayUrl
                if ([string]::IsNullOrWhiteSpace($gatewayUrl)) {
                    $gatewayUrl = Get-ApimGatewayUrl -SubscriptionId $body.subscriptionId -ResourceGroupName $body.resourceGroupName -ApimName $body.apimName
                }

                $verifyArgs = @{
                    SubscriptionId = [string]$body.subscriptionId
                    ResourceGroupName = [string]$body.resourceGroupName
                    ApimName = [string]$body.apimName
                    WorkspaceId = [string]$body.workspaceId
                    ApiPath = $apiPath
                    ProbePath = $probePath
                    ExpectedStatusCodes = $expectedCodes
                }

                if (-not [string]::IsNullOrWhiteSpace($gatewayUrl)) {
                    $verifyArgs["GatewayUrl"] = $gatewayUrl
                }

                $serverOutput = @()
                $serverOutput += "Workspace runtime check requested from Workspaces tab."
                $serverOutput += ("WorkspaceId: {0}" -f [string]$body.workspaceId)
                $serverOutput += "Invoking verify-apim-workspace-runtime.ps1 with arguments:"
                $serverOutput += (Convert-ArgToTraceLine -NamedArgs $verifyArgs)

                $verifyResult = Invoke-PowerShellScript -ScriptPath $verifyRuntimeScriptPath -NamedArgs $verifyArgs
                $serverOutput += ("verify-apim-workspace-runtime.ps1 completed. Success={0} ExitCode={1}" -f $verifyResult.Success, $verifyResult.ExitCode)

                $normalizedProbe = $probePath
                if (-not $normalizedProbe.StartsWith('/')) { $normalizedProbe = '/' + $normalizedProbe }
                $runtimeUrl = $null
                if (-not [string]::IsNullOrWhiteSpace($gatewayUrl)) {
                    $runtimeUrl = ($gatewayUrl.TrimEnd('/') + "/" + $apiPath + $normalizedProbe)
                }

                $workspaceResourceId = "/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.ApiManagement/service/{2}/workspaces/{3}" -f $body.subscriptionId, $body.resourceGroupName, $body.apimName, $body.workspaceId
                $runUrls = [pscustomobject]@{
                    WorkspacePortalUrl = Get-PortalResourceUrl -ResourceIdOrUrl $workspaceResourceId
                    WorkspaceArmUrl = (Get-AbsoluteManagementUrl -ResourceIdOrUrl $workspaceResourceId) + "?api-version=2024-05-01"
                    GatewayUrl = $gatewayUrl
                    RuntimeUrl = $runtimeUrl
                }

                if ($runUrls.WorkspacePortalUrl) { $serverOutput += ("Workspace Portal URL: {0}" -f $runUrls.WorkspacePortalUrl) }
                if ($runUrls.WorkspaceArmUrl) { $serverOutput += ("Workspace ARM URL: {0}" -f $runUrls.WorkspaceArmUrl) }
                if ($runUrls.GatewayUrl) { $serverOutput += ("Gateway URL: {0}" -f $runUrls.GatewayUrl) }
                if ($runUrls.RuntimeUrl) { $serverOutput += ("Runtime URL: {0}" -f $runUrls.RuntimeUrl) }

                $runStopwatch.Stop()
                $httpStatus = if ($verifyResult.Success) { 200 } else { 500 }
                Send-Json -Response $response -Payload @{
                    ok = $verifyResult.Success
                    serverOutput = $serverOutput
                    verify = $verifyResult
                    urls = $runUrls
                    durationSeconds = [math]::Round($runStopwatch.Elapsed.TotalSeconds, 2)
                } -StatusCode $httpStatus
                continue
            }

            if ($method -eq "POST" -and $path -eq "/api/run") {
                $bodyText = Read-RequestBody -Request $request
                if ([string]::IsNullOrWhiteSpace($bodyText)) {
                    throw "Request body is required."
                }

                $body = $bodyText | ConvertFrom-Json

                if (-not $body.subscriptionId) { throw "subscriptionId is required." }
                if (-not $body.apimName) { throw "apimName is required." }
                if (-not $body.workspaceId) { throw "workspaceId is required." }
                if (-not $body.mode) { throw "mode is required." }

                $mode = [string]$body.mode
                $runStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                $serverOutput = @()
                $serverOutput += "Request accepted by web wizard API."
                $serverOutput += ("Mode: {0}" -f $mode)
                $serverOutput += ("WhatIfOnly: {0}" -f [bool]$body.whatIfOnly)
                $serverOutput += ("Subscription: {0}" -f [string]$body.subscriptionId)
                $serverOutput += ("APIM: {0} (RG: {1})" -f [string]$body.apimName, [string]$body.apimResourceGroup)
                $serverOutput += ("WorkspaceId: {0}" -f [string]$body.workspaceId)
                $invokeArgs = @{
                    Mode = $mode
                    SubscriptionId = [string]$body.subscriptionId
                    ApimName = [string]$body.apimName
                    WorkspaceId = [string]$body.workspaceId
                }

                if ($body.whatIfOnly) { $invokeArgs["WhatIfOnly"] = $true }

                if ($body.displayName) { $invokeArgs["DisplayName"] = [string]$body.displayName }
                if ($body.description) { $invokeArgs["Description"] = [string]$body.description }

                if ($mode -eq "create-dedicated") {
                    if (-not $body.networkResourceGroup -or -not $body.location) {
                        throw "networkResourceGroup and location are required for create-dedicated mode."
                    }

                    $invokeArgs["NetworkResourceGroup"] = [string]$body.networkResourceGroup
                    $invokeArgs["Location"] = [string]$body.location
                    $invokeArgs["NetworkMode"] = if ($body.networkMode) { [string]$body.networkMode } else { "integration" }

                    if ($body.skipWorkspaceCreate) {
                        $invokeArgs["SkipWorkspaceCreate"] = $true
                    }
                }

                if ($mode -eq "verify") {
                    if ($body.strictVerify -and -not $body.displayName) {
                        throw "displayName is required when strictVerify is enabled."
                    }

                    if (-not $body.strictVerify) {
                        $invokeArgs.Remove("DisplayName")
                        $invokeArgs.Remove("Description")
                    }
                }

                if ($mode -eq "verify-runtime") {
                    if (-not $body.apiPath -or -not $body.probePath) {
                        throw "apiPath and probePath are required for verify-runtime mode."
                    }

                    $invokeArgs["ApiPath"] = [string]$body.apiPath
                    $invokeArgs["ProbePath"] = [string]$body.probePath

                    if ($body.gatewayUrl) {
                        $invokeArgs["GatewayUrl"] = [string]$body.gatewayUrl
                    }

                    $codes = @()
                    if ($body.expectedStatusCodes -is [System.Array]) {
                        $codes = @($body.expectedStatusCodes)
                    } elseif ($body.expectedStatusCodes) {
                        $codes = @([string]$body.expectedStatusCodes -split ",")
                    }

                    $codes = @($codes | ForEach-Object { [string]$_ } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                    if ($codes.Count -eq 0) {
                        throw "expectedStatusCodes is required for verify-runtime mode."
                    }

                    $expected = @()
                    foreach ($code in $codes) {
                        $n = 0
                        if (-not [int]::TryParse($code, [ref]$n)) {
                            throw "Invalid expected status code '$code'."
                        }
                        $expected += $n
                    }

                    $invokeArgs["ExpectedStatusCodes"] = $expected

                    if ($body.collectDiagnostics) {
                        $invokeArgs["CollectDiagnostics"] = $true
                        if ($body.diagnosticsOutputPath) {
                            $invokeArgs["DiagnosticsOutputPath"] = [string]$body.diagnosticsOutputPath
                        }
                    }
                }

                $serverOutput += "Invoking manage-apim-workspace.ps1 with arguments:"
                $serverOutput += (Convert-ArgToTraceLine -NamedArgs $invokeArgs)

                $workspaceResult = Invoke-PowerShellScript -ScriptPath $manageScriptPath -NamedArgs $invokeArgs
                $serverOutput += ("manage-apim-workspace.ps1 completed. Success={0} ExitCode={1}" -f $workspaceResult.Success, $workspaceResult.ExitCode)

                $autoVerifyResult = $null
                $sampleResult = $null
                if ($workspaceResult.Success -and $body.deploySampleApi) {
                    $sampleScript = if ([string]$body.sampleProfile -eq "Echo API") { $echoScriptPath } else { $weatherScriptPath }
                    $serverOutput += ("Sample API deploy enabled. Profile={0}" -f [string]$body.sampleProfile)

                    $sampleArgs = @{
                        SubscriptionId = [string]$body.subscriptionId
                        ResourceGroupName = [string]$body.apimResourceGroup
                        ApimName = [string]$body.apimName
                        WorkspaceId = [string]$body.workspaceId
                    }

                    if ($body.sampleBackendUrl) {
                        $sampleArgs["BackendUrl"] = [string]$body.sampleBackendUrl
                    }

                    if (-not $body.createSampleProduct) {
                        $sampleArgs["CreateProduct"] = $false
                    }

                    if ($body.whatIfOnly) {
                        $sampleArgs["WhatIfOnly"] = $true
                    }

                    $serverOutput += ("Invoking {0} with arguments:" -f (Split-Path -Leaf $sampleScript))
                    $serverOutput += (Convert-ArgToTraceLine -NamedArgs $sampleArgs)

                    $sampleResult = Invoke-PowerShellScript -ScriptPath $sampleScript -NamedArgs $sampleArgs
                    $serverOutput += ("{0} completed. Success={1} ExitCode={2}" -f (Split-Path -Leaf $sampleScript), $sampleResult.Success, $sampleResult.ExitCode)
                }

                if ($workspaceResult.Success -and ($mode -eq "create-default" -or $mode -eq "create-dedicated") -and [bool]$body.autoVerifyRuntime) {
                    $serverOutput += "Auto verify-runtime enabled after create."

                    $gatewaySeed = if ($body.gatewayUrl) { [string]$body.gatewayUrl } else { Get-ApimGatewayUrl -SubscriptionId $body.subscriptionId -ResourceGroupName $body.apimResourceGroup -ApimName $body.apimName }
                    $autoVerifyResult = Invoke-AutoVerifyRuntime -Body $body -GatewayUrlOverride $gatewaySeed
                    $serverOutput += ("Auto verify-runtime completed. Success={0} Attempts={1}" -f $autoVerifyResult.Success, $autoVerifyResult.Attempts)
                }

                Set-WebSettingState -Body $body

                $ok = $workspaceResult.Success -and ($null -eq $autoVerifyResult -or $autoVerifyResult.Success) -and ($null -eq $sampleResult -or $sampleResult.Success)
                $runStopwatch.Stop()
                $runUrls = Get-RunUrlInfo -Body $body -SampleResult $sampleResult
                if ($autoVerifyResult -and $runUrls.GatewayUrl -and [string]::IsNullOrWhiteSpace($runUrls.RuntimeUrl)) {
                    $probe = [string]$body.autoProbePath
                    if (-not $probe.StartsWith("/")) { $probe = "/" + $probe }
                    $apiPath = if ([string]::IsNullOrWhiteSpace([string]$body.autoApiPath)) { "weather" } else { [string]$body.autoApiPath }
                    $runUrls.RuntimeUrl = ($runUrls.GatewayUrl.TrimEnd('/') + "/" + $apiPath + $probe)
                }
                $serverOutput += ("Total duration: {0:N1}s" -f $runStopwatch.Elapsed.TotalSeconds)
                if ($runUrls.WorkspacePortalUrl) { $serverOutput += ("Workspace Portal URL: {0}" -f $runUrls.WorkspacePortalUrl) }
                if ($runUrls.WorkspaceArmUrl) { $serverOutput += ("Workspace ARM URL: {0}" -f $runUrls.WorkspaceArmUrl) }
                if ($runUrls.GatewayUrl) { $serverOutput += ("Gateway URL: {0}" -f $runUrls.GatewayUrl) }
                if ($runUrls.RuntimeUrl) { $serverOutput += ("Runtime URL: {0}" -f $runUrls.RuntimeUrl) }

                if ($mode -eq "create-default") {
                    $serverOutput += "Default-mode runtime preflight: probing resolved runtime URL to check effective routing."

                    $probeResult = Invoke-RuntimeQuickProbe -Url $runUrls.RuntimeUrl -TimeoutSeconds 20
                    if ($probeResult.Success -and $probeResult.StatusCode -ge 200 -and $probeResult.StatusCode -lt 300) {
                        $serverOutput += ("Default-mode runtime preflight passed (status={0})." -f $probeResult.StatusCode)
                    } else {
                        $statusText = if ($probeResult.StatusCode) { [string]$probeResult.StatusCode } else { "no-status" }
                        $serverOutput += ("WARNING: Default-mode runtime preflight indicates routing may be inactive (status={0})." -f $statusText)
                        if ($probeResult.Error) {
                            $serverOutput += ("WARNING: Runtime probe error: {0}" -f $probeResult.Error)
                        }
                        $serverOutput += "WARNING: Control-plane workspace creation succeeded, but gateway runtime did not return a success status for the resolved URL."
                    }
                }

                $httpStatus = if ($ok) { 200 } else { 500 }
                Send-Json -Response $response -Payload @{
                    ok = $ok
                    serverOutput = $serverOutput
                    workspace = $workspaceResult
                    autoVerify = $autoVerifyResult
                    sample = $sampleResult
                    urls = $runUrls
                    durationSeconds = [math]::Round($runStopwatch.Elapsed.TotalSeconds, 2)
                } -StatusCode $httpStatus
                continue
            }

            Send-Text -Response $response -Content "Not Found" -StatusCode 404
        } catch {
            $errorMessage = $_.Exception.Message
            Write-Warning ("Request handling error ({0} {1}): {2}" -f $method, $path, $errorMessage)
            try {
                if ($response -and $response.OutputStream -and $response.OutputStream.CanWrite) {
                    Send-Json -Response $response -Payload @{
                        ok = $false
                        error = $errorMessage
                        requestContext = @{
                            method = $method
                            path = $path
                        }
                        exception = $_.ToString()
                    } -StatusCode 500 -JsonDepth 16
                }
            } catch {
                Write-Warning ("Request handling error after response commit: {0}" -f $errorMessage)
                Write-Warning ("Error response could not be sent: {0}" -f $_.Exception.Message)
            }
        }
    }
} finally {
    $listener.Stop()
    $listener.Close()
}
