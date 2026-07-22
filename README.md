# APIM Workspace Automation and Runtime Validation

This repository contains PowerShell automation and a sample .NET API for working with Azure API Management (APIM) workspaces.

## Repository Layout

- scripts: APIM workspace deployment, diagnostics, role-assignment, and local web wizard.
- weather-api: sample ASP.NET Core API used for runtime validation.

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7+
- Azure CLI (`az`) authenticated to your target tenant and subscription
- .NET SDK 10.0+ (for `weather-api`)

Optional but recommended:

- Docker Desktop (for containerized local testing)

## Quick Start

1. Validate prerequisites:

```powershell
.\scripts\check-prereqs.ps1
```

1. Start the local web wizard:

```powershell
.\scripts\apim-workspace-wizard-web.ps1
```

1. Or run direct deployment flow:

```powershell
.\scripts\manage-apim-workspace.ps1 `
  -Mode create-default `
  -SubscriptionId "<sub-id>" `
  -ApimName "<apim-name>" `
  -WorkspaceId "<workspace-id>"
```

1. Optional workspace role assignment during deploy:

```powershell
.\scripts\manage-apim-workspace.ps1 `
  -Mode create-default `
  -SubscriptionId "<sub-id>" `
  -ApimName "<apim-name>" `
  -WorkspaceId "<workspace-id>" `
  -WorkspaceRoleAssignments "me|API Management Workspace API Developer|User"
```

1. Verify workspace runtime:

```powershell
.\scripts\manage-apim-workspace.ps1 `
  -Mode verify-runtime `
  -SubscriptionId "<sub-id>" `
  -ApimName "<apim-name>" `
  -WorkspaceId "<workspace-id>" `
  -ApiId "weather-api-cw11" `
  -ApiPath "weather-cw11" `
  -ProbePath "/weather/seattle" `
  -ExpectedStatusCodes 200 `
  -CollectDiagnostics
```

## Build and Run Weather API

```powershell
Set-Location .\weather-api
dotnet restore
dotnet build -c Release
dotnet run
```

Default local endpoint:

- [https://localhost:7109/weather/seattle](https://localhost:7109/weather/seattle)

## Script Documentation

Detailed script usage is documented in:

- scripts/README.md

## Open Source Standards

This repository includes standard governance files:

- LICENSE
- CODE_OF_CONDUCT.md
- CONTRIBUTING.md
- SECURITY.md
- SUPPORT.md
- .editorconfig
- .gitignore
