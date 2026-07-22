[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification='Command-specific parameters are used by selected subcommands.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet(
        "show-workspace",
        "list-apis",
        "create-api",
        "list-products",
        "create-product",
        "add-api-to-product",
        "list-subscriptions",
        "invoke-rest"
    )]
    [string]$Command,

    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$ApimName,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceId,

    [Parameter()]
    [string]$ApiVersion = "2024-05-01",

    [Parameter()]
    [string]$LogDirectory = (Join-Path $PSScriptRoot "logs"),

    [Parameter()]
    [string]$ApiId,

    [Parameter()]
    [string]$ApiDisplayName,

    [Parameter()]
    [string]$ApiPath,

    [Parameter()]
    [string]$ApiOpenApiSpecUrl,

    [Parameter()]
    [ValidateSet("openapi+json-link", "openapi-link", "swagger-link-json", "swagger-json")]
    [string]$ApiSpecFormat = "openapi+json-link",

    [Parameter()]
    [string]$ProductId,

    [Parameter()]
    [string]$ProductDisplayName,

    [Parameter()]
    [string]$ProductDescription = "",

    [Parameter()]
    [bool]$SubscriptionRequired = $true,

    [Parameter()]
    [bool]$ApprovalRequired = $false,

    [Parameter()]
    [ValidateSet("notPublished", "published")]
    [string]$ProductState = "published",

    [Parameter()]
    [string]$RelativePath,

    [Parameter()]
    [ValidateSet("GET", "PUT", "POST", "PATCH", "DELETE")]
    [string]$RestMethod = "GET",

    [Parameter()]
    [string]$BodyJson,

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

function ConvertFrom-JsonSafe {
    param([string]$Text)

    if (-not $Text) {
        return $null
    }

    try {
        return ($Text | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Get-WorkspaceUrl {
    param([string]$ChildPath)

    $base = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.ApiManagement/service/$ApimName/workspaces/$WorkspaceId"
    if ([string]::IsNullOrWhiteSpace($ChildPath)) {
        return $base
    }

    $trimmed = $ChildPath.TrimStart('/')
    return "$base/$trimmed"
}

function Invoke-WorkspaceRest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Method,

        [Parameter()]
        [string]$ChildPath,

        [Parameter()]
        [object]$BodyObject,

        [Parameter()]
        [string]$BodyText
    )

    $url = Get-WorkspaceUrl -ChildPath $ChildPath
    $readOnly = $Method -eq "GET"

    $cliTokens = @(
        "rest",
        "--method", $Method,
        "--url", $url,
        "--uri-parameters", "api-version=$ApiVersion"
    )

    $bodyFile = $null
    try {
        if ($BodyObject -or $BodyText) {
            $payload = if ($BodyText) { $BodyText } else { $BodyObject | ConvertTo-Json -Depth 12 -Compress }
            $bodyFile = Join-Path $env:TEMP ("apim-workspace-cli-body-" + [guid]::NewGuid().ToString() + ".json")
            Set-Content -Path $bodyFile -Value $payload -Encoding UTF8
            $cliTokens += @("--headers", "Content-Type=application/json", "--body", "@$bodyFile")
        }

        return Invoke-AzCli -AzTokens $cliTokens -ReadOnly:$readOnly
    } finally {
        if ($bodyFile -and (Test-Path $bodyFile)) {
            Remove-Item -Path $bodyFile -Force -ErrorAction SilentlyContinue
            Write-Log -Level "DEBUG" -Message "Temporary request body removed: $bodyFile"
        }
    }
}

function Invoke-ApiProductLink {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ApiId,

        [Parameter(Mandatory = $true)]
        [string]$ProductId
    )

    $candidatePaths = @(
        "products/$ProductId/apis/$ApiId",
        "apis/$ApiId/products/$ProductId"
    )

    $lastError = $null
    foreach ($candidatePath in $candidatePaths) {
        try {
            Write-Log -Level "INFO" -Message "Attempting API/product link via '$candidatePath'"
            Invoke-WorkspaceRest -Method "PUT" -ChildPath $candidatePath | Out-Null
            return $candidatePath
        } catch {
            $lastError = $_.Exception.Message
            Write-Log -Level "WARN" -Message "Link attempt failed for '$candidatePath': $lastError"
        }
    }

    throw "Unable to link API '$ApiId' to product '$ProductId' using any supported workspace path. Last error: $lastError"
}

function Test-RequiredValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "Parameter '$Name' is required for command '$Command'."
    }
}

Test-ToolAvailable -Name "az"
Write-Log -Level "INFO" -Message "Run started. Command: $Command. Log file: $LogFile"

Write-Log -Level "INFO" -Message "Selecting subscription"
Invoke-AzCli -AzTokens @("account", "set", "--subscription", $SubscriptionId) -ReadOnly | Out-Null

switch ($Command) {
    "show-workspace" {
        $json = Invoke-WorkspaceRest -Method "GET"
        $obj = ConvertFrom-JsonSafe -Text $json
        if ($obj) {
            $obj | Select-Object @{Name='name';Expression={$_.name}}, @{Name='displayName';Expression={$_.properties.displayName}}, @{Name='description';Expression={$_.properties.description}}, @{Name='id';Expression={$_.id}} | Format-Table
        } else {
            Write-Output $json
        }
    }

    "list-apis" {
        $json = Invoke-WorkspaceRest -Method "GET" -ChildPath "apis"
        $obj = ConvertFrom-JsonSafe -Text $json
        if ($obj -and $obj.value) {
            $obj.value | Select-Object @{Name='name';Expression={$_.name}}, @{Name='displayName';Expression={$_.properties.displayName}}, @{Name='path';Expression={$_.properties.path}}, @{Name='apiType';Expression={$_.properties.apiType}} | Format-Table
        } else {
            Write-Output $json
        }
    }

    "create-api" {
        Test-RequiredValue -Name "ApiId" -Value $ApiId
        Test-RequiredValue -Name "ApiDisplayName" -Value $ApiDisplayName
        Test-RequiredValue -Name "ApiPath" -Value $ApiPath
        Test-RequiredValue -Name "ApiOpenApiSpecUrl" -Value $ApiOpenApiSpecUrl

        $body = @{
            properties = @{
                displayName = $ApiDisplayName
                path = $ApiPath
                format = $ApiSpecFormat
                value = $ApiOpenApiSpecUrl
                protocols = @("https")
            }
        }

        $json = Invoke-WorkspaceRest -Method "PUT" -ChildPath "apis/$ApiId" -BodyObject $body
        $obj = ConvertFrom-JsonSafe -Text $json
        if ($obj) {
            $obj | Select-Object @{Name='name';Expression={$_.name}}, @{Name='displayName';Expression={$_.properties.displayName}}, @{Name='path';Expression={$_.properties.path}}, @{Name='id';Expression={$_.id}} | Format-Table
        } else {
            Write-Output $json
        }
    }

    "list-products" {
        $json = Invoke-WorkspaceRest -Method "GET" -ChildPath "products"
        $obj = ConvertFrom-JsonSafe -Text $json
        if ($obj -and $obj.value) {
            $obj.value | Select-Object @{Name='name';Expression={$_.name}}, @{Name='displayName';Expression={$_.properties.displayName}}, @{Name='state';Expression={$_.properties.state}}, @{Name='subscriptionRequired';Expression={$_.properties.subscriptionRequired}} | Format-Table
        } else {
            Write-Output $json
        }
    }

    "create-product" {
        Test-RequiredValue -Name "ProductId" -Value $ProductId
        Test-RequiredValue -Name "ProductDisplayName" -Value $ProductDisplayName

        $body = @{
            properties = @{
                displayName = $ProductDisplayName
                description = $ProductDescription
                subscriptionRequired = $SubscriptionRequired
                approvalRequired = $ApprovalRequired
                state = $ProductState
            }
        }

        $json = Invoke-WorkspaceRest -Method "PUT" -ChildPath "products/$ProductId" -BodyObject $body
        $obj = ConvertFrom-JsonSafe -Text $json
        if ($obj) {
            $obj | Select-Object @{Name='name';Expression={$_.name}}, @{Name='displayName';Expression={$_.properties.displayName}}, @{Name='state';Expression={$_.properties.state}}, @{Name='id';Expression={$_.id}} | Format-Table
        } else {
            Write-Output $json
        }
    }

    "add-api-to-product" {
        Test-RequiredValue -Name "ProductId" -Value $ProductId
        Test-RequiredValue -Name "ApiId" -Value $ApiId

        try {
            $linkedPath = Invoke-ApiProductLink -ApiId $ApiId -ProductId $ProductId
            Write-Log -Level "INFO" -Message "API '$ApiId' linked to product '$ProductId' via '$linkedPath'."
        } catch {
            Write-Log -Level "WARN" -Message $_.Exception.Message
            Write-Log -Level "WARN" -Message "API '$ApiId' and product '$ProductId' still exist; the association step will need a later retry or a service-side fix."
        }
    }

    "list-subscriptions" {
        $json = Invoke-WorkspaceRest -Method "GET" -ChildPath "subscriptions"
        $obj = ConvertFrom-JsonSafe -Text $json
        if ($obj -and $obj.value) {
            $obj.value | Select-Object @{Name='name';Expression={$_.name}}, @{Name='displayName';Expression={$_.properties.displayName}}, @{Name='scope';Expression={$_.properties.scope}}, @{Name='state';Expression={$_.properties.state}} | Format-Table
        } else {
            Write-Output $json
        }
    }

    "invoke-rest" {
        if ([string]::IsNullOrWhiteSpace($RelativePath)) {
            throw "Parameter 'RelativePath' is required for command 'invoke-rest'."
        }

        $json = Invoke-WorkspaceRest -Method $RestMethod -ChildPath $RelativePath -BodyText $BodyJson
        $obj = ConvertFrom-JsonSafe -Text $json
        if ($obj) {
            $obj | ConvertTo-Json -Depth 16
        } else {
            Write-Output $json
        }
    }
}

if ($WhatIfOnly) {
    Write-Log -Level "WARN" -Message "WhatIf simulation complete. No mutating operations were executed."
}
Write-Log -Level "INFO" -Message "Run completed successfully."
