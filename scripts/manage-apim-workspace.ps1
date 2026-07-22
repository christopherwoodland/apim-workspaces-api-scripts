<#
.SYNOPSIS
Creates or verifies an APIM workspace using simplified customer-facing commands.

.DESCRIPTION
Wraps the underlying workspace scripts with sensible defaults so customers can run
default gateway, dedicated gateway preparation, or verification flows with fewer parameters.
Use create-dedicated for the most predictable customer-facing runtime setup.
Use create-default when you want the workspace created with a request to use the service's default gateway,
but plan to validate runtime separately after adding APIs.

.EXAMPLE
.\scripts\manage-apim-workspace.ps1 -Mode create-default -SubscriptionId <sub-id> -ApimName intapim001 -WorkspaceId team-a

.EXAMPLE
.\scripts\manage-apim-workspace.ps1 -Mode create-dedicated -SubscriptionId <sub-id> -ApimName intapim001 -WorkspaceId team-a-dedicated

.EXAMPLE
.\scripts\manage-apim-workspace.ps1 -Mode verify -SubscriptionId <sub-id> -ApimName intapim001 -WorkspaceId team-a
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("create-default", "create-dedicated", "verify", "verify-runtime")]
    [string]$Mode,

    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$ApimName,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceId,

    [Parameter()]
    [string]$DisplayName,

    [Parameter()]
    [string]$Description,

    [Parameter()]
    [string]$ApiId,

    [Parameter()]
    [string]$ApiPath,

    [Parameter()]
    [string]$GatewayUrl,

    [Parameter()]
    [string]$ProbePath = "/weather/seattle",

    [Parameter()]
    [int[]]$ExpectedStatusCodes = @(200),

    [Parameter()]
    [switch]$CollectDiagnostics,

    [Parameter()]
    [string]$DiagnosticsOutputPath,

    [Parameter()]
    [string]$NetworkResourceGroup,

    [Parameter()]
    [string]$Location,

    [Parameter()]
    [string]$VnetName = "apim-ws-vnet",

    [Parameter()]
    [string]$VnetAddressPrefix = "10.90.0.0/16",

    [Parameter()]
    [string]$SubnetName = "apim-ws-gw-snet",

    [Parameter()]
    [string]$SubnetPrefix = "10.90.0.0/27",

    [Parameter()]
    [string]$NsgName = "apim-ws-gw-nsg",

    [Parameter()]
    [ValidateSet("integration", "injection")]
    [string]$NetworkMode = "integration",

    [Parameter()]
    [ValidateRange(30, 3600)]
    [int]$VerificationTimeoutSeconds = 180,

    [Parameter()]
    [string]$LogDirectory = (Join-Path $PSScriptRoot "logs"),

    [Parameter()]
    [string[]]$WorkspaceRoleAssignments,

    [switch]$SkipWorkspaceCreate,
    [switch]$WhatIfOnly
)

$ErrorActionPreference = "Stop"

function Get-DefaultDisplayName {
    param([string]$Value)

    $tokens = $Value -split '[-_]+' | Where-Object { $_ }
    if (-not $tokens) {
        return $Value
    }

    return (($tokens | ForEach-Object {
        if ($_.Length -eq 1) { $_.ToUpperInvariant() } else { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1) }
    }) -join ' ')
}

function Invoke-AzCliText {
    param([string[]]$CliParts)

    $output = & az @CliParts
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed: az $($CliParts -join ' ')"
    }

    return ($output -join "`n")
}

function Get-ApimDetail {
    $apimJson = Invoke-AzCliText -CliParts @("apim", "list", "--query", "[?name=='$ApimName'] | [0]", "-o", "json")
    if (-not $apimJson) {
        throw "Could not resolve APIM instance '$ApimName'."
    }

    $apim = $apimJson | ConvertFrom-Json
    if (-not $apim) {
        throw "APIM instance '$ApimName' not found in subscription '$SubscriptionId'."
    }

    return $apim
}

function Get-WorkspaceDetail {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ApimDetails
    )

    $workspaceUrl = "https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.ApiManagement/service/{2}/workspaces/{3}?api-version=2024-05-01" -f $SubscriptionId, $ApimDetails.resourceGroup, $ApimName, $WorkspaceId
    $workspaceJson = Invoke-AzCliText -CliParts @("rest", "--method", "get", "--url", $workspaceUrl, "-o", "json")
    if (-not $workspaceJson) {
        throw "Could not resolve workspace '$WorkspaceId'."
    }

    $workspace = $workspaceJson | ConvertFrom-Json
    if (-not $workspace) {
        throw "Workspace '$WorkspaceId' could not be parsed from ARM response."
    }

    return $workspace
}

function Invoke-WorkspaceRoleAssignmentStep {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ApimDetails
    )

    if (-not $WorkspaceRoleAssignments -or $WorkspaceRoleAssignments.Count -eq 0) {
        return
    }

    $assignScriptPath = Join-Path $PSScriptRoot "assign-apim-workspace-roles.ps1"
    if (-not (Test-Path $assignScriptPath)) {
        throw "Role assignment script not found: $assignScriptPath"
    }

    & $assignScriptPath `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ApimDetails.resourceGroup `
        -ApimName $ApimName `
        -WorkspaceId $WorkspaceId `
        -WorkspaceRoleAssignments $WorkspaceRoleAssignments `
        -LogDirectory $LogDirectory `
        -WhatIfOnly:$WhatIfOnly

    if ($LASTEXITCODE -ne 0) {
        throw "Workspace role-assignment step failed."
    }
}

& az account set --subscription $SubscriptionId | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Unable to select subscription '$SubscriptionId'."
}

$apim = Get-ApimDetail

if ([string]::IsNullOrWhiteSpace($Location)) {
    $Location = $apim.location
}

if ([string]::IsNullOrWhiteSpace($NetworkResourceGroup)) {
    $NetworkResourceGroup = $apim.resourceGroup
}

switch ($Mode) {
    "create-default" {
        if ([string]::IsNullOrWhiteSpace($DisplayName)) {
            $DisplayName = Get-DefaultDisplayName -Value $WorkspaceId
        }

        if ([string]::IsNullOrWhiteSpace($Description)) {
            $Description = "Workspace created with a request to use the default managed gateway"
        }

        $scriptPath = Join-Path $PSScriptRoot "deploy-apim-workspace-default.ps1"
        & $scriptPath `
            -SubscriptionId $SubscriptionId `
            -ApimName $ApimName `
            -WorkspaceId $WorkspaceId `
            -DisplayName $DisplayName `
            -Description $Description `
            -VerificationTimeoutSeconds $VerificationTimeoutSeconds `
            -LogDirectory $LogDirectory `
            -WhatIfOnly:$WhatIfOnly

        Invoke-WorkspaceRoleAssignmentStep -ApimDetails $apim
    }

    "create-dedicated" {
        if ([string]::IsNullOrWhiteSpace($DisplayName)) {
            $DisplayName = Get-DefaultDisplayName -Value $WorkspaceId
        }

        if ([string]::IsNullOrWhiteSpace($Description)) {
            $Description = "Workspace prepared for dedicated gateway deployment"
        }

        $scriptPath = Join-Path $PSScriptRoot "deploy-apim-workspace-dedicated.ps1"
        & $scriptPath `
            -SubscriptionId $SubscriptionId `
            -ApimName $ApimName `
            -WorkspaceId $WorkspaceId `
            -DisplayName $DisplayName `
            -Description $Description `
            -NetworkResourceGroup $NetworkResourceGroup `
            -Location $Location `
            -VnetName $VnetName `
            -VnetAddressPrefix $VnetAddressPrefix `
            -SubnetName $SubnetName `
            -SubnetPrefix $SubnetPrefix `
            -NsgName $NsgName `
            -NetworkMode $NetworkMode `
            -VerificationTimeoutSeconds $VerificationTimeoutSeconds `
            -LogDirectory $LogDirectory `
            -SkipWorkspaceCreate:$SkipWorkspaceCreate `
            -WhatIfOnly:$WhatIfOnly

        Invoke-WorkspaceRoleAssignmentStep -ApimDetails $apim
    }

    "verify" {
        if ([string]::IsNullOrWhiteSpace($DisplayName) -and [string]::IsNullOrWhiteSpace($Description)) {
            $workspace = Get-WorkspaceDetail -ApimDetails $apim
            $workspace | Select-Object @{Name='id';Expression={$_.id}}, @{Name='name';Expression={$_.name}}, @{Name='displayName';Expression={$_.properties.displayName}}, @{Name='description';Expression={$_.properties.description}} | Format-Table
            return
        }

        $scriptPath = Join-Path $PSScriptRoot "verify-apim-workspace.ps1"
        & $scriptPath `
            -SubscriptionId $SubscriptionId `
            -ApimName $ApimName `
            -WorkspaceId $WorkspaceId `
            -DisplayName $DisplayName `
            -Description $Description `
            -VerificationTimeoutSeconds $VerificationTimeoutSeconds `
            -LogDirectory $LogDirectory
    }

    "verify-runtime" {
        $scriptPath = Join-Path $PSScriptRoot "verify-apim-workspace-runtime.ps1"
        & $scriptPath `
            -SubscriptionId $SubscriptionId `
            -ApimName $ApimName `
            -WorkspaceId $WorkspaceId `
            -ResourceGroupName $apim.resourceGroup `
            -ApiId $ApiId `
            -ApiPath $ApiPath `
            -GatewayUrl $GatewayUrl `
            -ProbePath $ProbePath `
            -ExpectedStatusCodes $ExpectedStatusCodes `
            -LogDirectory $LogDirectory `
            -CollectDiagnostics:$CollectDiagnostics `
            -DiagnosticsOutputPath $DiagnosticsOutputPath
    }
}

if ($LASTEXITCODE -ne 0) {
    throw "Workspace command '$Mode' failed."
}