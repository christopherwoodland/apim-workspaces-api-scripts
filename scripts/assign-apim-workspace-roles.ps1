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
    [string[]]$WorkspaceRoleAssignments,

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
    $outputText = ""
    if ($null -ne $output) {
        $outputText = ($output -join "`n")
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Log -Level "ERROR" -Message "Azure CLI command failed with exit code $LASTEXITCODE"
        if (-not [string]::IsNullOrWhiteSpace($outputText)) {
            throw "Azure CLI command failed: az $($displayArgs -join ' ')`n$outputText"
        }

        throw "Azure CLI command failed: az $($displayArgs -join ' ')"
    }

    if ($null -eq $output) {
        return $null
    }

    return $outputText
}

function Get-SignedInUserContext {
    $principalId = $null
    $principalUpn = $null

    try {
        $accountJson = Invoke-AzCli -Args @("account", "show", "-o", "json") -ReadOnly
        if (-not [string]::IsNullOrWhiteSpace($accountJson)) {
            $account = $accountJson | ConvertFrom-Json
            if ($account.user -and $account.user.name) {
                $principalUpn = [string]$account.user.name
            }
        }
    } catch {
        Write-Log -Level "WARN" -Message "Unable to read account context: $($_.Exception.Message)"
    }

    try {
        $meJson = Invoke-AzCli -Args @("ad", "signed-in-user", "show", "--query", "{id:id,userPrincipalName:userPrincipalName}", "-o", "json") -ReadOnly
        if (-not [string]::IsNullOrWhiteSpace($meJson)) {
            $me = $meJson | ConvertFrom-Json
            if ($me.id) {
                $principalId = [string]$me.id
            }
            if ($me.userPrincipalName) {
                $principalUpn = [string]$me.userPrincipalName
            }
        }
    } catch {
        Write-Log -Level "WARN" -Message "Unable to resolve signed-in user object ID."
    }

    return [pscustomobject]@{
        ObjectId = $principalId
        UserPrincipalName = $principalUpn
    }
}

function Resolve-PrincipalObjectId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PrincipalInput,

        [Parameter()]
        [object]$SignedInUser
    )

    if ($PrincipalInput -match '^[0-9a-fA-F-]{36}$') {
        return $PrincipalInput
    }

    if ($PrincipalInput -eq "me" -or $PrincipalInput -eq "signed-in-user") {
        if ([string]::IsNullOrWhiteSpace($SignedInUser.ObjectId)) {
            throw "Could not resolve signed-in user object ID for principal token '$PrincipalInput'."
        }

        return $SignedInUser.ObjectId
    }

    if ($PrincipalInput -match '@') {
        $resolvedId = Invoke-AzCli -Args @("ad", "user", "show", "--id", $PrincipalInput, "--query", "id", "-o", "tsv") -ReadOnly
        if ([string]::IsNullOrWhiteSpace($resolvedId)) {
            throw "Could not resolve principal '$PrincipalInput' to an Entra object ID in the current tenant."
        }

        return $resolvedId.Trim()
    }

    return $PrincipalInput
}

function Parse-WorkspaceRoleAssignment {
    param([string]$Spec)

    if ([string]::IsNullOrWhiteSpace($Spec)) {
        throw "WorkspaceRoleAssignments contains an empty value."
    }

    $parts = $Spec.Split('|')
    if ($parts.Length -lt 2 -or $parts.Length -gt 3) {
        throw "Invalid role assignment format '$Spec'. Use: <principalObjectId>|<roleDefinitionName>|<principalType-optional>"
    }

    $principalObjectId = $parts[0].Trim()
    $roleDefinitionName = $parts[1].Trim()
    $principalType = $null

    if ($parts.Length -eq 3) {
        $principalType = $parts[2].Trim()
    }

    if ([string]::IsNullOrWhiteSpace($principalObjectId) -or [string]::IsNullOrWhiteSpace($roleDefinitionName)) {
        throw "Invalid role assignment format '$Spec'. Principal object ID and role name are required."
    }

    if ($principalType -and @("User", "Group", "ServicePrincipal", "ForeignGroup", "Device") -notcontains $principalType) {
        throw "Invalid principalType '$principalType' in '$Spec'. Allowed values: User, Group, ServicePrincipal, ForeignGroup, Device."
    }

    return [pscustomobject]@{
        PrincipalObjectId = $principalObjectId
        RoleDefinitionName = $roleDefinitionName
        PrincipalType = $principalType
    }
}

Test-ToolAvailable -Name "az"
Write-Log -Level "INFO" -Message "Run started. Log file: $LogFile"

Invoke-AzCli -Args @("account", "set", "--subscription", $SubscriptionId) -ReadOnly | Out-Null

$workspaceScope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.ApiManagement/service/$ApimName/workspaces/$WorkspaceId"
$workspaceUrl = "https://management.azure.com${workspaceScope}?api-version=2024-05-01"
$signedInUser = Get-SignedInUserContext

$parsedAssignments = @($WorkspaceRoleAssignments | ForEach-Object { Parse-WorkspaceRoleAssignment -Spec $_ })

if ($WhatIfOnly) {
    Write-Log -Level "INFO" -Message "WhatIfOnly is enabled. Workspace role assignments were parsed and would be applied at scope: $workspaceScope"
    foreach ($assignment in $parsedAssignments) {
        Write-Log -Level "INFO" -Message ("WhatIf assignment: principal={0} role='{1}' principalType='{2}'" -f $assignment.PrincipalObjectId, $assignment.RoleDefinitionName, $assignment.PrincipalType)
    }

    Write-Log -Level "INFO" -Message "Workspace role assignment step completed in WhatIf mode."
    return
}

Write-Log -Level "INFO" -Message "Validating workspace scope exists: $workspaceScope"
Invoke-AzCli -Args @("rest", "--method", "get", "--url", $workspaceUrl, "-o", "none") -ReadOnly | Out-Null

Write-Log -Level "INFO" -Message "Applying $($parsedAssignments.Count) workspace role assignment(s)."

foreach ($assignment in $parsedAssignments) {
    $principalInput = $assignment.PrincipalObjectId
    $role = $assignment.RoleDefinitionName
    $principalType = $assignment.PrincipalType
    $principal = Resolve-PrincipalObjectId -PrincipalInput $principalInput -SignedInUser $signedInUser

    Write-Log -Level "INFO" -Message "Checking assignment: principal=$principal role='$role'"
    $existingId = Invoke-AzCli -Args @(
        "role", "assignment", "list",
        "--scope", $workspaceScope,
        "--assignee-object-id", $principal,
        "--query", "[?roleDefinitionName=='$role'].id | [0]",
        "-o", "tsv"
    ) -ReadOnly

    if (-not [string]::IsNullOrWhiteSpace($existingId)) {
        Write-Log -Level "INFO" -Message "Assignment already exists. Skipping create."
        continue
    }

    $createArgs = @(
        "role", "assignment", "create",
        "--scope", $workspaceScope,
        "--assignee-object-id", $principal,
        "--role", $role,
        "-o", "none"
    )

    if (-not [string]::IsNullOrWhiteSpace($principalType)) {
        $createArgs += @("--assignee-principal-type", $principalType)
    }

    try {
        Invoke-AzCli -Args $createArgs | Out-Null
        Write-Log -Level "INFO" -Message "Created assignment: principal=$principal role='$role'"
    } catch {
        $errorText = $_.Exception.Message
        $canFallbackToSignedInUser = (
            $principal -match '^[0-9a-fA-F-]{36}$' -and
            ($null -eq $principalType -or [string]::IsNullOrWhiteSpace($principalType) -or $principalType -eq "User") -and
            -not [string]::IsNullOrWhiteSpace($signedInUser.ObjectId) -and
            $signedInUser.ObjectId -ne $principal -and
            $errorText -match "PrincipalNotFound"
        )

        if (-not $canFallbackToSignedInUser) {
            throw
        }

        Write-Log -Level "WARN" -Message "Principal '$principalInput' was not found in current tenant. Retrying with signed-in user object ID '$($signedInUser.ObjectId)'."
        $createArgsFallback = @(
            "role", "assignment", "create",
            "--scope", $workspaceScope,
            "--assignee-object-id", $signedInUser.ObjectId,
            "--assignee-principal-type", "User",
            "--role", $role,
            "-o", "none"
        )
        Invoke-AzCli -Args $createArgsFallback | Out-Null
        Write-Log -Level "INFO" -Message "Created assignment with fallback signed-in principal: principal=$($signedInUser.ObjectId) role='$role'"
    }
}

Write-Log -Level "INFO" -Message "Workspace role assignment step completed successfully."