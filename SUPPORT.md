# Support

## How to Get Help

- For repository issues, open an issue in this project with:
  - clear reproduction steps
  - expected vs actual behavior
  - relevant logs from scripts/logs
- For Azure platform/service incidents, open an Azure Support request in the Azure Portal.

## Troubleshooting First

1. Run:

```powershell
.\scripts\check-prereqs.ps1
```

1. Validate subscription and tenant context:

```powershell
az account show
```

1. Re-run failing command with `-Verbose` when supported.
1. Attach the latest log file from scripts/logs.

## Security Issues

For security vulnerabilities, follow SECURITY.md and report directly to MSRC.
