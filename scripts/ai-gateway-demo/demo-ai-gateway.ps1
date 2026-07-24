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
    [string]$ApiPath = "ai/chat",

    [Parameter()]
    [string]$GatewayUrl,

    [Parameter()]
    [string]$SubscriptionKey,

    [Parameter()]
    [string]$Prompt = "Summarize zero trust in 3 bullet points.",

    [Parameter()]
    [int]$MaxTokens = 160,

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
    if (-not [string]::IsNullOrWhiteSpace($GatewayUrl)) {
        return $GatewayUrl.TrimEnd('/')
    }

    $url = Invoke-AzCli -Args @(
        "apim", "show",
        "--name", $ApimName,
        "--resource-group", $ResourceGroupName,
        "--query", "gatewayUrl",
        "-o", "tsv"
    )

    if ([string]::IsNullOrWhiteSpace($url)) {
        throw "GatewayUrl was not provided and could not be resolved from APIM."
    }

    return $url.TrimEnd('/')
}

function Resolve-SubscriptionKey {
    if (-not [string]::IsNullOrWhiteSpace($SubscriptionKey)) {
        return $SubscriptionKey
    }

    throw "SubscriptionKey is required. Pass -SubscriptionKey from an APIM subscription key."
}

function Invoke-DemoCall {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [string]$Key,

        [Parameter(Mandatory = $true)]
        [string]$PromptText,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSec,

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
                content = $PromptText
            }
        )
        max_tokens = $MaxTokens
        temperature = 0.2
    } | ConvertTo-Json -Depth 8

    $headers = @{
        "Ocp-Apim-Subscription-Key" = $Key
        "Content-Type" = "application/json"
    }

    $statusCode = $null
    $durationMs = $null
    $body = $null
    $errorMessage = $null

    $start = Get-Date
    try {
        $response = Invoke-WebRequest -Method Post -Uri $Uri -Headers $headers -Body $payload -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
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
        if ($body.Length -le 240) { $body } else { $body.Substring(0, 240) + "..." }
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

$effectiveGatewayUrl = Resolve-GatewayUrl
$key = Resolve-SubscriptionKey
$endpoint = "{0}/{1}" -f $effectiveGatewayUrl, $ApiPath.TrimStart('/')

Write-Log -Level "INFO" -Message "Demo endpoint: $endpoint"
Write-Output ""
Write-Output "=== Running AI Gateway Demo Calls ==="
Write-Output "Endpoint: $endpoint"
Write-Output ""

$results = @()
$results += Invoke-DemoCall -Uri $endpoint -Key $key -PromptText $Prompt -TimeoutSec $HttpTimeoutSeconds -CallNumber 1
Start-Sleep -Seconds 1
$results += Invoke-DemoCall -Uri $endpoint -Key $key -PromptText $Prompt -TimeoutSec $HttpTimeoutSeconds -CallNumber 2

$results | ForEach-Object {
    Write-Log -Level "INFO" -Message ("Call #{0}: status={1}, durationMs={2}, error={3}" -f $_.CallNumber, $_.StatusCode, $_.DurationMs, $_.ErrorMessage)
}

Write-Output ""
Write-Output "=== Demo Results ==="
$results | Format-Table -AutoSize | Out-String | Write-Output

Write-Output "Tip: If semantic cache is enabled, call #2 should often be faster than call #1 for repeated prompts."
Write-Output "Log file: $LogFile"
