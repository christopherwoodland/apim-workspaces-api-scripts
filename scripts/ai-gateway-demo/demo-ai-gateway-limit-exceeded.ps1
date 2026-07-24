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

    [Parameter(Mandatory = $true)]
    [string]$OpenAiAccountName,

    [Parameter(Mandatory = $true)]
    [string]$OpenAiDeploymentName,

    [Parameter()]
    [string]$SubscriptionKey,

    [Parameter()]
    [string]$ApiPath = "ai/chat",

    [Parameter()]
    [string]$ApiId = "ai-chat-api",

    [Parameter()]
    [string]$OperationId = "post-chat-completions",

    [Parameter()]
    [int]$TokensPerMinute = 120,

    [Parameter()]
    [int]$RateLimitCalls = 1,

    [Parameter()]
    [int]$RateLimitRenewalPeriod = 60,

    [Parameter()]
    [int]$MaxTokens = 180,

    [Parameter()]
    [int]$HttpTimeoutSeconds = 45,

    [Parameter()]
    [string]$LogDirectory = (Join-Path $PSScriptRoot "logs")
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

function Resolve-GatewayUrl {
    $url = Invoke-AzCli -Args @(
        "apim", "show",
        "--name", $ApimName,
        "--resource-group", $ResourceGroupName,
        "--query", "gatewayUrl",
        "-o", "tsv"
    )

    if ([string]::IsNullOrWhiteSpace($url)) {
        throw "Unable to resolve APIM gateway URL."
    }

    return $url.TrimEnd('/')
}

function New-LongPrompt {
    $parts = @()
    1..80 | ForEach-Object {
        $parts += "Summarize enterprise governance controls for AI gateways including identity, logging, and abuse prevention with practical examples."
    }

    return ($parts -join " ")
}

function Invoke-DemoCall {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [string]$Prompt,

        [Parameter(Mandatory = $true)]
        [int]$CallNumber
    )

    $payload = @{
        messages = @(
            @{
                role = "system"
                content = "You are a concise enterprise assistant."
            },
            @{
                role = "user"
                content = $Prompt
            }
        )
        max_tokens = $MaxTokens
        temperature = 0.2
    } | ConvertTo-Json -Depth 8

    $headers = @{
        "Content-Type" = "application/json"
    }
    if (-not [string]::IsNullOrWhiteSpace($SubscriptionKey)) {
        $headers["Ocp-Apim-Subscription-Key"] = $SubscriptionKey
    }

    $statusCode = $null
    $durationMs = $null
    $body = $null
    $errorMessage = $null

    $start = Get-Date
    try {
        $response = Invoke-WebRequest -Method Post -Uri $Uri -Headers $headers -Body $payload -TimeoutSec $HttpTimeoutSeconds -UseBasicParsing -ErrorAction Stop
        $statusCode = [int]$response.StatusCode
        $body = $response.Content
    }
    catch {
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $statusCode = [int]$_.Exception.Response.StatusCode
            $stream = $_.Exception.Response.GetResponseStream()
            if ($stream) {
                $reader = New-Object System.IO.StreamReader($stream)
                $body = $reader.ReadToEnd()
                $reader.Close()
            }
        }
        $errorMessage = $_.Exception.Message
    }
    finally {
        $durationMs = [int]((Get-Date) - $start).TotalMilliseconds
    }

    $preview = if ($body) {
        if ($body.Length -le 220) { $body } else { $body.Substring(0, 220) + "..." }
    }
    else {
        ""
    }

    return [pscustomobject]@{
        CallNumber = $CallNumber
        StatusCode = $statusCode
        DurationMs = $durationMs
        ErrorMessage = $errorMessage
        ResponsePreview = $preview
    }
}

Test-ToolAvailable -Name "az"
Write-Log -Level "INFO" -Message "Run started. Log file: $LogFile"

Write-Log -Level "INFO" -Message "Selecting subscription"
Invoke-AzCli -Args @("account", "set", "--subscription", $SubscriptionId) | Out-Null

$applyPolicyScriptPath = Join-Path $PSScriptRoot "apply-ai-gateway-policies.ps1"
if (-not (Test-Path $applyPolicyScriptPath)) {
    throw "Required script not found: $applyPolicyScriptPath"
}

Write-Log -Level "INFO" -Message "Applying restrictive policy settings for enforcement demo"
& $applyPolicyScriptPath `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -ApimName $ApimName `
    -WorkspaceId $WorkspaceId `
    -OpenAiAccountName $OpenAiAccountName `
    -OpenAiDeploymentName $OpenAiDeploymentName `
    -ApiId $ApiId `
    -OperationId $OperationId `
    -TokensPerMinute $TokensPerMinute `
    -RateLimitCalls $RateLimitCalls `
    -RateLimitRenewalPeriod $RateLimitRenewalPeriod

if ($LASTEXITCODE -ne 0) {
    throw "Policy apply step failed."
}

$gatewayUrl = Resolve-GatewayUrl
$endpoint = "{0}/{1}" -f $gatewayUrl, $ApiPath.TrimStart('/')
Write-Log -Level "INFO" -Message "Enforcement demo endpoint: $endpoint"

$promptShort = "Summarize AI gateway governance in 3 bullet points."
$promptLong = New-LongPrompt

$results = @()
$results += Invoke-DemoCall -Uri $endpoint -Prompt $promptShort -CallNumber 1
$results += Invoke-DemoCall -Uri $endpoint -Prompt $promptShort -CallNumber 2
$results += Invoke-DemoCall -Uri $endpoint -Prompt $promptLong -CallNumber 3

$enforced = $results | Where-Object { $_.StatusCode -eq 429 }

Write-Output ""
Write-Output "=== AI Gateway Limit Enforcement Demo Results ==="
$results | Format-Table -AutoSize | Out-String | Write-Output

if ($enforced) {
    Write-Output "SUCCESS: Policy enforcement observed (HTTP 429 detected)."
}
else {
    Write-Warning "No 429 observed. Lower TokensPerMinute and/or RateLimitCalls, then run again."
}

Write-Output "Log file: $LogFile"
