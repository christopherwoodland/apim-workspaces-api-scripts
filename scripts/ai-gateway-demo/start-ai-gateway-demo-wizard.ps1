[CmdletBinding()]
param(
    [int]$Port = 5088,
    [switch]$NoBrowser
)

$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $PSCommandPath
$webRoot = Join-Path $scriptRoot "web"
$createScriptPath = Join-Path $scriptRoot "create-ai-gateway-api.ps1"
$policyScriptPath = Join-Path $scriptRoot "apply-ai-gateway-policies.ps1"
$demoScriptPath = Join-Path $scriptRoot "demo-ai-gateway.ps1"
$enforcementScriptPath = Join-Path $scriptRoot "demo-ai-gateway-limit-exceeded.ps1"

foreach ($requiredPath in @($webRoot, $createScriptPath, $policyScriptPath, $demoScriptPath, $enforcementScriptPath)) {
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
        [int]$JsonDepth = 12
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

function Get-RequestValue {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Body,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [switch]$Mandatory
    )

    $value = [string]$Body.$Name
    if ($Mandatory -and [string]::IsNullOrWhiteSpace($value)) {
        throw "Missing required field: $Name"
    }

    return $value
}

function Invoke-Step {
    param([pscustomobject]$Body)

    $step = Get-RequestValue -Body $Body -Name "step" -Mandatory

    $subscriptionId = Get-RequestValue -Body $Body -Name "subscriptionId" -Mandatory
    $resourceGroupName = Get-RequestValue -Body $Body -Name "resourceGroupName" -Mandatory
    $apimName = Get-RequestValue -Body $Body -Name "apimName" -Mandatory
    $workspaceId = Get-RequestValue -Body $Body -Name "workspaceId" -Mandatory
    $openAiAccountName = Get-RequestValue -Body $Body -Name "openAiAccountName" -Mandatory
    $openAiDeploymentName = Get-RequestValue -Body $Body -Name "openAiDeploymentName" -Mandatory
    $subscriptionKey = Get-RequestValue -Body $Body -Name "subscriptionKey"

    $tokensPerMinute = if ($Body.tokensPerMinute) { [int]$Body.tokensPerMinute } else { 20000 }
    $rateLimitCalls = if ($Body.rateLimitCalls) { [int]$Body.rateLimitCalls } else { 30 }
    $rateLimitRenewal = if ($Body.rateLimitRenewalPeriod) { [int]$Body.rateLimitRenewalPeriod } else { 60 }

    switch ($step) {
        "1" {
            $args = @{
                SubscriptionId = $subscriptionId
                ResourceGroupName = $resourceGroupName
                ApimName = $apimName
                WorkspaceId = $workspaceId
                OpenAiAccountName = $openAiAccountName
                OpenAiDeploymentName = $openAiDeploymentName
            }

            return Invoke-PowerShellScript -ScriptPath $createScriptPath -NamedArgs $args
        }
        "2" {
            $args = @{
                SubscriptionId = $subscriptionId
                ResourceGroupName = $resourceGroupName
                ApimName = $apimName
                WorkspaceId = $workspaceId
                OpenAiAccountName = $openAiAccountName
                OpenAiDeploymentName = $openAiDeploymentName
                TokensPerMinute = $tokensPerMinute
                RateLimitCalls = $rateLimitCalls
                RateLimitRenewalPeriod = $rateLimitRenewal
            }

            return Invoke-PowerShellScript -ScriptPath $policyScriptPath -NamedArgs $args
        }
        "3" {
            $args = @{
                SubscriptionId = $subscriptionId
                ResourceGroupName = $resourceGroupName
                ApimName = $apimName
                WorkspaceId = $workspaceId
                ApiPath = "ai/chat"
            }

            if (-not [string]::IsNullOrWhiteSpace($subscriptionKey)) {
                $args.SubscriptionKey = $subscriptionKey
            }

            return Invoke-PowerShellScript -ScriptPath $demoScriptPath -NamedArgs $args
        }
        "4" {
            $args = @{
                SubscriptionId = $subscriptionId
                ResourceGroupName = $resourceGroupName
                ApimName = $apimName
                WorkspaceId = $workspaceId
                OpenAiAccountName = $openAiAccountName
                OpenAiDeploymentName = $openAiDeploymentName
                TokensPerMinute = if ($Body.enforcementTokensPerMinute) { [int]$Body.enforcementTokensPerMinute } else { 120 }
                RateLimitCalls = if ($Body.enforcementRateLimitCalls) { [int]$Body.enforcementRateLimitCalls } else { 1 }
                RateLimitRenewalPeriod = if ($Body.enforcementRateLimitRenewalPeriod) { [int]$Body.enforcementRateLimitRenewalPeriod } else { 60 }
            }

            if (-not [string]::IsNullOrWhiteSpace($subscriptionKey)) {
                $args.SubscriptionKey = $subscriptionKey
            }

            return Invoke-PowerShellScript -ScriptPath $enforcementScriptPath -NamedArgs $args
        }
        default {
            throw "Unknown step '$step'."
        }
    }
}

$listener = New-Object System.Net.HttpListener
$prefix = "http://localhost:$Port/"
$listener.Prefixes.Add($prefix)
$listener.Start()

Write-Output "AI gateway demo wizard is running at $prefix"
Write-Output "Press Ctrl+C to stop."

if (-not $NoBrowser) {
    Start-Process $prefix | Out-Null
}

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response
        $path = $request.Url.AbsolutePath

        try {
            if ($request.HttpMethod -eq "GET" -and $path -eq "/") {
                Send-File -Response $response -Path (Join-Path $webRoot "index.html")
                continue
            }

            if ($request.HttpMethod -eq "GET" -and $path -eq "/styles.css") {
                Send-File -Response $response -Path (Join-Path $webRoot "styles.css")
                continue
            }

            if ($request.HttpMethod -eq "GET" -and $path -eq "/app.js") {
                Send-File -Response $response -Path (Join-Path $webRoot "app.js")
                continue
            }

            if ($request.HttpMethod -eq "GET" -and $path -eq "/api/health") {
                Send-Json -Response $response -Payload @{ ok = $true; timestamp = (Get-Date).ToString("o") }
                continue
            }

            if ($request.HttpMethod -eq "POST" -and $path -eq "/api/run-step") {
                $bodyText = Read-RequestBody -Request $request
                if ([string]::IsNullOrWhiteSpace($bodyText)) {
                    Send-Json -Response $response -StatusCode 400 -Payload @{ ok = $false; message = "Request body is required." }
                    continue
                }

                $body = $bodyText | ConvertFrom-Json
                $result = Invoke-Step -Body $body

                Send-Json -Response $response -Payload @{
                    ok = $result.Success
                    exitCode = $result.ExitCode
                    output = $result.Output
                }
                continue
            }

            Send-Text -Response $response -StatusCode 404 -Content "Not Found"
        } catch {
            $message = $_.Exception.Message
            Write-Warning "Request handling error ($($request.HttpMethod) $path): $message"
            try {
                Send-Json -Response $response -StatusCode 500 -Payload @{ ok = $false; message = $message }
            } catch {
                Write-Warning "Error response could not be sent: $($_.Exception.Message)"
            }
        }
    }
} finally {
    if ($listener) {
        $listener.Stop()
        $listener.Close()
    }
}
