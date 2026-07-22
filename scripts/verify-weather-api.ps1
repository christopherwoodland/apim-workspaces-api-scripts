[CmdletBinding()]
param(
    [Parameter()]
    [string]$BaseUrl = "https://weather-api-cw001.mangomeadow-171b7d7e.eastus2.azurecontainerapps.io",

    [Parameter()]
    [string]$HealthPath = "/health",

    [Parameter()]
    [string]$WeatherPath = "/weather/seattle",

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

function Invoke-EndpointCheck {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    [void](Write-Log -Level "INFO" -Message ("Checking {0}: {1}" -f $Name, $Url))
    try {
        $response = Invoke-RestMethod -Uri $Url -Method Get -TimeoutSec 30
        return [pscustomobject]@{
            Name = $Name
            Url = $Url
            Healthy = $true
            Response = $response
        }
    } catch {
        return [pscustomobject]@{
            Name = $Name
            Url = $Url
            Healthy = $false
            Error = $_.Exception.Message
        }
    }
}

$healthUrl = ($BaseUrl.TrimEnd('/') + $HealthPath)
$weatherUrl = ($BaseUrl.TrimEnd('/') + $WeatherPath)

Write-Log -Level "INFO" -Message "Run started. Log file: $LogFile"

$results = @(
    Invoke-EndpointCheck -Url $healthUrl -Name "health"
    Invoke-EndpointCheck -Url $weatherUrl -Name "weather"
)

$failed = $results | Where-Object { -not $_.Healthy }

if ($failed) {
    foreach ($item in $failed) {
        Write-Log -Level "ERROR" -Message "$($item.Name) check failed: $($item.Error)"
    }

    Write-Output ($results | ConvertTo-Json -Depth 8)
    exit 1
}

Write-Log -Level "INFO" -Message "All endpoint checks passed."
Write-Output ($results | ConvertTo-Json -Depth 8)
Write-Output "LOG_FILE=$LogFile"