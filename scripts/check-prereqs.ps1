[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

function Write-Check {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Detail
    )

    $status = if ($Passed) { "PASS" } else { "FAIL" }
    Write-Output ("[{0}] {1} - {2}" -f $status, $Name, $Detail)
}

$failed = $false

# PowerShell version
$psVersion = $PSVersionTable.PSVersion.ToString()
Write-Check -Name "PowerShell" -Passed $true -Detail $psVersion

# Azure CLI
$az = Get-Command az -ErrorAction SilentlyContinue
if (-not $az) {
    Write-Check -Name "Azure CLI" -Passed $false -Detail "az not found in PATH"
    $failed = $true
} else {
    $azVersion = "unknown"
    try {
        $versionJson = & az version -o json 2>$null
        if ($versionJson) {
            $versionObj = ($versionJson -join "`n") | ConvertFrom-Json
            if ($versionObj."azure-cli") {
                $azVersion = [string]$versionObj."azure-cli"
            }
        }
    } catch {
    }
    Write-Check -Name "Azure CLI" -Passed $true -Detail "version $azVersion"
}

# Azure login context
if ($az) {
    try {
        $account = & az account show -o json | ConvertFrom-Json
        if ($account -and $account.id) {
            Write-Check -Name "Azure Login" -Passed $true -Detail ("subscription {0}, tenant {1}" -f $account.id, $account.tenantId)
        } else {
            Write-Check -Name "Azure Login" -Passed $false -Detail "no active account"
            $failed = $true
        }
    } catch {
        Write-Check -Name "Azure Login" -Passed $false -Detail "not logged in or context unavailable"
        $failed = $true
    }
}

# Dotnet SDK
$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if (-not $dotnet) {
    Write-Check -Name ".NET SDK" -Passed $false -Detail "dotnet not found in PATH"
    $failed = $true
} else {
    $sdkVersion = (& dotnet --version 2>$null)
    Write-Check -Name ".NET SDK" -Passed $true -Detail "version $sdkVersion"
}

# Required scripts
$required = @(
    "manage-apim-workspace.ps1",
    "deploy-apim-workspace-default.ps1",
    "deploy-apim-workspace-dedicated.ps1",
    "verify-apim-workspace-runtime.ps1",
    "assign-apim-workspace-roles.ps1"
)

foreach ($scriptName in $required) {
    $fullPath = Join-Path $PSScriptRoot $scriptName
    $exists = Test-Path $fullPath
    Write-Check -Name ("Script {0}" -f $scriptName) -Passed $exists -Detail $fullPath
    if (-not $exists) {
        $failed = $true
    }
}

if ($failed) {
    throw "Prerequisite validation failed. See FAIL items above."
}

Write-Output "All prerequisite checks passed."