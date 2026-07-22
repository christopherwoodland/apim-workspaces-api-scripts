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
    [string]$Description = "Workspace prepared for dedicated gateway deployment",

    [Parameter(Mandatory = $true)]
    [string]$NetworkResourceGroup,

    [Parameter(Mandatory = $true)]
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

    [switch]$SkipWorkspaceCreate,
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

function Write-Step {
    param([string]$Message)
    Write-Log -Level "INFO" -Message "STEP: $Message"
}

function Test-ToolAvailable {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required tool '$Name' not found in PATH."
    }
}

function Test-WorkspaceSku {
    param([string]$SkuName)
    $supported = @("BasicV2", "StandardV2", "Premium", "PremiumV2")
    return $supported -contains $SkuName
}

function ConvertTo-LocationToken {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    return (($Value -replace "[^a-zA-Z0-9]", "").ToLowerInvariant())
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

Test-ToolAvailable -Name "az"
Write-Log -Level "INFO" -Message "Run started. Log file: $LogFile"

Write-Step "Selecting subscription"
Invoke-AzCli -Args @("account", "set", "--subscription", $SubscriptionId) -ReadOnly | Out-Null

Write-Step "Resolving API Management instance"
$apimJson = Invoke-AzCli -Args @("apim", "list", "--query", "[?name=='$ApimName'] | [0]", "-o", "json") -ReadOnly

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

$skuName = $apim.sku.name
if (-not (Test-WorkspaceSku -SkuName $skuName)) {
    throw "APIM SKU '$skuName' may not support workspaces. Supported SKUs are BasicV2, StandardV2, Premium, PremiumV2."
}

$apimLocation = $apim.location
if ($apimLocation -and (ConvertTo-LocationToken -Value $apimLocation) -ne (ConvertTo-LocationToken -Value $Location)) {
    throw "Location mismatch: APIM is in '$apimLocation' but script Location is '$Location'. Dedicated workspace gateway networking requires same region."
}

Write-Log -Level "INFO" -Message "APIM resource group: $resourceGroup"
Write-Log -Level "INFO" -Message "APIM SKU: $skuName"
Write-Log -Level "INFO" -Message "APIM location: $apimLocation"

Write-Step "Registering Microsoft.Web provider (required for subnet delegation)"
Invoke-AzCli -Args @("provider", "register", "--namespace", "Microsoft.Web") | Out-Null

Write-Step "Ensuring network resource group exists"
Invoke-AzCli -Args @("group", "create", "--name", $NetworkResourceGroup, "--location", $Location, "--output", "none") | Out-Null

Write-Step "Creating NSG"
Invoke-AzCli -Args @("network", "nsg", "create", "--resource-group", $NetworkResourceGroup, "--name", $NsgName, "--location", $Location, "--output", "none") | Out-Null

Write-Step "Creating VNet and subnet"
Invoke-AzCli -Args @("network", "vnet", "create", "--resource-group", $NetworkResourceGroup, "--name", $VnetName, "--location", $Location, "--address-prefixes", $VnetAddressPrefix, "--subnet-name", $SubnetName, "--subnet-prefixes", $SubnetPrefix, "--output", "none") | Out-Null

if ($NetworkMode -eq "integration") {
    $delegation = "Microsoft.Web/serverFarms"
} else {
    $delegation = "Microsoft.Web/hostingEnvironments"
}

Write-Step "Delegating subnet for workspace gateway mode: $NetworkMode"
Invoke-AzCli -Args @("network", "vnet", "subnet", "update", "--resource-group", $NetworkResourceGroup, "--vnet-name", $VnetName, "--name", $SubnetName, "--delegations", $delegation, "--network-security-group", $NsgName, "--output", "none") | Out-Null

Write-Step "Creating required outbound NSG rules"
Invoke-AzCli -Args @("network", "nsg", "rule", "create", "--resource-group", $NetworkResourceGroup, "--nsg-name", $NsgName, "--name", "allow-storage-443", "--priority", "200", "--direction", "Outbound", "--access", "Allow", "--protocol", "Tcp", "--source-address-prefixes", "VirtualNetwork", "--source-port-ranges", "*", "--destination-address-prefixes", "Storage", "--destination-port-ranges", "443", "--output", "none") | Out-Null
Invoke-AzCli -Args @("network", "nsg", "rule", "create", "--resource-group", $NetworkResourceGroup, "--nsg-name", $NsgName, "--name", "allow-keyvault-443", "--priority", "210", "--direction", "Outbound", "--access", "Allow", "--protocol", "Tcp", "--source-address-prefixes", "VirtualNetwork", "--source-port-ranges", "*", "--destination-address-prefixes", "AzureKeyVault", "--destination-port-ranges", "443", "--output", "none") | Out-Null

if ($NetworkMode -eq "injection") {
    Write-Step "Creating additional inbound NSG rules for injection mode"
    Invoke-AzCli -Args @("network", "nsg", "rule", "create", "--resource-group", $NetworkResourceGroup, "--nsg-name", $NsgName, "--name", "allow-lb-80", "--priority", "220", "--direction", "Inbound", "--access", "Allow", "--protocol", "Tcp", "--source-address-prefixes", "AzureLoadBalancer", "--source-port-ranges", "*", "--destination-address-prefixes", "*", "--destination-port-ranges", "80", "--output", "none") | Out-Null
    Invoke-AzCli -Args @("network", "nsg", "rule", "create", "--resource-group", $NetworkResourceGroup, "--nsg-name", $NsgName, "--name", "allow-vnet-80-443", "--priority", "230", "--direction", "Inbound", "--access", "Allow", "--protocol", "Tcp", "--source-address-prefixes", "VirtualNetwork", "--source-port-ranges", "*", "--destination-address-prefixes", "*", "--destination-port-ranges", "80", "443", "--output", "none") | Out-Null
}

$subnetId = "/subscriptions/$SubscriptionId/resourceGroups/$NetworkResourceGroup/providers/Microsoft.Network/virtualNetworks/$VnetName/subnets/$SubnetName"
if ($WhatIfOnly) {
    Write-Log -Level "INFO" -Message "WhatIfOnly: dedicated subnet would be prepared as: $subnetId"
} else {
    Write-Log -Level "INFO" -Message "Dedicated subnet prepared: $subnetId"
}

if (-not $SkipWorkspaceCreate) {
    if (-not $WhatIfOnly) {
        $body = @{
            properties = @{
                displayName = $DisplayName
                description = $Description
            }
        } | ConvertTo-Json -Depth 6 -Compress

        $bodyFile = Join-Path $env:TEMP ("apim-workspace-body-" + [guid]::NewGuid().ToString() + ".json")
        Set-Content -Path $bodyFile -Value $body -Encoding UTF8

        $apiVersion = "2024-05-01"
        $workspaceUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ApiManagement/service/$ApimName/workspaces/$WorkspaceId"

        Write-Step "Creating or updating workspace"
        try {
            Invoke-AzCli -Args @("rest", "--method", "put", "--url", $workspaceUrl, "--uri-parameters", "api-version=$apiVersion", "--headers", "Content-Type=application/json", "--body", "@$bodyFile") | Out-Null
        } finally {
            if (Test-Path $bodyFile) {
                Remove-Item -Path $bodyFile -Force -ErrorAction SilentlyContinue
                Write-Log -Level "DEBUG" -Message "Temporary request body removed: $bodyFile"
            }
        }

        Write-Step "Verifying workspace deployment"
        $verifiedWorkspace = Wait-WorkspaceVerification -WorkspaceUrl $workspaceUrl -ExpectedWorkspaceId $WorkspaceId -ExpectedDisplayName $DisplayName -ExpectedDescription $Description -ApiVersion $apiVersion -TimeoutSeconds $VerificationTimeoutSeconds

        $verifiedWorkspace | Select-Object @{Name='id';Expression={$_.id}}, @{Name='name';Expression={$_.name}}, @{Name='displayName';Expression={$_.properties.displayName}}, @{Name='description';Expression={$_.properties.description}} | Format-Table
    }
}

if ($WhatIfOnly) {
    Write-Log -Level "WARN" -Message "NEXT: WhatIf simulation complete. No Azure resources were changed."
} else {
    Write-Log -Level "WARN" -Message "NEXT: Network prerequisites are complete for dedicated mode."
}
Write-Log -Level "WARN" -Message "NEXT: Create or associate a workspace gateway to this workspace using the Azure portal (documented and fully supported path)."
Write-Log -Level "WARN" -Message "NEXT: Use this subnet ID during gateway setup: $subnetId"
Write-Log -Level "INFO" -Message "Dedicated-mode preparation completed."
Write-Log -Level "INFO" -Message "Run completed successfully."
