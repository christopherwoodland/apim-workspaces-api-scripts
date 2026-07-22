[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$ApimName,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceId,

    [Parameter()]
    [string]$ResourceGroupName,

    [Parameter()]
    [string]$ApiVersionPreview = "2024-10-01-preview",

    [Parameter()]
    [string]$ApiVersionGa = "2024-05-01",

    [Parameter()]
    [string]$GatewayUrl,

    [Parameter()]
    [string]$ApiPath,

    [Parameter()]
    [string]$ProbePath,

    [Parameter()]
    [ValidateRange(1, 72)]
    [int]$ActivityLogHours = 24,

    [Parameter()]
    [switch]$FixDefaultGatewayAssociation,

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
$ReportPath = Join-Path $LogDirectory ("$scriptName-report-$runId.json")

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

function Invoke-AzCliRaw {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Args
    )

    $display = $Args | ForEach-Object {
        if ($_ -match "\s") { '"' + $_ + '"' } else { $_ }
    }

    Write-Log -Level "DEBUG" -Message ("Running command: az " + ($display -join " "))

    $output = @()
    $exitCode = 0
    try {
        $output = & az @Args 2>&1
        $exitCode = $LASTEXITCODE
    } catch {
        $exitCode = 1
        if ($_.Exception -and $_.Exception.Message) {
            $output += $_.Exception.Message
        } else {
            $output += "Azure CLI failed with an unknown error."
        }
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = @($output | ForEach-Object { $_.ToString() })
    }
}

function Invoke-AzCliJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Args
    )

    $result = Invoke-AzCliRaw -Args $Args
    if ($result.ExitCode -ne 0) {
        $message = ($result.Output -join "`n")
        throw "Azure CLI command failed: az $($Args -join ' ')`n$message"
    }

    $text = ($result.Output -join "`n")
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    try {
        return ($text | ConvertFrom-Json)
    } catch {
        throw "Could not parse Azure CLI JSON output."
    }
}

function Resolve-ApimResourceGroup {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $apim = Invoke-AzCliJson -Args @("apim", "list", "--query", "[?name=='$Name'] | [0]", "-o", "json")
    if (-not $apim) {
        throw "APIM service '$Name' was not found in subscription '$SubscriptionId'."
    }

    return $apim.resourceGroup
}

function Get-ApimServiceInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroup,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return Invoke-AzCliJson -Args @("apim", "show", "-g", $ResourceGroup, "-n", $Name, "-o", "json")
}

function Get-WorkspaceByVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Version,

        [Parameter(Mandatory = $true)]
        [string]$WorkspaceUrl
    )

    $result = Invoke-AzCliRaw -Args @("rest", "--method", "get", "--url", "${WorkspaceUrl}?api-version=$Version", "-o", "json")
    if ($result.ExitCode -ne 0) {
        return [pscustomobject]@{
            Succeeded = $false
            ApiVersion = $Version
            Error = ($result.Output -join "`n")
            Resource = $null
        }
    }

    $text = ($result.Output -join "`n")
    $obj = $null
    if (-not [string]::IsNullOrWhiteSpace($text)) {
        try {
            $obj = $text | ConvertFrom-Json
        } catch {
            return [pscustomobject]@{
                Succeeded = $false
                ApiVersion = $Version
                Error = "JSON parse failed for workspace GET response."
                Resource = $null
            }
        }
    }

    return [pscustomobject]@{
        Succeeded = $true
        ApiVersion = $Version
        Error = $null
        Resource = $obj
    }
}

function Get-WorkspaceGatewaySnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkspaceBaseUrl,

        [Parameter(Mandatory = $true)]
        [string]$Version
    )

    $result = Invoke-AzCliRaw -Args @("rest", "--method", "get", "--url", "$WorkspaceBaseUrl/gateways?api-version=$Version", "-o", "json")
    if ($result.ExitCode -ne 0) {
        return [pscustomobject]@{
            Succeeded = $false
            ApiVersion = $Version
            Gateways = @()
            Error = ($result.Output -join "`n")
        }
    }

    $obj = $null
    try {
        $obj = (($result.Output -join "`n") | ConvertFrom-Json)
    } catch {
        return [pscustomobject]@{
            Succeeded = $false
            ApiVersion = $Version
            Gateways = @()
            Error = "JSON parse failed for gateways list response."
        }
    }

    $names = @()
    if ($obj -and $obj.value) {
        $names = @($obj.value | ForEach-Object {
            if ($_.name) { [string]$_.name }
            elseif ($_.id) { [string]$_.id }
            else { $null }
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    return [pscustomobject]@{
        Succeeded = $true
        ApiVersion = $Version
        Gateways = $names
        Error = $null
    }
}

function Set-WorkspaceServeOnDefault {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkspaceBaseUrl,

        [Parameter(Mandatory = $true)]
        [string[]]$ApiVersions,

        [Parameter(Mandatory = $true)]
        [object]$WorkspaceResource
    )

    $displayName = [string]$WorkspaceResource.properties.displayName
    if ([string]::IsNullOrWhiteSpace($displayName)) {
        $displayName = $WorkspaceId
    }

    $description = [string]$WorkspaceResource.properties.description

    $payload = [pscustomobject]@{
        properties = [pscustomobject]@{
            displayName = $displayName
            description = $description
            serveOn = "workspaceAndDefault"
        }
    } | ConvertTo-Json -Depth 10 -Compress

    $bodyPath = Join-Path $env:TEMP ("workspace-default-gw-" + [guid]::NewGuid().ToString() + ".json")
    Set-Content -Path $bodyPath -Value $payload -Encoding UTF8

    try {
        $attempts = @()
        foreach ($version in $ApiVersions) {
            $putResult = Invoke-AzCliRaw -Args @(
                "rest",
                "--method", "put",
                "--url", "${WorkspaceBaseUrl}?api-version=$version",
                "--headers", "Content-Type=application/json",
                "--body", "@$bodyPath",
                "-o", "json"
            )

            $attempts += [pscustomobject]@{
                ApiVersion = $version
                ExitCode = $putResult.ExitCode
                OutputPreview = (($putResult.Output | Select-Object -First 5) -join " | ")
            }

            if ($putResult.ExitCode -eq 0) {
                return [pscustomobject]@{
                    Success = $true
                    AppliedApiVersion = $version
                    Attempts = $attempts
                }
            }
        }

        return [pscustomobject]@{
            Success = $false
            AppliedApiVersion = $null
            Attempts = $attempts
        }
    } finally {
        if (Test-Path $bodyPath) {
            Remove-Item -Path $bodyPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-WorkspaceApis {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkspaceBaseUrl,

        [Parameter(Mandatory = $true)]
        [string]$Version
    )

    $result = Invoke-AzCliRaw -Args @("rest", "--method", "get", "--url", "$WorkspaceBaseUrl/apis?api-version=$Version", "-o", "json")
    if ($result.ExitCode -ne 0) {
        return [pscustomobject]@{
            Succeeded = $false
            ApiVersion = $Version
            Apis = @()
            Error = ($result.Output -join "`n")
        }
    }

    $obj = $null
    try {
        $obj = (($result.Output -join "`n") | ConvertFrom-Json)
    } catch {
        return [pscustomobject]@{
            Succeeded = $false
            ApiVersion = $Version
            Apis = @()
            Error = "JSON parse failed for workspace APIs response."
        }
    }

    $apis = @()
    if ($obj -and $obj.value) {
        $apis = @($obj.value)
    }

    return [pscustomobject]@{
        Succeeded = $true
        ApiVersion = $Version
        Apis = $apis
        Error = $null
    }
}

function Get-ApiGatewayAssignments {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkspaceBaseUrl,

        [Parameter(Mandatory = $true)]
        [string]$ApiName,

        [Parameter(Mandatory = $true)]
        [string]$Version
    )

    $result = Invoke-AzCliRaw -Args @("rest", "--method", "get", "--url", "$WorkspaceBaseUrl/apis/$ApiName/gateways?api-version=$Version", "-o", "json")
    if ($result.ExitCode -ne 0) {
        return [pscustomobject]@{
            ApiName = $ApiName
            Succeeded = $false
            Gateways = @()
            Error = ($result.Output -join "`n")
        }
    }

    $obj = $null
    try {
        $obj = (($result.Output -join "`n") | ConvertFrom-Json)
    } catch {
        return [pscustomobject]@{
            ApiName = $ApiName
            Succeeded = $false
            Gateways = @()
            Error = "JSON parse failed for API gateways response."
        }
    }

    $gateways = @()
    if ($obj -and $obj.value) {
        $gateways = @($obj.value | ForEach-Object {
            if ($_.name) { [string]$_.name }
            elseif ($_.id) { [string]$_.id }
            else { $null }
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    return [pscustomobject]@{
        ApiName = $ApiName
        Succeeded = $true
        Gateways = $gateways
        Error = $null
    }
}

function Invoke-UrlProbe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    try {
        $response = Invoke-WebRequest -Uri $Url -Method Get -TimeoutSec 20 -UseBasicParsing -ErrorAction Stop
        return [pscustomobject]@{
            Url = $Url
            Succeeded = $true
            StatusCode = [int]$response.StatusCode
            Error = $null
        }
    } catch {
        $statusCode = $null
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }

        return [pscustomobject]@{
            Url = $Url
            Succeeded = $false
            StatusCode = $statusCode
            Error = $_.Exception.Message
        }
    }
}

function Get-WorkspaceActivityLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceId,

        [Parameter(Mandatory = $true)]
        [int]$Hours
    )

    $offset = "{0}h" -f $Hours
    $raw = Invoke-AzCliRaw -Args @("monitor", "activity-log", "list", "--resource-id", $ResourceId, "--offset", $offset, "--max-events", "50", "-o", "json")
    if ($raw.ExitCode -ne 0) {
        return [pscustomobject]@{
            Succeeded = $false
            Events = @()
            Error = ($raw.Output -join "`n")
        }
    }

    $events = @()
    try {
        $events = @((($raw.Output -join "`n") | ConvertFrom-Json))
    } catch {
        return [pscustomobject]@{
            Succeeded = $false
            Events = @()
            Error = "JSON parse failed for activity log response."
        }
    }

    return [pscustomobject]@{
        Succeeded = $true
        Events = $events
        Error = $null
    }
}

Test-ToolAvailable -Name "az"
Write-Log -Level "INFO" -Message "Run started. Log file: $LogFile"

Write-Log -Level "INFO" -Message "Selecting subscription $SubscriptionId"
$setResult = Invoke-AzCliRaw -Args @("account", "set", "--subscription", $SubscriptionId)
if ($setResult.ExitCode -ne 0) {
    throw "Unable to select subscription '$SubscriptionId'."
}

$effectiveResourceGroup = $ResourceGroupName
if ([string]::IsNullOrWhiteSpace($effectiveResourceGroup)) {
    $effectiveResourceGroup = Resolve-ApimResourceGroup -Name $ApimName
}

$apimService = Get-ApimServiceInfo -ResourceGroup $effectiveResourceGroup -Name $ApimName
$apimSkuName = [string]$apimService.sku.name
$managedV2Sku = @("BasicV2", "StandardV2", "PremiumV2") -contains $apimSkuName

$workspaceBaseUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$effectiveResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName/workspaces/$WorkspaceId"
$workspaceResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$effectiveResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName/workspaces/$WorkspaceId"

Write-Log -Level "INFO" -Message "Step 1: Reading workspace resource and gateway association fields"
$workspacePreview = Get-WorkspaceByVersion -Version $ApiVersionPreview -WorkspaceUrl $workspaceBaseUrl
$workspaceGa = Get-WorkspaceByVersion -Version $ApiVersionGa -WorkspaceUrl $workspaceBaseUrl
$gatewaysPreview = if ($managedV2Sku) {
    [pscustomobject]@{
        Succeeded = $false
        ApiVersion = $ApiVersionPreview
        Gateways = @()
        Error = $null
        Skipped = $true
        Reason = "Gateway subresource listing is not supported on SKU '$apimSkuName' for this managed workspace flow."
    }
} else {
    Get-WorkspaceGatewaySnapshot -WorkspaceBaseUrl $workspaceBaseUrl -Version $ApiVersionPreview
}

if (-not $workspacePreview.Succeeded) {
    Write-Log -Level "WARN" -Message ("Workspace read failed for preview api-version {0}: {1}" -f $ApiVersionPreview, $workspacePreview.Error)
}
if (-not $workspaceGa.Succeeded) {
    Write-Log -Level "WARN" -Message ("Workspace read failed for GA api-version {0}: {1}" -f $ApiVersionGa, $workspaceGa.Error)
}

$workspaceForFix = $null
if ($workspacePreview.Succeeded -and $workspacePreview.Resource) {
    $workspaceForFix = $workspacePreview.Resource
} elseif ($workspaceGa.Succeeded -and $workspaceGa.Resource) {
    $workspaceForFix = $workspaceGa.Resource
}

$serveOn = $null
if ($workspacePreview.Succeeded -and $workspacePreview.Resource -and $workspacePreview.Resource.properties.serveOn) {
    $serveOn = [string]$workspacePreview.Resource.properties.serveOn
}

$defaultGatewayAssociated = "unknown"
$associationSource = if ($managedV2Sku) { "not-returned-by-arm-on-v2-sku" } else { "not-returned-by-arm" }
if (-not [string]::IsNullOrWhiteSpace($serveOn)) {
    $defaultGatewayAssociated = if ($serveOn -match "workspaceAndDefault") { "yes" } else { "no" }
    $associationSource = "workspace.properties.serveOn"
}

$associatedGateways = @()
if ($gatewaysPreview.Succeeded -and $gatewaysPreview.Gateways.Count -gt 0) {
    $associatedGateways = $gatewaysPreview.Gateways
}

Write-Log -Level "INFO" -Message "Step 2: Inspecting activity logs for create/update call pattern and caller"
$activity = Get-WorkspaceActivityLog -ResourceId $workspaceResourceId -Hours $ActivityLogHours
$workspaceWriteEvents = @()
$failedEvents = @()
if ($activity.Succeeded) {
    $workspaceWriteEvents = @($activity.Events | Where-Object {
        $_.operationName -and $_.operationName.value -match "Microsoft.ApiManagement/service/workspaces/write"
    })

    $failedEvents = @($activity.Events | Where-Object {
        $_.status -and $_.status.value -match "Failed"
    })
}

$inferredCreateSource = "unknown"
if ($workspaceWriteEvents.Count -gt 0) {
    $latestCaller = [string]$workspaceWriteEvents[0].caller
    if ($latestCaller -match "@") {
        $inferredCreateSource = "interactive-or-service-principal"
    }

    if ($workspaceWriteEvents[0].claims -and $workspaceWriteEvents[0].claims.http) {
        $inferredCreateSource = "arm-deployment-or-cli"
    }
}

Write-Log -Level "INFO" -Message "Step 3: Optional explicit PUT to set default gateway association"
$fixResult = $null
if ($FixDefaultGatewayAssociation) {
    if (-not $workspaceForFix) {
        $fixResult = [pscustomobject]@{
            Success = $false
            AppliedApiVersion = $null
            Attempts = @()
            Error = "Cannot apply fix because workspace could not be read."
            WorkspaceReadErrors = [pscustomobject]@{
                Preview = $workspacePreview.Error
                Ga = $workspaceGa.Error
            }
        }
        Write-Log -Level "WARN" -Message $fixResult.Error
        if ($workspacePreview.Error) {
            Write-Log -Level "WARN" -Message ("Preview read error: " + $workspacePreview.Error)
        }
        if ($workspaceGa.Error) {
            Write-Log -Level "WARN" -Message ("GA read error: " + $workspaceGa.Error)
        }
    } else {
        $fixResult = Set-WorkspaceServeOnDefault -WorkspaceBaseUrl $workspaceBaseUrl -ApiVersions @($ApiVersionPreview, $ApiVersionGa) -WorkspaceResource $workspaceForFix

        # Re-read snapshot after fix attempt.
        $workspacePreview = Get-WorkspaceByVersion -Version $ApiVersionPreview -WorkspaceUrl $workspaceBaseUrl
        $gatewaysPreview = if ($managedV2Sku) {
            [pscustomobject]@{
                Succeeded = $false
                ApiVersion = $ApiVersionPreview
                Gateways = @()
                Error = $null
                Skipped = $true
                Reason = "Gateway subresource listing is not supported on SKU '$apimSkuName' for this managed workspace flow."
            }
        } else {
            Get-WorkspaceGatewaySnapshot -WorkspaceBaseUrl $workspaceBaseUrl -Version $ApiVersionPreview
        }

        $serveOn = $null
        if ($workspacePreview.Succeeded -and $workspacePreview.Resource -and $workspacePreview.Resource.properties.serveOn) {
            $serveOn = [string]$workspacePreview.Resource.properties.serveOn
        }

        if (-not [string]::IsNullOrWhiteSpace($serveOn)) {
            $defaultGatewayAssociated = if ($serveOn -match "workspaceAndDefault") { "yes" } else { "no" }
            $associationSource = "workspace.properties.serveOn"
        }

        if ($gatewaysPreview.Succeeded -and $gatewaysPreview.Gateways.Count -gt 0) {
            $associatedGateways = $gatewaysPreview.Gateways
        }
    }
}

Write-Log -Level "INFO" -Message "Step 4 and 5: Checking workspace path form and API-to-gateway links"
$apiList = Get-WorkspaceApis -WorkspaceBaseUrl $workspaceBaseUrl -Version $ApiVersionPreview
$apiGatewayAssignments = @()
if ($apiList.Succeeded) {
    foreach ($api in $apiList.Apis) {
        $apiName = [string]$api.name
        if ([string]::IsNullOrWhiteSpace($apiName)) {
            continue
        }

        if ($managedV2Sku) {
            $apiGatewayAssignments += [pscustomobject]@{
                ApiName = $apiName
                Succeeded = $null
                Skipped = $true
                Gateways = @()
                Error = "Per-API gateway assignment subresource is not supported on SKU '$apimSkuName' for this managed workspace flow."
            }
        } else {
            $apiGatewayAssignments += Get-ApiGatewayAssignments -WorkspaceBaseUrl $workspaceBaseUrl -ApiName $apiName -Version $ApiVersionPreview
        }
    }
}

$urlProbe = $null
if (-not [string]::IsNullOrWhiteSpace($GatewayUrl) -and -not [string]::IsNullOrWhiteSpace($ApiPath) -and -not [string]::IsNullOrWhiteSpace($ProbePath)) {
    $normalizedApiPath = $ApiPath.Trim('/')
    $normalizedProbePath = if ($ProbePath.StartsWith('/')) { $ProbePath } else { "/$ProbePath" }
    $rootUrl = $GatewayUrl.TrimEnd('/') + "/" + $normalizedApiPath + $normalizedProbePath
    $workspaceUrl = $GatewayUrl.TrimEnd('/') + "/workspaces/" + $WorkspaceId + "/" + $normalizedApiPath + $normalizedProbePath

    $urlProbe = [pscustomobject]@{
        RootGatewayPathProbe = Invoke-UrlProbe -Url $rootUrl
        WorkspacePathProbe = Invoke-UrlProbe -Url $workspaceUrl
    }
}

Write-Log -Level "INFO" -Message "Step 6: Capturing provisioning state and deployment-window failures"
$provisioningState = $null
if ($workspacePreview.Succeeded -and $workspacePreview.Resource) {
    $provisioningState = [string]$workspacePreview.Resource.properties.provisioningState
}
if ([string]::IsNullOrWhiteSpace($provisioningState) -and $workspaceGa.Succeeded -and $workspaceGa.Resource) {
    $provisioningState = [string]$workspaceGa.Resource.properties.provisioningState
}

$associationInference = $null
if ($fixResult -and $fixResult.Success -and $defaultGatewayAssociated -eq "unknown") {
    $associationInference = "put-succeeded-arm-field-not-returned"
}

$summary = @()
if ($defaultGatewayAssociated -eq "yes") {
    $summary += "Workspace appears associated with the default managed gateway (serveOn includes workspaceAndDefault)."
} elseif ($defaultGatewayAssociated -eq "no") {
    $summary += "Workspace does not appear associated with the default managed gateway."
} else {
    if ($managedV2Sku) {
        $summary += "ARM does not expose a reliable default-gateway association field for this managed workspace flow on SKU '$apimSkuName'."
    } else {
        $summary += "Could not determine default gateway association from ARM fields."
    }
    if ($associationInference -eq "put-succeeded-arm-field-not-returned") {
        $summary += "Explicit workspace PUT succeeded, so the default gateway association was likely applied even though ARM GET did not return serveOn or gateway membership fields."
    }
}

if ($urlProbe) {
    $rootStatus = if ($urlProbe.RootGatewayPathProbe.StatusCode) { $urlProbe.RootGatewayPathProbe.StatusCode } else { "no-status" }
    $wsStatus = if ($urlProbe.WorkspacePathProbe.StatusCode) { $urlProbe.WorkspacePathProbe.StatusCode } else { "no-status" }
    $summary += "Root-path probe status=$rootStatus; workspace-path probe status=$wsStatus."
}

if ($failedEvents.Count -gt 0) {
    $summary += "Activity log contains failed events in the selected time window."
}

if ($fixResult -and $fixResult.Success) {
    $summary += "Explicit PUT association update succeeded."
} elseif ($FixDefaultGatewayAssociation) {
    $summary += "Explicit PUT association update failed."
    if ($fixResult -and $fixResult.Error) {
        $summary += ("Fix failure detail: " + $fixResult.Error)
    }
}

$apiGatewayFailures = @($apiGatewayAssignments | Where-Object { $_.Succeeded -eq $false -and -not $_.Skipped })
if ($apiGatewayFailures.Count -gt 0) {
    $summary += ("One or more workspace API gateway-assignment checks failed: " + (($apiGatewayFailures | ForEach-Object { $_.ApiName }) -join ", ") + ".")
}

$apiGatewaySkipped = @($apiGatewayAssignments | Where-Object { $_.Skipped })
if ($apiGatewaySkipped.Count -gt 0) {
    $summary += ("Per-API gateway assignment subresource checks are unsupported on SKU '$apimSkuName' for this managed workspace flow.")
}

$report = [pscustomobject]@{
    TimestampUtc = (Get-Date).ToUniversalTime().ToString("o")
    SubscriptionId = $SubscriptionId
    ResourceGroupName = $effectiveResourceGroup
    ApimName = $ApimName
    ApimSkuName = $apimSkuName
    WorkspaceId = $WorkspaceId
    WorkspaceResourceId = $workspaceResourceId
    ApiVersionsChecked = [pscustomobject]@{
        Preview = $ApiVersionPreview
        Ga = $ApiVersionGa
    }
    WorkspaceRead = [pscustomobject]@{
        Preview = $workspacePreview
        Ga = $workspaceGa
    }
    Association = [pscustomobject]@{
        DefaultGatewayAssociated = $defaultGatewayAssociated
        Source = $associationSource
        ServeOn = $serveOn
        WorkspaceGateways = $associatedGateways
        Inference = $associationInference
        GatewayListCheck = $gatewaysPreview
    }
    FixAttempt = $fixResult
    ProvisioningState = $provisioningState
    ActivityLog = [pscustomobject]@{
        LookbackHours = $ActivityLogHours
        ReadSucceeded = $activity.Succeeded
        ReadError = $activity.Error
        WorkspaceWriteEvents = @($workspaceWriteEvents | Select-Object -First 20 | ForEach-Object {
            [pscustomobject]@{
                EventTimestamp = $_.eventTimestamp
                Caller = $_.caller
                Operation = $_.operationName.localizedValue
                Status = $_.status.localizedValue
                CorrelationId = $_.correlationId
                SubStatus = if ($_.subStatus) { $_.subStatus.localizedValue } else { $null }
            }
        })
        FailedEvents = @($failedEvents | Select-Object -First 20 | ForEach-Object {
            [pscustomobject]@{
                EventTimestamp = $_.eventTimestamp
                Caller = $_.caller
                Operation = $_.operationName.localizedValue
                Status = $_.status.localizedValue
                CorrelationId = $_.correlationId
            }
        })
        InferredCreateSource = $inferredCreateSource
        Note = "Activity logs usually do not expose REST api-version directly; use correlation IDs and deployment records for deeper forensic tracing."
    }
    ApiGatewayAssignments = [pscustomobject]@{
        ApiListSucceeded = $apiList.Succeeded
        ApiListError = $apiList.Error
        ApiCount = if ($apiList.Succeeded) { @($apiList.Apis).Count } else { $null }
        PerApi = $apiGatewayAssignments
    }
    UrlPathValidation = $urlProbe
    Summary = $summary
    LogFile = $LogFile
    ReportPath = $ReportPath
}

$report | ConvertTo-Json -Depth 16 | Set-Content -Path $ReportPath -Encoding UTF8

Write-Log -Level "INFO" -Message "Diagnosis complete."
Write-Output ""
Write-Output "===== Workspace Gateway Diagnosis Summary ====="
foreach ($line in $summary) {
    Write-Output ("- " + $line)
}
$provisioningStateDisplay = if ([string]::IsNullOrWhiteSpace($provisioningState)) { "not-returned-by-arm" } else { $provisioningState }
Write-Output ("ProvisioningState: " + $provisioningStateDisplay)
Write-Output ("ReportPath: " + $ReportPath)
Write-Output ("LogFile: " + $LogFile)

# Ensure wrapper callers do not inherit an internal az command exit code.
$global:LASTEXITCODE = 0

$report
