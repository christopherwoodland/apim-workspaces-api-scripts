[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$ApimName,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceId,

    [Parameter(Mandatory = $true)]
    [string]$DisplayName,

    [Parameter()]
    [string]$Description = "",

    [Parameter()]
    [ValidateRange(30, 3600)]
    [int]$VerificationTimeoutSeconds = 180,

    [Parameter()]
    [string]$ApiVersion = "2024-05-01",

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
        Write-Log -Level "ERROR" -Message "Azure CLI command failed with exit code $LASTEXITCODE"
        throw "Azure CLI command failed: az $($displayArgs -join ' ')"
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

function Wait-WorkspaceVerification {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkspaceUrl,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedWorkspaceId,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedDisplayName,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedDescription,

        [Parameter(Mandatory = $true)]
        [string]$ApiVersion,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastErrorMessage = "No successful response was received from workspace endpoint."

    while ((Get-Date) -lt $deadline) {
        try {
            Write-Log -Level "DEBUG" -Message "Polling workspace endpoint for verification."
            $json = Invoke-AzCli -Args @("rest", "--method", "get", "--url", $WorkspaceUrl, "--uri-parameters", "api-version=$ApiVersion", "-o", "json")
            if (-not $json) {
                $lastErrorMessage = "Workspace read returned empty response or non-zero exit code."
                Start-Sleep -Seconds 5
                continue
            }

            $ws = $json | ConvertFrom-Json
            if (-not $ws) {
                $lastErrorMessage = "Workspace response could not be parsed as JSON."
                Start-Sleep -Seconds 5
                continue
            }

            $idOk = $ws.name -eq $ExpectedWorkspaceId
            $displayOk = $ws.properties.displayName -eq $ExpectedDisplayName
            $descOk = $ws.properties.description -eq $ExpectedDescription

            if ($idOk -and $displayOk -and $descOk) {
                Write-Log -Level "INFO" -Message "Workspace verification checks passed."
                return $ws
            }

            $lastErrorMessage = "Workspace response did not match expected values."
        } catch {
            $lastErrorMessage = $_.Exception.Message
        }

        Start-Sleep -Seconds 5
    }

    throw "Workspace verification failed within $TimeoutSeconds seconds. Last error: $lastErrorMessage"
}

Test-ToolAvailable -Name "az"
Write-Log -Level "INFO" -Message "Run started. Log file: $LogFile"
Write-Log -Level "INFO" -Message "Selecting subscription"
Invoke-AzCli -Args @("account", "set", "--subscription", $SubscriptionId) | Out-Null

Write-Log -Level "INFO" -Message "Resolving API Management instance"
$apimJson = Invoke-AzCli -Args @("apim", "list", "--query", "[?name=='$ApimName'] | [0]", "-o", "json")
if (-not $apimJson) {
    throw "Could not resolve APIM instance '$ApimName'."
}

$apim = $apimJson | ConvertFrom-Json
if (-not $apim) {
    throw "APIM instance '$ApimName' not found in subscription '$SubscriptionId'."
}

$resourceGroup = $apim.resourceGroup
if (-not $resourceGroup) {
    throw "Unable to determine resource group for APIM instance '$ApimName'."
}

$workspaceUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ApiManagement/service/$ApimName/workspaces/$WorkspaceId"

Write-Log -Level "INFO" -Message "Running workspace verification"
$verifiedWorkspace = Wait-WorkspaceVerification -WorkspaceUrl $workspaceUrl -ExpectedWorkspaceId $WorkspaceId -ExpectedDisplayName $DisplayName -ExpectedDescription $Description -ApiVersion $ApiVersion -TimeoutSeconds $VerificationTimeoutSeconds

$verifiedWorkspace | Select-Object @{Name='id';Expression={$_.id}}, @{Name='name';Expression={$_.name}}, @{Name='displayName';Expression={$_.properties.displayName}}, @{Name='description';Expression={$_.properties.description}} | Format-Table

Write-Log -Level "INFO" -Message "Workspace verification completed successfully."
Write-Log -Level "INFO" -Message "Run completed successfully."
