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
    [string]$ApiDisplayName = "AI Chat API",

    [Parameter()]
    [string]$ApiPath = "ai/chat",

    [Parameter()]
    [string]$OperationId = "post-chat-completions",

    [Parameter()]
    [string]$BackendId = "aoai-backend",

    [Parameter()]
    [string]$ApiVersion = "2024-10-01-preview",

    [Parameter()]
    [string]$OpenAiApiVersion = "2024-02-01",

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
            $bodyFile = Join-Path $env:TEMP ("apim-ai-gateway-body-" + [guid]::NewGuid().ToString() + ".json")
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

function Resolve-ApimPrincipalId {
    $json = Invoke-AzCli -Args @(
        "apim", "show",
        "--name", $ApimName,
        "--resource-group", $ResourceGroupName,
        "--query", "identity.principalId",
        "-o", "tsv"
    ) -ReadOnly

    if ([string]::IsNullOrWhiteSpace($json)) {
        throw "APIM managed identity principalId is not available. Ensure managed identity is enabled on APIM."
    }

    return $json.Trim()
}

function Ensure-Backend {
    $backendUrl = "https://{0}.openai.azure.com/openai" -f $OpenAiAccountName

    $backendBody = @{
        properties = @{
            title = "Azure OpenAI Backend"
            protocol = "http"
            url = $backendUrl
            description = "Azure OpenAI backend for APIM AI gateway demo"
        }
    }

    Write-Log -Level "INFO" -Message "Creating or updating backend '$BackendId' -> $backendUrl"
    Invoke-ApimRest -Method "PUT" -RelativePath ("backends/{0}" -f $BackendId) -BodyObject $backendBody | Out-Null
}

function Ensure-Api {
    $openApiDocument = @{
        openapi = "3.0.3"
        info = @{
            title = $ApiDisplayName
            version = "1.0"
        }
        paths = @{
            "/" = @{
                post = @{
                    operationId = $OperationId
                    responses = @{
                        "200" = @{
                            description = "OK"
                        }
                    }
                }
            }
        }
    }

    $apiBody = @{
        properties = @{
            displayName = $ApiDisplayName
            path = $ApiPath.Trim('/')
            protocols = @("https")
            format = "openapi+json"
            value = ($openApiDocument | ConvertTo-Json -Depth 20 -Compress)
            subscriptionRequired = $true
        }
    }

    Write-Log -Level "INFO" -Message "Creating or updating workspace API '$ApiId'"
    Invoke-ApimRest -Method "PUT" -RelativePath ("workspaces/{0}/apis/{1}" -f $WorkspaceId, $ApiId) -BodyObject $apiBody | Out-Null
}

function Ensure-Operation {
    $operationBody = @{
        properties = @{
            displayName = "Chat Completions"
            method = "POST"
            urlTemplate = "/"
            request = @{
                description = "OpenAI chat completions payload"
                representations = @(
                    @{
                        contentType = "application/json"
                    }
                )
            }
            responses = @(
                @{
                    statusCode = 200
                    description = "OK"
                }
            )
        }
    }

    Write-Log -Level "INFO" -Message "Creating or updating operation '$OperationId'"
    Invoke-ApimRest -Method "PUT" -RelativePath ("workspaces/{0}/apis/{1}/operations/{2}" -f $WorkspaceId, $ApiId, $OperationId) -BodyObject $operationBody | Out-Null
}

function Assign-OpenAiRole {
    param([Parameter(Mandatory = $true)][string]$PrincipalId)

    $aoaiResourceId = Invoke-AzCli -Args @(
        "cognitiveservices", "account", "show",
        "--name", $OpenAiAccountName,
        "--resource-group", $ResourceGroupName,
        "--query", "id",
        "-o", "tsv"
    ) -ReadOnly

    if ([string]::IsNullOrWhiteSpace($aoaiResourceId)) {
        throw "Unable to resolve Azure OpenAI resource id for '$OpenAiAccountName'."
    }

    $existing = Invoke-AzCli -Args @(
        "role", "assignment", "list",
        "--assignee", $PrincipalId,
        "--scope", $aoaiResourceId.Trim(),
        "--query", "[?roleDefinitionName=='Cognitive Services User'] | [0].id",
        "-o", "tsv"
    ) -ReadOnly

    if (-not [string]::IsNullOrWhiteSpace($existing)) {
        Write-Log -Level "INFO" -Message "Role assignment already exists: Cognitive Services User"
        return
    }

    Write-Log -Level "INFO" -Message "Assigning 'Cognitive Services User' role to APIM managed identity"
    Invoke-AzCli -Args @(
        "role", "assignment", "create",
        "--assignee", $PrincipalId,
        "--role", "Cognitive Services User",
        "--scope", $aoaiResourceId.Trim(),
        "-o", "none"
    ) | Out-Null
}

Test-ToolAvailable -Name "az"
Write-Log -Level "INFO" -Message "Run started. Log file: $LogFile"

Write-Log -Level "INFO" -Message "Selecting subscription"
Invoke-AzCli -Args @("account", "set", "--subscription", $SubscriptionId) -ReadOnly | Out-Null

$principalId = Resolve-ApimPrincipalId
Write-Log -Level "INFO" -Message "APIM managed identity principalId: $principalId"

Assign-OpenAiRole -PrincipalId $principalId
Ensure-Backend
Ensure-Api
Ensure-Operation

$summary = [pscustomobject]@{
    SubscriptionId = $SubscriptionId
    ResourceGroupName = $ResourceGroupName
    ApimName = $ApimName
    WorkspaceId = $WorkspaceId
    OpenAiAccountName = $OpenAiAccountName
    OpenAiDeploymentName = $OpenAiDeploymentName
    BackendId = $BackendId
    ApiId = $ApiId
    ApiPath = $ApiPath.Trim('/')
    OperationId = $OperationId
    LogFile = $LogFile
}

Write-Output ""
Write-Output "=== AI Gateway API Setup Summary ==="
$summary | Format-List | Out-String | Write-Output
