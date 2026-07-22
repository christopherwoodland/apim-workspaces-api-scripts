# APIM Workspace Deployment Scripts

This folder contains Azure CLI PowerShell scripts for deploying and verifying Azure API Management workspaces.

## Recommended Entry Point

Use `manage-apim-workspace.ps1` as the customer-facing entry point.

For guided usage, run `apim-workspace-wizard-web.ps1` and use the local browser-based wizard on localhost.

- `create-dedicated` is the recommended path for the most predictable customer-facing runtime setup.
- `create-default` creates the workspace and requests use of the service's default managed gateway (v2 tiers only, REST API path), but you should still validate runtime through APIM after adding APIs.
- `verify` confirms the workspace exists in ARM with the expected display name and description.
- `verify-runtime` validates the APIM gateway probe for a workspace API path and reports status/body preview.
- `verify-runtime` with `-CollectDiagnostics` writes a troubleshooting JSON report with APIM workspace/API/gateway state, API operations, and product-link checks.

Quick start:

```powershell
# Validate prerequisites
.\scripts\check-prereqs.ps1

# Local web wizard (localhost)
.\scripts\apim-workspace-wizard-web.ps1

# Recommended: dedicated workspace flow
.\scripts\manage-apim-workspace.ps1 `
  -Mode create-dedicated `
  -SubscriptionId "<sub-id>" `
  -ApimName "intapim001" `
  -WorkspaceId "team-a"

# Dedicated flow + post-deploy workspace RBAC assignments
.\scripts\manage-apim-workspace.ps1 `
  -Mode create-dedicated `
  -SubscriptionId "<sub-id>" `
  -ApimName "intapim001" `
  -WorkspaceId "team-a" `
  -WorkspaceRoleAssignments `
    "<principalObjectId-1>|API Management Workspace API Developer|User", `
    "<principalObjectId-2>|API Management Workspace API Product Manager|Group"

# Default-gateway request flow
.\scripts\manage-apim-workspace.ps1 `
  -Mode create-default `
  -SubscriptionId "<sub-id>" `
  -ApimName "intapim001" `
  -WorkspaceId "team-a"

# Default-gateway flow + workspace RBAC assignments
.\scripts\manage-apim-workspace.ps1 `
  -Mode create-default `
  -SubscriptionId "<sub-id>" `
  -ApimName "intapim001" `
  -WorkspaceId "team-a" `
  -WorkspaceRoleAssignments "<principalObjectId>|API Management Workspace API Developer|User"

# Verification
.\scripts\manage-apim-workspace.ps1 `
  -Mode verify `
  -SubscriptionId "<sub-id>" `
  -ApimName "intapim001" `
  -WorkspaceId "team-a"

# Runtime verification through APIM gateway
.\scripts\manage-apim-workspace.ps1 `
  -Mode verify-runtime `
  -SubscriptionId "<sub-id>" `
  -ApimName "intapim001" `
  -WorkspaceId "team-a" `
  -GatewayUrl "https://<gateway-hostname>" `
  -ApiPath "weather" `
  -ProbePath "/weather/seattle" `
  -ExpectedStatusCodes 200

# Runtime verification with diagnostics report
.\scripts\manage-apim-workspace.ps1 `
  -Mode verify-runtime `
  -SubscriptionId "<sub-id>" `
  -ApimName "intapim001" `
  -WorkspaceId "team-a" `
  -ApiPath "weather" `
  -ProbePath "/weather/seattle" `
  -ExpectedStatusCodes 200 `
  -CollectDiagnostics
```

## Run the Local Web UI

Run from repository root:

```powershell
Set-Location C:\Users\cwoodland\dev\apim
.\scripts\check-prereqs.ps1
.\scripts\apim-workspace-wizard-web.ps1
```

UI address:

- [http://localhost:5077](http://localhost:5077)

Optional flags:

```powershell
# Change listening port
.\scripts\apim-workspace-wizard-web.ps1 -Port 5080

# Start server without opening browser
.\scripts\apim-workspace-wizard-web.ps1 -NoBrowser
```

Stop the server:

- Press Ctrl+C in the terminal where the script is running.

Common startup issues:

- Port already in use: start with `-Port 5080` (or another free port).
- Azure CLI not signed in: run `az login` first.
- Missing permissions for subscription/APIM reads: ensure your account has at least Reader on target scope.

## Files

- apim-workspace-wizard-web.ps1
  - Starts a local HTTP server on `http://localhost:5077` and hosts the web wizard UI.
  - Serves `scripts/web/index.html`, `scripts/web/styles.css`, and `scripts/web/app.js`.
  - Exposes local API endpoints for subscriptions/APIM loading and workspace execution.
  - Provides detailed execution output in the browser including run summary, argument traces, elapsed-time updates, script output, and completion timing.
  - Shows live validation status in the Output header (`Not started`, `Running`, `Passed`, `Failed`) while actions execute.
  - Writes validation lifecycle lines directly into Output logs (`Validation status: Running/Passed/Failed`) for both wizard runs and workspace runtime checks.
  - Prints resolved URLs at completion when available (Workspace Portal URL, Workspace ARM URL, APIM Gateway URL, and Runtime URL).
  - Runtime URL fallback behavior: for create/verify flows without a concrete probe path, Runtime URL falls back to the gateway base URL.
  - Supports optional auto-run of `verify-runtime` after successful create modes with configurable retry interval and timeout.
  - Includes a `Workspaces` tab to list existing APIM workspaces, run per-workspace `Check Runtime`, and delete a selected workspace.
  - Workspace inventory includes columns for `State`, `State Source`, and `Associated Gateways` plus a Portal URL link per workspace.
  - `State` and `Associated Gateways` use ARM metadata from list responses with detail fallback; if ARM does not return a value, the UI shows `unknown` / `not-returned-by-arm`.
  - Persists last-used selections and inputs to `.apim-workspace-wizard-web.settings.json`.
  - Stop with Ctrl+C in the terminal where the server is running.
- create-echo-workspace-api.ps1
  - Deploys/imports a sample Echo API into a workspace for quick smoke testing.
  - Defaults to `https://postman-echo.com` backend and optional test product creation.
- manage-apim-workspace.ps1
  - Simplified wrapper for customer use across default, dedicated, and verification flows.
  - When `-WorkspaceRoleAssignments` is provided during `create-default` or `create-dedicated`, it runs a post-deploy workspace RBAC assignment step.
- assign-apim-workspace-roles.ps1
  - Assigns Azure RBAC roles at APIM workspace scope.
  - Input format: `-WorkspaceRoleAssignments "<principalObjectId-or-UPN-or-me>|<roleDefinitionName>|<principalType-optional>"`
  - `principalType` allowed values: `User`, `Group`, `ServicePrincipal`, `ForeignGroup`, `Device`.
  - Existing assignments are detected and skipped.
  - If a user principal object ID is not found in the current tenant, the script retries with the current signed-in user's object ID and logs a warning.
- deploy-apim-workspace-default.ps1
  - Creates or updates a workspace in APIM with a request to use the default managed gateway.
  - Enforces documented v2-only requirement for default gateway association (`serveOn=workspaceAndDefault`).
  - Verifies control-plane creation only. Validate runtime separately after adding APIs.
- deploy-apim-workspace-dedicated.ps1
  - Prepares dedicated networking (VNet, subnet delegation, NSG rules) and creates/updates workspace.
  - Prints next steps to complete supported workspace gateway association.
- verify-apim-workspace.ps1
  - Verifies workspace state independently (name, displayName, description) with retries.
- verify-apim-workspace-runtime.ps1
  - Verifies workspace runtime reachability through a gateway URL and validates expected HTTP status code.
  - If `-GatewayUrl` is not supplied, the service default gateway URL is used.
  - Optional diagnostics report captures APIM service state, workspace metadata, API metadata, API operations, product inventory, product-link checks, and probe details.
- diagnose-apim-workspace-gateway.ps1
  - Runs an end-to-end default-gateway diagnosis for a workspace and writes a JSON report.
  - Confirms whether the workspace shows default-gateway association fields (`serveOn`, workspace gateways), captures provisioning state, inspects Activity Log write/failure events, checks per-API gateway links, and optionally probes both root and workspace-scoped runtime URLs.
  - Optional remediation: `-FixDefaultGatewayAssociation` issues an explicit workspace Create-or-Update (`PUT`) with `serveOn=workspaceAndDefault`, then re-checks association state.
- verify-weather-api.ps1
  - Checks the live weather API health and sample weather endpoint.
- apim-workspace-cli.ps1
  - Unified command-line interface for workspace operations (APIs, products, subscriptions, and generic REST calls).
- check-prereqs.ps1
  - Validates local prerequisites (PowerShell, Azure CLI login context, .NET SDK, and required scripts).

## Logging

- All scripts write detailed timestamped logs to `scripts/logs` by default.
- Override with `-LogDirectory`.
- Logs include command traces, command outputs, verification polling, and errors.
- For detailed command traces in console, run scripts with `-Verbose`.
- To remove all historical logs: `Remove-Item .\scripts\logs\* -Force`

## Advanced Usage

Default mode:

```powershell
.\scripts\deploy-apim-workspace-default.ps1 `
  -SubscriptionId "<sub-id>" `
  -ApimName "intapim001" `
  -WorkspaceId "team-a-ws" `
  -DisplayName "Team A Workspace"
```

Dedicated mode (integration):

```powershell
.\scripts\deploy-apim-workspace-dedicated.ps1 `
  -SubscriptionId "<sub-id>" `
  -ApimName "intapim001" `
  -WorkspaceId "team-a-ws-dedicated" `
  -DisplayName "Team A Dedicated Workspace" `
  -NetworkResourceGroup "rg-apim-network" `
  -Location "eastus" `
  -NetworkMode "integration"
```

Standalone verification:

```powershell
.\scripts\verify-apim-workspace.ps1 `
  -SubscriptionId "<sub-id>" `
  -ApimName "intapim001" `
  -WorkspaceId "team-a-ws" `
  -DisplayName "Team A Workspace" `
  -Description "Workspace using default managed gateway"
```

Workspace CLI examples:

```powershell
# Show workspace
.\scripts\apim-workspace-cli.ps1 `
  -Command show-workspace `
  -SubscriptionId "<sub-id>" `
  -ResourceGroupName "integration" `
  -ApimName "intapim001" `
  -WorkspaceId "cw-wp-001"

# List workspace APIs
.\scripts\apim-workspace-cli.ps1 `
  -Command list-apis `
  -SubscriptionId "<sub-id>" `
  -ResourceGroupName "integration" `
  -ApimName "intapim001" `
  -WorkspaceId "cw-wp-001"

# Create API from OpenAPI URL
.\scripts\apim-workspace-cli.ps1 `
  -Command create-api `
  -SubscriptionId "<sub-id>" `
  -ResourceGroupName "integration" `
  -ApimName "intapim001" `
  -WorkspaceId "cw-wp-001" `
  -ApiId "orders-api" `
  -ApiDisplayName "Orders API" `
  -ApiPath "orders" `
  -ApiOpenApiSpecUrl "https://example.com/openapi.json"

# Create product
.\scripts\apim-workspace-cli.ps1 `
  -Command create-product `
  -SubscriptionId "<sub-id>" `
  -ResourceGroupName "integration" `
  -ApimName "intapim001" `
  -WorkspaceId "cw-wp-001" `
  -ProductId "starter" `
  -ProductDisplayName "Starter" `
  -ProductDescription "Starter tier"

# Add API to product
.\scripts\apim-workspace-cli.ps1 `
  -Command add-api-to-product `
  -SubscriptionId "<sub-id>" `
  -ResourceGroupName "integration" `
  -ApimName "intapim001" `
  -WorkspaceId "cw-wp-001" `
  -ProductId "starter" `
  -ApiId "orders-api"
```

Weather API validation:

```powershell
.\scripts\verify-weather-api.ps1

# APIM gateway runtime validation (direct script)
.\scripts\verify-apim-workspace-runtime.ps1 `
  -SubscriptionId "<sub-id>" `
  -ApimName "intapim001" `
  -WorkspaceId "cw-wp-001" `
  -GatewayUrl "https://<gateway-hostname>" `
  -ApiPath "weather" `
  -ProbePath "/weather/seattle" `
  -ExpectedStatusCodes 200 `
  -CollectDiagnostics `
  -DiagnosticsOutputPath ".\scripts\logs\runtime-diagnostics.json"

# Diagnose workspace default-gateway association and path routing
.\scripts\diagnose-apim-workspace-gateway.ps1 `
  -SubscriptionId "<sub-id>" `
  -ApimName "intapim001" `
  -WorkspaceId "cw-wp-001" `
  -GatewayUrl "https://<gateway-hostname>" `
  -ApiPath "weather" `
  -ProbePath "/weather/seattle"

# Same diagnosis, plus explicit PUT remediation to set serveOn=workspaceAndDefault
.\scripts\diagnose-apim-workspace-gateway.ps1 `
  -SubscriptionId "<sub-id>" `
  -ApimName "intapim001" `
  -WorkspaceId "cw-wp-001" `
  -FixDefaultGatewayAssociation
```

## Notes

- Scripts validate APIM SKU against workspace-supported tiers.
- Dedicated mode checks that APIM region matches the provided network location.
- Use `-WhatIfOnly` to print commands without executing mutating actions.
- Scripts include deployment verification with retry and fail if the workspace isn't readable with expected values.
- Override verification wait time using `-VerificationTimeoutSeconds` (default: 180).
- Override log output location using `-LogDirectory`.
- The earlier Container Apps startup-probe failure was tied to an older failed revision; the current active revision is healthy and listening on port 80.
- In this repo's current state, workspace control-plane creation is working, but APIM runtime through the default hostname should still be validated after API import.
- Dedicated workspace gateway creation/association is a portal-driven, long-running deployment and is the documented runtime path when not using default managed gateway association.
- Use `verify-runtime` after each workspace API import/update to catch routing issues early.
- Use `verify-runtime -CollectDiagnostics` when runtime checks fail to produce a support-ready JSON diagnostic report.

### Workspace state in the Web Wizard

- The `Workspaces` tab `State` column reflects ARM-reported workspace state when available.
- The `State Source` column shows where the value came from (`list.properties.provisioningState`, `detail.properties.state`, etc.).
- If no state property is returned by ARM for that workspace, the UI shows `unknown` and source `not-returned-by-arm`.

### Associated gateways in the Web Wizard

- The `Associated Gateways` column only shows explicit workspace gateway associations returned by ARM.
- For default-hostname runtime paths, it is normal for this value to remain empty in ARM; the UI displays `not-returned-by-arm`.
- Use `Check Runtime` (row action) or `verify-runtime` to validate end-to-end request path readiness through APIM gateway URLs.
