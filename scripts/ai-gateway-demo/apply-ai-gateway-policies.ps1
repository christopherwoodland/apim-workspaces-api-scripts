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
        [string]$RelativePath,

        [Parameter()]
        [object]$BodyObject
    )

    $url = "https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.ApiManagement/service/{2}/{3}?api-version={4}" -f `
        $SubscriptionId, $ResourceGroupName, $ApimName, $RelativePath.TrimStart('/'), $ApiVersion

    $args = @("rest", "--method", $Method, "--url", $url, "-o", "json")

    $bodyFile = $null
    try {
        if ($null -ne $BodyObject) {
            $payload = $BodyObject | ConvertTo-Json -Depth 50 -Compress
            $bodyFile = Join-Path $env:TEMP ("apim-ai-policy-body-" + [guid]::NewGuid().ToString() + ".json")
            Set-Content -Path $bodyFile -Value $payload -Encoding UTF8
            $args += @("--headers", "Content-Type=application/json", "--body", "@$bodyFile")
        }

        return Invoke-AzCli -Args $args -ReadOnly:($Method -eq "GET")
    }
    finally {
        if ($bodyFile -and (Test-Path $bodyFile)) {
            Remove-Item -Path $bodyFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-PolicyXml {
    $tokenLimitCounterKey = "@(context.Subscription?.Key ?? context.Request.IpAddress ?? 'anonymous')"

    $xml = @"
<policies>
  <inbound>
    <base />
    <set-backend-service backend-id=\"aoai-backend\" />
    <authentication-managed-identity resource=\"https://cognitiveservices.azure.com\" output-token-variable-name=\"msi-access-token\" ignore-error=\"false\" />
    <set-header name=\"Authorization\" exists-action=\"override\">
      <value>@(""Bearer "" + (string)context.Variables[""msi-access-token""])</value>
    </set-header>
    <set-header name=\"api-key\" exists-action=\"delete\" />

    <azure-openai-token-limit counter-key=\"$tokenLimitCounterKey\" tokens-per-minute=\"$TokensPerMinute\" estimate-prompt-tokens=\"true\" />

    <rate-limit-by-key calls=\"$RateLimitCalls\" renewal-period=\"$RateLimitRenewalPeriod\" counter-key=\"$tokenLimitCounterKey\" />

    <rewrite-uri template=\"/openai/deployments/$OpenAiDeploymentName/chat/completions?api-version=2024-02-01\" copy-unmatched-params=\"false\" />

    <!-- Optional policy placeholders for a live demo sequence -->
    <!--
    <azure-openai-semantic-cache-lookup score-threshold=\"0.8\" />
    <llm-content-safety shield-prompt=\"true\" />
    -->
  </inbound>
  <backend>
    <base />
  </backend>
  <outbound>
    <base />
    <!-- <azure-openai-semantic-cache-store duration=\"300\" /> -->
    <azure-openai-emit-token-metric namespace=\"apim-ai-gateway-demo\" />
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

$policyXml = Get-PolicyXml

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
