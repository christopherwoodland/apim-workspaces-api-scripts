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
    [string]$ApiId = "ai-chat-api",

    [Parameter()]
    [string]$OperationId = "post-chat-completions",

    [Parameter()]
    [string]$BackendUrl,

    [Parameter()]
    [int]$TokensPerMinute = 20000,

    [Parameter()]
    [int]$RateLimitCalls = 30,

    [Parameter()]
    [int]$RateLimitRenewalPeriod = 60,

    [Parameter()]
    [string]$ApiVersion = "2024-10-01-preview",

    [Parameter()]
    [string]$PolicyOutputPath,

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
        [string[]]$Args,

        [switch]$ReadOnly
    )

    $displayArgs = $Args | ForEach-Object {
        if ($_ -match "\s") { '"' + $_ + '"' } else { $_ }
    }
    Write-Log -Level "DEBUG" -Message "Running command: az $($displayArgs -join ' ')"

    if ($WhatIfOnly -and -not $ReadOnly) {
        Write-Log -Level "INFO" -Message "WhatIfOnly is enabled. Skipping command execution."
        return $null
    }

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & az @Args 2>&1
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($LASTEXITCODE -ne 0) {
        $detail = ($output | ForEach-Object { $_.ToString() }) -join "`n"
        throw "Azure CLI command failed: az $($displayArgs -join ' ')`n$detail"
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
        [string]$RelativePath,

        [Parameter()]
        [object]$BodyObject
    )

    $url = "https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.ApiManagement/service/{2}/{3}?api-version={4}" -f `
        $SubscriptionId, $ResourceGroupName, $ApimName, $RelativePath.TrimStart('/'), $ApiVersion

    $args = @("rest", "--method", $Method, "--url", $url)
    if ($Method -eq "GET") {
        $args += @("-o", "json")
    } else {
        $args += @("-o", "none")
    }

    $bodyFile = $null
    try {
        if ($null -ne $BodyObject) {
            $payload = $BodyObject | ConvertTo-Json -Depth 50 -Compress
            $bodyFile = Join-Path $env:TEMP ("apim-ai-policy-body-" + [guid]::NewGuid().ToString() + ".json")
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($bodyFile, $payload, $utf8NoBom)
            $args += @("--headers", "Content-Type=application/json", "--body", "@$bodyFile")
        }

        try {
            return Invoke-AzCli -Args $args -ReadOnly:($Method -eq "GET")
        } catch {
            $message = $_.Exception.Message
            $isEncodingFailure = ($message -match "UnicodeEncodeError") -or ($message -match "Unexpected UTF-8 BOM") -or ($message -match "charmap")
            if (-not $isEncodingFailure) {
                throw
            }

            Write-Log -Level "WARN" -Message "Azure CLI rest call hit encoding issue; retrying with direct ARM REST call."

            $token = Invoke-AzCli -Args @(
                "account", "get-access-token",
                "--resource", "https://management.azure.com/",
                "--query", "accessToken",
                "-o", "tsv"
            ) -ReadOnly

            if ([string]::IsNullOrWhiteSpace($token)) {
                throw "Could not retrieve ARM access token for fallback request."
            }

            $headers = @{
                Authorization = "Bearer $token"
            }

            if ($null -ne $BodyObject) {
                $fallbackPayload = $BodyObject | ConvertTo-Json -Depth 50 -Compress
                Invoke-RestMethod -Method $Method -Uri $url -Headers $headers -ContentType "application/json" -Body $fallbackPayload -ErrorAction Stop | Out-Null
                return $null
            }

            return (Invoke-RestMethod -Method $Method -Uri $url -Headers $headers -ErrorAction Stop | ConvertTo-Json -Depth 50)
        }
    }
    finally {
        if ($bodyFile -and (Test-Path $bodyFile)) {
            Remove-Item -Path $bodyFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Resolve-BackendUrl {
    if (-not [string]::IsNullOrWhiteSpace($BackendUrl)) {
        return $BackendUrl.TrimEnd('/')
    }

    $endpoint = Invoke-AzCli -Args @(
        "cognitiveservices", "account", "show",
        "--name", $OpenAiAccountName,
        "--resource-group", $ResourceGroupName,
        "--query", "properties.endpoint",
        "-o", "tsv"
    ) -ReadOnly

    if ([string]::IsNullOrWhiteSpace($endpoint)) {
        throw "Unable to resolve endpoint for cognitive account '$OpenAiAccountName'."
    }

    $baseEndpoint = $endpoint.TrimEnd('/')
    if ($baseEndpoint -match "services\.ai\.azure\.com/api/projects") {
        return $baseEndpoint
    }

    return ($baseEndpoint + "/openai")
}

function Get-PolicyXml {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResolvedBackendUrl
    )

    $tokenLimitCounterKey = "@((context.Subscription != null && !string.IsNullOrEmpty(context.Subscription.Key)) ? context.Subscription.Key : context.Request.IpAddress)"

    $xml = @"
<policies>
  <inbound>
    <base />
        <set-backend-service base-url="$ResolvedBackendUrl" />
        <authentication-managed-identity resource="https://cognitiveservices.azure.com" output-token-variable-name="msi-access-token" ignore-error="false" />
        <set-header name="Authorization" exists-action="override">
            <value>@("Bearer " + (string)context.Variables["msi-access-token"])</value>
    </set-header>
        <set-header name="api-key" exists-action="delete" />

        <azure-openai-token-limit counter-key="$tokenLimitCounterKey" tokens-per-minute="$TokensPerMinute" estimate-prompt-tokens="true" />

        <rate-limit-by-key calls="$RateLimitCalls" renewal-period="$RateLimitRenewalPeriod" counter-key="$tokenLimitCounterKey" />

        <rewrite-uri template="/openai/deployments/$OpenAiDeploymentName/chat/completions?api-version=2024-02-01" copy-unmatched-params="false" />

    <!-- Optional policy placeholders for a live demo sequence -->
    <!--
    <azure-openai-semantic-cache-lookup score-threshold="0.8" />
    <llm-content-safety shield-prompt="true" />
    -->
  </inbound>
  <backend>
    <base />
  </backend>
  <outbound>
    <base />
    <!-- <azure-openai-semantic-cache-store duration="300" /> -->
  </outbound>
  <on-error>
    <base />
  </on-error>
</policies>
"@

    return $xml
}

Test-ToolAvailable -Name "az"
Write-Log -Level "INFO" -Message "Run started. Log file: $LogFile"
Write-Log -Level "INFO" -Message "Selecting subscription"
Invoke-AzCli -Args @("account", "set", "--subscription", $SubscriptionId) -ReadOnly | Out-Null

$resolvedBackendUrl = Resolve-BackendUrl
$policyXml = Get-PolicyXml -ResolvedBackendUrl $resolvedBackendUrl

if ([string]::IsNullOrWhiteSpace($PolicyOutputPath)) {
    $PolicyOutputPath = Join-Path $PSScriptRoot "policies/ai-gateway-operation-policy.xml"
}

$policyDirectory = Split-Path -Parent $PolicyOutputPath
if (-not (Test-Path $policyDirectory)) {
    New-Item -Path $policyDirectory -ItemType Directory -Force | Out-Null
}
Set-Content -Path $PolicyOutputPath -Value $policyXml -Encoding UTF8
Write-Log -Level "INFO" -Message "Policy XML saved to: $PolicyOutputPath"

$policyBody = @{
    properties = @{
        format = "rawxml"
        value = $policyXml
    }
}

$relativePath = "workspaces/{0}/apis/{1}/operations/{2}/policies/policy" -f $WorkspaceId, $ApiId, $OperationId
Write-Log -Level "INFO" -Message "Applying operation policy to $relativePath"
Invoke-ApimRest -Method "PUT" -RelativePath $relativePath -BodyObject $policyBody | Out-Null

$summary = [pscustomobject]@{
    SubscriptionId = $SubscriptionId
    ResourceGroupName = $ResourceGroupName
    ApimName = $ApimName
    WorkspaceId = $WorkspaceId
    ApiId = $ApiId
    OperationId = $OperationId
    OpenAiAccountName = $OpenAiAccountName
    OpenAiDeploymentName = $OpenAiDeploymentName
    TokensPerMinute = $TokensPerMinute
    RateLimitCalls = $RateLimitCalls
    RateLimitRenewalPeriod = $RateLimitRenewalPeriod
    PolicyOutputPath = $PolicyOutputPath
    LogFile = $LogFile
}

Write-Output ""
Write-Output "=== AI Gateway Policy Apply Summary ==="
$summary | Format-List | Out-String | Write-Output
